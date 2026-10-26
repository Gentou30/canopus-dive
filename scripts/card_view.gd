class_name CardView
extends Control

## 手札のカード1枚。種類で色を変え、上に絵（icons.png の 1コマ）、下に名前と説明。
## 左上の丸が元気のコスト。宝のカードは金色で、持ち帰ると何点かを出す。

signal tapped(cv: CardView)

const ICON_COLS := 4

static var _icons: Texture2D
static var _obj := {}

var id := ""
var index := -1
var selected := false
var playable := true
var _lift := 0.0
var _t := 0.0


func _init(card_id: String = "") -> void:
	id = card_id
	mouse_filter = Control.MOUSE_FILTER_STOP
	pivot_offset = Vector2.ZERO
	if _icons == null and ResourceLoader.exists("res://assets/images/ui/icons.png"):
		_icons = load("res://assets/images/ui/icons.png")


static func obj_tex(n: String) -> Texture2D:
	if not _obj.has(n):
		var p := "res://assets/images/obj/%s.png" % n
		_obj[n] = load(p) if ResourceLoader.exists(p) else null
	return _obj[n]


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit(self)
		accept_event()


func _process(delta: float) -> void:
	_t += delta
	var goal := 1.0 if selected else 0.0
	_lift = move_toward(_lift, goal, delta * 8.0)
	queue_redraw()


func _draw() -> void:
	if id == "":
		return
	var d := Cards.def(id)
	var w := size.x
	var h := size.y
	var top := -_lift * h * 0.14
	var r := Rect2(0, top, w, h)
	var main: Color = UiStyle.KIND_COLORS[d.kind]
	var dim := 1.0 if playable else 0.55
	# 影
	draw_style_box(_box(Color(0, 0, 0, 0.4), Color(0, 0, 0, 0), 0), Rect2(4, top + 6, w, h))
	# 札の本体：上が明るいグラデーション風（2色を重ねる）
	var edge := UiStyle.GOLD if selected else Color(1, 1, 1, 0.85)
	draw_style_box(_box(Color(main.darkened(0.45) * dim, 1), edge, 3), r)
	draw_style_box(_box(Color(main.lightened(0.1) * dim, 0.55), Color(0, 0, 0, 0), 0),
		Rect2(5, top + 5, w - 10, h * 0.5))
	# 絵
	var art := Rect2(w * 0.12, top + h * 0.1, w * 0.76, w * 0.76)
	draw_style_box(_box(Color(0.02, 0.06, 0.12, 0.55), Color(1, 1, 1, 0.25), 1), art)
	if d.kind == "treasure":
		var tex := obj_tex(["chest", "coin", "pearl", "gem"][int(d.get("obj", 1))])
		if tex:
			_fit(tex, art.grow(-6), Color(dim, dim, dim))
	elif _icons:
		var cell := _icons.get_size().x / ICON_COLS
		var ix := int(d.icon)
		draw_texture_rect_region(_icons, art.grow(-4), Rect2((ix % ICON_COLS) * cell, (ix / ICON_COLS) * cell, cell, cell),
			Color(dim, dim, dim))
	var font := get_theme_default_font()
	# 名前
	var name_fs := int(w * 0.15) if d.name.length() <= 4 else int(w * 0.62 / d.name.length())
	_text(font, d.name, Vector2(w / 2, top + h * 0.1 + w * 0.76 + name_fs + 6), name_fs, Color.WHITE)
	# 説明（2行まで）
	var lines: PackedStringArray = d.desc.split("\n")
	var fs := int(w * 0.105)
	for i in min(lines.size(), 2):
		var lf: int = min(fs, int((w - 12) / max(lines[i].length(), 1)))
		_text(font, lines[i], Vector2(w / 2, top + h - h * 0.17 + i * (fs + 3)), lf, Color(0.92, 0.96, 1.0), 4)
	# コスト
	if d.cost >= 0:
		var c := Vector2(w * 0.13, top + w * 0.13)
		draw_circle(c, w * 0.13, Color(0.05, 0.1, 0.2))
		draw_circle(c, w * 0.11, UiStyle.AQUA if playable else Color(0.4, 0.5, 0.6))
		_text(font, str(d.cost), c + Vector2(0, w * 0.075), int(w * 0.17), Color(0.02, 0.1, 0.2), 0)
	if d.kind == "treasure":
		var c := Vector2(w * 0.83, top + w * 0.13)
		var v := str(d.value)
		draw_style_box(_box(Color(0.25, 0.15, 0.02), UiStyle.GOLD, 2), Rect2(c - Vector2(w * 0.18, w * 0.1), Vector2(w * 0.36, w * 0.2)))
		_text(font, v, c + Vector2(0, w * 0.06), int(w * 0.14), UiStyle.GOLD, 0)
	if selected:
		var a := 0.3 + 0.2 * sin(_t * 6.0)
		draw_style_box(_box(Color(0, 0, 0, 0), Color(UiStyle.GOLD, a), 6), r.grow(4))


func _text(font: Font, s: String, at: Vector2, fs: int, col: Color, ol: int = 5) -> void:
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var p := Vector2(at.x - w / 2, at.y)
	if ol > 0:
		draw_string_outline(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ol, UiStyle.INK)
	draw_string(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _fit(tex: Texture2D, r: Rect2, mod: Color) -> void:
	var s := tex.get_size()
	var k: float = min(r.size.x / s.x, r.size.y / s.y)
	var sz := s * k
	draw_texture_rect(tex, Rect2(r.get_center() - sz / 2, sz), false, mod)


func _box(bg: Color, edge: Color, bw: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = edge
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(int(size.x * 0.09))
	sb.anti_aliasing = true
	return sb
