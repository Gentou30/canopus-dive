class_name Tactics
extends RefCounted

## 1回の潜水（ラン）の状態とルール。画面とは切り離してあり、balance_sim からも使う。
## ターン制の潜入カードゲーム（メタルギア アシッド風）。
##   自分のターン：手札（5枚まで）から2回まで行動。カードは「わざ」か「泳ぐ（左上の数字マス）」として使う。
##   敵のターン：見張りが巡回し、扇形の視界にカノープスが入ると見つかる（！）。見つかると追ってきて攻撃する。
##   空気：カードのコストとターン終了ごとに減る。0なら代わりに体力が減る。
## 行動の結果は events（辞書の配列）で返し、画面側はそれを順に演出する。
##   {t:"move", id, path}  {t:"face", id, dir}  {t:"attack", id, to}  {t:"hit", id, dmg, sneak, wall}
##   {t:"die", id}  {t:"push", id, to}  {t:"stun", id}  {t:"phit", id, dmg, blocked}
##   {t:"spot", id}（見つかった）{t:"hear", id, at}（音を聞いた）{t:"lost", id}（見失った）{t:"calm", id}
##   {t:"noise", at}  {t:"hide"}  {t:"shield"}  {t:"heal", n}  {t:"air", n}  {t:"draw", n}  {t:"reshuffle"}
##   {t:"pickup", item, at}  {t:"chest", at}  {t:"exit"}  {t:"faint"}  {t:"suffocate"}

const W := 9
const H := 13
const DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const STAGES := 3

const MAX_HP := 12
const MAX_AIR := 40
const HAND := 5
const PLAYS := 2
const ALERT_RADIUS := 4   # 見つかったとき、仲間に知らせる距離
const LOSE_TURNS := 2     # 見えない状態がこれだけ続くと見失う

enum { FLOOR, ROCK, WEED }

## sight: 視界の奥行き（0 は見ない） speed: 巡回の速さ  aspeed: 追うときの速さ
## move: "patrol" 往復 / "sentry" その場で向きを変える / "fixed" 動かない / "drift" ふらふら
const ENEMIES := {
	"fugu": {"name": "フグ", "hp": 2, "atk": 1, "sight": 3, "speed": 1, "aspeed": 2, "move": "patrol"},
	"kurage": {"name": "クラゲ", "hp": 1, "atk": 1, "sight": 0, "speed": 1, "aspeed": 1, "move": "drift"},
	"ankou": {"name": "アンコウ", "hp": 3, "atk": 2, "sight": 4, "speed": 0, "aspeed": 1, "move": "sentry"},
	"kani": {"name": "オオガニ", "hp": 4, "atk": 2, "sight": 2, "speed": 1, "aspeed": 2, "move": "patrol"},
	"utsubo": {"name": "ウツボ", "hp": 3, "atk": 2, "sight": 2, "speed": 0, "aspeed": 0, "move": "fixed"},
	"same": {"name": "サメ", "hp": 6, "atk": 3, "sight": 4, "speed": 1, "aspeed": 3, "move": "patrol"},
}

## 階ごとの敵
const STAGE_ENEMIES := [
	["fugu", "fugu", "ankou", "kurage"],
	["fugu", "fugu", "kani", "utsubo", "ankou", "kurage"],
	["same", "kani", "fugu", "fugu", "ankou", "utsubo", "kurage"],
]

var rng := RandomNumberGenerator.new()

# ラン全体
var stage := 1
var hp := MAX_HP
var max_hp := MAX_HP
var air := MAX_AIR
var deck: Array[String] = []
var hand: Array[String] = []
var discard: Array[String] = []
var exhausted: Array[String] = []
var owned: Array[String] = []        # デッキ全体（山札・手札・捨て札・使い切り）
var kills := 0
var spotted_total := 0
var turn := 0

# 階
var tiles := PackedInt32Array()
var items := {}      # Vector2i -> "chest" / "pearl" / "vent" / "exit"
var units := []      # 0 番がカノープス。敵は {id, kind, pos, dir, hp, max_hp, atk, sight, speed, aspeed, move,
                     #   state, route, ri, rstep, last_seen, lost, stun, invest, wait}
var plays_left := PLAYS
var hidden := false
var shield := 0
var spotted := 0     # この階で見つかった回数
var cleared := false
var exited := false
var _next_id := 1


func _init(seed_value: int = -1) -> void:
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	for c in Cards.START_DECK:
		owned.append(c)


# ───────── 階づくり ─────────

func start_stage() -> Array:
	turn = 0
	spotted = 0
	exited = false
	hidden = false
	shield = 0
	air = MAX_AIR
	_build_map()
	deck = owned.duplicate()
	_shuffle(deck)
	hand.clear()
	discard.clear()
	exhausted.clear()
	var ev := []
	_begin_turn(ev)
	return ev


func _build_map() -> void:
	for attempt in 200:
		if _try_build():
			return
	push_error("map build failed")


func _try_build() -> bool:
	tiles = PackedInt32Array()
	tiles.resize(W * H)
	tiles.fill(FLOOR)
	items.clear()
	units.clear()
	_next_id = 1
	var start := Vector2i(W / 2, 0)
	var exit := Vector2i(rng.randi_range(1, W - 2), H - 1)
	# 遺跡の壁：横に2本。すき間（1〜2マス）を2か所あけて、見張りの通り道にする
	for row in [4, 8]:
		var r: int = row + rng.randi_range(0, 1)
		var gaps := []
		var g1 := rng.randi_range(0, 3)
		var g2 := rng.randi_range(5, W - 1)
		gaps.append(g1)
		gaps.append(g2)
		if rng.randf() < 0.5:
			gaps.append(mini(g1 + 1, W - 1))
		for x in W:
			if not x in gaps:
				_put(Vector2i(x, r), ROCK)
	# 岩
	for i in rng.randi_range(6, 10):
		var p := Vector2i(rng.randi_range(0, W - 1), rng.randi_range(2, H - 2))
		_put(p, ROCK)
		if rng.randf() < 0.4:
			var q: Vector2i = p + DIRS[rng.randi() % 4]
			if inside(q) and q.y >= 2:
				_put(q, ROCK)
	# 海藻のしげみ
	for i in rng.randi_range(3, 5):
		var p := Vector2i(rng.randi_range(0, W - 1), rng.randi_range(1, H - 2))
		for k in rng.randi_range(2, 4):
			if inside(p) and tile(p) == FLOOR:
				_put(p, WEED)
			p += DIRS[rng.randi() % 4]
	# スタートのまわりと出口は空ける
	for d in [Vector2i.ZERO, Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(1, 1)]:
		if inside(start + d):
			_put(start + d, FLOOR)
	_put(exit, FLOOR)
	_put(exit + Vector2i(0, -1), FLOOR)
	if _path(start, exit, false).is_empty():
		return false
	# どこからでも出口へ行けるか（閉じた部屋は岩で埋める）
	var reach := _flood(start)
	for p in all_cells():
		if tile(p) != ROCK and not reach.has(p):
			_put(p, ROCK)
	items[exit] = "exit"
	units.append({"id": 0, "kind": "canopus", "pos": start, "dir": Vector2i(0, 1), "hp": hp})
	# 物：宝箱（遠い所）、真珠、空気の泡
	var free := []
	for p in all_cells():
		if tile(p) != ROCK and p != exit and _dist(p, start) >= 3:
			free.append(p)
	_shuffle(free)
	free.sort_custom(func(a, b): return _far_score(a, start, exit) > _far_score(b, start, exit))
	var chests := 1 if stage == 1 else 2
	var placed := 0
	for p in free:
		if placed >= chests:
			break
		if _near_item(p, 3):
			continue
		items[p] = "chest"
		placed += 1
	_shuffle(free)
	for it in ["pearl", "vent"]:
		for p in free:
			if not items.has(p) and not _near_item(p, 2) and p.y >= 3:
				items[p] = it
				break
	# 敵
	for kind in STAGE_ENEMIES[mini(stage, STAGES) - 1]:
		if not _place_enemy(kind, start):
			return false
	return true


func _far_score(p: Vector2i, start: Vector2i, exit: Vector2i) -> int:
	# 宝箱はスタートからも出口への道からも離れた所に置く（寄り道する価値をつくる）
	return mini(_dist(p, start), 8) + abs(p.x - exit.x) * 2


func _near_item(p: Vector2i, r: int) -> bool:
	for q in items:
		if _dist(p, q) < r:
			return true
	return false


func _place_enemy(kind: String, start: Vector2i) -> bool:
	var d: Dictionary = ENEMIES[kind]
	for attempt in 60:
		var p := Vector2i(rng.randi_range(0, W - 1), rng.randi_range(3, H - 1))
		if tile(p) == ROCK or unit_at(p) != null or items.has(p) or _dist(p, start) < 5:
			continue
		var route := [p]
		var dir: Vector2i = DIRS[rng.randi() % 4]
		if d.move == "patrol":
			# まっすぐ2〜4マス往復する。横向きを多めに
			var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
			dir = dirs[rng.randi() % dirs.size()]
			var len := rng.randi_range(2, 4)
			var q := p
			for i in len:
				q += dir
				if not walkable_tile(q) or items.get(q, "") == "exit" or unit_at(q) != null:
					break
				route.append(q)
			if route.size() < 3:
				continue
		elif d.move == "fixed":
			# ウツボは壁を背にして、ひらけた方を向く
			var open := []
			for dd in DIRS:
				if walkable_tile(p + dd):
					open.append(dd)
			if open.is_empty():
				continue
			dir = open[rng.randi() % open.size()]
		elif d.move == "sentry":
			dir = DIRS[rng.randi() % 4]
		if kind != "kurage" and _sees_from(p, dir, int(d.sight), start, false):
			continue
		units.append({"id": _next_id, "kind": kind, "pos": p, "dir": dir, "hp": int(d.hp), "max_hp": int(d.hp),
			"atk": int(d.atk), "sight": int(d.sight), "speed": int(d.speed), "aspeed": int(d.aspeed), "move": d.move,
			"state": "patrol", "route": route, "ri": 0, "rstep": 1, "last_seen": Vector2i(-1, -1), "lost": 0,
			"stun": 0, "invest": Vector2i(-1, -1), "wait": 0, "home": p, "home_dir": dir})
		_next_id += 1
		return true
	return false


# ───────── 盤の問い合わせ ─────────

func inside(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < W and p.y < H


func tile(p: Vector2i) -> int:
	return tiles[p.y * W + p.x] if inside(p) else ROCK


func _put(p: Vector2i, t: int) -> void:
	if inside(p):
		tiles[p.y * W + p.x] = t


func walkable_tile(p: Vector2i) -> bool:
	return inside(p) and tile(p) != ROCK


func all_cells() -> Array:
	var a := []
	for y in H:
		for x in W:
			a.append(Vector2i(x, y))
	return a


func me() -> Dictionary:
	return units[0]


func enemies() -> Array:
	return units.slice(1)


func unit_at(p: Vector2i):
	for u in units:
		if u.pos == p:
			return u
	return null


func unit_by_id(id: int):
	for u in units:
		if u.id == id:
			return u
	return null


func _dist(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)


func _flood(from: Vector2i) -> Dictionary:
	var seen := {from: true}
	var q := [from]
	while not q.is_empty():
		var p: Vector2i = q.pop_front()
		for d in DIRS:
			var n: Vector2i = p + d
			if walkable_tile(n) and not seen.has(n):
				seen[n] = true
				q.append(n)
	return seen


## 道なりの最短路（from を含まない）。block_units なら他のユニットのマスを通らない
func _path(from: Vector2i, to: Vector2i, block_units: bool = true, max_len: int = 999) -> Array:
	if from == to:
		return []
	var prev := {from: from}
	var q := [from]
	while not q.is_empty():
		var p: Vector2i = q.pop_front()
		for d in DIRS:
			var n: Vector2i = p + d
			if prev.has(n) or not walkable_tile(n):
				continue
			if block_units and n != to and unit_at(n) != null:
				continue
			prev[n] = p
			if n == to:
				var path := [n]
				var c: Vector2i = p
				while c != from:
					path.push_front(c)
					c = prev[c]
				return path if path.size() <= max_len else []
			q.append(n)
	return []


## 泳げるマスと、そこまでの道。{マス: 道}
func move_targets(range_n: int) -> Dictionary:
	var out := {}
	var start: Vector2i = me().pos
	var prev := {start: start}
	var dist := {start: 0}
	var q := [start]
	while not q.is_empty():
		var p: Vector2i = q.pop_front()
		if dist[p] >= range_n:
			continue
		# 出口に着いたらそこで終わり
		if p != start and items.get(p, "") == "exit":
			continue
		for d in DIRS:
			var n: Vector2i = p + d
			if prev.has(n) or not walkable_tile(n) or unit_at(n) != null:
				continue
			prev[n] = p
			dist[n] = dist[p] + 1
			q.append(n)
	for p in prev:
		if p == start:
			continue
		var path := [p]
		var c: Vector2i = prev[p]
		while c != start:
			path.push_front(c)
			c = prev[c]
		out[p] = path
	return out


# ───────── 視界 ─────────

## 敵 u の視界のマス（扇形。奥ほど広い。壁でさえぎられる）
func vision(u: Dictionary) -> Array:
	return _cone(u.pos, u.dir, int(u.sight))


func _cone(pos: Vector2i, dir: Vector2i, sight: int) -> Array:
	var out := []
	if sight <= 0:
		return out
	var side := Vector2i(-dir.y, dir.x)
	for f in range(1, sight + 1):
		var wdt := (f + 1) / 2
		for s in range(-wdt, wdt + 1):
			var p: Vector2i = pos + dir * f + side * s
			if inside(p) and tile(p) != ROCK and _clear_line(pos, p):
				out.append(p)
	return out


func _clear_line(a: Vector2i, b: Vector2i) -> bool:
	# a から b までの間に岩がないか（両端は含まない）。少し広めにサンプルする
	var n: int = maxi(abs(b.x - a.x), abs(b.y - a.y)) * 2
	for i in range(1, n):
		var t := float(i) / n
		var q := Vector2i(roundi(lerpf(a.x, b.x, t)), roundi(lerpf(a.y, b.y, t)))
		if q != a and q != b and tile(q) == ROCK:
			return false
	return true


## カノープスが p にいたら敵 u に見えるか
func sees(u: Dictionary, p: Vector2i) -> bool:
	if u.stun > 0:
		return false
	return _sees_from(u.pos, u.dir, int(u.sight), p, hidden)


func _sees_from(pos: Vector2i, dir: Vector2i, sight: int, p: Vector2i, is_hidden: bool) -> bool:
	if sight <= 0:
		return false
	# 海藻の中・海藻がくれ中は、真正面のとなりからしか見えない
	if is_hidden or tile(p) == WEED:
		return p == pos + dir
	return p in _cone(pos, dir, sight)


## 見張られているマス（画面の赤い扇と、ボットが使う）
func watched() -> Dictionary:
	var out := {}
	for u in enemies():
		if u.stun > 0:
			continue
		for p in vision(u):
			out[p] = true
	return out


# ───────── カード ─────────

func can_play(i: int) -> bool:
	if i < 0 or i >= hand.size() or exited:
		return false
	var d := Cards.def(hand[i])
	return plays_left > 0 or d.get("free", false)


## わざとして使うときに選べるマス。self のときは空
func targets(i: int) -> Dictionary:
	var d := Cards.def(hand[i])
	var out := {}
	var pos: Vector2i = me().pos
	match d.target:
		"move":
			for p in move_targets(int(d.range)):
				out[p] = true
		"adj":
			for dd in DIRS:
				var u = unit_at(pos + dd)
				if u != null and u.id != 0:
					out[pos + dd] = true
		"line":
			for dd in DIRS:
				for k in range(1, int(d.range) + 1):
					var p: Vector2i = pos + dd * k
					if not walkable_tile(p):
						break
					out[p] = true
		"spot":
			for p in all_cells():
				if walkable_tile(p) and _dist(p, pos) <= int(d.range) and p != pos:
					out[p] = true
	return out


## 泳ぐとして使うときに選べるマス
func swim_targets(i: int) -> Dictionary:
	var out := {}
	for p in move_targets(int(Cards.def(hand[i]).mv)):
		out[p] = true
	return out


## カードを使う。as_move なら「泳ぐ」として使う。at は選んだマス（self なら無視）
func play(i: int, as_move: bool, at: Vector2i) -> Array:
	var ev := []
	if not can_play(i):
		return ev
	var id: String = hand[i]
	var d := Cards.def(id)
	hand.remove_at(i)
	if d.get("exhaust", false) and not as_move:
		exhausted.append(id)
	else:
		discard.append(id)
	if as_move or not d.get("free", false):
		plays_left -= 1
	_spend_air(int(d.cost), ev)
	var pos: Vector2i = me().pos
	if as_move:
		_move_me(at, int(d.mv), ev)
	else:
		match id:
			"swim", "swim2", "dash":
				_move_me(at, int(d.range), ev)
				if d.has("noise") and not exited:
					_noise(me().pos, int(d.noise), ev)
			"tail":
				var u = unit_at(at)
				if u != null and u.id != 0:
					_face_me(at - pos, ev)
					ev.append({"t": "attack", "id": 0, "to": at})
					_hit(u, int(d.dmg), at - pos, ev)
			"charge":
				var dir := _dir_to(pos, at)
				_face_me(dir, ev)
				var path := []
				var p := pos
				var target = null
				for k in int(d.range):
					var n: Vector2i = p + dir
					if not walkable_tile(n):
						break
					var u = unit_at(n)
					if u != null:
						target = u
						break
					p = n
					path.append(p)
					if items.get(p, "") == "exit":
						break
				if not path.is_empty():
					me().pos = p
					ev.append({"t": "move", "id": 0, "path": path, "fast": true})
					_arrive(ev)
				if target != null and not exited:
					ev.append({"t": "attack", "id": 0, "to": target.pos})
					_hit(target, int(d.dmg), dir, ev)
			"bubble", "pod":
				var dir := _dir_to(pos, at)
				_face_me(dir, ev)
				ev.append({"t": "beam", "from": pos, "dir": dir, "kind": id})
				for k in range(1, int(d.range) + 1):
					var p: Vector2i = pos + dir * k
					if not walkable_tile(p):
						break
					var u = unit_at(p)
					if u != null:
						_hit(u, int(d.dmg), Vector2i.ZERO, ev)
						if d.has("stun") and u.hp > 0:
							u.stun = int(d.stun)
							ev.append({"t": "stun", "id": u.id})
						if not d.get("pierce", false):
							break
			"whirl":
				ev.append({"t": "whirl", "at": pos})
				for dx in [-1, 0, 1]:
					for dy in [-1, 0, 1]:
						var p := pos + Vector2i(dx, dy)
						var u = unit_at(p)
						if u != null and u.id != 0:
							_hit(u, int(d.dmg), Vector2i(dx, dy), ev)
			"sonar":
				ev.append({"t": "sonar", "at": pos, "r": int(d.radius)})
				for u in enemies():
					if _dist(u.pos, pos) <= int(d.radius) and u.hp > 0:
						u.stun = int(d.stun)
						ev.append({"t": "stun", "id": u.id})
			"hide":
				hidden = true
				ev.append({"t": "hide"})
			"shield":
				shield = int(d.block)
				ev.append({"t": "shield"})
			"breath":
				air += int(d.air)
				ev.append({"t": "air", "n": int(d.air)})
			"call":
				ev.append({"t": "call", "at": at})
				_noise(at, int(d.noise), ev)
			"wing":
				ev.append({"t": "wing"})
				_draw(int(d.draw), ev)
			"hug":
				var n: int = mini(int(d.heal), max_hp - hp)
				hp += n
				ev.append({"t": "heal", "n": n})
	_check_spotted(ev)
	return ev


func _dir_to(from: Vector2i, to: Vector2i) -> Vector2i:
	var v := to - from
	if abs(v.x) >= abs(v.y):
		return Vector2i(signi(v.x), 0)
	return Vector2i(0, signi(v.y))


func _face_me(dir: Vector2i, ev: Array) -> void:
	if dir == Vector2i.ZERO:
		return
	me().dir = Vector2i(signi(dir.x), signi(dir.y))
	ev.append({"t": "face", "id": 0, "dir": me().dir})


func _move_me(at: Vector2i, range_n: int, ev: Array) -> void:
	var opts := move_targets(range_n)
	if not opts.has(at):
		return
	var path: Array = opts[at]
	var last: Vector2i = path[path.size() - 1]
	var prev: Vector2i = path[path.size() - 2] if path.size() > 1 else me().pos
	me().dir = last - prev
	me().pos = last
	ev.append({"t": "move", "id": 0, "path": path})
	_arrive(ev)


func _arrive(ev: Array) -> void:
	var p: Vector2i = me().pos
	var it: String = items.get(p, "")
	match it:
		"exit":
			exited = true
			ev.append({"t": "exit"})
			if stage >= STAGES:
				cleared = true
		"chest":
			items.erase(p)
			ev.append({"t": "chest", "at": p})
		"pearl":
			items.erase(p)
			var n: int = mini(3, max_hp - hp)
			hp += n
			ev.append({"t": "pickup", "item": "pearl", "at": p})
			ev.append({"t": "heal", "n": n})
		"vent":
			items.erase(p)
			air += 10
			ev.append({"t": "pickup", "item": "vent", "at": p})
			ev.append({"t": "air", "n": 10})


func _spend_air(n: int, ev: Array) -> void:
	if n <= 0:
		return
	var from_air: int = mini(n, air)
	air -= from_air
	var rest := n - from_air
	if rest > 0:
		_hurt_me(rest, null, ev, true)


## 敵にダメージ。push は吹き飛ばす向き（ZERO なら飛ばさない）
func _hit(u: Dictionary, dmg: int, push: Vector2i, ev: Array) -> void:
	var sneak: bool = u.state != "alert" and u.stun == 0
	if sneak:
		dmg *= 2
	var wall := false
	if push != Vector2i.ZERO and u.hp > dmg:
		var dir := Vector2i(signi(push.x), signi(push.y))
		var to: Vector2i = u.pos + dir
		if walkable_tile(to) and unit_at(to) == null and items.get(to, "") != "exit":
			u.pos = to
			ev.append({"t": "push", "id": u.id, "to": to})
		else:
			# 壁や仲間にぶつかると、もう1ダメージ
			wall = true
			dmg += 1
	u.hp -= dmg
	ev.append({"t": "hit", "id": u.id, "dmg": dmg, "sneak": sneak, "wall": wall})
	if u.hp <= 0:
		units.erase(u)
		kills += 1
		ev.append({"t": "die", "id": u.id})
	elif u.state != "alert":
		# 攻撃された敵はこちらに気づく
		_alert(u, ev, false)


func _hurt_me(dmg: int, from, ev: Array, from_air: bool = false) -> void:
	var blocked := 0
	if not from_air and shield > 0:
		blocked = mini(shield, dmg)
		shield -= blocked
		dmg -= blocked
	hp = maxi(hp - dmg, 0)
	ev.append({"t": "phit", "id": from.id if from != null else -1, "dmg": dmg, "blocked": blocked, "air": from_air})
	if hp <= 0:
		ev.append({"t": "faint"})


func _noise(at: Vector2i, r: int, ev: Array) -> void:
	ev.append({"t": "noise", "at": at})
	for u in enemies():
		if u.state == "alert" or u.move == "fixed" or u.sight <= 0:
			continue
		if _dist(u.pos, at) <= r:
			u.state = "invest"
			u.invest = at
			u.wait = 0
			u.dir = _dir_to(u.pos, at) if u.pos != at else u.dir
			ev.append({"t": "hear", "id": u.id, "at": at})
			ev.append({"t": "face", "id": u.id, "dir": u.dir})


func _alert(u: Dictionary, ev: Array, spread: bool) -> void:
	var first: bool = u.state != "alert"
	u.state = "alert"
	u.last_seen = me().pos
	u.lost = 0
	if first:
		ev.append({"t": "spot", "id": u.id})
	if not spread:
		return
	for o in enemies():
		if o.state != "alert" and o.move != "fixed" and o.sight > 0 and _dist(o.pos, u.pos) <= ALERT_RADIUS:
			o.state = "alert"
			o.last_seen = me().pos
			o.lost = 0
			ev.append({"t": "spot", "id": o.id, "called": true})


func _check_spotted(ev: Array) -> void:
	if exited or hp <= 0:
		return
	for u in enemies():
		if sees(u, me().pos):
			if u.state != "alert":
				spotted += 1
				spotted_total += 1
				_alert(u, ev, true)
			else:
				u.last_seen = me().pos
				u.lost = 0


func _draw(n: int, ev: Array) -> void:
	var got := 0
	for k in n:
		if hand.size() >= HAND + 2:
			break
		if deck.is_empty():
			if discard.is_empty():
				break
			deck = discard.duplicate()
			discard.clear()
			_shuffle(deck)
			ev.append({"t": "reshuffle"})
		hand.append(deck.pop_back())
		got += 1
	if got > 0:
		ev.append({"t": "draw", "n": got})


func _begin_turn(ev: Array) -> void:
	turn += 1
	plays_left = PLAYS
	hidden = false
	shield = 0
	_draw(maxi(HAND - hand.size(), 0), ev)


## ターン終了 → 敵のターン → 次のターン
func end_turn() -> Array:
	var ev := []
	if exited or hp <= 0:
		return ev
	# 時間がたつと空気が減る
	if air > 0:
		air -= 1
	else:
		ev.append({"t": "suffocate"})
		_hurt_me(1, null, ev, true)
		if hp <= 0:
			return ev
	for u in enemies():
		if hp <= 0:
			break
		if not units.has(u):
			continue
		_enemy_act(u, ev)
	if hp > 0:
		_begin_turn(ev)
		ev.append({"t": "turn"})
	return ev


func _enemy_act(u: Dictionary, ev: Array) -> void:
	if u.stun > 0:
		u.stun -= 1
		return
	var pos: Vector2i = me().pos
	if u.move == "drift":
		# クラゲ：ふらふら動いて、となりにいたら刺す
		if _dist(u.pos, pos) == 1:
			ev.append({"t": "attack", "id": u.id, "to": pos})
			_hurt_me(u.atk, u, ev)
			return
		var opts := []
		for d in DIRS:
			var n: Vector2i = u.pos + d
			if walkable_tile(n) and unit_at(n) == null and items.get(n, "") != "exit":
				opts.append(n)
		if not opts.is_empty() and rng.randf() < 0.7:
			var n: Vector2i = opts[rng.randi() % opts.size()]
			u.dir = n - u.pos
			u.pos = n
			ev.append({"t": "move", "id": u.id, "path": [n]})
		return
	if u.move == "fixed":
		# ウツボ：動かない。見ている先（2マス）にいたらかみつく
		if pos in vision(u) or _dist(u.pos, pos) == 1:
			if _dist(u.pos, pos) > 1 or pos != u.pos + u.dir:
				u.dir = _dir_to(u.pos, pos)
				ev.append({"t": "face", "id": u.id, "dir": u.dir})
			ev.append({"t": "attack", "id": u.id, "to": pos, "reach": _dist(u.pos, pos)})
			_hurt_me(u.atk, u, ev)
		return
	match u.state:
		"alert":
			_chase(u, ev)
		"search", "invest":
			var goal: Vector2i = u.invest if u.state == "invest" else u.last_seen
			if u.pos == goal or _dist(u.pos, goal) <= 1 and unit_at(goal) != null:
				# 着いたら、まわりを見回す
				u.wait += 1
				u.dir = Vector2i(-u.dir.y, u.dir.x)
				ev.append({"t": "face", "id": u.id, "dir": u.dir})
				if u.wait >= 2:
					u.state = "return"
					ev.append({"t": "calm", "id": u.id})
			else:
				_step_toward(u, goal, u.speed + (1 if u.state == "search" else 0), ev)
		"return":
			var home: Vector2i = u.route[u.ri]
			if u.pos == home:
				u.state = "patrol"
				if u.move == "sentry":
					u.dir = u.home_dir
					ev.append({"t": "face", "id": u.id, "dir": u.dir})
			else:
				_step_toward(u, home, maxi(u.speed, 1), ev)
		_:
			_patrol(u, ev)
	# 動いたあとに見えるか
	if hp > 0 and not exited:
		if sees(u, pos):
			if u.state != "alert":
				spotted += 1
				spotted_total += 1
				_alert(u, ev, true)
			else:
				u.last_seen = pos
				u.lost = 0


func _patrol(u: Dictionary, ev: Array) -> void:
	if u.move == "sentry":
		# アンコウ：その場で2ターンごとに右へ向きを変える
		u.wait += 1
		if u.wait >= 2:
			u.wait = 0
			u.dir = Vector2i(-u.dir.y, u.dir.x)
			ev.append({"t": "face", "id": u.id, "dir": u.dir})
		return
	var route: Array = u.route
	for s in u.speed:
		var ni: int = u.ri + u.rstep
		if ni < 0 or ni >= route.size():
			u.rstep = -u.rstep
			ni = u.ri + u.rstep
		var n: Vector2i = route[ni]
		if unit_at(n) != null:
			break
		u.dir = n - u.pos
		u.pos = n
		u.ri = ni
		ev.append({"t": "move", "id": u.id, "path": [n]})
	# 端に着いたら折り返しの向きを先に向く（視界が読みやすい）
	var nx: int = u.ri + u.rstep
	if nx < 0 or nx >= route.size():
		u.rstep = -u.rstep
		u.dir = route[u.ri + u.rstep] - u.pos
		ev.append({"t": "face", "id": u.id, "dir": u.dir})


func _chase(u: Dictionary, ev: Array) -> void:
	var pos: Vector2i = me().pos
	if not sees(u, pos) and _dist(u.pos, pos) > 1:
		u.lost += 1
		if u.lost > LOSE_TURNS:
			u.state = "search"
			u.wait = 0
			ev.append({"t": "lost", "id": u.id})
			_step_toward(u, u.last_seen, u.speed + 1, ev)
			return
		# まだ覚えている：最後に見た場所へ
		_step_toward(u, u.last_seen if u.lost > 1 else pos, u.aspeed, ev)
	else:
		_step_toward(u, pos, u.aspeed, ev)
	if _dist(u.pos, pos) == 1 and hp > 0:
		u.dir = pos - u.pos
		ev.append({"t": "face", "id": u.id, "dir": u.dir})
		ev.append({"t": "attack", "id": u.id, "to": pos})
		_hurt_me(u.atk, u, ev)


func _step_toward(u: Dictionary, goal: Vector2i, steps: int, ev: Array) -> void:
	if steps <= 0:
		return
	var path := _path(u.pos, goal)
	var moved := []
	for p in path:
		if moved.size() >= steps:
			break
		if unit_at(p) != null or items.get(p, "") == "exit":
			break
		u.dir = p - u.pos
		u.pos = p
		moved.append(p)
	if not moved.is_empty():
		ev.append({"t": "move", "id": u.id, "path": moved})


## 敵 u の次の行き先（画面の矢印用）
func next_step(u: Dictionary) -> Vector2i:
	if u.move != "patrol" or u.state != "patrol":
		return u.pos
	var ni: int = u.ri + u.rstep
	if ni < 0 or ni >= u.route.size():
		ni = u.ri - u.rstep
	return u.route[ni]


# ───────── 階の終わり ─────────

func reward_choices(n: int = 3) -> Array:
	var pool := Cards.REWARDS.duplicate()
	_shuffle(pool)
	return pool.slice(0, n)


func add_card(id: String) -> void:
	owned.append(id)
	discard.append(id)


func remove_card(id: String) -> void:
	owned.erase(id)


## 空気だまりで休んで次の階へ
func next_stage() -> Array:
	stage += 1
	hp = mini(hp + 4, max_hp)
	units.clear()
	return start_stage()


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t
