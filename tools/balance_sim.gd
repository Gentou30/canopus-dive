extends SceneTree

## バランス確認：ボットに潜らせて、どこまで行けたか・何点持ち帰ったかを数える。
## godot --headless -s res://tools/balance_sim.gd -- 回数 [log]
## ボット：見えている宝へ寄り道しながら出口を目指し、となりの敵は叩く。空気が減ったら息を継ぐ。
## 空気だまりでは「体力と空気に余裕があれば潜る」。greed を変えて欲張り具合ごとに比べる。

const PICK := ["charge", "swim2", "rise", "whirl", "bubble", "pod", "wing", "spark", "dive", "tail", "sonar"]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var n := int(args[0]) if args.size() > 0 else 100
	var log := args.size() > 1
	for greed in [0, 1, 2]:
		var floors := {}
		var faint := 0
		var total := 0
		var turns := 0
		for i in n:
			var r := _run(i, greed, log and i == 0)
			floors[r.floor] = floors.get(r.floor, 0) + 1
			faint += 1 if r.faint else 0
			total += r.score
			turns += r.turns
		var keys := floors.keys()
		keys.sort()
		var s := PackedStringArray()
		for k in keys:
			s.append("%d:%d" % [k, floors[k]])
		print("欲張り%d  平均%d点  気絶%d/%d  1階あたり%.1fターン  到達階 %s" % [greed, total / n, faint, n,
			turns / float(max(1, _floors_sum(floors))), " ".join(s)])
	quit()


func _floors_sum(f: Dictionary) -> int:
	var t := 0
	for k in f:
		t += k * f[k]
	return t


func _run(seed_value: int, greed: int, log: bool) -> Dictionary:
	var d := Dive.new(seed_value)
	var turns := 0
	while true:
		d.start_floor()
		var res := _play_floor(d, log)
		turns += res.turns
		if res.faint:
			return {"floor": d.floor_no, "faint": true, "score": d.surface(true), "turns": turns}
		if d.floor_no >= Dive.FLOORS:
			return {"floor": d.floor_no, "faint": false, "score": d.surface(false), "turns": turns}
		# 空気だまり
		var ch := d.reward_choices()
		ch.sort_custom(func(a, b): return PICK.find(a) < PICK.find(b))
		d.add_card(ch[0])
		d.rest()
		var need_air := 6 - greed * 2
		if d.hp < 3 - greed or d.air < need_air:
			return {"floor": d.floor_no - 1, "faint": false, "score": d.surface(false), "turns": turns}
	return {}


func _play_floor(d: Dive, log: bool) -> Dictionary:
	for t in 60:
		var acted := true
		while acted:
			acted = false
			var i := _choose(d)
			if i[0] < 0:
				break
			var ev := d.play(i[0], i[1])
			acted = true
			for e in ev:
				if e.t == "exit":
					if log:
						print("  %d階 %dターン hp%d 空気%d 宝%d" % [d.floor_no, t + 1, d.hp, d.air, d.carried_value()])
					return {"faint": false, "turns": t + 1}
		var ev2 := d.end_turn()
		for e in ev2:
			if e.t == "faint":
				if log:
					print("  %d階で気絶" % d.floor_no)
				return {"faint": true, "turns": t + 1}
	return {"faint": true, "turns": 60}


func _danger(d: Dive) -> Dictionary:
	var out := {}
	for u in d.enemies():
		for p in u.intent.get("tiles", []):
			out[p] = true
		# 起きているフグのとなりも危ない
		if u.kind == "fugu" and u.awake:
			for dir in Dive.DIRS:
				out[u.pos + dir] = true
	return out


## [手札の番号, マス]。何もしないなら [-1]
func _choose(d: Dive) -> Array:
	var pp := d.ppos()
	var hand := d.hand
	# 1. 空気がない
	if d.air <= 3:
		for i in hand.size():
			if hand[i] in ["breath", "rise", "pearl"] and d.can_play(i):
				return [i, pp]
	# 2. となりの敵を叩く
	for i in hand.size():
		if not d.can_play(i):
			continue
		var c: String = hand[i]
		if c in ["tail"]:
			return [i, d.targets(i)[0]]
		if c in ["bubble", "charge", "pod"]:
			for p in d.targets(i):
				var dir: Vector2i = p - pp
				for k in range(1, 4):
					var u := d.unit_at(pp + dir * k)
					if not u.is_empty() and u.id != 0:
						return [i, p]
					if d.tile(pp + dir * k) != Dive.WATER:
						break
		if c == "whirl":
			for y in range(-1, 2):
				for x in range(-1, 2):
					var u := d.unit_at(pp + Vector2i(x, y))
					if not u.is_empty() and u.id != 0:
						return [i, pp]
	# 3. 音波・引く
	for i in hand.size():
		if hand[i] in ["sonar", "wing"] and d.can_play(i) and (hand[i] != "sonar" or d.turn % 2 == 1):
			return [i, pp]
	# 4. 移動：見えている宝（空気に余裕があれば）か出口へ
	var goal := _goal(d)
	var danger := _danger(d)
	var dist := _dist_from(d, goal)
	var best := [-1]
	var best_score: int = dist.get(pp, 99) * 10 + (5 if danger.has(pp) else 0)
	for i in hand.size():
		var c: String = hand[i]
		if Cards.def(c).target != "move" and c != "dive":
			continue
		if not d.can_play(i):
			continue
		for p in d.targets(i):
			var s: int = dist.get(p, 99) * 10 + (5 if danger.has(p) else 0)
			if s < best_score:
				best_score = s
				best = [i, p]
	return best


func _goal(d: Dive) -> Vector2i:
	var pp := d.ppos()
	var exit := Vector2i.ZERO
	for p in d.items:
		if d.items[p] == "exit":
			exit = p
	var best := exit
	var bd := 99
	var dist := _dist_from(d, pp)
	for p in d.items:
		var it: String = d.items[p]
		if it == "exit" or not d.is_seen(p):
			continue
		if it == "vent" and d.air > 8:
			continue
		if dist.has(p) and dist[p] < bd and d.air > dist[p] / 2 + Dive.manhattan(p, exit) / 3 + 2:
			bd = dist[p]
			best = p
	return best


func _dist_from(d: Dive, from: Vector2i) -> Dictionary:
	return d._bfs(from, true)
