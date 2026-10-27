extends SceneTree

## バランス確認：ボットに潜らせて、どの階まで行けたか・クリア率を数える。
## godot --headless -s res://tools/balance_sim.gd -- 回数 [log]
## ボット：となりに敵がいれば攻撃。いなければ、見張りの視界に入らないマスのうち出口に近い所へ泳ぐ。
## 宝箱が近ければ寄り道する。空気・体力が減ったら深呼吸・ぎゅっを使う。

static var DEATHS := {}
static var _last_hit := ""
static var _stall := 0
const MAX_TURNS := 80


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var n := int(args[0]) if args.size() > 0 else 100
	var log := args.size() > 1
	if not log:
		args.append("-1")
	var reach := {}
	var clears := 0
	var turns := [0, 0, 0, 0]
	var tcnt := [0, 0, 0, 0]
	var spots := 0
	var kills := 0
	var t0 := Time.get_ticks_msec()
	for i in n:
		var r := _run(i, log and i == int(args[1]))
		reach[r.stage] = reach.get(r.stage, 0) + 1
		clears += 1 if r.clear else 0
		spots += r.spots
		kills += r.kills
		for s in r.turns:
			turns[s] += r.turns[s]
			tcnt[s] += 1
	var s := PackedStringArray()
	for k in [1, 2, 3]:
		s.append("%d階:%d" % [k, reach.get(k, 0)])
	var ts := PackedStringArray()
	for k in [1, 2, 3]:
		if tcnt[k] > 0:
			ts.append("%d階%.1fターン" % [k, turns[k] / float(tcnt[k])])
	print("クリア %d/%d  最後の階 %s  %s  見つかった%.1f回 倒した%.1f体/ラン (%.1fs)" % [clears, n, " ".join(s),
		" ".join(ts), spots / float(n), kills / float(n), (Time.get_ticks_msec() - t0) / 1000.0])
	print("倒れた理由 ", DEATHS)
	quit()


func _run(seed_value: int, log: bool) -> Dictionary:
	var t := Tactics.new(seed_value)
	t.start_stage()
	var turns := {}
	while true:
		var n := 0
		_stall = 0
		while not t.exited and t.hp > 0 and n < MAX_TURNS:
			var before: Vector2i = t.me().pos
			_turn(t, log)
			_stall = _stall + 1 if t.me().pos == before else 0
			if log and _stall == 5:
				_dump(t)
			if t.exited or t.hp <= 0:
				break
			var ev := t.end_turn()
			_note(ev)
			n += 1
		turns[t.stage] = n
		if log:
			print("stage %d  turns %d  hp %d air %d spotted %d" % [t.stage, n, t.hp, t.air, t.spotted])
		if t.hp <= 0 or not t.exited:
			if not t.exited and t.hp > 0:
				DEATHS["時間切れ"] = DEATHS.get("時間切れ", 0) + 1
			return {"stage": t.stage, "clear": false, "turns": turns, "spots": t.spotted_total, "kills": t.kills}
		if t.cleared:
			return {"stage": t.stage, "clear": true, "turns": turns, "spots": t.spotted_total, "kills": t.kills}
		t.add_card(t.reward_choices()[0])
		t.next_stage()
	return {}


func _note(ev: Array) -> void:
	for e in ev:
		if e.t == "phit":
			_last_hit = "空気" if e.air else "敵"
		if e.t == "faint":
			DEATHS[_last_hit] = DEATHS.get(_last_hit, 0) + 1


func _turn(t: Tactics, log: bool) -> void:
	for guard in 8:
		if t.exited or t.hp <= 0 or t.hand.is_empty():
			return
		var c := _choose(t)
		if c.is_empty():
			return
		var ev := t.play(c.card, c.as_move, c.at)
		_note(ev)
		if ev.any(func(e): return e.t == "chest"):
			t.add_card(t.reward_choices()[0])
		if log:
			print("  ", Cards.def(c.card_id).name, " (泳ぐ)" if c.as_move else "", " ", c.at, " hp", t.hp, " air", t.air)


func _choose(t: Tactics) -> Dictionary:
	var pos: Vector2i = t.me().pos
	for k in t.hand.size():
		if not t.can_play(k):
			continue
		var id: String = t.hand[k]
		if id == "wing":
			return {"card": k, "card_id": id, "as_move": false, "at": pos}
		if id == "breath" and t.air < 10:
			return {"card": k, "card_id": id, "as_move": false, "at": pos}
		if id == "hug" and t.hp <= t.max_hp - 5:
			return {"card": k, "card_id": id, "as_move": false, "at": pos}
	if t.plays_left <= 0:
		return {}
	# となりの敵を攻撃
	for k in t.hand.size():
		var id: String = t.hand[k]
		var d := Cards.def(id)
		if d.kind != "atk" or d.target == "self":
			continue
		var tg := t.targets(k)
		for p in tg:
			var u = t.unit_at(p)
			if u != null and u.id != 0 and _dist(p, pos) <= 2:
				return {"card": k, "card_id": id, "as_move": false, "at": p}
	# 移動：見張られていない所で、ゴール（宝箱か出口）に近い所
	var goal := _goal(t)
	var watched := t.watched()
	var best := {}
	var best_score := _score(t, pos, goal, watched) + 0.5
	for k in t.hand.size():
		var id: String = t.hand[k]
		var d := Cards.def(id)
		var opts := [[t.swim_targets(k), true]]
		if d.target == "move":
			opts.append([t.targets(k), false])
		for o in opts:
			for p in o[0]:
				var sc := _score(t, p, goal, watched)
				if o[1] and d.kind == "atk" and _stall < 1:
					sc -= 1.5
				if sc > best_score:
					best_score = sc
					best = {"card": k, "card_id": id, "as_move": o[1], "at": p}
	return best


func _goal(t: Tactics) -> Vector2i:
	var pos: Vector2i = t.me().pos
	var best := Vector2i.ZERO
	for p in t.items:
		if t.items[p] == "exit":
			best = p
	var bd := 999
	for p in t.items:
		if t.items[p] in ["chest", "vent", "pearl"]:
			var dd := t._path(pos, p, false).size()
			if dd > 0 and dd < bd and dd <= 6:
				bd = dd
				best = p
	return best


func _score(t: Tactics, p: Vector2i, goal: Vector2i, watched: Dictionary) -> float:
	var d := t._path(p, goal, false).size() if p != goal else 0
	var sc := -float(d)
	# 足止めが続いたら、見つかってもいいから進む
	if watched.has(p) and t.tile(p) != Tactics.WEED:
		sc -= 8.0 if _stall < 2 else 1.0
	return sc


func _dist(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)


func _dump(t: Tactics) -> void:
	for y in Tactics.H:
		var row := ""
		for x in Tactics.W:
			var p := Vector2i(x, y)
			var u = t.unit_at(p)
			if u != null:
				row += "C" if u.id == 0 else u.kind[0].to_upper()
			elif t.items.has(p):
				row += t.items[p][0]
			else:
				row += [".", "#", "w"][t.tile(p)]
		print(row)
	print(t.hand, " goal ", _goal(t))
