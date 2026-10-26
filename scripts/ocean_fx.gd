class_name OceanFx
extends Node2D

## 背景の上の水中の演出：水面から差しこむ光の筋と、下から上る泡。
## light は光の強さ（浅瀬 1.0 → 深海 0）。深海では泡の代わりに青白い光の粒がただよう。

var area := Vector2(720, 1280)
var light := 1.0
var _t := 0.0
var _bubbles := []   # [{pos, r, speed, phase}]


func setup(view: Vector2, light_amount: float) -> void:
	area = view
	light = light_amount
	_bubbles.clear()
	for i in 34:
		_bubbles.append(_new_bubble(true))


func resize(view: Vector2) -> void:
	area = view


func _new_bubble(anywhere: bool) -> Dictionary:
	return {"pos": Vector2(randf() * area.x, randf() * area.y if anywhere else area.y + 20),
		"r": randf_range(2.0, 7.0), "speed": randf_range(25.0, 70.0), "phase": randf() * TAU}


func _process(delta: float) -> void:
	_t += delta
	for i in _bubbles.size():
		var b: Dictionary = _bubbles[i]
		b.pos.y -= b.speed * delta
		b.pos.x += sin(_t * 1.5 + b.phase) * 12.0 * delta
		if b.pos.y < -20:
			_bubbles[i] = _new_bubble(false)
	queue_redraw()


func _draw() -> void:
	# 光の筋：上が広く下へ細くなる台形を、ゆっくり左右にゆらす
	if light > 0.01:
		for k in 5:
			var x := area.x * (0.1 + k * 0.21) + sin(_t * 0.3 + k * 1.7) * area.x * 0.06
			var w := area.x * (0.05 + 0.03 * sin(_t * 0.5 + k))
			var a := (0.06 + 0.04 * sin(_t * 0.7 + k * 2.0)) * light
			var tilt := area.y * 0.25
			var pts := PackedVector2Array([Vector2(x - w, -10), Vector2(x + w, -10),
				Vector2(x + w * 0.3 + tilt, area.y * 0.85), Vector2(x - w * 0.3 + tilt, area.y * 0.85)])
			var cols := PackedColorArray([Color(0.8, 0.95, 1, a), Color(0.8, 0.95, 1, a), Color(0.8, 0.95, 1, 0), Color(0.8, 0.95, 1, 0)])
			draw_polygon(pts, cols)
	for b in _bubbles:
		if light > 0.3:
			draw_arc(b.pos, b.r, 0, TAU, 16, Color(0.85, 0.97, 1, 0.45), 1.5)
			draw_circle(b.pos + Vector2(-b.r * 0.35, -b.r * 0.35), b.r * 0.25, Color(1, 1, 1, 0.5))
		else:
			# 深いところでは光る粒
			var a := 0.3 + 0.3 * sin(_t * 2.0 + b.phase)
			draw_circle(b.pos, b.r * 0.6, Color(0.5, 0.9, 1.0, a * 0.5))
			draw_circle(b.pos, b.r * 0.25, Color(0.85, 1.0, 1.0, a))
