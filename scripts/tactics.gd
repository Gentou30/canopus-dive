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
##   {t:"coin", n, at}  {t:"relic", id, at}  {t:"revive"}  {t:"ink", id}  {t:"weed", at}  {t:"resist", id}
##   {t:"summon", id}  {t:"boss_phase", id}  {t:"warn", id, tiles, kind, name}  {t:"boss_atk", id, kind, tiles}
## コース（難しさ）は COURSES。お守りは Relics、コインは敵・宝箱・小判の山で手に入り、空気だまりのお店で使う。

const W := 9
const H := 13
const DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const MAX_HP := 12
const MAX_AIR := 40
const HAND := 5
const PLAYS := 2

## コース：floors は [見た目の層(0〜3), 敵の並び]。最後の階が海竜（ボス戦）
##   air/hp 最初の空気・体力  boss_hp/boss_dmg 海竜の体力・攻撃の上乗せ  atk/hp_plus 敵の攻撃・体力の上乗せ
##   alert 見つかったとき仲間に知らせる距離  lose 見えない状態がこれだけ続くと見失う  elite_from この階から「ぬし」が出る
##   summon 海竜が怒ったとき呼ぶ子分  double false なら、怒っても攻撃は重ならない
const COURSES := {
	"easy": {"name": "あさせコース", "sub": "はじめての人に。4階で海竜", "air": 40, "hp": 12, "boss_hp": 16, "boss_dmg": 0,
		"atk": 0, "hp_plus": 0, "alert": 4, "lose": 2, "elite_from": 2, "summon": ["fugu"], "double": false,
		"floors": [
			[0, ["fugu", "fugu", "ankou", "kurage"]],
			[1, ["fugu", "ika", "kani", "utsubo", "ankou", "kurage"]],
			[2, ["same", "kani", "fugu", "tako", "ankou", "utsubo", "kurage"]],
			[3, ["fugu", "fugu"]],
		]},
	"normal": {"name": "しんかいコース", "sub": "敵が多い。5階で怒りっぽい海竜", "air": 38, "hp": 12, "boss_hp": 26, "boss_dmg": 1,
		"atk": 0, "hp_plus": 0, "alert": 4, "lose": 3, "elite_from": 2, "summon": ["ika", "fugu"],
		"floors": [
			[0, ["fugu", "fugu", "ankou", "kurage", "ika"]],
			[1, ["fugu", "ika", "kani", "utsubo", "ankou", "uni", "kurage"]],
			[1, ["tako", "kani", "ika", "utsubo", "ankou", "ei", "uni"]],
			[2, ["same", "ei", "tako", "fugu", "ankou", "utsubo", "uni", "kurage"]],
			[3, ["fugu", "ika"]],
		]},
	"hard": {"name": "ならくコース", "sub": "敵が強い。6階で本気の海竜", "air": 36, "hp": 12, "boss_hp": 32, "boss_dmg": 1,
		"atk": 1, "hp_plus": 0, "alert": 5, "lose": 3, "elite_from": 1, "summon": ["same", "ika"],
		"floors": [
			[0, ["fugu", "ika", "ankou", "kurage", "kani"]],
			[1, ["fugu", "ika", "kani", "utsubo", "ankou", "uni", "tako"]],
			[1, ["tako", "kani", "ika", "utsubo", "ankou", "ei", "uni", "fugu"]],
			[2, ["same", "ei", "tako", "ika", "ankou", "utsubo", "uni", "kurage"]],
			[2, ["same", "same", "ei", "tako", "ankou", "utsubo", "uni", "ika"]],
			[3, ["ika", "ika", "uni"]],
		]},
}
const COURSE_IDS := ["easy", "normal", "hard"]

enum { FLOOR, ROCK, WEED }

## sight: 視界の奥行き（0 は見ない） speed: 巡回の速さ  aspeed: 追うときの速さ  coin: 倒したときのコイン
## move: "patrol" 往復 / "sentry" その場で向きを変える / "fixed" 動かない / "drift" ふらふら / "spike" 動かないトゲ
## ink: 攻撃が当たると、じゃまな「タコの墨」カードを捨て札に混ぜる
const ENEMIES := {
	"fugu": {"name": "フグ", "hp": 2, "atk": 1, "sight": 3, "speed": 1, "aspeed": 2, "move": "patrol", "coin": 4,
		"note": "決まった道を行ったり来たり"},
	"kurage": {"name": "クラゲ", "hp": 1, "atk": 1, "sight": 0, "speed": 1, "aspeed": 1, "move": "drift", "coin": 2,
		"note": "目が見えない。ふらふら動いて、となりを刺す"},
	"ankou": {"name": "アンコウ", "hp": 3, "atk": 2, "sight": 4, "speed": 0, "aspeed": 1, "move": "sentry", "coin": 6,
		"note": "その場で2ターンごとに向きを変える"},
	"kani": {"name": "オオガニ", "hp": 4, "atk": 2, "sight": 2, "speed": 1, "aspeed": 2, "move": "patrol", "coin": 7,
		"note": "かたい。視界はせまい"},
	"utsubo": {"name": "ウツボ", "hp": 3, "atk": 2, "sight": 2, "speed": 0, "aspeed": 0, "move": "fixed", "coin": 6,
		"note": "動かない。前とまわりにかみつく"},
	"same": {"name": "サメ", "hp": 6, "atk": 3, "sight": 4, "speed": 1, "aspeed": 3, "move": "patrol", "coin": 12,
		"note": "強くて速い。見つかったら逃げよう"},
	"ika": {"name": "イカ", "hp": 2, "atk": 1, "sight": 3, "speed": 2, "aspeed": 3, "move": "patrol", "coin": 5,
		"note": "巡回が2マスずつと速い"},
	"tako": {"name": "タコ", "hp": 3, "atk": 1, "sight": 3, "speed": 0, "aspeed": 1, "move": "sentry", "coin": 7, "ink": true,
		"note": "墨をかけられると、じゃまなカードがデッキに混ざる"},
	"ei": {"name": "エイ", "hp": 4, "atk": 2, "sight": 4, "speed": 2, "aspeed": 2, "move": "patrol", "coin": 9,
		"note": "大きく速い見張り。視界が広い"},
	"uni": {"name": "ウニ", "hp": 3, "atk": 1, "sight": 0, "speed": 0, "aspeed": 0, "move": "spike", "coin": 5,
		"note": "動かない。となりでターンを終えるとトゲが刺さる。かみつく・尾びれで殴ると自分も1ダメージ"},
	"ryu": {"name": "海竜", "hp": 24, "atk": 4, "sight": 0, "speed": 1, "aspeed": 1, "move": "boss", "coin": 0,
		"note": "赤く光るマスに次のターン攻撃。泡のブレスか音波で気絶させると止まる（すぐには効かない）。押し出せない"},
}

## 海竜の技：予告したマスに次の敵のターンで当たる。泡のブレスや音波で気絶させると取り消せる
const BOSS_ATTACKS := {
	"tail": {"name": "尾の大なぎ", "dmg": 3},
	"breath": {"name": "竜のブレス", "dmg": 4},
	"whirl": {"name": "大渦", "dmg": 3},
	"rain": {"name": "星くずの雨", "dmg": 3},
}

var rng := RandomNumberGenerator.new()

# ラン全体
var course_id := "easy"
var course: Dictionary = COURSES["easy"]
var stage := 1
var hp := MAX_HP
var max_hp := MAX_HP
var air := MAX_AIR
var max_air := MAX_AIR
var coins := 0
var coins_total := 0
var relics: Array[String] = []
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
var coin_items := {}  # Vector2i -> コインの山の額
var cleared := false
var exited := false
var _next_id := 1


func _init(seed_value: int = -1, cid: String = "easy") -> void:
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	course_id = cid
	course = COURSES[cid]
	max_hp = int(course.hp)
	hp = max_hp
	max_air = int(course.air)
	air = max_air
	for c in Cards.START_DECK:
		owned.append(c)


func stages() -> int:
	return course.floors.size()


## 見た目の層（0 浅瀬 / 1 遺跡 / 2 深海 / 3 最深部）
func zone() -> int:
	return int(course.floors[mini(stage, stages()) - 1][0])


func has_relic(id: String) -> bool:
	return id in relics


func add_relic(id: String) -> void:
	if id in relics:
		return
	relics.append(id)
	match id:
		"coral":
			max_hp += 4
			hp += 4
		"float":
			max_air += 10
			air += 10


func hand_size() -> int:
	return HAND + (1 if has_relic("bag") else 0)


func _gain_coins(n: int, at: Vector2i, ev: Array) -> void:
	if has_relic("scale"):
		n = ceili(n * 1.5)
	coins += n
	coins_total += n
	ev.append({"t": "coin", "n": n, "at": at})


# ───────── 階づくり ─────────

func start_stage() -> Array:
	turn = 0
	spotted = 0
	exited = false
	hidden = false
	shield = 0
	air = max_air
	coin_items.clear()
	if is_boss_stage():
		_build_boss_map()
	else:
		_build_map()
	deck = owned.duplicate()
	_shuffle(deck)
	hand.clear()
	discard.clear()
	exhausted.clear()
	var ev := []
	_begin_turn(ev)
	return ev


func is_boss_stage() -> bool:
	return stage >= stages()


func boss():
	for u in enemies():
		if u.move == "boss":
			return u
	return null


## 最深部：柱と海藻のある広間。奥で海竜が星を抱いて眠っている
func _build_boss_map() -> void:
	for attempt in 50:
		tiles = PackedInt32Array()
		tiles.resize(W * H)
		tiles.fill(FLOOR)
		items.clear()
		units.clear()
		_next_id = 1
		for p in [Vector2i(2, 4), Vector2i(6, 4), Vector2i(1, 8), Vector2i(7, 8), Vector2i(4, 6)]:
			_put(p, ROCK)
		for p in [Vector2i(0, 5), Vector2i(0, 6), Vector2i(8, 5), Vector2i(8, 6), Vector2i(3, 10), Vector2i(5, 10),
				Vector2i(2, 2), Vector2i(6, 2)]:
			_put(p, WEED)
		for x in W:
			_put(Vector2i(x, H - 1), ROCK)
		var start := Vector2i(W / 2, 0)
		units.append({"id": 0, "kind": "canopus", "pos": start, "dir": Vector2i(0, 1), "hp": hp})
		items[Vector2i(0, 9)] = "vent"
		items[Vector2i(8, 2)] = "vent"
		items[Vector2i(0, 1)] = "pearl"
		items[Vector2i(8, 10)] = "vent"
		var bp := Vector2i(W / 2, H - 3)
		var b := _make_enemy("ryu", bp, Vector2i(0, -1), [bp])
		b.hp = int(course.boss_hp)
		b.max_hp = b.hp
		b.state = "sleep"
		b.merge({"pending": [], "pkind": "", "pdmg": 0, "acount": 0, "sleep_turns": 0, "guard": 0, "phase2": false})
		var ok := true
		for kind in _floor_enemies():
			if not _place_enemy(kind, start):
				ok = false
		if ok:
			return


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
		# 2階からは、ときどき金の宝箱（お守りが入っている）
		items[p] = "gchest" if placed == 1 and stage >= 2 and rng.randf() < 0.3 else "chest"
		placed += 1
	_shuffle(free)
	for it in ["pearl", "vent", "coin", "coin"]:
		for p in free:
			if not items.has(p) and not _near_item(p, 2) and p.y >= 3:
				items[p] = it
				if it == "coin":
					coin_items[p] = rng.randi_range(6, 10) + stage
				break
	# 敵。2階から（コースによる）1体が「ぬし」になる：強いけど、倒すとお守りが手に入る
	for kind in _floor_enemies():
		if not _place_enemy(kind, start):
			return false
	if stage >= int(course.elite_from):
		var cands := enemies().filter(func(u): return not u.kind in ["kurage", "uni"])
		if not cands.is_empty():
			var e: Dictionary = cands[rng.randi() % cands.size()]
			e.elite = true
			e.hp = e.hp * 2 + 1
			e.max_hp = e.hp
			e.atk += 1
	return true


func _floor_enemies() -> Array:
	return course.floors[mini(stage, stages()) - 1][1]


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
		elif d.move == "fixed" or d.move == "spike":
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
		_make_enemy(kind, p, dir, route)
		return true
	return false


func _make_enemy(kind: String, p: Vector2i, dir: Vector2i, route: Array) -> Dictionary:
	var d: Dictionary = ENEMIES[kind]
	var boss_like: bool = d.move == "boss"
	var hpv: int = int(d.hp) + (0 if boss_like else int(course.hp_plus))
	var u := {"id": _next_id, "kind": kind, "pos": p, "dir": dir, "hp": hpv, "max_hp": hpv,
		"atk": int(d.atk) + (0 if boss_like else int(course.atk)), "sight": int(d.sight), "speed": int(d.speed),
		"aspeed": int(d.aspeed), "move": d.move, "state": "patrol", "route": route, "ri": 0, "rstep": 1,
		"last_seen": Vector2i(-1, -1), "lost": 0, "stun": 0, "invest": Vector2i(-1, -1), "wait": 0, "home": p,
		"home_dir": dir, "elite": false}
	_next_id += 1
	units.append(u)
	return u


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
	return _cone(u.pos, u.dir, _sight(u))


## 深海ちょうちんを持っていると、敵の視界が1マス短い
func _sight(u: Dictionary) -> int:
	var sv := int(u.sight)
	if sv > 0 and has_relic("lantern"):
		sv = maxi(sv - 1, 1)
	return sv


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
	return _sees_from(u.pos, u.dir, _sight(u), p, hidden)


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
		"jump":
			for p in all_cells():
				if p != pos and walkable_tile(p) and unit_at(p) == null and _dist(p, pos) <= int(d.range):
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
			var weed_only: bool = Cards.base(hand[i]) == "curtain"
			for p in all_cells():
				if walkable_tile(p) and _dist(p, pos) <= int(d.range) and p != pos:
					if weed_only and (tile(p) != FLOOR or items.has(p)):
						continue
					out[p] = true
	return out


## 泳ぐとして使うときに選べるマス
func swim_targets(i: int) -> Dictionary:
	var out := {}
	for p in move_targets(swim_range(i)):
		out[p] = true
	return out


func swim_range(i: int) -> int:
	return int(Cards.def(hand[i]).mv) + (1 if has_relic("board") else 0)


## カードを使う。as_move なら「泳ぐ」として使う。at は選んだマス（self なら無視）
func play(i: int, as_move: bool, at: Vector2i) -> Array:
	var ev := []
	if not can_play(i):
		return ev
	var id: String = hand[i]
	var d := Cards.def(id)
	var bid := Cards.base(id)
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
		_move_me(at, int(d.mv) + (1 if has_relic("board") else 0), ev)
	else:
		match bid:
			"swim", "swim2", "dash":
				_move_me(at, int(d.range), ev)
				if d.has("noise") and not exited:
					_noise(me().pos, int(d.noise), ev)
			"tail", "bite":
				var u = unit_at(at)
				if u != null and u.id != 0:
					_face_me(at - pos, ev)
					ev.append({"t": "attack", "id": 0, "to": at})
					var spiky: bool = u.move == "spike"
					_hit(u, int(d.dmg), at - pos if d.get("push", false) else Vector2i.ZERO, ev)
					if spiky:
						# ウニを殴るとトゲが刺さる
						_hurt_me(1, u, ev)
			"current":
				var dir := _dir_to(pos, at)
				var path := []
				var p := pos
				for k in int(d.range):
					var n: Vector2i = p + dir
					if not walkable_tile(n) or unit_at(n) != null:
						break
					p = n
					path.append(p)
					if items.has(p):
						break
				if not path.is_empty():
					me().dir = dir
					me().pos = p
					ev.append({"t": "move", "id": 0, "path": path, "fast": true})
					_arrive(ev)
			"leap":
				if walkable_tile(at) and unit_at(at) == null:
					_face_me(_dir_to(pos, at), ev)
					me().pos = at
					ev.append({"t": "move", "id": 0, "path": [at], "fast": true, "jump": true})
					_arrive(ev)
			"horn":
				var dir := _dir_to(pos, at)
				_face_me(dir, ev)
				ev.append({"t": "beam", "from": pos, "dir": dir, "kind": "horn", "n": int(d.range)})
				var hits := []
				for k in range(1, int(d.range) + 1):
					var p: Vector2i = pos + dir * k
					if not walkable_tile(p):
						break
					var u = unit_at(p)
					if u != null:
						hits.append(u)
				# 奥から順に（手前の敵が奥の敵にぶつからないように）
				hits.reverse()
				for u in hits:
					if units.has(u):
						_hit(u, int(d.dmg), dir, ev)
			"tide":
				var dir := _dir_to(pos, at)
				_face_me(dir, ev)
				ev.append({"t": "beam", "from": pos, "dir": dir, "kind": "tide", "n": int(d.range)})
				for k in range(1, int(d.range) + 1):
					var p: Vector2i = pos + dir * k
					if not walkable_tile(p):
						break
					var u = unit_at(p)
					if u != null:
						_hit(u, int(d.dmg), Vector2i.ZERO, ev)
						if units.has(u) and u.move != "boss":
							# となりまで引きよせる
							var to: Vector2i = u.pos
							while to - dir != pos and walkable_tile(to - dir) and unit_at(to - dir) == null:
								to -= dir
							if to != u.pos:
								u.pos = to
								ev.append({"t": "push", "id": u.id, "to": to})
						if units.has(u) and d.has("stun"):
							_stun(u, int(d.stun), ev)
						break
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
						if d.has("stun") and u.hp > 0 and units.has(u):
							_stun(u, int(d.stun), ev)
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
						_stun(u, int(d.stun), ev)
			"hide":
				hidden = true
				ev.append({"t": "hide"})
			"shield":
				shield += int(d.block)
				ev.append({"t": "shield"})
			"curtain":
				if tile(at) == FLOOR:
					_put(at, WEED)
					ev.append({"t": "weed", "at": at})
			"map":
				_gain_coins(int(d.coins), pos, ev)
			"cheer":
				plays_left += int(d.plays)
				ev.append({"t": "cheer", "n": int(d.plays)})
			"ink":
				ev.append({"t": "ink_clear"})
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


## 敵を倒したら、コインと（ぬしなら）お守り
func _on_kill(u: Dictionary, ev: Array) -> void:
	var c: int = int(ENEMIES[u.kind].coin)
	if u.get("elite", false):
		c *= 2
	if c > 0:
		_gain_coins(c, u.pos, ev)
	if has_relic("gill"):
		air += 3
		ev.append({"t": "air", "n": 3})
	if u.get("elite", false):
		var r := relic_choices(1)
		if not r.is_empty():
			add_relic(r[0])
			ev.append({"t": "relic", "id": r[0], "at": u.pos})


func _stun(u: Dictionary, n: int, ev: Array) -> void:
	# 海竜は一度気絶すると、しばらく気絶しない
	if u.move == "boss" and u.guard > 0:
		ev.append({"t": "resist", "id": u.id})
		return
	u.stun = n
	ev.append({"t": "stun", "id": u.id})
	# 海竜の予告攻撃は、気絶させると取り消せる
	if u.move == "boss" and not u.pending.is_empty():
		u.pending = []
		ev.append({"t": "warn", "id": u.id, "tiles": [], "kind": "", "cancel": true})


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
			if spotted == 0:
				_gain_coins(15, p, ev)
			ev.append({"t": "exit"})
		"chest":
			items.erase(p)
			_gain_coins(8 + stage * 2, p, ev)
			ev.append({"t": "chest", "at": p})
		"gchest":
			items.erase(p)
			var r := relic_choices(1)
			if r.is_empty():
				ev.append({"t": "chest", "at": p})
			else:
				add_relic(r[0])
				ev.append({"t": "relic", "id": r[0], "at": p, "chest": true})
		"coin":
			items.erase(p)
			ev.append({"t": "pickup", "item": "coin", "at": p})
			_gain_coins(coin_items.get(p, 8), p, ev)
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
		dmg *= 3 if has_relic("fang") else 2
	var wall := false
	if push != Vector2i.ZERO and u.hp > dmg and u.move != "boss":
		var dir := Vector2i(signi(push.x), signi(push.y))
		var to: Vector2i = u.pos + dir
		if walkable_tile(to) and unit_at(to) == null and items.get(to, "") != "exit":
			u.pos = to
			ev.append({"t": "push", "id": u.id, "to": to})
		else:
			# 壁や仲間にぶつかると、もう1ダメージ
			wall = true
			dmg += 3 if has_relic("spiral") else 1
	u.hp -= dmg
	ev.append({"t": "hit", "id": u.id, "dmg": dmg, "sneak": sneak, "wall": wall})
	if u.hp <= 0:
		units.erase(u)
		kills += 1
		ev.append({"t": "die", "id": u.id})
		_on_kill(u, ev)
		if u.move == "boss":
			# 海竜を倒すと星のかけらが手に入る
			cleared = true
			exited = true
			ev.append({"t": "star", "at": u.pos})
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
	if hp <= 0 and has_relic("ribbon"):
		# ミラのリボン：1回だけ起き上がる
		relics.erase("ribbon")
		hp = 5
		ev.append({"t": "revive"})
	elif hp <= 0:
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
		if o.state != "alert" and o.move != "fixed" and o.sight > 0 and _dist(o.pos, u.pos) <= int(course.alert):
			o.state = "alert"
			o.last_seen = me().pos
			o.lost = 0
			ev.append({"t": "spot", "id": o.id, "called": true})


func _check_spotted(ev: Array) -> void:
	if exited or hp <= 0:
		return
	var b = boss()
	if b != null and b.state == "sleep" and _dist(b.pos, me().pos) <= 2:
		_wake(b, ev)
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
		if hand.size() >= hand_size() + 2:
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
	shield = 1 if has_relic("shell") else 0
	_draw(maxi(hand_size() - hand.size(), 0), ev)


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
	if u.move == "boss":
		_boss_act(u, ev)
		return
	if u.stun > 0:
		u.stun -= 1
		return
	var pos: Vector2i = me().pos
	if u.move == "spike":
		# ウニ：となりにいたらトゲが刺さる
		if _dist(u.pos, pos) == 1:
			ev.append({"t": "attack", "id": u.id, "to": pos})
			_hurt_me(u.atk, u, ev)
		return
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


func _wake(u: Dictionary, ev: Array) -> void:
	u.state = "alert"
	u.last_seen = me().pos
	ev.append({"t": "spot", "id": u.id, "boss": true})


## 海竜：眠っている間はじっとしている（近づくか攻撃すると起きる。6ターンで自然に起きる）。
## 起きたら毎ターン「予告していた攻撃 → 近づく → 次の攻撃を予告」。体力が半分を切ると怒って子分を呼び、
## 攻撃が2つ重なるようになる。気絶させると予告が消えるが、そのあと2ターンは気絶しない
func _boss_act(u: Dictionary, ev: Array) -> void:
	if u.state != "alert":
		u.sleep_turns += 1
		if u.sleep_turns >= 6:
			_wake(u, ev)
		return
	if u.stun > 0:
		u.stun = 0
		u.guard = 2
		_boss_plan(u, ev)
		return
	if u.guard > 0:
		u.guard -= 1
	var pos: Vector2i = me().pos
	if not u.pending.is_empty():
		ev.append({"t": "boss_atk", "id": u.id, "kind": u.pkind, "tiles": u.pending})
		var dmg: int = int(u.pdmg)
		var hit_me: bool = pos in u.pending
		# 子分も巻きこまれる
		for o in enemies():
			if o.id != u.id and o.pos in u.pending and units.has(o):
				_hit(o, dmg, Vector2i.ZERO, ev)
		if hit_me:
			_hurt_me(dmg, u, ev)
		u.pending = []
		ev.append({"t": "warn", "id": u.id, "tiles": [], "kind": ""})
		if hp <= 0:
			return
	if not u.phase2 and u.hp * 2 <= u.max_hp:
		u.phase2 = true
		ev.append({"t": "boss_phase", "id": u.id})
		for kind in course.summon:
			_summon(kind, u.pos, ev)
	_boss_plan(u, ev)


func _boss_plan(u: Dictionary, ev: Array) -> void:
	var pos: Vector2i = me().pos
	var cheb: int = maxi(abs(pos.x - u.pos.x), abs(pos.y - u.pos.y))
	if cheb > 2:
		_step_toward(u, pos, 2 if u.phase2 else 1, ev)
		cheb = maxi(abs(pos.x - u.pos.x), abs(pos.y - u.pos.y))
	u.acount += 1
	var kinds := []
	if cheb <= 1:
		kinds.append("tail")
	else:
		kinds.append(["breath", "whirl", "breath", "rain"][u.acount % 4])
	if u.phase2 and course.get("double", true):
		kinds.append("rain" if kinds[0] == "whirl" else "whirl")
	var set := {}
	var dmg := 0
	for k in kinds:
		for p in _boss_shape(u, k, ev):
			set[p] = true
		dmg = maxi(dmg, int(BOSS_ATTACKS[k].dmg))
	var names := []
	for k in kinds:
		names.append(BOSS_ATTACKS[k].name)
	u.pending = set.keys()
	u.pkind = kinds[0]
	u.pdmg = dmg + int(course.boss_dmg)
	ev.append({"t": "warn", "id": u.id, "tiles": u.pending, "kind": kinds[0], "name": "＋".join(names)})


func _boss_shape(u: Dictionary, kind: String, ev: Array) -> Array:
	var pos: Vector2i = me().pos
	var tiles := []
	match kind:
		"tail":
			# まわり2マス（5×5）をなぎ払う
			for dx in range(-2, 3):
				for dy in range(-2, 3):
					var p: Vector2i = u.pos + Vector2i(dx, dy)
					if p != u.pos and walkable_tile(p):
						tiles.append(p)
		"whirl":
			# カノープスのまわり3×3
			for dx in [-1, 0, 1]:
				for dy in [-1, 0, 1]:
					var p: Vector2i = pos + Vector2i(dx, dy)
					if walkable_tile(p):
						tiles.append(p)
		"rain":
			# カノープスのいるマスと、そのまわりに降る星くず
			tiles.append(pos)
			var cand := []
			for p in all_cells():
				if walkable_tile(p) and p != pos and _dist(p, pos) <= 4:
					cand.append(p)
			_shuffle(cand)
			tiles.append_array(cand.slice(0, 10))
		"breath":
			var dir := _dir_to(u.pos, pos)
			u.dir = dir
			ev.append({"t": "face", "id": u.id, "dir": dir})
			var side := Vector2i(-dir.y, dir.x)
			for k in range(1, 13):
				# 柱（岩）の陰には届かない
				var c: Vector2i = u.pos + dir * k
				if not walkable_tile(c):
					break
				for sdx in [-1, 0, 1]:
					var p: Vector2i = c + side * sdx
					if walkable_tile(p):
						tiles.append(p)
	return tiles


## 海竜が呼ぶ子分（はじめから追ってくる）
func _summon(kind: String, near: Vector2i, ev: Array) -> void:
	var cand := []
	for p in all_cells():
		if walkable_tile(p) and unit_at(p) == null and not items.has(p) and _dist(p, near) <= 3 and _dist(p, me().pos) >= 2:
			cand.append(p)
	if cand.is_empty():
		return
	var p: Vector2i = cand[rng.randi() % cand.size()]
	var u := _make_enemy(kind, p, _dir_to(p, me().pos), [p])
	u.state = "alert"
	u.last_seen = me().pos
	ev.append({"t": "summon", "id": u.id})


## 次の敵のターンに攻撃が来るマス
func danger() -> Dictionary:
	var out := {}
	for u in enemies():
		if u.move == "boss":
			for p in u.pending:
				out[p] = true
	return out


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
		if u.lost > int(course.lose):
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
		if ENEMIES[u.kind].get("ink", false) and hp > 0:
			# タコの墨：じゃまなカードが捨て札に混ざる
			discard.append("ink")
			ev.append({"t": "ink", "id": u.id})


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


# ───────── 階の終わり・お店 ─────────

## カードの候補。めずらしいカードほど出にくい
func reward_choices(n: int = 3, up: bool = false) -> Array:
	var out := []
	for guard in 50:
		if out.size() >= n:
			break
		var pool := []
		for id in Cards.REWARDS:
			for k in 3 - int(Cards.DEFS[id].rare):
				pool.append(id)
		var id: String = pool[rng.randi() % pool.size()]
		if id in out:
			continue
		out.append(id)
	if up:
		out = out.map(func(id): return Cards.upgraded(id))
	return out


## 宝箱から出るカード（星のかぎを持っていれば強化済み）
func chest_choices() -> Array:
	return reward_choices(3, has_relic("key"))


func relic_choices(n: int) -> Array:
	var pool := []
	for id in Relics.DEFS:
		if not id in relics:
			pool.append(id)
	_shuffle(pool)
	return pool.slice(0, n)


const UPGRADE_COST := 40
const REMOVE_COST := 30
const HEAL_COST := 20
const HEAL_AMOUNT := 5


func spend(n: int) -> bool:
	if coins < n:
		return false
	coins -= n
	return true


## お店の品ぞろえ：カード4枚（1枚は強化済み）とお守り2つ
func shop_stock() -> Dictionary:
	var cards := reward_choices(4)
	cards[3] = Cards.upgraded(cards[3])
	return {"cards": cards, "relics": relic_choices(2)}


func add_card(id: String) -> void:
	owned.append(id)
	discard.append(id)


func remove_card(id: String) -> void:
	owned.erase(id)


func upgrade_card(id: String) -> void:
	var i := owned.find(id)
	if i >= 0 and Cards.can_upgrade(id):
		owned[i] = Cards.upgraded(id)


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
