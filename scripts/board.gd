class_name Board
extends Control

## 深海の盤（マインスイーパー型）。照らしていないマスは暗い水、照らしたマスは海底と数字。
## 敵は Actor（ドット絵）を子に持ち、照らした敵だけ見せる。カノープスとミラも子の Actor。
## タップされたマスは cell_tapped で知らせる。

signal cell_tapped(p: Vector2i)

const OBJ_NAMES := ["chest", "coin", "pearl", "gem", "vent", "exit", "rock", "coral"]
## 数字の色（マインスイーパーと同じく、大きいほど暖色）
const NUM_COLORS := [Color(0.55, 0.9, 1.0), Color(0.55, 1.0, 0.6), Color(1.0, 0.95, 0.45), Color(1.0, 0.7, 0.35),
	Color(1.0, 0.45, 0.4), Color(1.0, 0.45, 0.75), Color(0.8, 0.55, 1.0)]

var game: Sweep
var cs := 80.0
var marks := {}          # Vector2i -> true（プレイヤーのメモ）
var mode := ""           # "" / "sonar" / "mira" / "memo"（選べるマスの光り方が変わる）
var hover := Vector2i(-1, -1)
var actors := {}         # Vector2i(敵のいるマス) -> Actor
var canopus: Actor
var mira: Actor
var _t := 0.0
var _obj := {}
var _rings := []
var _flashes := []
var _pop := {}           # Vector2i -> 照らした瞬間からの時間（数字がぽんと出る）
var _font: Font
var _top: Node2D


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	for n in OBJ_NAMES:
		var p := "res://assets/images/obj/%s.png" % n
		_obj[n] = load(p) if ResourceLoader.exists(p) else null


func _ready() -> void:
	_font = get_theme_default_font()
	_top = Node2D.new()
	_top.z_index = 10
	_top.draw.connect(_draw_top)
	add_child(_top)


func setup(g: Sweep, cell: float) -> void:
	game = g
	cs = cell
	size = Vector2(Sweep.W, Sweep.H) * cs
	for a in actors.values():
		a.queue_free()
	actors.clear()
	if canopus:
		canopus.queue_free()
		mira.queue_free()
	for p in g.all_cells():
		var c := g.cell(p)
		if c.enemy > 0 and c.alive:
			var big := 1.5 if c.enemy == 10 else 1.0
			var a := Actor.new(g.enemy_kind(p), cs * 0.95 * big, true)
			a.position = center(p)
			a.bob = 0.6
			add_child(a)
			actors[p] = a
	canopus = Actor.new("canopus", cs * 1.05, false)
	canopus.position = center(g.canopus)
	add_child(canopus)
	mira = Actor.new("mira", cs * 0.7, false)
	mira.position = mira_spot(g.canopus, false)
	add_child(mira)
	if _top:
		move_child(_top, -1)
	sync()


func center(p: Vector2i) -> Vector2:
	return (Vector2(p) + Vector2(0.5, 0.5)) * cs


## ミラはカノープスの斜め後ろに浮かぶ
func mira_spot(p: Vector2i, facing_left: bool) -> Vector2:
	return center(p) + Vector2(cs * (0.4 if facing_left else -0.4), -cs * 0.35)


func cell_at(local: Vector2) -> Vector2i:
	return Vector2i(floor(local.x / cs), floor(local.y / cs))


## 敵の見え方をルールに合わせる（照らした生きている敵だけ）
func sync() -> void:
	for p in actors:
		var c := game.cell(p)
		var a: Actor = actors[p]
		if c.alive:
			a.visible = c.seen


func pop(cells: Array) -> void:
	for p in cells:
		_pop[p] = 0.0


func ring(at: Vector2i, r: float, color: Color = Color(0.6, 0.95, 1.0)) -> void:
	_rings.append({"at": center(at), "r": r * cs, "life": 0.0, "color": color})


func flash_tiles(tiles: Array, color: Color, sec: float = 0.5) -> void:
	_flashes.append({"tiles": tiles, "color": color, "life": sec, "max": sec})


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		hover = cell_at(e.position)
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		var p := cell_at(e.position)
		hover = p
		if game and game.inside(p):
			cell_tapped.emit(p)
			accept_event()


func _process(delta: float) -> void:
	_t += delta
	for r in _rings:
		r.life += delta
	_rings = _rings.filter(func(r): return r.life < 0.9)
	for f in _flashes:
		f.life -= delta
	_flashes = _flashes.filter(func(f): return f.life > 0)
	for p in _pop.keys():
		_pop[p] += delta
		if _pop[p] > 0.5:
			_pop.erase(p)
	queue_redraw()
	if _top:
		_top.queue_redraw()


func _draw() -> void:
	if game == null:
		return
	draw_style_box(UiStyle.panel(Color(0.5, 0.85, 1.0, 0.55), Color(0.01, 0.05, 0.1, 0.5), 12, 14), Rect2(Vector2.ZERO, size).grow(8))
	var pulse := 0.5 + 0.5 * sin(_t * 4.0)
	for p in game.all_cells():
		var c := game.cell(p)
		var r := Rect2(Vector2(p) * cs, Vector2(cs, cs)).grow(-2)
		if not c.seen:
			# 暗い水。照らせるマス（通れるマスの隣）はふちを光らせる
			var wob := 0.04 * sin(_t * 1.3 + p.x * 0.9 + p.y * 1.3)
			draw_rect(r, Color(0.03, 0.09, 0.2, 0.86 + wob))
			draw_rect(Rect2(r.position, Vector2(r.size.x, r.size.y * 0.35)), Color(0.2, 0.4, 0.6, 0.12))
			if game.reachable(p):
				var col := UiStyle.PINK if mode == "mira" else UiStyle.AQUA
				draw_rect(r, Color(col, 0.2 + 0.25 * pulse * (1.0 if mode != "" else 0.5)), false, 2.5)
			elif mode == "sonar":
				draw_rect(r, Color(UiStyle.AQUA, 0.15), false, 1.5)
			continue
		# 照らしたマス：海底の砂
		draw_rect(r, Color(0.55, 0.75, 0.85, 0.16) if (p.x + p.y) % 2 == 0 else Color(0.45, 0.65, 0.8, 0.16))
	# 物（照らしたマスだけ）
	for p in game.all_cells():
		var c := game.cell(p)
		if not c.seen or c.item == "" or c.taken:
			continue
		var r := Rect2(Vector2(p) * cs, Vector2(cs, cs))
		if c.item == "exit":
			draw_circle(center(p), cs * 0.5, Color(0.4, 0.8, 1.0, 0.18 + 0.12 * pulse))
			_draw_obj("exit", r, 0.95)
			continue
		var bob := r
		bob.position.y += sin(_t * 2.0 + p.x) * cs * 0.03
		var tw := maxf(sin(_t * 3.0 + p.x * 1.7 + p.y), 0.0)
		draw_circle(center(p), cs * 0.34, Color(1, 0.95, 0.6, 0.1 + 0.1 * tw))
		_draw_obj(obj_name(c.item), bob, 0.78)
	for f in _flashes:
		var a: float = f.life / f.max
		for p in f.tiles:
			draw_rect(Rect2(Vector2(p) * cs, Vector2(cs, cs)).grow(-2), Color(f.color, 0.65 * a))


static func obj_name(item: String) -> String:
	return {"bottle": "gem"}.get(item, item)


## キャラより手前：数字・ヒント・メモ・敵の強さ・輪
func _draw_top() -> void:
	if game == null or _font == null:
		return
	for p in game.all_cells():
		var c := game.cell(p)
		var ctr := center(p)
		if c.seen:
			var empty: bool = not (c.enemy > 0 and c.alive) and (c.item == "" or c.taken)
			if empty:
				var n := game.number(p)
				if n > 0:
					var k: float = clamp(_pop.get(p, 1.0) / 0.25, 0.0, 1.0)
					var fs := int(cs * (0.5 + 0.25 * (1.0 - k)))
					var col: Color = NUM_COLORS[mini(int((n - 1) / 2), NUM_COLORS.size() - 1)]
					if p == game.canopus:
						# カノープスが立っているマスは、数字を右下に小さく
						fs = int(cs * 0.32)
						_text_c(str(n), ctr + Vector2(cs * 0.3, cs * 0.42), fs, col, 6)
					else:
						_text_c(str(n), ctr + Vector2(0, fs * 0.36), fs, col, 7)
			continue
		# 照らしていないマスの印
		match c.hint:
			"exit":
				var a := 0.35 + 0.25 * sin(_t * 3.0)
				_top.draw_circle(ctr, cs * 0.3, Color(0.5, 0.9, 1.0, a))
				_text_c("出口", ctr + Vector2(0, cs * 0.1), int(cs * 0.24), Color(0.85, 0.97, 1.0), 5)
			"safe":
				_top.draw_arc(ctr, cs * 0.22, 0, TAU, 24, Color(UiStyle.PINK, 0.95), 4.0)
			"item":
				_text_c("★", ctr + Vector2(0, cs * 0.14), int(cs * 0.4), Color(1, 0.9, 0.4, 0.9), 5)
			_:
				if c.hint.begins_with("lv"):
					var box := Rect2(ctr - Vector2(cs * 0.32, cs * 0.22), Vector2(cs * 0.64, cs * 0.44))
					_top.draw_style_box(UiStyle.panel(UiStyle.PINK, Color(0.25, 0.05, 0.15, 0.85), 0, 10), box)
					_text_c("強" + c.hint.substr(2), ctr + Vector2(0, cs * 0.1), int(cs * 0.26), UiStyle.PINK, 4)
		if marks.has(p):
			_text_c("！", ctr + Vector2(0, cs * 0.16), int(cs * 0.45), Color(1, 0.55, 0.3), 6)
	# 見えている敵の強さ（今の体力で負ける敵は赤）
	for p in actors:
		var c := game.cell(p)
		if c.seen and c.alive:
			var at := center(p) + Vector2(cs * 0.3, -cs * 0.3)
			var danger: bool = c.enemy >= game.hp
			_top.draw_circle(at, cs * 0.18, Color(0.6, 0.05, 0.1) if danger else Color(0.05, 0.1, 0.2))
			_top.draw_arc(at, cs * 0.18, 0, TAU, 20, UiStyle.DANGER if danger else Color.WHITE, 2.0)
			_text_c(str(c.enemy), at + Vector2(0, cs * 0.085), int(cs * 0.25), Color.WHITE, 0)
	# 音波を使うときは、3×3 の範囲を見せる
	if mode == "sonar" and game.inside(hover):
		var r := Rect2(Vector2(hover - Vector2i(1, 1)) * cs, Vector2(cs, cs) * 3)
		_top.draw_rect(r, Color(UiStyle.AQUA, 0.15))
		_top.draw_rect(r, Color(UiStyle.AQUA, 0.8), false, 3.0)
	for r in _rings:
		var k: float = r.life / 0.9
		for j in 3:
			var kk: float = clamp(k - j * 0.15, 0.0, 1.0)
			if kk > 0:
				_top.draw_arc(r.at, r.r * kk, 0, TAU, 64, Color(r.color, (1.0 - kk) * 0.8), 4.0 - j)


func _text_c(s: String, at: Vector2, fs: int, col: Color, ol: int) -> void:
	var w := _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var p := Vector2(at.x - w / 2, at.y)
	if ol > 0:
		_top.draw_string_outline(_font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ol, UiStyle.INK)
	_top.draw_string(_font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw_obj(n: String, r: Rect2, scale: float) -> void:
	var tex: Texture2D = _obj.get(n)
	if tex == null:
		draw_circle(r.get_center(), r.size.x * 0.3, Color.MAGENTA)
		return
	var s := tex.get_size()
	var k: float = min(r.size.x / s.x, r.size.y / s.y) * scale
	var sz := s * k
	draw_texture_rect(tex, Rect2(r.get_center() - sz / 2, sz), false)
