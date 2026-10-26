class_name Dive
extends RefCounted

## 1回の潜水（ラン）の状態とルール。画面とは切り離してあり、balance_sim からも使う。
## 行動の結果は events（辞書の配列）として返し、画面側はそれを順に演出する。
##   {t:"move", id, path}         ユニットが path に沿って動く（id 0 がカノープス）
##   {t:"hit", id, dmg}           ダメージ / {t:"die", id} / {t:"push", id, to} / {t:"bump", id}
##   {t:"pickup", item, at, card} 宝を拾った / {t:"vent", at, air}
##   {t:"zap", tiles} {t:"bite", id, tiles} 敵の攻撃 / {t:"phit", dmg} カノープスが受けた
##   {t:"wake", id} {t:"stun", id} {t:"reveal"} {t:"air", n} {t:"exit"} {t:"faint"}
##   {t:"block"} 雷のうろこで防いだ / {t:"draw", n}

const W := 7
const H := 9
const DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const SIGHT := 2       # いつも見えている範囲（上下左右の歩数）
const SONAR := 4

const MAX_HP := 5
const MAX_AIR := 12
const ENERGY := 3
const HAND := 5
const FLOORS := 9
const REST_AIR := 5

enum { WATER, ROCK, CORAL }

const ENEMIES := {
	"fugu": {"name": "フグ", "hp": 2, "dmg": 1},
	"kurage": {"name": "クラゲ", "hp": 1, "dmg": 1},
	"utsubo": {"name": "ウツボ", "hp": 3, "dmg": 2},
}

## 宝の物と、その階での出やすさ
const ITEM_CARD := {"coin": "coin", "pearl": "pearl", "gem": "gem"}

var rng := RandomNumberGenerator.new()

# ラン全体
var floor_no := 1
var hp := MAX_HP
var air := MAX_AIR
var deck: Array[String] = []        # 山札
var hand: Array[String] = []
var discard: Array[String] = []
var exhausted: Array[String] = []   # この階では使い切ったカード（階が変わると戻る）
var bag: Array[String] = []         # ミラにあずけた宝
var bag_used := false               # この階でミラにあずけたか
var banked := 0
var turn := 0
var energy := ENERGY
var shield := false

# 階
var tiles := PackedInt32Array()
var seen := PackedByteArray()
var items := {}      # Vector2i -> "coin" / "pearl" / "gem" / "vent" / "exit"
var units := []      # [{id, kind, pos, hp, awake, stun, phase, dir, intent}] 0 番がカノープス
var _next_id := 1


func _init(seed_value: int = -1) -> void:
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	deck.assign(Cards.START_DECK)
	_shuffle(deck)


# ───────── 便利 ─────────

func player() -> Dictionary:
	return units[0]


func ppos() -> Vector2i:
	return units[0].pos


func inside(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < W and p.y < H


func tile(p: Vector2i) -> int:
	return tiles[p.y * W + p.x] if inside(p) else ROCK


func is_seen(p: Vector2i) -> bool:
	return inside(p) and seen[p.y * W + p.x] == 1


func unit_at(p: Vector2i) -> Dictionary:
	for u in units:
		if u.pos == p and u.hp > 0:
			return u
	return {}


func open(p: Vector2i) -> bool:
	return inside(p) and tile(p) == WATER and unit_at(p).is_empty()


func enemies() -> Array:
	return units.filter(func(u): return u.id != 0 and u.hp > 0)


func zone() -> int:
	return (floor_no - 1) / 3


func depth_m() -> int:
	return floor_no * 40


func carried_value() -> int:
	var v := 0
	for pile in [deck, hand, discard, exhausted, bag]:
		for c in pile:
			v += int(Cards.def(c).get("value", 0))
	return v


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t


static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)


# ───────── 階を作る ─────────

func start_floor() -> Array:
	for i in 200:
		if _generate():
			break
	# 前の階で使い切ったカードと手札を山札に戻す
	deck.append_array(hand)
	deck.append_array(discard)
	deck.append_array(exhausted)
	hand.clear()
	discard.clear()
	exhausted.clear()
	_shuffle(deck)
	bag_used = false
	turn = 0
	_reveal_around(ppos(), SIGHT)
	return _begin_turn()


func _generate() -> bool:
	tiles.resize(W * H)
	tiles.fill(WATER)
	seen.resize(W * H)
	seen.fill(0)
	items.clear()
	var start := Vector2i(rng.randi_range(1, W - 2), 0)
	var exit := Vector2i(rng.randi_range(0, W - 1), H - 1)
	# 岩のかたまりを何か所かに置く
	var clusters := 5 + zone()
	for c in clusters:
		var p := Vector2i(rng.randi_range(0, W - 1), rng.randi_range(1, H - 2))
		for k in rng.randi_range(2, 4):
			if manhattan(p, start) > 1 and manhattan(p, exit) > 1:
				tiles[p.y * W + p.x] = ROCK if rng.randf() < 0.75 else CORAL
			p += DIRS[rng.randi_range(0, 3)]
			p = p.clamp(Vector2i(0, 1), Vector2i(W - 1, H - 2))
	var dist := _bfs(start, true)
	if not dist.has(exit):
		return false
	# 行けるマスだけを候補にする
	var cells: Array = dist.keys().filter(func(p): return p != start and p != exit)
	if cells.size() < 25:
		return false
	units = [{"id": 0, "kind": "canopus", "pos": start, "hp": hp, "awake": true, "stun": 0, "phase": 0,
		"dir": Vector2i.ZERO, "intent": {}}]
	_next_id = 1
	items[exit] = "exit"
	# 宝：岩に囲まれた奥まったマスほど置かれやすい
	var nook := func(p: Vector2i) -> int:
		var n := 0
		for d in DIRS:
			if tile(p + d) != WATER:
				n += 1
		return n
	_shuffle(cells)
	cells.sort_custom(func(a, b): return nook.call(a) * 10 + dist[a] > nook.call(b) * 10 + dist[b])
	var n_treasure := 3 + floor_no / 3
	var placed := 0
	for p in cells:
		if placed >= n_treasure:
			break
		if dist[p] < 3 or _near_item(p):
			continue
		items[p] = _roll_treasure()
		placed += 1
	# 空気の泡
	var free := cells.filter(func(p): return not items.has(p) and dist[p] >= 3)
	_shuffle(free)
	for i in (1 if floor_no < 4 else 2):
		if free.size() > 0:
			items[free.pop_back()] = "vent"
	# 敵
	var n_enemy := 2 + floor_no / 2 + zone()
	var kinds := ["fugu", "kurage"]
	if floor_no >= 2:
		kinds.append("utsubo")
	free = free.filter(func(p): return manhattan(p, start) >= 4 and not items.has(p))
	for i in n_enemy:
		if free.is_empty():
			break
		var kind: String = kinds[rng.randi_range(0, kinds.size() - 1)]
		var p: Vector2i = free.pop_back()
		var dir := Vector2i.ZERO
		if kind == "utsubo":
			# ウツボは岩を背にして、開けた方を向く
			var faces := DIRS.filter(func(d): return tile(p + d) == WATER and tile(p - d) != WATER)
			if faces.is_empty():
				kind = "fugu"
			else:
				dir = faces[rng.randi_range(0, faces.size() - 1)]
		units.append({"id": _next_id, "kind": kind, "pos": p, "hp": ENEMIES[kind].hp, "awake": kind != "fugu",
			"stun": 0, "phase": rng.randi_range(0, 1), "dir": dir, "intent": {}})
		_next_id += 1
	return true


func _near_item(p: Vector2i) -> bool:
	for q in items:
		if manhattan(p, q) < 2:
			return true
	return false


func _roll_treasure() -> String:
	var r := rng.randf()
	var gem := 0.1 + 0.07 * zone()
	var pearl := 0.3
	if r < gem:
		return "gem"
	if r < gem + pearl:
		return "pearl"
	return "coin"


## from から歩いて行けるマスと歩数。units_block なら敵のいるマスは通れない
func _bfs(from: Vector2i, ignore_units: bool = false, limit: int = 99) -> Dictionary:
	var dist := {from: 0}
	var q := [from]
	while not q.is_empty():
		var p: Vector2i = q.pop_front()
		if dist[p] >= limit:
			continue
		for d in DIRS:
			var n: Vector2i = p + d
			if dist.has(n) or not inside(n) or tile(n) != WATER:
				continue
			if not ignore_units and not unit_at(n).is_empty():
				continue
			dist[n] = dist[p] + 1
			q.append(n)
	return dist


func _path(from: Vector2i, to: Vector2i, dist: Dictionary) -> Array:
	# dist は from からの歩数。to から逆にたどる
	var path := [to]
	var p := to
	while p != from:
		for d in DIRS:
			var n: Vector2i = p + d
			if dist.has(n) and dist[n] == dist[p] - 1:
				p = n
				break
		path.push_front(p)
	return path


func _reveal_around(c: Vector2i, r: int) -> void:
	for y in H:
		for x in W:
			if manhattan(Vector2i(x, y), c) <= r:
				seen[y * W + x] = 1


# ───────── ターン ─────────

func _begin_turn() -> Array:
	turn += 1
	energy = ENERGY
	shield = false
	var ev := _draw(HAND)
	_plan_intents()
	return ev


func _draw(n: int) -> Array:
	var got := 0
	for i in n:
		if deck.is_empty():
			if discard.is_empty():
				break
			deck.append_array(discard)
			discard.clear()
			_shuffle(deck)
		hand.append(deck.pop_back())
		got += 1
	return [{"t": "draw", "n": got}]


func _plan_intents() -> void:
	var pp := ppos()
	for u in enemies():
		if u.kind == "fugu" and not u.awake and manhattan(u.pos, pp) <= 2:
			u.awake = true
		u.intent = _intent_for(u, pp)


func _intent_for(u: Dictionary, pp: Vector2i) -> Dictionary:
	if u.stun > 0:
		return {"type": "rest", "tiles": []}
	match u.kind:
		"fugu":
			if not u.awake:
				return {"type": "sleep", "tiles": []}
			if manhattan(u.pos, pp) == 1:
				return {"type": "bite", "tiles": [pp]}
			return {"type": "move", "tiles": []}
		"kurage":
			if u.phase == 1:
				var t := []
				for y in range(-1, 2):
					for x in range(-1, 2):
						var p: Vector2i = u.pos + Vector2i(x, y)
						if inside(p) and p != u.pos and tile(p) == WATER:
							t.append(p)
				return {"type": "zap", "tiles": t}
			return {"type": "charge", "tiles": []}
		"utsubo":
			var t := []
			var p: Vector2i = u.pos
			for i in 2:
				p += u.dir
				if tile(p) != WATER:
					break
				t.append(p)
			return {"type": "bite", "tiles": t}
	return {"type": "rest", "tiles": []}


## このカードを今使えるか
func can_play(i: int) -> bool:
	var d := Cards.def(hand[i])
	return d.cost >= 0 and d.cost <= energy and not targets(i).is_empty()


## カードで選べるマス
func targets(i: int) -> Array:
	var d := Cards.def(hand[i])
	var pp := ppos()
	var out := []
	match d.target:
		"move":
			var dist := _bfs(pp, false, d.range)
			for p in dist:
				if p != pp:
					out.append(p)
		"dive":
			var p := pp
			for k in d.range:
				p += Vector2i(0, 1)
				if not open(p):
					break
				out.append(p)
		"line":
			for dir in DIRS:
				var p: Vector2i = pp + dir
				if inside(p) and tile(p) == WATER:
					out.append(p)
		"adj":
			for dir in DIRS:
				if not unit_at(pp + dir).is_empty():
					out.append(pp + dir)
		"self":
			out.append(pp)
	return out


## カードを使う。at は選んだマス
func play(i: int, at: Vector2i) -> Array:
	var id: String = hand[i]
	var d := Cards.def(id)
	energy -= max(d.cost, 0)
	hand.remove_at(i)
	if d.get("exhaust", false) or id == "pearl":
		if id != "pearl":
			exhausted.append(id)
	else:
		discard.append(id)
	var ev := []
	var pp := ppos()
	match id:
		"swim", "swim2", "dive":
			var path: Array
			if id == "dive":
				path = [pp]
				var p := pp
				while p != at:
					p += Vector2i(0, 1)
					path.append(p)
				air = max(air - 1, 0)
				ev.append({"t": "air", "n": -1})
			else:
				path = _path(pp, at, _bfs(pp, false, d.range))
			ev.append_array(_move_player(path))
		"sonar":
			_reveal_around(pp, SONAR)
			ev.append({"t": "reveal", "at": pp, "r": SONAR})
			for u in enemies():
				if manhattan(u.pos, pp) <= SONAR and not u.awake:
					u.awake = true
					ev.append({"t": "wake", "id": u.id})
		"tail":
			var u := unit_at(at)
			ev.append_array(_damage(u, d.dmg))
			ev.append_array(_push(u, at - pp))
		"bubble":
			var dir: Vector2i = at - pp
			var p := pp
			var hit := []
			for k in d.range:
				p += dir
				if tile(p) != WATER:
					break
				hit.append(p)
			ev.append({"t": "beam", "tiles": hit, "kind": "bubble"})
			for q in hit:
				var u := unit_at(q)
				if not u.is_empty():
					ev.append_array(_damage(u, d.dmg))
					if u.hp > 0:
						u.stun = 1
						ev.append({"t": "stun", "id": u.id})
		"charge":
			var dir: Vector2i = at - pp
			var path := [pp]
			var p := pp
			var target := {}
			for k in d.range:
				var n: Vector2i = p + dir
				if not inside(n) or tile(n) != WATER:
					break
				target = unit_at(n)
				if not target.is_empty():
					break
				p = n
				path.append(p)
			if path.size() > 1:
				ev.append_array(_move_player(path))
			if not target.is_empty():
				ev.append({"t": "bump", "id": 0})
				ev.append_array(_damage(target, d.dmg))
				ev.append_array(_push(target, dir))
		"pod":
			var dir: Vector2i = at - pp
			var p := pp
			var hit := []
			while true:
				p += dir
				if not inside(p) or tile(p) == ROCK:
					break
				hit.append(p)
			ev.append({"t": "beam", "tiles": hit, "kind": "pod"})
			for q in hit:
				var u := unit_at(q)
				if not u.is_empty():
					ev.append_array(_damage(u, d.dmg))
		"whirl":
			ev.append({"t": "whirl", "at": pp})
			for y in range(-1, 2):
				for x in range(-1, 2):
					var u := unit_at(pp + Vector2i(x, y))
					if not u.is_empty() and u.id != 0:
						ev.append_array(_damage(u, d.dmg))
						var dir: Vector2i = Vector2i(x, y)
						if dir.x != 0 and dir.y != 0:
							dir = Vector2i(dir.x, 0) if rng.randf() < 0.5 else Vector2i(0, dir.y)
						ev.append_array(_push(u, dir))
		"breath", "rise", "pearl":
			var before := air
			air = min(air + int(d.air), MAX_AIR)
			ev.append({"t": "air", "n": air - before})
			if id == "rise":
				ev.append_array(_draw(1))
		"wing":
			ev.append_array(_draw(2))
		"spark":
			shield = true
			ev.append({"t": "shield"})
	_plan_intents()
	return ev


## 宝をミラにあずける（1階に1回、元気1）。手札からなくなり、持ち帰る宝の袋に入る
func can_stash(i: int) -> bool:
	return not bag_used and energy >= 1 and Cards.is_treasure(hand[i])


func stash(i: int) -> Array:
	var id: String = hand[i]
	hand.remove_at(i)
	bag.append(id)
	bag_used = true
	energy -= 1
	return [{"t": "stash", "card": id}]


func _move_player(path: Array) -> Array:
	var ev := [{"t": "move", "id": 0, "path": path}]
	var to: Vector2i = path[-1]
	player().pos = to
	for p in path:
		_reveal_around(p, SIGHT)
	var it: String = items.get(to, "")
	if ITEM_CARD.has(it):
		items.erase(to)
		discard.append(ITEM_CARD[it])
		ev.append({"t": "pickup", "item": it, "at": to, "card": ITEM_CARD[it]})
	elif it == "vent":
		items.erase(to)
		var before := air
		air = min(air + 4, MAX_AIR)
		ev.append({"t": "vent", "at": to, "air": air - before})
	elif it == "exit":
		ev.append({"t": "exit"})
	return ev


func _damage(u: Dictionary, n: int) -> Array:
	if u.is_empty() or u.hp <= 0:
		return []
	if u.id == 0:
		if shield:
			return [{"t": "block"}]
		hp = max(hp - n, 0)
		u.hp = hp
		return [{"t": "phit", "dmg": n}]
	u.hp -= n
	u.awake = true
	var ev := [{"t": "hit", "id": u.id, "dmg": n}]
	if u.hp <= 0:
		ev.append({"t": "die", "id": u.id})
	return ev


## 押し出す。岩や他の敵にぶつかるとさらに1
func _push(u: Dictionary, dir: Vector2i) -> Array:
	if u.is_empty() or u.hp <= 0 or u.kind == "utsubo":
		return []
	var to: Vector2i = u.pos + dir
	if open(to):
		u.pos = to
		return [{"t": "push", "id": u.id, "to": to}]
	var ev := [{"t": "bump", "id": u.id}]
	ev.append_array(_damage(u, 1))
	var other := unit_at(to)
	if not other.is_empty() and other.id != 0:
		ev.append_array(_damage(other, 1))
	return ev


## ターン終了：敵が動き、空気が減り、次のターンのカードを引く
func end_turn() -> Array:
	var ev := []
	discard.append_array(hand)
	hand.clear()
	for u in enemies():
		if u.hp <= 0:
			continue
		var it: Dictionary = u.intent
		if u.stun > 0:
			u.stun -= 1
			continue
		match it.get("type", ""):
			"move":
				var dist := _bfs(u.pos, false, 12)
				# カノープスのとなりのマスのうち、一番近い所へ1歩
				var best: Vector2i = u.pos
				var best_d: int = manhattan(u.pos, ppos())
				for d in DIRS:
					var n: Vector2i = u.pos + d
					if dist.has(n) and manhattan(n, ppos()) < best_d:
						best = n
						best_d = manhattan(n, ppos())
				if best != u.pos:
					ev.append({"t": "move", "id": u.id, "path": [u.pos, best]})
					u.pos = best
			"bite":
				ev.append({"t": "bite", "id": u.id, "tiles": it.tiles})
				for p in it.tiles:
					var v := unit_at(p)
					if not v.is_empty() and v.id != u.id:
						ev.append_array(_damage(v, ENEMIES[u.kind].dmg))
			"zap":
				ev.append({"t": "zap", "id": u.id, "tiles": it.tiles})
				for p in it.tiles:
					var v := unit_at(p)
					if not v.is_empty():
						ev.append_array(_damage(v, ENEMIES[u.kind].dmg))
		if u.kind == "kurage":
			u.phase = 1 - u.phase
	# 空気
	if air > 0:
		air -= 1
		ev.append({"t": "air", "n": -1})
	else:
		ev.append({"t": "drown"})
		hp = max(hp - 1, 0)
		player().hp = hp
		ev.append({"t": "phit", "dmg": 1})
	if hp <= 0:
		ev.append({"t": "faint"})
		return ev
	ev.append_array(_begin_turn())
	return ev


## 階を出たあと（空気だまり）。空気が少し戻る
func rest() -> void:
	air = min(air + REST_AIR, MAX_AIR)
	floor_no += 1


## 浮上して持ち帰る。気絶したときはミラが袋の分と、残りの半分を運ぶ
func surface(fainted: bool) -> int:
	var deck_value := carried_value()
	var bag_value := 0
	for c in bag:
		bag_value += int(Cards.def(c).value)
	if fainted:
		banked = bag_value + (deck_value - bag_value) / 2
	else:
		banked = deck_value
	return banked


## 空気だまりでもらえるカード3枚
func reward_choices() -> Array:
	var pool: Array = Cards.REWARDS.duplicate()
	_shuffle(pool)
	return pool.slice(0, 3)


func add_card(id: String) -> void:
	discard.append(id)
