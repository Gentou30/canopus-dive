class_name Board
extends Control

## 海底の盤。マス・岩・宝・霧・選べるマス・敵の予告を描き、キャラ（Actor）を子に持つ。
## タップされたマスは cell_tapped で知らせる。

signal cell_tapped(p: Vector2i)

const OBJ_NAMES := ["chest", "coin", "pearl", "gem", "vent", "exit", "rock", "coral"]

var dive: Dive
var cs := 80.0                  # マスの大きさ
var marks := {}                 # Vector2i -> Color（カードで選べるマス）
var preview := {}               # Vector2i -> Color（効果が届くマスの下見）
var show_intents := true
var actors := {}                # unit id -> Actor
var mira: Actor
var _t := 0.0
var _obj := {}
var _rings := []                # [{at, r, life}] 音波など
var _flashes := []              # [{tiles, color, life}]
var _font: Font
var _top: Node2D       # キャラより手前に描く物（敵の予告マーク）


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


func _draw_top() -> void:
	if dive == null or not show_intents:
		return
	for u in dive.enemies():
		if dive.is_seen(u.pos):
			_draw_intent_icon(u)


func setup(d: Dive, cell: float) -> void:
	dive = d
	cs = cell
	size = Vector2(Dive.W, Dive.H) * cs
	for a in actors.values():
		a.queue_free()
	actors.clear()
	if mira:
		mira.queue_free()
	for u in d.units:
		var a := Actor.new(u.kind, cs * (1.15 if u.id == 0 else 1.0), u.id != 0)
		a.position = center(u.pos)
		add_child(a)
		actors[u.id] = a
		if u.kind == "utsubo":
			a.flip = u.dir.x > 0
	# ミラはカノープスの斜め後ろをついてくる（盤の上では当たり判定なし）
	mira = Actor.new("mira", cs * 0.7, false)
	mira.position = center(d.ppos()) + Vector2(-cs * 0.42, -cs * 0.38)
	add_child(mira)
	move_child(mira, 0)
	sync_visibility()


## マスの大きさだけ変える（画面の向きが変わったとき）
func relayout(cell: float) -> void:
	cs = cell
	size = Vector2(Dive.W, Dive.H) * cs
	for u in dive.units:
		if actors.has(u.id):
			actors[u.id].size = cs * (1.15 if u.id == 0 else 1.0)
			actors[u.id].position = center(u.pos)
	mira.size = cs * 0.7
	mira.position = center(dive.ppos()) + Vector2(-cs * 0.42, -cs * 0.38)


func center(p: Vector2i) -> Vector2:
	return (Vector2(p) + Vector2(0.5, 0.5)) * cs


func cell_at(local: Vector2) -> Vector2i:
	return Vector2i(floor(local.x / cs), floor(local.y / cs))


## 霧の中の敵は隠す
func sync_visibility() -> void:
	for u in dive.units:
		if actors.has(u.id):
			actors[u.id].visible = u.hp > 0 and dive.is_seen(u.pos)


func ring(at: Vector2i, r: float, color: Color = Color(0.6, 0.95, 1.0)) -> void:
	_rings.append({"at": center(at), "r": r * cs, "life": 0.0, "color": color})


func flash_tiles(tiles: Array, color: Color, sec: float = 0.5) -> void:
	_flashes.append({"tiles": tiles, "color": color, "life": sec, "max": sec})


func _gui_input(e: InputEvent) -> void:
	if (e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT):
		var p := cell_at(e.position)
		if dive and dive.inside(p):
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
	queue_redraw()
	if _top:
		_top.queue_redraw()


func _draw() -> void:
	if dive == null:
		return
	var full := Rect2(Vector2.ZERO, size)
	# 盤の下地（水の中の海底）
	draw_style_box(UiStyle.panel(Color(0.5, 0.85, 1.0, 0.5), Color(0.02, 0.1, 0.18, 0.55), 12, 14), full.grow(8))
	for y in Dive.H:
		for x in Dive.W:
			var p := Vector2i(x, y)
			var r := Rect2(Vector2(p) * cs, Vector2(cs, cs))
			var t := dive.tile(p)
			# 市松に少しだけ色を変えて、マスを数えやすくする
			var c := Color(0.25, 0.55, 0.7, 0.16) if (x + y) % 2 == 0 else Color(0.18, 0.45, 0.6, 0.16)
			draw_rect(r.grow(-1.5), c)
			if t != Dive.WATER:
				_draw_obj("rock" if t == Dive.ROCK else "coral", r, 1.08)
	# 物
	for p in dive.items:
		var it: String = dive.items[p]
		var r := Rect2(Vector2(p) * cs, Vector2(cs, cs))
		if it == "exit":
			# 出口は霧の中でも光って見える
			var glow := 0.5 + 0.3 * sin(_t * 3.0)
			draw_circle(center(p), cs * 0.5, Color(0.4, 0.8, 1.0, 0.18 * glow))
			_draw_obj("exit", r, 0.95)
		elif dive.is_seen(p):
			var bobbing := r
			if it != "vent":
				bobbing.position.y += sin(_t * 2.0 + p.x) * cs * 0.03
				# 宝はきらっと光る
				var tw := maxf(sin(_t * 3.0 + p.x * 1.7 + p.y), 0.0)
				draw_circle(center(p), cs * 0.36, Color(1, 0.95, 0.6, 0.12 + 0.1 * tw))
			_draw_obj(it, bobbing, 0.82)
	# 霧
	for y in Dive.H:
		for x in Dive.W:
			var p := Vector2i(x, y)
			if not dive.is_seen(p):
				var r := Rect2(Vector2(p) * cs, Vector2(cs, cs))
				var wob := 0.04 * sin(_t * 1.3 + x * 0.9 + y * 1.3)
				draw_rect(r, Color(0.01, 0.04, 0.1, 0.74 + wob))
				if dive.items.get(p, "") == "exit":
					draw_circle(center(p), cs * 0.3, Color(0.5, 0.9, 1.0, 0.25 + 0.15 * sin(_t * 3.0)))
	# 敵の予告（次の敵の番に攻撃が来るマス）
	if show_intents:
		for u in dive.enemies():
			if not dive.is_seen(u.pos):
				continue
			var it: Dictionary = u.intent
			var col := Color(1, 0.25, 0.2) if it.get("type", "") == "bite" else Color(1, 0.85, 0.2)
			for p in it.get("tiles", []):
				var r := Rect2(Vector2(p) * cs, Vector2(cs, cs)).grow(-4)
				var a := 0.22 + 0.12 * sin(_t * 6.0)
				draw_rect(r, Color(col, a))
				draw_rect(r, Color(col, 0.85), false, 3.0)
				# 斜線で「危ない」ことを示す
				for k in range(1, 4):
					var o := r.size.x * k / 4.0
					draw_line(r.position + Vector2(o, 0), r.position + Vector2(0, o), Color(col, 0.35), 2.0)
	# 下見（カードの効果が届くマス）
	for p in preview:
		var r := Rect2(Vector2(p) * cs, Vector2(cs, cs)).grow(-6)
		draw_rect(r, Color(preview[p], 0.25))
	# 選べるマス
	var pulse := 0.5 + 0.5 * sin(_t * 5.0)
	for p in marks:
		var col: Color = marks[p]
		var r := Rect2(Vector2(p) * cs, Vector2(cs, cs)).grow(-5)
		draw_rect(r, Color(col, 0.18 + 0.12 * pulse))
		draw_rect(r, Color(col, 0.9), false, 3.0 + pulse * 1.5)
	# 光った所
	for f in _flashes:
		var a: float = f.life / f.max
		for p in f.tiles:
			draw_rect(Rect2(Vector2(p) * cs, Vector2(cs, cs)).grow(-2), Color(f.color, 0.7 * a))
	# 音波の輪
	for r in _rings:
		var k: float = r.life / 0.9
		for j in 3:
			var kk: float = clamp(k - j * 0.15, 0.0, 1.0)
			if kk > 0:
				draw_arc(r.at, r.r * kk, 0, TAU, 64, Color(r.color, (1.0 - kk) * 0.8), 4.0 - j)


func _draw_obj(n: String, r: Rect2, scale: float) -> void:
	var tex: Texture2D = _obj.get(n)
	if tex == null:
		var c := {"rock": Color(0.35, 0.38, 0.42), "coral": Color(0.9, 0.45, 0.6), "coin": Color.GOLD,
			"pearl": Color.WHITE, "gem": Color(0.3, 0.6, 1), "vent": Color(0.6, 0.9, 1), "exit": Color(0, 0, 0)}
		draw_circle(r.get_center(), r.size.x * 0.35, c.get(n, Color.MAGENTA))
		return
	var s := tex.get_size()
	var k: float = min(r.size.x / s.x, r.size.y / s.y) * scale
	var sz := s * k
	draw_texture_rect(tex, Rect2(r.get_center() - sz / 2, sz), false)


func _draw_intent_icon(u: Dictionary) -> void:
	var t: String = u.intent.get("type", "")
	var txt: String = {"bite": "噛", "zap": "雷", "charge": "ため", "sleep": "zzz", "rest": "休", "move": "→"}.get(t, "")
	if u.stun > 0:
		txt = "泡"
	if txt == "" or _font == null:
		return
	var at := center(u.pos) + Vector2(cs * 0.3, -cs * 0.36)
	var col: Color = {"bite": UiStyle.DANGER, "zap": Color(1, 0.85, 0.2), "charge": Color(1, 0.85, 0.2)}.get(t, Color(0.75, 0.85, 0.95))
	var fs := int(cs * 0.24)
	var w := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var box := Rect2(at - Vector2(w / 2 + 6, fs * 0.6), Vector2(w + 12, fs * 1.2))
	_top.draw_style_box(UiStyle.panel(col, Color(0.03, 0.05, 0.1, 0.9), 0, 8), box)
	_top.draw_string(_font, Vector2(at.x - w / 2, at.y + fs * 0.36), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
