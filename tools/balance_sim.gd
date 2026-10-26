extends SceneTree

## バランス確認：ボットに潜らせて、どの階まで行けたか・クリア率を数える。
## godot --headless -s res://tools/balance_sim.gd -- 回数 [log]
## ボット：数字から「確実に安全」と分かるマスを先に照らし、勝てる敵は弱い順に倒す。
## 体力が減ったらレベルアップ（全回復）を使う。手詰まりなら音波、それでもだめなら一番ましなマスに賭ける。

static var DEATHS := {}
static var STUCK := {}
const PERK_ORDER := ["scale", "sonar", "mira", "greed", "lung", "hunt", "eye", "nose"]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var n := int(args[0]) if args.size() > 0 else 100
	var log := args.size() > 1
	var reach := {}
	var clears := 0
	var lv_sum := [0, 0, 0, 0]
	var lv_cnt := [0, 0, 0, 0]
	var gambles := 0
	var t0 := Time.get_ticks_msec()
	for i in n:
		var r := _run(i, log and i < 3)
		reach[r.floor] = reach.get(r.floor, 0) + 1
		clears += 1 if r.clear else 0
		gambles += r.gambles
		for f in r.lvs:
			lv_sum[f] += r.lvs[f]
			lv_cnt[f] += 1
	var s := PackedStringArray()
	for k in [1, 2, 3]:
		s.append("%d階:%d" % [k, reach.get(k, 0)])
	var lvs := PackedStringArray()
	for f in [1, 2, 3]:
		if lv_cnt[f] > 0:
			lvs.append("%d階末Lv%.1f" % [f, lv_sum[f] / float(lv_cnt[f])])
	print("クリア %d/%d  倒れた階 %s  %s  賭け%.1f回/ラン  (%.1fs)" % [clears, n, " ".join(s), " ".join(lvs),
		gambles / float(n), (Time.get_ticks_msec() - t0) / 1000.0])
	print("倒れた理由 ", DEATHS)
	var ks := STUCK.keys()
	ks.sort_custom(func(a, b): return STUCK[a] > STUCK[b])
	for k in ks.slice(0, 12):
		print("  ", k, " x", STUCK[k])
	quit()


func _run(seed_value: int, log: bool) -> Dictionary:
	var g := Sweep.new(seed_value)
	var lvs := {}
	var gambles := 0
	while true:
		g.start_floor()
		var res := _play_floor(g)
		gambles += res.gambles
		if log:
			print("  %d階 %s Lv%d 体力%d/%d 空気%d" % [g.floor_no, res.end, g.lv, g.hp, g.max_hp, g.air])
		if res.end == "faint" or res.end == "stuck":
			return {"floor": g.floor_no, "clear": false, "lvs": lvs, "gambles": gambles}
		lvs[g.floor_no] = g.lv
		if res.end == "star":
			return {"floor": 4, "clear": true, "lvs": lvs, "gambles": gambles}
		var ch := g.perk_choices()
		ch.sort_custom(func(a, b): return PERK_ORDER.find(a) < PERK_ORDER.find(b))
		g.next_floor(ch[0])
	return {}


func _apply(g: Sweep, ev: Array) -> String:
	for e in ev:
		if e.t in ["faint", "exit", "star"]:
			return e.t
	return ""


func _play_floor(g: Sweep) -> Dictionary:
	var gambles := 0
	for step in 400:
		var act := _choose(g)
		var ev: Array
		match act[0]:
			"tap":
				ev = g.tap(act[1])
				if act.size() > 2:
					gambles += 1
			"level":
				ev = g.level_up()
			"item":
				ev = g.use_item(act[1])
			"sonar":
				ev = g.sonar(act[1])
			"mira":
				ev = g.mira_hint(act[1])
			_:
				var hidden := 0
				for q in g.all_cells():
					if not g.cell(q).seen:
						hidden += 1
				var key := "詰み f%d 体力%d/%d Lv%d xp%d/%d 未照らし%d" % [g.floor_no, g.hp, g.max_hp, g.lv, g.xp, g.xp_need(), hidden / 5 * 5]
				STUCK[key] = STUCK.get(key, 0) + 1
				return {"end": "stuck", "gambles": gambles}
		var r := _apply(g, ev)
		if r == "faint":
			var why: String = "賭け" if act.size() > 2 else str(act[0])
			for e in ev:
				if e.t == "drown":
					why = "空気"
				if e.t == "fight":
					why += "(強さ%d 体力%d/%d Lv%d)" % [e.lv, g.hp + e.dmg, g.max_hp, g.lv] if g.floor_no == 3 and e.lv >= 9 else ""
			DEATHS[why] = DEATHS.get(why, 0) + 1
		if r != "":
			return {"end": r, "gambles": gambles}
	return {"end": "stuck", "gambles": gambles}


## 照らしていないマスの強さの上限（まわりの数字から）。手がかりがなければ 99
func _bound(g: Sweep, q: Vector2i) -> int:
	var c := g.cell(q)
	if c.hint == "safe" or c.hint == "item" or c.hint == "exit":
		return 0
	if c.hint.begins_with("lv"):
		return int(c.hint.substr(2))
	var b := 99
	for n in g.neighbors(q):
		var d := g.cell(n)
		if not g.is_open(n) or (d.item != "" and not d.taken and d.item != "exit"):
			continue
		var known := 0
		for m in g.neighbors(n):
			var e := g.cell(m)
			if e.seen and e.enemy > 0 and e.alive:
				known += e.enemy
		b = mini(b, g.number(n) - known)
	return b


func _choose(g: Sweep) -> Array:
	if g.air <= 0 and g.items.bottle > 0:
		return ["item", "bottle"]
	# 空気が少ないときは出口へ（最後の階は海竜へ）
	var goal := Vector2i(-1, -1)
	for p in g.all_cells():
		var c := g.cell(p)
		if (c.item == "exit") or (c.enemy == 10 and c.alive):
			goal = p
	var dist_goal := 99
	if goal.x >= 0:
		for p in g.all_cells():
			if g.is_open(p):
				dist_goal = mini(dist_goal, maxi(absi(p.x - goal.x), absi(p.y - goal.y)))
	if g.floor_no < Sweep.FLOORS and g.air <= dist_goal + 2:
		if g.reachable(goal):
			return ["tap", goal]
		var best_p := Vector2i(-1, -1)
		var best_s := 999
		for p in g.all_cells():
			if g.cell(p).seen or not g.reachable(p):
				continue
			var b := _bound(g, p)
			if b >= g.hp:
				continue
			var s := maxi(absi(p.x - goal.x), absi(p.y - goal.y)) * 10 + mini(b, 9)
			if s < best_s:
				best_s = s
				best_p = p
		if best_p.x >= 0:
			return ["tap", best_p, "gamble"] if _bound(g, best_p) > 0 else ["tap", best_p]
	# 物を拾う
	for p in g.all_cells():
		var c := g.cell(p)
		if c.seen and c.item != "" and not c.taken and c.item != "exit" and g.reachable(p):
			return ["tap", p]
	# 確実に安全なマス
	var frontier := []
	for p in g.all_cells():
		if not g.cell(p).seen and g.reachable(p):
			frontier.append(p)
	for p in frontier:
		if _bound(g, p) == 0 and g.cell(p).hint != "exit":
			if g.air <= 0 and g.items.bottle > 0:
				return ["item", "bottle"]
			return ["tap", p]
	# まわりの未照らしが1マスだけの数字 → そのマスの強さがぴったり分かる
	for p in frontier:
		var ex := _exact(g, p)
		if ex > 0 and ex < g.hp and g.cell(p).hint != "exit":
			return ["tap", p]
	# 見えている敵で勝てるもの（弱い順）
	var foes := []
	for p in g.all_cells():
		var c := g.cell(p)
		if c.seen and c.enemy > 0 and c.alive and g.reachable(p):
			foes.append(p)
	foes.sort_custom(func(a, b): return g.cell(a).enemy < g.cell(b).enemy)
	for p in foes:
		if g.cell(p).enemy < g.hp:
			return ["tap", p]
	# 回復（レベルアップの全回復は、体力が少ないときまで取っておく）
	if g.can_level_up() and g.hp <= max(2, g.max_hp / 3):
		return ["level"]
	if g.items.pearl > 0 and g.hp <= g.max_hp - 3:
		return ["item", "pearl"]
	for p in foes:
		if g.cell(p).enemy < g.hp:
			return ["tap", p]
	# 手がかりがないなら音波・ミラ
	var best: Variant = null
	var bb := 999
	for p in frontier:
		if g.cell(p).hint == "exit":
			continue
		var b := _bound(g, p)
		if b < bb:
			bb = b
			best = p
	if g.sonar_left > 0 and frontier.size() > 0 and bb >= g.hp:
		return ["sonar", frontier[g.rng.randi_range(0, frontier.size() - 1)]]
	if g.mira_left > 0 and best != null and bb >= 2:
		return ["mira", best]
	# 出口が見えていれば出る
	if g.floor_no < Sweep.FLOORS:
		for p in g.all_cells():
			if g.cell(p).item == "exit" and g.reachable(p):
				return ["tap", p]
	if best != null and bb < g.hp:
		return ["tap", best, "gamble"]
	if g.can_level_up():
		return ["level"]
	if best != null and bb < 99:
		return ["tap", best, "gamble"]
	# 出口がまだ見えていない：一番手がかりのないマスに賭ける
	if best != null:
		return ["tap", best, "gamble"]
	return ["stuck"]


## 隣の数字のうち、未照らしのマスが q だけのものがあれば、q の強さが分かる（-1 なら不明）
func _exact(g: Sweep, q: Vector2i) -> int:
	for n in g.neighbors(q):
		if not g.is_open(n):
			continue
		var d := g.cell(n)
		if d.item != "" and not d.taken and d.item != "exit":
			continue
		var hidden := 0
		var known := 0
		for m in g.neighbors(n):
			var e := g.cell(m)
			if not e.seen:
				hidden += 1
			elif e.enemy > 0 and e.alive:
				known += e.enemy
		if hidden == 1:
			return g.number(n) - known
	return -1
