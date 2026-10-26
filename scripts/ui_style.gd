class_name UiStyle

## 見た目の共通設定。深い紺の水中に、水色のふちと金を差し色にする。

const GOLD := Color(1.0, 0.84, 0.36)
const AQUA := Color(0.42, 0.9, 1.0)
const AIR := Color(0.55, 0.85, 1.0)
const HEART := Color(1.0, 0.38, 0.45)
const PINK := Color(1.0, 0.55, 0.78)     # ミラの色
const DANGER := Color(1.0, 0.3, 0.3)
const PANEL_BG := Color(0.03, 0.08, 0.16, 0.88)
const INK := Color(0.02, 0.05, 0.1, 0.95)

const KIND_COLORS := {
	"move": Color(0.2, 0.55, 0.85),
	"atk": Color(0.85, 0.3, 0.3),
	"skill": Color(0.3, 0.7, 0.5),
	"treasure": Color(0.85, 0.65, 0.2),
}


static func panel(edge: Color = AQUA, bg: Color = PANEL_BG, glow: int = 8, radius: int = 18) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = edge
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(radius)
	sb.shadow_color = Color(edge, 0.3)
	sb.shadow_size = glow
	sb.anti_aliasing = true
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


## 丸くてぷっくりしたボタン。上半分に明るい帯を重ねてつやを出す
static func button_styles(b: Button, main: Color = Color(0.1, 0.45, 0.8)) -> void:
	b.add_theme_stylebox_override("normal", _glossy(main, Color(1, 1, 1, 0.9), 4))
	b.add_theme_stylebox_override("hover", _glossy(main.lightened(0.15), GOLD, 10))
	b.add_theme_stylebox_override("pressed", _glossy(main.darkened(0.25), GOLD, 2))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("disabled", _glossy(Color(0.25, 0.3, 0.38), Color(0.5, 0.55, 0.6), 0))
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color(1, 0.97, 0.8))
	b.add_theme_color_override("font_pressed_color", GOLD)
	b.add_theme_color_override("font_disabled_color", Color(0.65, 0.7, 0.75))
	b.add_theme_constant_override("outline_size", 7)
	b.add_theme_color_override("font_outline_color", Color(main.darkened(0.7), 0.95))


static func _glossy(main: Color, edge: Color, glow: int) -> StyleBoxFlat:
	var sb := panel(edge, main, glow, 26)
	sb.set_border_width_all(3)
	sb.border_blend = false
	# 下側を濃くして立体感を出す
	sb.border_width_bottom = 7
	sb.border_color = edge
	sb.expand_margin_bottom = 0
	return sb


static func outline(l: Control, size: int = 8) -> void:
	l.add_theme_constant_override("outline_size", size)
	l.add_theme_color_override("font_outline_color", INK)


static func label(text: String, size: int, color: Color = Color.WHITE, ol: int = 8) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	outline(l, ol)
	return l
