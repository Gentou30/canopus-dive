class_name Sweep
extends RefCounted

## 深海マインスイーパーのルール。画面とは切り離してあり、balance_sim からも使う。
## 暗い海をマスで区切り、照らしたマスの隣（ななめも）を順に照らして進む。
## 照らした空きマスには「まわり8マスの、生きている敵の強さの合計」が出る（音波の跳ね返り）。
## 敵のマスを照らす・タップすると戦う：強さの分だけ体力が減り、倒すと強さの分の経験値。
## 経験値がたまったらレベルアップ（体力が全回復して最大体力も増える）。いつ上げるかは自分で決める。
## 行動の結果は events（辞書の配列）で返し、画面側が順に演出する。
##   {t:"open", cells}  照らした / {t:"fight", at, lv, dmg} / {t:"kill", at, xp} / {t:"faint"}
##   {t:"item", at, item} 拾った / {t:"vent", at, air} / {t:"air", n} / {t:"drown"} / {t:"exit", at}
##   {t:"sonar", at, cells} / {t:"hint", at, info} / {t:"ink", at, cells}（タコの墨が晴れる）/ {t:"star"}

const W := 8
const H := 10
const FLOORS := 3
const START_HP := 5
const START_AIR := 18
const VENT_AIR := 8
const COIN_XP := 2

## 強さごとの敵（絵の名前と呼び名）
const KINDS := {1: "fugu", 2: "kurage", 3: "utsubo", 4: "tako", 5: "ankou", 6: "same", 7: "kani", 8: "ika", 10: "ryu"}
const NAMES := {"fugu": "フグ", "kurage": "クラゲ", "utsubo": "ウツボ", "tako": "タコ", "ankou": "アンコウ",
	"same": "サメ", "kani": "オオガニ", "ika": "ダイオウイカ", "ryu": "海竜"}
const NOTES := {"tako": "倒すと墨が晴れて、まわりが見える", "ankou": "ちょうちんが光っていて、最初から見える",
	"ryu": "星のかけらを守っている。倒せばクリア"}

## 階ごとの敵の強さの一覧
const FLOOR_ENEMIES := [
	[1, 1, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5],
	[1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6, 6, 7],
	[1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 8, 10],
]
## 階ごとの物（金貨=経験値、真珠=体力回復、泡のびん=空気、宝箱=どれか、泡=空気の湧く所）
const FLOOR_ITEMS := [
	["coin", "coin", "coin", "coin", "pearl", "bottle", "chest", "vent", "vent"],
	["coin", "coin", "coin", "coin", "pearl", "pearl", "bottle", "chest", "vent", "vent"],
	["coin", "coin", "coin", "coin", "coin", "coin", "pearl", "pearl", "bottle", "chest", "chest", "vent", "vent"],
]

## 階のあいだに選ぶ強化
const PERKS := {
	"scale": ["丈夫なうろこ", "最大体力 +2"],
	"lung": ["大きな肺", "階のはじめの空気 +10"],
	"sonar": ["響く音波", "音波を1階に1回多く使える"],
	"mira": ["ミラのおやつ", "ミラのカンを1階に1回多く使える"],
	"greed": ["ドラゴンの欲", "金貨の経験値が2倍"],
	"hunt": ["シャチの狩り", "強さ1の敵からはダメージを受けない"],
	"eye": ["アンコウの目", "階のはじめに、一番強い敵の場所が見える"],
	"nose": ["宝の匂い", "階のはじめに、宝と泡の場所が見える"],
}

var rng := RandomNumberGenerator.new()

# ラン全体
var floor_no := 1
var lv := 1
var xp := 0
var max_hp := START_HP
var hp := START_HP
var perks: Array[String] = []
var items := {"pearl": 0, "bottle": 0}
var kills := 0
var cleared := false

# 階
var air := START_AIR
var sonar_left := 0
var mira_left := 0
var cells := []      # [{enemy(lv,0=なし), alive, item, seen, taken, hint}] y*W+x
var start := Vector2i.ZERO
var canopus := Vector2i.ZERO   # カノープスが今いるマス（演出用）


func _init(seed_value: int = -1) -> void:
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()


# ───────── 便利 ─────────

func inside(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < W and p.y < H


func cell(p: Vector2i) -> Dictionary:
	return cells[p.y * W + p.x]


func neighbors(p: Vector2i) -> Array:
	var out := []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var q := p + Vector2i(dx, dy)
			if (dx != 0 or dy != 0) and inside(q):
				out.append(q)
	return out


func all_cells() -> Array:
	var out := []
	for y in H:
		for x in W:
			out.append(Vector2i(x, y))
	return out


func has_perk(id: String) -> bool:
	return id in perks


func xp_need() -> int:
	return 2 + lv * 2


func can_level_up() -> bool:
	return xp >= xp_need()


func enemy_kind(p: Vector2i) -> String:
	return KINDS.get(cell(p).enemy, "fugu")


## 照らした空きマスの数字（まわりの生きている敵の強さの合計）
func number(p: Vector2i) -> int:
	var n := 0
	for q in neighbors(p):
		var c := cell(q)
		if c.enemy > 0 and c.alive:
			n += c.enemy
	return n


## 通れるマス（照らしてあって、生きている敵がいない）
func is_open(p: Vector2i) -> bool:
	var c := cell(p)
	return c.seen and not (c.enemy > 0 and c.alive)


## タップして何かできるマスか（通れるマスの隣、または通れるマスそのものに物がある）
func reachable(p: Vector2i) -> bool:
	if not inside(p):
		return false
	for q in neighbors(p):
		if is_open(q):
			return true
	return is_open(p)


func sonar_max() -> int:
	return 2 + (1 if has_perk("sonar") else 0)


func mira_max() -> int:
	return 1 + (1 if has_perk("mira") else 0)


# ───────── 階を作る ─────────

func start_floor() -> Array:
	air = START_AIR + (10 if has_perk("lung") else 0)
	sonar_left = sonar_max()
	mira_left = mira_max()
	cells.clear()
	for i in W * H:
		cells.append({"enemy": 0, "alive": false, "item": "", "seen": false, "taken": false, "hint": ""})
	start = Vector2i(rng.randi_range(2, W - 3), 0)
	canopus = start
	var safe := {start: true}
	for q in neighbors(start):
		safe[q] = true
	var free := all_cells().filter(func(p): return not safe.has(p))
	_shuffle(free)
	var lvls: Array = FLOOR_ENEMIES[floor_no - 1].duplicate()
	# 最後の階の海竜は、いちばん下の段に置く
	if lvls.has(10):
		lvls.erase(10)
		var bottom := free.filter(func(p): return p.y == H - 1)
		var b: Vector2i = bottom[rng.randi_range(0, bottom.size() - 1)]
		free.erase(b)
		_put_enemy(b, 10)
	# 強い敵ほど下（深い所）に置かれやすい
	lvls.sort()
	lvls.reverse()
	for l in lvls:
		var want := clampi(int(float(l) / 8.0 * H) + rng.randi_range(-3, 2), 2, H - 1)
		if l >= 3:
			want = maxi(want, 3)
		free.sort_custom(func(a, b): return absi(a.y - want) < absi(b.y - want) or (l >= 3 and a.y >= 3 and b.y < 3))
		var k := rng.randi_range(0, mini(5, free.size() - 1))
		_put_enemy(free[k], l)
		free.remove_at(k)
	_shuffle(free)
	for it in FLOOR_ITEMS[floor_no - 1]:
		cell(free.pop_back()).item = it
	# 出口（最後の階は海竜を倒すとクリアなので無し）
	if floor_no < FLOORS:
		var low := free.filter(func(p): return p.y >= H - 2)
		var e: Vector2i = low[rng.randi_range(0, low.size() - 1)] if not low.is_empty() else free.pop_back()
		free.erase(e)
		cell(e).item = "exit"
	# 最初から見えるもの
	var ev := [{"t": "open", "cells": _flood(start)}]
	for p in all_cells():
		var c := cell(p)
		if enemy_kind(p) == "ankou" and c.enemy == 5:
			c.seen = true
		if c.item == "exit":
			c.hint = "exit"
	if has_perk("eye"):
		var best := Vector2i(-1, -1)
		for p in all_cells():
			if cell(p).enemy > 0 and (best.x < 0 or cell(p).enemy > cell(best).enemy):
				best = p
		cell(best).seen = true
	if has_perk("nose"):
		for p in all_cells():
			if cell(p).item in ["coin", "pearl", "bottle", "chest", "vent"]:
				cell(p).hint = "item"
	return ev


func _put_enemy(p: Vector2i, l: int) -> void:
	var c := cell(p)
	c.enemy = l
	c.alive = true


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t


## p を照らし、数字が0なら隣も続けて照らす（マインスイーパーと同じ）
func _flood(p: Vector2i) -> Array:
	var out := []
	var q := [p]
	while not q.is_empty():
		var c: Vector2i = q.pop_back()
		var d := cell(c)
		if d.seen and c != p:
			continue
		if not d.seen:
			d.seen = true
			out.append(c)
		if d.enemy > 0 and d.alive:
			continue
		if d.item != "" and not d.taken and d.item != "exit":
			continue
		if number(c) == 0:
			for n in neighbors(c):
				if not cell(n).seen:
					q.append(n)
	return out


# ───────── 行動 ─────────

## マスをタップしたとき。照らす・戦う・拾う・出口に入る
func tap(p: Vector2i) -> Array:
	if not reachable(p):
		return []
	var c := cell(p)
	var ev := []
	if not c.seen:
		# 照らすと空気を1使う。空気がなければ体力が減る
		if air > 0:
			air -= 1
			ev.append({"t": "air", "n": -1})
		else:
			hp -= 1
			ev.append({"t": "drown"})
			if hp <= 0:
				ev.append({"t": "faint"})
				return ev
		c.seen = true
		c.hint = "" if c.hint != "exit" else c.hint
		ev.append({"t": "open", "cells": [p]})
	canopus = p
	if c.enemy > 0 and c.alive:
		ev.append_array(_fight(p))
		return ev
	if c.item != "" and not c.taken:
		ev.append_array(_take(p))
		if c.item == "exit":
			return ev
	# 数字が0ならまわりも照らす（空気は使わない）
	var more := _flood(p)
	more.erase(p)
	if not more.is_empty():
		ev.append({"t": "open", "cells": more})
	return ev


func _fight(p: Vector2i) -> Array:
	var c := cell(p)
	var dmg: int = c.enemy
	if dmg == 1 and has_perk("hunt"):
		dmg = 0
	hp -= dmg
	var ev := [{"t": "fight", "at": p, "lv": c.enemy, "dmg": dmg}]
	if hp <= 0:
		hp = 0
		ev.append({"t": "faint"})
		return ev
	c.alive = false
	xp += c.enemy
	kills += 1
	ev.append({"t": "kill", "at": p, "xp": c.enemy})
	if c.enemy == 10:
		cleared = true
		ev.append({"t": "star"})
		return ev
	if enemy_kind(p) == "tako":
		var opened := []
		for q in neighbors(p):
			if not cell(q).seen:
				cell(q).seen = true
				opened.append(q)
		ev.append({"t": "ink", "at": p, "cells": opened})
	var more := _flood(p)
	more.erase(p)
	if not more.is_empty():
		ev.append({"t": "open", "cells": more})
	return ev


func _take(p: Vector2i) -> Array:
	var c := cell(p)
	var it: String = c.item
	if it == "exit":
		return [{"t": "exit", "at": p}]
	c.taken = true
	match it:
		"coin":
			var gain := COIN_XP * (2 if has_perk("greed") else 1)
			xp += gain
			return [{"t": "item", "at": p, "item": it, "xp": gain}]
		"vent":
			air += VENT_AIR
			return [{"t": "vent", "at": p, "air": VENT_AIR}]
		"pearl", "bottle":
			items[it] += 1
			return [{"t": "item", "at": p, "item": it}]
		"chest":
			var got: String = ["pearl", "bottle", "coin3"][rng.randi_range(0, 2)]
			if got == "coin3":
				xp += 5
				return [{"t": "item", "at": p, "item": "chest", "got": "coin3", "xp": 5}]
			items[got] += 1
			return [{"t": "item", "at": p, "item": "chest", "got": got}]
	return []


func level_up() -> Array:
	if not can_level_up():
		return []
	xp -= xp_need()
	lv += 1
	max_hp += 1
	hp = max_hp
	return [{"t": "levelup", "lv": lv}]


## 持ち物を使う：真珠（体力+3）、泡のびん（空気+10）
func use_item(it: String) -> Array:
	if items.get(it, 0) <= 0:
		return []
	items[it] -= 1
	if it == "pearl":
		var before := hp
		hp = mini(hp + 3, max_hp)
		return [{"t": "heal", "n": hp - before}]
	air += 10
	return [{"t": "air", "n": 10}]


## 音波：どこでも 3×3 を照らす（敵は見えるだけで戦わない。物も拾わない）
func sonar(p: Vector2i) -> Array:
	if sonar_left <= 0:
		return []
	sonar_left -= 1
	var opened := []
	for q in [p] + neighbors(p):
		if not cell(q).seen:
			cell(q).seen = true
			opened.append(q)
	return [{"t": "sonar", "at": p, "cells": opened}]


## ミラのカン：照らしていないマスに何がいるかだけ教えてくれる
func mira_hint(p: Vector2i) -> Array:
	if mira_left <= 0 or cell(p).seen:
		return []
	mira_left -= 1
	var c := cell(p)
	var info := "safe"
	if c.enemy > 0 and c.alive:
		info = "lv%d" % c.enemy
	elif c.item != "":
		info = "item"
	c.hint = info
	return [{"t": "hint", "at": p, "info": info}]


## 次の階へ。空気だまりで体力は全回復する
func next_floor(perk: String) -> void:
	hp = max_hp
	if perk != "":
		perks.append(perk)
		if perk == "scale":
			max_hp += 2
			hp += 2
	floor_no += 1


func perk_choices() -> Array:
	var pool: Array = PERKS.keys().filter(func(k): return not has_perk(k) or k == "scale")
	_shuffle(pool)
	return pool.slice(0, 3)
