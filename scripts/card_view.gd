class_name CardView
extends Control

## 手札のカード1枚。種類で色を変え、まん中に絵、下に名前。
## 左上の泡＝使うと減る空気（コスト）。右上の青い札＝「泳ぐ」として使ったときのマス数。

signal tapped(cv: CardView)

const ICON_COLS := 4
const KIND_COLORS := {
	"move": Color(0.2, 0.55, 0.85),
	"atk": Color(0.85, 0.3, 0.3),
	"skill": Color(0.3, 0.7, 0.5),
	"mira": Color(0.85, 0.42, 0.7),
}

static var _icons: Texture2D
static var _icons2: Texture2D

var id := ""
var index := -1
var selected := false
var playable := true
var _lift := 0.0
var _t := 0.0


func _init(card_id: String = "") -> void:
	id = card_id
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _icons == null:
		_icons = load("res://assets/images/ui/icons.png")
		if ResourceLoader.exists("res://assets/images/ui/icons2.png"):
			_icons2 = load("res://assets/images/ui/icons2.png")


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit(self)
		accept_event()


func _process(delta: float) -> void:
	_t += delta
	_lift = move_toward(_lift, 1.0 if selected else 0.0, delta * 8.0)
	queue_redraw()


func _draw() -> void:
	if id == "":
		return
	var d := Cards.def(id)
	var w := size.x
	var h := size.y
	var top := -_lift * h * 0.16
	var r := Rect2(0, top, w, h)
	var main: Color = KIND_COLORS[d.kind]
	var dim := 1.0 if playable else 0.5
	draw_style_box(_box(Color(0, 0, 0, 0.4), Color(0, 0, 0, 0), 0), Rect2(4, top + 6, w, h))
	var edge := UiStyle.GOLD if selected else Color(1, 1, 1, 0.85)
	draw_style_box(_box(Color(main.darkened(0.45) * dim, 1), edge, 3), r)
	draw_style_box(_box(Color(main.lightened(0.1) * dim, 0.55), Color(0, 0, 0, 0), 0), Rect2(5, top + 5, w - 10, h * 0.5))
	# 絵
	var art := Rect2(w * 0.1, top + h * 0.13, w * 0.8, w * 0.8)
	draw_style_box(_box(Color(0.02, 0.06, 0.12, 0.55), Color(1, 1, 1, 0.25), 1), art)
	var ix := int(d.icon)
	var sheet := _icons if ix < 12 else _icons2
	if sheet:
		var cols := 4
		var cell := sheet.get_size().x / cols
		var k := ix if ix < 12 else ix - 12
		draw_texture_rect_region(sheet, art.grow(-3), Rect2((k % cols) * cell, (k / cols) * cell, cell, cell), Color(dim, dim, dim))
	var font := get_theme_default_font()
	# 名前（2行に分けない。長いときは小さく）
	var name_fs: int = mini(int(w * 0.17), int((w - 10) / max(d.name.length(), 1)))
	_text(font, d.name, Vector2(w / 2, top + h * 0.13 + w * 0.8 + name_fs + 8), name_fs, Color.WHITE)
	# 泳ぐマス数（右上）
	var mv := Rect2(w - w * 0.36, top - h * 0.03, w * 0.4, w * 0.24)
	draw_style_box(_box(Color(0.08, 0.35, 0.65) * Color(dim, dim, dim), Color(1, 1, 1, 0.9), 2), mv)
	_text(font, "泳%d" % int(d.mv), mv.get_center() + Vector2(0, w * 0.06), int(w * 0.15), Color.WHITE, 4)
	# コスト（左上の泡）
	var c := Vector2(w * 0.1, top + w * 0.06)
	draw_circle(c, w * 0.13, Color(0.03, 0.1, 0.2))
	draw_circle(c, w * 0.11, UiStyle.AIR * Color(dim, dim, dim) if int(d.cost) > 0 else Color(0.35, 0.45, 0.55))
	draw_circle(c + Vector2(-w * 0.04, -w * 0.04), w * 0.03, Color(1, 1, 1, 0.7))
	_text(font, str(d.cost), c + Vector2(0, w * 0.065), int(w * 0.17), Color(0.02, 0.1, 0.2), 0)
	if d.get("free", false):
		_text(font, "おまけ", Vector2(w / 2, top + h - 6), int(w * 0.12), UiStyle.GOLD, 4)
	if selected:
		var a := 0.35 + 0.25 * sin(_t * 6.0)
		draw_style_box(_box(Color(0, 0, 0, 0), Color(UiStyle.GOLD, a), 6), r.grow(4))


func _text(font: Font, s: String, at: Vector2, fs: int, col: Color, ol: int = 5) -> void:
	var tw := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var p := Vector2(at.x - tw / 2, at.y)
	if ol > 0:
		draw_string_outline(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ol, UiStyle.INK)
	draw_string(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _box(bg: Color, edge: Color, bw: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = edge
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(int(size.x * 0.09))
	sb.anti_aliasing = true
	return sb
