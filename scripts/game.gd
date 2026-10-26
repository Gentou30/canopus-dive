extends Control

## 画面の流れ：TITLE →（はじめてなら おはなし）→ PLAY（階）→ REST（空気だまり）→ PLAY … → RESULT
## ルールは Dive（dive.gd）。ここは画面づくりと演出。Dive が返す events を _run_events で順に見せる。

enum { TITLE, PLAY, REST, RESULT }

const BGS := ["bg_shallow", "bg_mid", "bg_deep"]
const SAVE_PATH := "user://save.cfg"

var state := TITLE
var dive: Dive
var best := 0
var _story_seen := false

# 層（下から）：背景 → 水の演出 → 画面 → 演出の文字 → 会話
var _bg: TextureRect
var _bg_shade: ColorRect
var _ocean: OceanFx
var _ui: Control
var _fx: Control
var _talk_layer: Control

# PLAY の部品
var board: Board
var _hand_box: Control
var _cards: Array[CardView] = []
var _sel := -1
var _busy := false
var _hud := {}
var _hint: RichTextLabel
var _stash_btn: Button
var _end_btn: Button
var _speech: PanelContainer
var _speech_tween: Tween
var _said_low_air := false
var _result := {}   # 終わり方（RESULT 画面用）

# 会話
var _talk_lines := []
var _talk_i := 0
var _talk_done: Callable
var _talk_nodes := {}
var _talk_typing: Tween


func _ready() -> void:
	_load_save()
	_bg = TextureRect.new()
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	_bg_shade = ColorRect.new()
	_bg_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg_shade)
	_ocean = OceanFx.new()
	add_child(_ocean)
	_ui = Control.new()
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ui)
	_fx = Control.new()
	_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx.z_index = 100
	add_child(_fx)
	_talk_layer = Control.new()
	_talk_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_talk_layer.z_index = 200
	add_child(_talk_layer)
	Screen.layout_changed.connect(_on_layout)
	_show_title()


func _view() -> Vector2:
	return Screen.view_size()


func _on_layout() -> void:
	var v := _view()
	for n in [_bg, _bg_shade, _ui, _fx, _talk_layer]:
		n.position = Vector2.ZERO
		n.size = v
	_ocean.resize(v)
	if _busy:
		# 演出中に組み直すとキャラの位置がずれるので、終わってから
		return
	match state:
		TITLE:
			_show_title()
		PLAY:
			_build_play()
		REST:
			_show_rest()
		RESULT:
			_show_result()
	if not _talk_lines.is_empty():
		_build_talk()


func _load_save() -> void:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) == OK:
		best = int(cf.get_value("run", "best", 0))
		_story_seen = bool(cf.get_value("run", "story", false))


func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("run", "best", best)
	cf.set_value("run", "story", _story_seen)
	cf.save(SAVE_PATH)


func _set_bg(name: String, shade: float, light: float) -> void:
	var p := "res://assets/images/%s.jpg" % name
	_bg.texture = load(p) if ResourceLoader.exists(p) else null
	_bg_shade.color = Color(0.0, 0.03, 0.08, shade)
	_ocean.setup(_view(), light)
	_on_layout_sizes()


func _on_layout_sizes() -> void:
	var v := _view()
	for n in [_bg, _bg_shade, _ui, _fx, _talk_layer]:
		n.size = v


func _clear_ui() -> void:
	for c in _ui.get_children():
		c.queue_free()
	_cards.clear()
	_hud.clear()
	board = null


# ───────── 部品 ─────────

func _button(text: String, cb: Callable, font: int = 30, col: Color = Color(0.1, 0.45, 0.8)) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font)
	UiStyle.button_styles(b, col)
	b.pressed.connect(func():
		Audio.sfx("click")
		cb.call())
	# 押したときにぷにっと縮む
	b.button_down.connect(func():
		b.pivot_offset = b.size / 2
		b.scale = Vector2(0.94, 0.94))
	b.button_up.connect(func(): b.scale = Vector2.ONE)
	return b


func _panel(rect: Rect2, parent: Control, edge: Color = UiStyle.AQUA, bg: Color = UiStyle.PANEL_BG) -> Panel:
	var p := Panel.new()
	p.position = rect.position
	p.size = rect.size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", UiStyle.panel(edge, bg))
	parent.add_child(p)
	return p


func _label(text: String, fs: int, pos: Vector2, parent: Control, col: Color = Color.WHITE, w: float = 0.0,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := UiStyle.label(text, fs, col)
	l.position = pos
	if w > 0:
		l.size.x = w
		l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _ill(name: String) -> Texture2D:
	var p := "res://assets/images/ill/%s.png" % name
	return load(p) if ResourceLoader.exists(p) else null


## 画面の文字がふわっと浮かんで消える
func _float(text: String, at: Vector2, col: Color = Color.WHITE, fs: int = 30) -> void:
	var l := UiStyle.label(text, fs, col, 8)
	l.position = at - Vector2(150, fs)
	l.size.x = 300
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.pivot_offset = Vector2(150, fs * 0.6)
	l.scale = Vector2(0.4, 0.4)
	_fx.add_child(l)
	var tw := l.create_tween()
	tw.tween_property(l, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(l, "position:y", l.position.y - 50, 0.9)
	tw.tween_property(l, "modulate:a", 0.0, 0.3)
	tw.tween_callback(l.queue_free)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shake(power: float = 10.0) -> void:
	var tw := _ui.create_tween()
	for i in 6:
		tw.tween_property(_ui, "position", Vector2(randf_range(-1, 1), randf_range(-1, 1)) * power * (1.0 - i / 6.0), 0.04)
	tw.tween_property(_ui, "position", Vector2.ZERO, 0.04)


# ───────── タイトル ─────────

func _show_title() -> void:
	state = TITLE
	_clear_ui()
	_set_bg("title", 0.1, 0.8)
	Audio.bgm("title")
	var v := _view()
	var portrait := Screen.portrait
	# 上を少し暗くしてロゴを読みやすく
	var grad := TextureRect.new()
	var g := GradientTexture2D.new()
	g.fill_from = Vector2(0, 0)
	g.fill_to = Vector2(0, 1)
	g.gradient = Gradient.new()
	g.gradient.set_color(0, Color(0, 0.03, 0.1, 0.75))
	g.gradient.set_color(1, Color(0, 0.03, 0.1, 0.0))
	grad.texture = g
	grad.size = Vector2(v.x, v.y * 0.45)
	grad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(grad)
	# ロゴ：一文字ずつ波のようにゆれる
	var top := 70.0 if portrait else 40.0
	_label("カノープスの", 44 if portrait else 40, Vector2(0, top), _ui, UiStyle.AQUA, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	var big := "深海たからさがし"
	var fs := 74 if portrait else 80
	var total := fs * big.length() * 0.98
	for i in big.length():
		var ch := UiStyle.label(big[i], fs, UiStyle.GOLD, 14)
		ch.position = Vector2(v.x / 2 - total / 2 + i * fs * 0.98, top + 56)
		ch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(ch)
		var base_y := ch.position.y
		ch.position.y -= 300
		var tw := ch.create_tween()
		tw.tween_interval(0.08 * i)
		tw.tween_property(ch, "position:y", base_y, 0.6).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		tw.tween_callback(func():
			var wave := ch.create_tween().set_loops()
			wave.tween_property(ch, "position:y", base_y - 10, 0.9).set_trans(Tween.TRANS_SINE).set_delay(i * 0.12)
			wave.tween_property(ch, "position:y", base_y, 0.9).set_trans(Tween.TRANS_SINE))
	_label("best %d" % best if best > 0 else "", 26, Vector2(0, top + 160), _ui, Color(1, 1, 1, 0.9), v.x, HORIZONTAL_ALIGNMENT_CENTER)
	# ボタン
	var bw := 360.0
	var by := v.y - (430 if portrait else 330)
	var specs := [["もぐる！", _on_start, Color(0.1, 0.5, 0.85)], ["おはなし", func(): _talk(Scenario.STORY, func(): pass), Color(0.75, 0.35, 0.6)],
		["遊び方", _show_help, Color(0.2, 0.6, 0.5)], ["音：" + ("オフ" if Audio.muted else "オン"), _toggle_mute, Color(0.35, 0.4, 0.5)]]
	if not portrait:
		bw = 300
	for i in specs.size():
		var b := _button(specs[i][0], specs[i][1], 34 if i == 0 else 28, specs[i][2])
		b.size = Vector2(bw, 84 if i == 0 else 66)
		var x := v.x / 2 - bw / 2 if portrait else v.x - bw - 60
		b.position = Vector2(x + 400, by + (0 if i == 0 else 100 + (i - 1) * 78))
		_ui.add_child(b)
		var tw := b.create_tween()
		tw.tween_interval(0.5 + i * 0.1)
		tw.tween_property(b, "position:x", x, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var ver := "build " + (FileAccess.get_file_as_string("res://version.txt").strip_edges() if FileAccess.file_exists("res://version.txt") else "dev")
	_label(ver, 18, Vector2(v.x - 220, v.y - 34), _ui, Color(1, 1, 1, 0.6), 200, HORIZONTAL_ALIGNMENT_RIGHT)
	_label("画像は生成AIで作成しています", 18, Vector2(20, v.y - 34), _ui, Color(1, 1, 1, 0.6))


func _toggle_mute() -> void:
	Audio.toggle_mute()
	_show_title()


func _on_start() -> void:
	if not _story_seen:
		_story_seen = true
		_save()
		_talk(Scenario.STORY, _start_run)
	else:
		_start_run()


func _show_help() -> void:
	var v := _view()
	var shade := ColorRect.new()
	shade.color = Color(0, 0.02, 0.06, 0.8)
	shade.size = v
	shade.z_index = 150
	_ui.add_child(shade)
	var w: float = min(v.x - 40, 860)
	var h: float = min(v.y - 120, 760)
	var p := _panel(Rect2((v.x - w) / 2, (v.y - h) / 2 - 30, w, h), shade)
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.text = Scenario.HOW_TO
	rt.position = Vector2(24, 20)
	rt.size = Vector2(w - 48, h - 40)
	rt.add_theme_font_size_override("normal_font_size", 23 if Screen.portrait else 22)
	rt.add_theme_font_size_override("bold_font_size", 28)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(rt)
	var b := _button("とじる", shade.queue_free, 28)
	b.size = Vector2(220, 64)
	b.position = Vector2(v.x / 2 - 110, (v.y + h) / 2 - 10)
	shade.add_child(b)


# ───────── 会話 ─────────

## lines: [[話す人, 文, ミラの動き], ...]
func _talk(lines: Array, done: Callable) -> void:
	_talk_lines = lines
	_talk_i = 0
	_talk_done = done
	_build_talk()
	_show_talk_line()


func _build_talk() -> void:
	for c in _talk_layer.get_children():
		c.queue_free()
	var v := _view()
	var shade := ColorRect.new()
	shade.color = Color(0, 0.02, 0.06, 0.55)
	shade.size = v
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_advance_talk())
	_talk_layer.add_child(shade)
	var portrait := Screen.portrait
	var box_h := 230.0 if portrait else 190.0
	var pic_h := v.y * (0.42 if portrait else 0.78)
	var mk := func(tex_name: String, left: bool) -> TextureRect:
		var t := TextureRect.new()
		t.texture = _ill(tex_name)
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var w := pic_h * 0.68
		t.size = Vector2(w, pic_h)
		var x := (v.x * 0.02 if left else v.x - w - v.x * 0.02) if portrait else (v.x * 0.08 if left else v.x - w - v.x * 0.08)
		t.position = Vector2(x, v.y - box_h - pic_h + 30)
		t.pivot_offset = Vector2(w / 2, pic_h)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		shade.add_child(t)
		return t
	var c: TextureRect = mk.call("canopus", true)
	var m: TextureRect = mk.call("mira", false)
	# ミラは少し小さい
	m.scale = Vector2(0.82, 0.82)
	var box := _panel(Rect2(16, v.y - box_h - 16, v.x - 32, box_h), shade, UiStyle.AQUA, Color(0.02, 0.07, 0.15, 0.94))
	var name_l := UiStyle.label("", 28, UiStyle.GOLD)
	name_l.position = Vector2(28, -22)
	box.add_child(name_l)
	var text := RichTextLabel.new()
	text.position = Vector2(28, 30)
	text.size = Vector2(box.size.x - 56, box_h - 50)
	text.add_theme_font_size_override("normal_font_size", 30 if portrait else 28)
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(text)
	var next := UiStyle.label("▼", 24, UiStyle.AQUA)
	next.position = Vector2(box.size.x - 50, box_h - 44)
	box.add_child(next)
	var tw := next.create_tween().set_loops()
	tw.tween_property(next, "position:y", box_h - 36, 0.4)
	tw.tween_property(next, "position:y", box_h - 44, 0.4)
	_talk_nodes = {"c": c, "m": m, "name": name_l, "text": text, "base_c": c.position, "base_m": m.position}


func _show_talk_line() -> void:
	if _talk_i >= _talk_lines.size():
		_end_talk()
		return
	var line: Array = _talk_lines[_talk_i]
	var who: String = line[0]
	var n := _talk_nodes
	n.name.text = "カノープス" if who == "C" else "ミラ"
	n.name.add_theme_color_override("font_color", UiStyle.AQUA if who == "C" else UiStyle.PINK)
	var text: RichTextLabel = n.text
	text.text = line[1]
	text.visible_ratio = 0.0
	if _talk_typing:
		_talk_typing.kill()
	_talk_typing = text.create_tween()
	_talk_typing.tween_property(text, "visible_ratio", 1.0, max(0.25, line[1].length() * 0.035))
	var speaker: TextureRect = n.c if who == "C" else n.m
	var other: TextureRect = n.m if who == "C" else n.c
	speaker.modulate = Color.WHITE
	other.modulate = Color(0.55, 0.6, 0.7)
	speaker.position = n.base_c if who == "C" else n.base_m
	if who == "C":
		var tw := speaker.create_tween()
		tw.tween_property(speaker, "position:y", speaker.position.y - 18, 0.1)
		tw.tween_property(speaker, "position:y", speaker.position.y, 0.16).set_trans(Tween.TRANS_BOUNCE)
		Audio.sfx("talk", -10.0, randf_range(0.95, 1.1))
	else:
		_mira_motion(speaker, line[2], n.c)
		_mira_cry(line[1], line[2])


## ミラはしゃべらないので、立ち絵の動きで気持ちを見せる
func _mira_motion(t: Control, motion: String, partner: Control) -> void:
	var base := t.position
	var tw := t.create_tween()
	match motion:
		"hop":
			for i in 2:
				tw.tween_property(t, "position:y", base.y - 40, 0.12).set_ease(Tween.EASE_OUT)
				tw.tween_property(t, "position:y", base.y, 0.14).set_ease(Tween.EASE_IN)
		"shake":
			for i in 4:
				tw.tween_property(t, "rotation", 0.08 * (1 if i % 2 == 0 else -1), 0.07)
			tw.tween_property(t, "rotation", 0.0, 0.07)
		"spin":
			var s := t.scale
			tw.tween_property(t, "scale:x", -s.x, 0.15)
			tw.tween_property(t, "scale:x", s.x, 0.15)
			tw.tween_property(t, "position:y", base.y - 30, 0.1)
			tw.tween_property(t, "position:y", base.y, 0.15).set_trans(Tween.TRANS_BOUNCE)
		"droop":
			tw.tween_property(t, "position:y", base.y + 30, 0.4).set_trans(Tween.TRANS_SINE)
			tw.parallel().tween_property(t, "modulate", Color(0.75, 0.8, 0.95), 0.4)
		"point":
			tw.tween_property(t, "rotation", -0.12, 0.12)
			tw.tween_property(t, "position:x", base.x - 30, 0.12)
			tw.tween_interval(0.3)
			tw.tween_property(t, "rotation", 0.0, 0.2)
			tw.parallel().tween_property(t, "position:x", base.x, 0.2)
		"slap":
			# 羽でぺしっとはたく。カノープスがよろける
			tw.tween_property(t, "position:x", base.x - 90, 0.1).set_ease(Tween.EASE_IN)
			tw.tween_callback(func():
				Audio.sfx("slap")
				var pt := partner.create_tween()
				var pb := partner.position
				pt.tween_property(partner, "rotation", -0.1, 0.06)
				pt.tween_property(partner, "rotation", 0.06, 0.08)
				pt.tween_property(partner, "rotation", 0.0, 0.1)
				pt.parallel().tween_property(partner, "position", pb, 0.1))
			tw.tween_property(t, "position:x", base.x, 0.25).set_trans(Tween.TRANS_BACK)
		_:
			tw.tween_property(t, "position:y", base.y - 16, 0.1)
			tw.tween_property(t, "position:y", base.y, 0.14)


func _mira_cry(text: String, motion: String) -> void:
	var s := "mira_happy"
	if "？" in text or "?" in text:
		s = "mira_q"
	elif motion == "droop" or "……" in text:
		s = "mira_sad"
	elif motion in ["point", "shake", "slap"] or "！" in text:
		s = "mira_alert"
	Audio.sfx(s, -4.0, randf_range(0.96, 1.06))


func _advance_talk() -> void:
	var text: RichTextLabel = _talk_nodes.get("text")
	if text and text.visible_ratio < 1.0:
		if _talk_typing:
			_talk_typing.kill()
		text.visible_ratio = 1.0
		return
	_talk_i += 1
	Audio.sfx("click", -10.0)
	_show_talk_line()


func _end_talk() -> void:
	for c in _talk_layer.get_children():
		c.queue_free()
	_talk_lines = []
	_talk_nodes = {}
	var cb := _talk_done
	_talk_done = Callable()
	if cb.is_valid():
		cb.call()


# ───────── ラン ─────────

func _start_run() -> void:
	dive = Dive.new()
	_start_floor()


func _start_floor() -> void:
	state = PLAY
	_said_low_air = false
	dive.start_floor()
	var z := dive.zone()
	_set_bg(BGS[z], 0.25 + z * 0.1, [1.0, 0.4, 0.0][z])
	Audio.bgm(["shallow", "mid", "deep"][z])
	_build_play()
	_floor_banner()
	if dive.floor_no % 3 == 1:
		var trip: Array = Scenario.pick(Scenario.FLOOR_START[z])
		_say_line(trip[0], "きゅ", trip[1], 1.2)
	if dive.floor_no == 1:
		_set_hint("[color=#7fe8ff]カードをタップ[/color] → [color=#7fe8ff]光ったマスをタップ[/color]で使う。光る穴が出口！")


func _floor_banner() -> void:
	var v := _view()
	var z := dive.zone()
	var box := Control.new()
	box.position = Vector2(-v.x, v.y * 0.38)
	box.size = Vector2(v.x, 150)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx.add_child(box)
	var band := ColorRect.new()
	band.color = Color(0.0, 0.05, 0.12, 0.8)
	band.size = Vector2(v.x, 150)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(band)
	_label("%s　%s" % Scenario.ZONES[z], 54, Vector2(0, 14), box, UiStyle.GOLD, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	_label("%d階　・　深さ %dm" % [dive.floor_no, dive.depth_m()], 32, Vector2(0, 90), box, UiStyle.AQUA, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	var tw := box.create_tween()
	tw.tween_property(box, "position:x", 0.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.0)
	tw.tween_property(box, "position:x", v.x, 0.3).set_ease(Tween.EASE_IN)
	tw.tween_callback(box.queue_free)
	Audio.sfx("dive")


## 画面の向きに合わせて、盤・情報・手札の位置を決める
func _layout() -> Dictionary:
	var v := _view()
	if Screen.portrait:
		var cs: float = min((v.x - 40) / Dive.W, (v.y - 520) / Dive.H)
		var bw := cs * Dive.W
		var by := 136.0
		var hand_y := by + cs * Dive.H + 74
		return {"cs": cs, "board": Vector2((v.x - bw) / 2, by), "hud": Rect2(12, 8, v.x - 24, 118),
			"hint": Rect2(12, by + cs * Dive.H + 12, v.x - 24, 56), "hand": Rect2(10, hand_y, v.x - 20, 200),
			"bar": Rect2(12, v.y - 84, v.x - 24, 76), "speech": Vector2(v.x / 2, by + 14)}
	var cs2: float = min((v.y - 48) / Dive.H, (v.x - 760) / Dive.W)
	var bx := 24.0
	var right := bx + cs2 * Dive.W + 40
	var rw := v.x - right - 20
	return {"cs": cs2, "board": Vector2(bx, 24), "hud": Rect2(right, 16, rw, 118),
		"hint": Rect2(right, 146, rw, 70), "hand": Rect2(right, v.y - 300, rw, 200),
		"bar": Rect2(right, v.y - 92, rw, 76), "speech": Vector2(right + rw / 2, 236)}


func _build_play() -> void:
	_clear_ui()
	_sel = -1
	var L := _layout()
	var v := _view()
	board = Board.new()
	board.position = L.board
	_ui.add_child(board)
	board.setup(dive, L.cs)
	board.cell_tapped.connect(_on_cell)
	# 何もない所をタップしたら選択を外す
	var catcher := Control.new()
	catcher.size = v
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	catcher.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			_select(-1))
	_ui.add_child(catcher)
	_ui.move_child(catcher, 0)
	_build_hud(L.hud)
	# ヒント（選んだカードの説明など）
	var hp := _panel(L.hint, _ui, Color(0.5, 0.85, 1.0, 0.6), Color(0.02, 0.07, 0.15, 0.82))
	_hint = RichTextLabel.new()
	_hint.bbcode_enabled = true
	_hint.position = Vector2(14, 8)
	_hint.size = L.hint.size - Vector2(28, 12)
	_hint.add_theme_font_size_override("normal_font_size", 22)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.scroll_active = false
	hp.add_child(_hint)
	_stash_btn = _button("ミラにあずける（元気1）", _on_stash, 22, Color(0.75, 0.35, 0.6))
	_stash_btn.size = Vector2(300, 52)
	_stash_btn.position = L.hint.position + Vector2(L.hint.size.x - 306, L.hint.size.y - 4)
	_stash_btn.visible = false
	_stash_btn.z_index = 5
	_ui.add_child(_stash_btn)
	# 手札
	_hand_box = Control.new()
	_hand_box.position = L.hand.position
	_hand_box.size = L.hand.size
	_hand_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_hand_box)
	# 下のバー：山札・捨て札・元気・ターン終了
	var bar: Rect2 = L.bar
	_hud.deck = _label("", 22, bar.position + Vector2(0, 6), _ui, Color(0.85, 0.92, 1))
	_hud.energy = _label("", 34, bar.position + Vector2(bar.size.x * 0.3, 12), _ui, UiStyle.AQUA)
	_end_btn = _button("ターン終了", _on_end_turn, 30, Color(0.85, 0.4, 0.2))
	_end_btn.size = Vector2(230, 70)
	_end_btn.position = bar.position + Vector2(bar.size.x - 230, 2)
	_ui.add_child(_end_btn)
	_speech = null
	_refresh()
	_rebuild_hand(false)


func _build_hud(r: Rect2) -> void:
	_panel(r, _ui, Color(0.5, 0.85, 1.0, 0.6), Color(0.02, 0.07, 0.15, 0.82))
	var z := dive.zone()
	_hud.depth = _label("", 26, r.position + Vector2(16, 8), _ui, UiStyle.GOLD)
	_hud.treasure = _label("", 26, r.position + Vector2(r.size.x - 236, 8), _ui, UiStyle.GOLD, 220, HORIZONTAL_ALIGNMENT_RIGHT)
	var g := Gauges.new()
	g.position = r.position + Vector2(14, 50)
	g.size = Vector2(r.size.x - 28, 60)
	g.game = self
	_ui.add_child(g)
	_hud.gauges = g
	# 何階まで来たか（9つの丸）
	var dots := DepthDots.new()
	dots.position = r.position + Vector2(r.size.x * 0.42, 12)
	dots.size = Vector2(r.size.x * 0.22, 24)
	dots.game = self
	_ui.add_child(dots)


func _refresh() -> void:
	if dive == null or board == null:
		return
	var z := dive.zone()
	_hud.depth.text = "%s %d階" % [Scenario.ZONES[z][0], dive.floor_no]
	var bag_txt := "  ミラ%d" % dive.bag.size() if dive.bag.size() > 0 else ""
	_hud.treasure.text = "宝 %d%s" % [dive.carried_value(), bag_txt]
	_hud.gauges.queue_redraw()
	_hud.deck.text = "山札 %d\n捨て札 %d" % [dive.deck.size(), dive.discard.size()]
	_hud.energy.text = "元気 " + "●".repeat(dive.energy) + "○".repeat(max(Dive.ENERGY - dive.energy, 0))
	_end_btn.disabled = _busy
	board.sync_visibility()


func _rebuild_hand(deal: bool) -> void:
	for c in _cards:
		c.queue_free()
	_cards.clear()
	var n := dive.hand.size()
	if n == 0:
		return
	var area := _hand_box.size
	var cw: float = min(area.x / 5.0 - 8, 138)
	var ch := cw * 1.45
	var step: float = min(cw + 8, (area.x - cw) / max(n - 1, 1))
	var total := step * (n - 1) + cw
	var x0 := (area.x - total) / 2
	for i in n:
		var cv := CardView.new(dive.hand[i])
		cv.index = i
		cv.size = Vector2(cw, ch)
		cv.position = Vector2(x0 + i * step, area.y - ch)
		cv.playable = dive.can_play(i) or dive.can_stash(i)
		cv.tapped.connect(_on_card)
		_hand_box.add_child(cv)
		_cards.append(cv)
		if deal:
			var goal := cv.position
			cv.position = Vector2(-cw, goal.y + 60)
			cv.modulate.a = 0.0
			var tw := cv.create_tween()
			tw.tween_interval(i * 0.06)
			tw.tween_property(cv, "position", goal, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tw.parallel().tween_property(cv, "modulate:a", 1.0, 0.15)


func _set_hint(bb: String) -> void:
	if _hint:
		_hint.text = bb


# ───────── 操作 ─────────

func _on_card(cv: CardView) -> void:
	if _busy:
		return
	var i := cv.index
	if _sel == i:
		var d := Cards.def(dive.hand[i])
		if d.target == "self" and dive.can_play(i):
			_play(i, dive.ppos())
			return
		_select(-1)
		return
	_select(i)
	Audio.sfx("card")


func _select(i: int) -> void:
	_sel = i
	for c in _cards:
		c.selected = c.index == i
	if board == null:
		return
	board.marks.clear()
	board.preview.clear()
	_stash_btn.visible = false
	if i < 0:
		_set_hint("")
		return
	var id: String = dive.hand[i]
	var d := Cards.def(id)
	var why := ""
	if d.cost < 0:
		why = "[color=#ffd75e]宝は使えない。持ち帰ると %d 点[/color]" % d.value
	elif d.cost > dive.energy:
		why = "[color=#ff7a7a]元気が足りない[/color]"
	elif dive.targets(i).is_empty():
		why = "[color=#ff7a7a]今は使えない[/color]"
	var how: String = {"move": "泳ぐ先をタップ", "dive": "どこまで潜るかタップ", "line": "向きをタップ", "adj": "となりの敵をタップ",
		"self": "カノープスか、カードをもう一度タップ"}.get(d.target, "")
	_set_hint("[b]%s[/b]　%s\n%s" % [d.name, d.desc.replace("\n", "　"), why if why != "" else "[color=#7fe8ff]%s[/color]" % how])
	if dive.can_stash(i):
		_stash_btn.visible = true
	if not dive.can_play(i):
		return
	var col := UiStyle.AQUA if d.kind != "atk" else UiStyle.DANGER
	for p in dive.targets(i):
		board.marks[p] = col
	# 一直線の技は、届く範囲を薄く見せる
	if d.target == "line":
		for dir in Dive.DIRS:
			var p: Vector2i = dive.ppos()
			for k in int(d.range):
				p += dir
				if not dive.inside(p) or dive.tile(p) == Dive.ROCK:
					break
				board.preview[p] = col
	if id == "sonar":
		for y in Dive.H:
			for x in Dive.W:
				if Dive.manhattan(Vector2i(x, y), dive.ppos()) <= Dive.SONAR:
					board.preview[Vector2i(x, y)] = UiStyle.AQUA
	if id == "whirl":
		for y in range(-1, 2):
			for x in range(-1, 2):
				board.preview[dive.ppos() + Vector2i(x, y)] = col


func _on_cell(p: Vector2i) -> void:
	if _busy:
		return
	if _sel >= 0 and _sel < dive.hand.size():
		var d := Cards.def(dive.hand[_sel])
		var at := p
		# 一直線の技は、線の上ならどこをタップしてもその向きにする
		if d.target == "line" and not board.marks.has(p):
			var diff := p - dive.ppos()
			if (diff.x == 0) != (diff.y == 0):
				at = dive.ppos() + Vector2i(signi(diff.x), signi(diff.y))
		if board.marks.has(at):
			_play(_sel, at)
			return
	# 敵をタップしたら説明
	var u := dive.unit_at(p)
	if not u.is_empty() and u.id != 0 and dive.is_seen(p):
		_set_hint(_enemy_info(u))
		_select_keep_hint()
		return
	_select(-1)


func _select_keep_hint() -> void:
	var h := _hint.text
	_select(-1)
	_set_hint(h)


func _enemy_info(u: Dictionary) -> String:
	var e: Dictionary = Dive.ENEMIES[u.kind]
	var how: String = {
		"fugu": "近づくと起きて追ってくる。となりにいると噛む（%d）" % e.dmg,
		"kurage": "動かない。2ターンに1回、まわり8マスに電撃（%d）" % e.dmg,
		"utsubo": "動かない。口の前2マスに入ったままだと噛む（%d）" % e.dmg,
	}[u.kind]
	return "[b]%s[/b]　体力 %d\n%s" % [e.name, u.hp, how]


func _play(i: int, at: Vector2i) -> void:
	var id: String = dive.hand[i]
	_select(-1)
	_busy = true
	Audio.sfx("card")
	var ev := dive.play(i, at)
	_rebuild_hand(false)
	_refresh()
	if id == "sonar" and randf() < 0.5:
		_say(Scenario.SAY_SONAR)
	await _run_events(ev)
	_busy = false
	_after_events(ev)


func _on_stash() -> void:
	if _busy or _sel < 0 or not dive.can_stash(_sel):
		return
	var i := _sel
	var cv := _cards[i]
	var from := cv.global_position + cv.size / 2
	_select(-1)
	var ev := dive.stash(i)
	# カードがミラのところへ飛んでいく
	var tex := CardView.obj_tex(["chest", "coin", "pearl", "gem"][int(Cards.def(ev[0].card).get("obj", 1))])
	var to := board.global_position + board.mira.position
	_fly_icon(tex, from, to)
	board.mira.act(1, 1.0, true)
	_say(Scenario.SAY_STASH)
	Audio.sfx("stash")
	_rebuild_hand(false)
	_refresh()


func _fly_icon(tex: Texture2D, from: Vector2, to: Vector2) -> void:
	if tex == null:
		return
	var t := TextureRect.new()
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.size = Vector2(64, 64)
	t.position = from - Vector2(32, 32)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx.add_child(t)
	var tw := t.create_tween()
	var mid := (from + to) / 2 + Vector2(0, -120)
	tw.tween_method(func(k: float):
		var a := from.lerp(mid, k)
		var b := mid.lerp(to, k)
		t.position = a.lerp(b, k) - Vector2(32, 32)
		t.scale = Vector2.ONE * (1.0 - k * 0.4), 0.0, 1.0, 0.5)
	tw.tween_callback(t.queue_free)


func _on_end_turn() -> void:
	if _busy or state != PLAY:
		return
	_select(-1)
	_busy = true
	_end_btn.disabled = true
	# 手札を捨てる
	for c in _cards:
		var tw := c.create_tween()
		tw.tween_property(c, "position:y", c.position.y + 260, 0.2).set_ease(Tween.EASE_IN)
	Audio.sfx("whoosh", -8.0)
	await _wait(0.2)
	var ev := dive.end_turn()
	await _run_events(ev)
	_busy = false
	_after_events(ev)


func _after_events(ev: Array) -> void:
	if state != PLAY:
		return
	for e in ev:
		if e.t == "faint":
			_on_faint()
			return
		if e.t == "exit":
			_on_exit()
			return
	var drew := false
	for e in ev:
		if e.t == "draw":
			drew = true
	_rebuild_hand(drew)
	_refresh()
	if drew:
		_turn_quips()


func _turn_quips() -> void:
	var tcount := 0
	for c in dive.hand:
		if Cards.is_treasure(c):
			tcount += 1
	if dive.air <= 3 and not _said_low_air:
		_said_low_air = true
		_say(Scenario.SAY_LOW_AIR)
		board.actors[0].act(2, 1.4)
	elif tcount >= 3:
		_say(Scenario.SAY_CLOG)


# ───────── 演出 ─────────

func _actor(id: int) -> Actor:
	return board.actors.get(id)


func _at(id: int) -> Vector2:
	var a := _actor(id)
	return board.global_position + a.position if a else Vector2.ZERO


func _run_events(ev: Array) -> void:
	for e in ev:
		if board == null:
			return
		match e.t:
			"move":
				await _anim_move(e)
			"pickup":
				var at: Vector2 = board.global_position + board.center(e.at)
				var d := Cards.def(e.card)
				_float("+%s %d" % [d.name, d.value], at, UiStyle.GOLD, 30)
				Audio.sfx("gem" if e.item == "gem" else "coin")
				_fly_icon(CardView.obj_tex(e.item), at, _hud_deck_pos())
				_actor(0).act(1, 0.8, true)
				board.mira.act(1, 0.8, true)
				_say(Scenario.SAY_GEM if e.item == "gem" else Scenario.SAY_PICKUP)
				await _wait(0.35)
			"vent":
				var at: Vector2 = board.global_position + board.center(e.at)
				board.ring(e.at, 0.8, Color(0.85, 1, 1))
				_float("空気 +%d" % e.air, at, UiStyle.AIR, 32)
				Audio.sfx("bubble")
				_say(Scenario.SAY_VENT)
				await _wait(0.3)
			"hit":
				var a := _actor(e.id)
				if a:
					a.flash = 1.0
					a.act(2, 0.4)
					_float("-%d" % e.dmg, _at(e.id) + Vector2(0, -30), Color(1, 0.9, 0.5), 34)
				Audio.sfx("hit")
				await _wait(0.18)
			"die":
				var a := _actor(e.id)
				if a:
					var tw := a.create_tween()
					tw.tween_property(a, "alpha", 0.0, 0.4)
					tw.parallel().tween_property(a, "position:y", a.position.y - 30, 0.4)
					tw.tween_callback(func(): a.visible = false)
				Audio.sfx("pop")
				if randf() < 0.5:
					_say(Scenario.SAY_KILL)
				await _wait(0.25)
			"push":
				var a := _actor(e.id)
				if a:
					var tw := a.create_tween()
					tw.tween_property(a, "position", board.center(e.to), 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
					await tw.finished
			"bump":
				var a := _actor(e.id)
				if a:
					var base := a.position
					var tw := a.create_tween()
					tw.tween_property(a, "position", base + Vector2(6, 0), 0.04)
					tw.tween_property(a, "position", base - Vector2(6, 0), 0.04)
					tw.tween_property(a, "position", base, 0.04)
				Audio.sfx("bump")
				await _wait(0.1)
			"beam":
				_actor(0).act(3, 0.5)
				var col := Color(0.6, 0.9, 1.0) if e.kind == "bubble" else Color(0.9, 0.95, 1.0)
				for k in e.tiles.size():
					board.flash_tiles([e.tiles[k]], col, 0.45)
					await _wait(0.04)
				Audio.sfx("bubble" if e.kind == "bubble" else "whoosh")
				await _wait(0.1)
			"whirl":
				_actor(0).act(3, 0.6)
				board.ring(e.at, 1.6, Color(0.6, 0.9, 1.0))
				Audio.sfx("whoosh")
				await _wait(0.25)
			"stun":
				_float("泡づつみ", _at(e.id) + Vector2(0, -40), UiStyle.AIR, 24)
			"reveal":
				board.ring(e.at, e.r + 0.5)
				_actor(0).act(3, 0.6)
				Audio.sfx("sonar")
				await _wait(0.45)
			"wake":
				_float("！", _at(e.id) + Vector2(0, -50), UiStyle.DANGER, 40)
				Audio.sfx("alert", -6.0)
				await _wait(0.12)
			"air":
				_hud.gauges.queue_redraw()
				if e.n > 0:
					_float("空気 +%d" % e.n, _at(0) + Vector2(0, -50), UiStyle.AIR, 30)
					Audio.sfx("bubble")
			"drown":
				_float("息が……！", _at(0) + Vector2(0, -60), UiStyle.AIR, 30)
				_actor(0).act(2, 1.0)
				board.mira.act(2, 1.0)
				Audio.sfx("drown")
				await _wait(0.3)
			"phit":
				var a := _actor(0)
				a.flash = 1.0
				a.act(2, 0.8)
				_float("-%d" % e.dmg, _at(0) + Vector2(0, -40), UiStyle.HEART, 40)
				_shake(12)
				Audio.sfx("hurt")
				board.mira.act(2, 1.0)
				_say(Scenario.SAY_HIT)
				_hud.gauges.queue_redraw()
				await _wait(0.35)
			"block":
				_float("防いだ！", _at(0) + Vector2(0, -50), Color(1, 0.95, 0.4), 32)
				Audio.sfx("block")
				await _wait(0.2)
			"shield":
				board.ring(dive.ppos(), 0.6, Color(1, 0.95, 0.4))
				Audio.sfx("block")
			"bite":
				var a := _actor(e.id)
				if a and a.visible:
					a.act(3, 0.4)
					var base := a.position
					if not e.tiles.is_empty():
						var tw := a.create_tween()
						tw.tween_property(a, "position", base.lerp(board.center(e.tiles[0]), 0.4), 0.08)
						tw.tween_property(a, "position", base, 0.12)
				board.flash_tiles(e.tiles, UiStyle.DANGER, 0.4)
				Audio.sfx("bite")
				await _wait(0.25)
			"zap":
				var a := _actor(e.id)
				if a and a.visible:
					a.act(3, 0.5)
				board.flash_tiles(e.tiles, Color(1, 0.95, 0.3), 0.45)
				Audio.sfx("zap")
				await _wait(0.3)
	if board:
		board.sync_visibility()


func _anim_move(e: Dictionary) -> void:
	var a := _actor(e.id)
	if a == null:
		return
	var path: Array = e.path
	if e.id != 0 and not (dive.is_seen(path[0]) or dive.is_seen(path[-1])):
		a.position = board.center(path[-1])
		return
	if e.id == 0:
		Audio.sfx("swim")
	for k in range(1, path.size()):
		var to := board.center(path[k])
		var dx: int = path[k].x - path[k - 1].x
		if dx != 0:
			a.flip = dx < 0 if e.id == 0 else dx > 0
		var tw := a.create_tween()
		tw.tween_property(a, "position", to, 0.11).set_trans(Tween.TRANS_SINE)
		if e.id == 0:
			# ミラは少し遅れてついてくる
			var mt := board.mira.create_tween()
			mt.tween_interval(0.08)
			var side := 1.0 if a.flip else -1.0
			mt.tween_property(board.mira, "position", to + Vector2(cs_side(side), -board.cs * 0.38), 0.16).set_trans(Tween.TRANS_SINE)
			board.mira.flip = a.flip
		await tw.finished
	if e.id != 0:
		board.sync_visibility()


func cs_side(side: float) -> float:
	return side * board.cs * 0.42


func _hud_deck_pos() -> Vector2:
	var l: Label = _hud.get("deck")
	return l.global_position + Vector2(40, 10) if l else Vector2.ZERO


## カノープスのセリフ（吹き出し）と、ミラの鳴き声・動き
func _say(arr: Array) -> void:
	var trip: Array = Scenario.pick(arr)
	_say_line(trip[0], trip[1], trip[2])


func _say_line(text: String, cry: String, motion: String, delay: float = 0.0) -> void:
	if board == null:
		return
	if delay > 0:
		await _wait(delay)
		if board == null:
			return
	if _speech and is_instance_valid(_speech):
		_speech.queue_free()
	var L := _layout()
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UiStyle.panel(UiStyle.AQUA, Color(0.98, 0.99, 1.0, 0.96), 4, 22))
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 24)
	l.add_theme_color_override("font_color", Color(0.05, 0.1, 0.2))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var maxw: float = min(_view().x - 60, 560)
	l.custom_minimum_size.x = min(maxw, 24 * text.length() + 10)
	p.add_child(l)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.z_index = 50
	_ui.add_child(p)
	_speech = p
	await get_tree().process_frame
	if not is_instance_valid(p):
		return
	p.position = Vector2(L.speech.x - p.size.x / 2, L.speech.y)
	p.pivot_offset = p.size / 2
	p.scale = Vector2(0.6, 0.6)
	var tw := p.create_tween()
	tw.tween_property(p, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(2.6)
	tw.tween_property(p, "modulate:a", 0.0, 0.3)
	tw.tween_callback(p.queue_free)
	# ミラは少し遅れて反応する
	await _wait(0.5)
	if board == null:
		return
	var f: int = {"hop": 1, "spin": 1, "shake": 2, "droop": 2, "point": 3, "slap": 3}.get(motion, 1)
	board.mira.act(f, 1.0, motion in ["hop", "spin", "point"])
	if motion == "spin":
		board.mira.flip = not board.mira.flip
	_float(cry, board.global_position + board.mira.position + Vector2(0, -board.cs * 0.7), UiStyle.PINK, 24)
	_mira_cry(cry, motion)


# ───────── 階の終わり ─────────

func _on_exit() -> void:
	_busy = true
	var a := _actor(0)
	Audio.sfx("dive")
	var tw := a.create_tween()
	tw.tween_property(a, "scale", Vector2(0.2, 0.2), 0.45).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(a, "alpha", 0.0, 0.45)
	var mt := board.mira.create_tween()
	mt.tween_interval(0.15)
	mt.tween_property(board.mira, "position", a.position, 0.3)
	mt.parallel().tween_property(board.mira, "alpha", 0.0, 0.45)
	await _wait(0.8)
	_busy = false
	if dive.floor_no >= Dive.FLOORS:
		_result = {"kind": "clear", "score": dive.surface(false) + 200}
		_talk(Scenario.CLEAR_TALK, _show_result_after)
		return
	_reward_choices = dive.reward_choices()
	_reward_taken = false
	_show_rest()


func _on_faint() -> void:
	_busy = true
	Audio.jingle("faint")
	_actor(0).act(2, 2.0)
	await _wait(1.0)
	_busy = false
	_result = {"kind": "faint", "score": dive.surface(true)}
	_talk(Scenario.FAINT_TALK, _show_result_after)


func _show_result_after() -> void:
	_show_result()


var _reward_choices := []
var _reward_taken := false


func _show_rest() -> void:
	state = REST
	_clear_ui()
	Audio.bgm("rest")
	var full := _view()
	var portrait := Screen.portrait
	# 横画面では左半分に状態とふたり、右半分にカードとボタン
	var left := Control.new()
	left.size = Vector2(full.x if portrait else full.x * 0.45, full.y)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(left)
	var right := Control.new()
	right.position = Vector2(0 if portrait else full.x * 0.45, 0)
	right.size = Vector2(full.x if portrait else full.x * 0.55, full.y)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(right)
	var v := left.size
	var top := 40.0 if portrait else 90.0
	_label("空気だまり", 54, Vector2(0, top), left, UiStyle.AQUA, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	_label("%d階を抜けた！　深さ %dm" % [dive.floor_no, dive.depth_m()], 28, Vector2(0, top + 72), left, Color.WHITE, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	# 状態
	var st := "体力 %d/%d　　空気 %d/%d　　宝 %d" % [dive.hp, Dive.MAX_HP, dive.air, Dive.MAX_AIR, dive.carried_value()]
	_label(st, 28, Vector2(0, top + 120), left, UiStyle.GOLD, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	# ふたり
	var mini_y := top + 160
	var c := MiniChar.new("canopus")
	c.size = Vector2(170, 170)
	c.position = Vector2(v.x / 2 - 190, mini_y)
	left.add_child(c)
	var m := MiniChar.new("mira", true)
	m.size = Vector2(130, 130)
	m.position = Vector2(v.x / 2 + 40, mini_y + 40)
	left.add_child(m)
	var trip: Array = Scenario.pick(Scenario.REST_TALKS)
	_label("カノープス「%s」" % trip[0], 24, Vector2(0, mini_y + 180), left, Color.WHITE, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	_label("ミラ「%s」" % trip[1], 24, Vector2(0, mini_y + 214), left, UiStyle.PINK, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	c.act(MiniChar.HAPPY, 1.2, true)
	m.act(MiniChar.HAPPY, 1.2, true)
	var cy := mini_y + 270 if portrait else 150.0
	v = right.size
	var _ui_parent := right
	if not _reward_taken:
		_label("カードを1枚もらえる", 28, Vector2(0, cy), _ui_parent, UiStyle.AQUA, v.x, HORIZONTAL_ALIGNMENT_CENTER)
		var cw := 170.0 if portrait else 150.0
		var gap := 24.0
		var x0 := v.x / 2 - (cw * 3 + gap * 2) / 2
		for i in _reward_choices.size():
			var cv := CardView.new(_reward_choices[i])
			cv.size = Vector2(cw, cw * 1.45)
			cv.position = Vector2(x0 + i * (cw + gap), cy + 50)
			cv.tapped.connect(func(_c):
				dive.add_card(_reward_choices[i])
				_reward_taken = true
				Audio.sfx("get")
				_show_rest())
			_ui_parent.add_child(cv)
		var skip := _button("もらわない", func():
			_reward_taken = true
			_show_rest(), 24, Color(0.35, 0.4, 0.5))
		skip.size = Vector2(220, 56)
		skip.position = Vector2(v.x / 2 - 110, cy + 70 + cw * 1.45)
		_ui_parent.add_child(skip)
		return
	# 帰るか潜るか
	var bw: float = min(v.x - 60, 560)
	var up := _button("浮上して持ち帰る（宝 %d）" % dive.carried_value(), func():
		_result = {"kind": "surface", "score": dive.surface(false)}
		Audio.jingle("surface")
		_talk(Scenario.SURFACE_TALK, _show_result_after), 30, Color(0.85, 0.6, 0.15))
	up.size = Vector2(bw, 90)
	up.position = Vector2(v.x / 2 - bw / 2, cy + 20)
	_ui_parent.add_child(up)
	var nz := (dive.floor_no) / 3
	var down := _button("もっと潜る（%s %d階・空気+%d）" % [Scenario.ZONES[nz][0], dive.floor_no + 1, Dive.REST_AIR], func():
		dive.rest()
		_start_floor(), 30, Color(0.1, 0.4, 0.85))
	down.size = Vector2(bw, 90)
	down.position = Vector2(v.x / 2 - bw / 2, cy + 130)
	_ui_parent.add_child(down)
	var warn := ""
	if dive.air + Dive.REST_AIR < 8:
		warn = "空気が少ない。深い所ほど敵も強い"
	if dive.hp <= 2:
		warn = "体力が少ない。気絶すると宝は半分"
	if warn != "":
		_label(warn, 24, Vector2(0, cy + 236), _ui_parent, UiStyle.DANGER, v.x, HORIZONTAL_ALIGNMENT_CENTER)


func _show_result() -> void:
	state = RESULT
	_clear_ui()
	var v := _view()
	var kind: String = _result.get("kind", "surface")
	var score: int = _result.get("score", 0)
	var new_best := score > best
	if new_best:
		best = score
		_save()
	if kind == "clear":
		_set_bg("bg_deep", 0.3, 0.0)
	var title: String = {"surface": "帰ってきた！", "faint": "ミラに助けられた……", "clear": "星のかけらを見つけた！"}[kind]
	var portrait := Screen.portrait
	# 横画面では左にふたり、右に結果
	var mx := v.x / 2 if portrait else v.x * 0.3
	var my := v.y * 0.24 if portrait else v.y * 0.3
	var col := Control.new()
	col.position = Vector2(0 if portrait else v.x * 0.48, 0)
	col.size = Vector2(v.x if portrait else v.x * 0.5, v.y)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(col)
	var cw := col.size.x
	_label(title, 52 if portrait else 46, Vector2(0, v.y * 0.12) if portrait else Vector2(0, 60), col, UiStyle.GOLD, cw, HORIZONTAL_ALIGNMENT_CENTER)
	var c := MiniChar.new("canopus")
	var big := 200.0 if portrait else 260.0
	c.size = Vector2(big, big)
	c.position = Vector2(mx - big * 1.1, my)
	_ui.add_child(c)
	var m := MiniChar.new("mira", true)
	m.size = Vector2(big * 0.75, big * 0.75)
	m.position = Vector2(mx + big * 0.2, my + big * 0.25)
	_ui.add_child(m)
	if kind == "faint":
		c.act(MiniChar.PANIC, 99)
		m.act(MiniChar.PANIC, 99)
	else:
		c.act(MiniChar.HAPPY, 99, true)
		m.act(MiniChar.HAPPY, 99, true)
	var y := v.y * 0.24 + 230 if portrait else 150.0
	_label("深さ %dm まで" % dive.depth_m(), 30, Vector2(0, y), col, UiStyle.AQUA, cw, HORIZONTAL_ALIGNMENT_CENTER)
	var sc := _label("0", 80, Vector2(0, y + 50), col, UiStyle.GOLD, cw, HORIZONTAL_ALIGNMENT_CENTER)
	var tw := sc.create_tween()
	tw.tween_method(func(k: int): sc.text = "宝 %d" % k, 0, score, 1.2)
	if kind == "clear":
		_label("（星のかけら +200）", 26, Vector2(0, y + 150), col, Color.WHITE, cw, HORIZONTAL_ALIGNMENT_CENTER)
	_label("新記録！" if new_best else "best %d" % best, 32, Vector2(0, y + 190), col, UiStyle.PINK if new_best else Color.WHITE,
		cw, HORIZONTAL_ALIGNMENT_CENTER)
	var bw := 300.0
	var again := _button("もう一度もぐる", _start_run, 32, Color(0.1, 0.5, 0.85))
	again.size = Vector2(bw, 84)
	again.position = Vector2(cw / 2 - bw / 2, y + 260)
	col.add_child(again)
	var back := _button("タイトルへ", _show_title, 26, Color(0.35, 0.4, 0.5))
	back.size = Vector2(bw, 64)
	back.position = Vector2(cw / 2 - bw / 2, y + 360)
	col.add_child(back)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		if e.keycode == KEY_M:
			Audio.toggle_mute()
		if OS.is_debug_build() and state == PLAY and not _busy:
			# デバッグ：F1 出口へワープ / F2 空気1 / F3 体力1
			match e.keycode:
				KEY_F1:
					_after_events([{"t": "exit"}])
				KEY_F2:
					dive.air = 1
					_refresh()
				KEY_F3:
					dive.hp = 1
					dive.player().hp = 1
					_refresh()
				KEY_F4:
					# 撮影用：泳ぐカードで一番深いマスへ
					for i in dive.hand.size():
						if Cards.def(dive.hand[i]).target in ["move", "dive"] and dive.can_play(i):
							var ts := dive.targets(i)
							ts.sort_custom(func(a, b): return a.y > b.y)
							_play(i, ts[0])
							break
				KEY_F5:
					# 撮影用：手札の1枚目を選ぶ
					_select(0)
				KEY_F6:
					_on_faint()
				KEY_F7:
					dive.floor_no = Dive.FLOORS
					_on_exit()
		if state == PLAY and not _busy and e.keycode == KEY_SPACE:
			_on_end_turn()


# ───────── HUD の絵 ─────────

## 体力（ハート）と空気（泡）を並べて描く
class Gauges extends Control:
	var game: Node

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var d: Dive = game.dive
		if d == null:
			return
		var font := get_theme_default_font()
		var h := size.y
		# ハート
		var r := h * 0.26
		for i in Dive.MAX_HP:
			var c := Vector2(r * 1.3 + i * r * 2.5, h * 0.5)
			_heart(c, r, UiStyle.HEART if i < d.hp else Color(0.25, 0.25, 0.35))
		# 空気の泡
		var x0 := r * 2.5 * Dive.MAX_HP + 30
		draw_string_outline(font, Vector2(x0, h * 0.68), "空気", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, 6, UiStyle.INK)
		draw_string(font, Vector2(x0, h * 0.68), "空気", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, UiStyle.AIR)
		var bx := x0 + 60
		var room := size.x - bx
		var step: float = min(room / Dive.MAX_AIR, h * 0.5)
		var low := d.air <= 3
		var t := Time.get_ticks_msec() / 1000.0
		for i in Dive.MAX_AIR:
			var c := Vector2(bx + step * (i + 0.5), h * 0.5)
			var br := step * 0.4
			if i < d.air:
				var col := UiStyle.AIR if not low else Color(1, 0.5 + 0.3 * sin(t * 8.0), 0.5)
				draw_circle(c, br, Color(col, 0.35))
				draw_arc(c, br, 0, TAU, 18, col, 2.5)
				draw_circle(c + Vector2(-br * 0.35, -br * 0.35), br * 0.25, Color(1, 1, 1, 0.8))
			else:
				draw_arc(c, br * 0.7, 0, TAU, 14, Color(0.4, 0.5, 0.6, 0.5), 1.5)
		if low:
			queue_redraw()

	func _heart(c: Vector2, r: float, col: Color) -> void:
		var pts := PackedVector2Array()
		for k in 24:
			var a := TAU * k / 24.0
			var x := 16 * pow(sin(a), 3)
			var y := -(13 * cos(a) - 5 * cos(2 * a) - 2 * cos(3 * a) - cos(4 * a))
			pts.append(c + Vector2(x, y) * r / 16.0)
		draw_colored_polygon(pts, col)
		draw_polyline(pts + PackedVector2Array([pts[0]]), Color(UiStyle.INK, 0.9), 2.0)


## 9つの階を丸で並べ、今いる階を光らせる（3つごとに海の色が変わる）
class DepthDots extends Control:
	var game: Node

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var d: Dive = game.dive
		if d == null:
			return
		var cols := [Color(0.45, 0.9, 1.0), Color(0.3, 0.55, 1.0), Color(0.55, 0.4, 0.95)]
		var step := size.x / Dive.FLOORS
		var t := Time.get_ticks_msec() / 1000.0
		for i in Dive.FLOORS:
			var c := Vector2(step * (i + 0.5), size.y / 2)
			var col: Color = cols[i / 3]
			if i + 1 < d.floor_no:
				draw_circle(c, step * 0.3, col)
			elif i + 1 == d.floor_no:
				draw_circle(c, step * (0.38 + 0.06 * sin(t * 5.0)), UiStyle.GOLD)
			else:
				draw_arc(c, step * 0.28, 0, TAU, 16, Color(col, 0.6), 2.0)
			if i == Dive.FLOORS - 1:
				# いちばん下は星
				draw_string(get_theme_default_font(), c + Vector2(-8, 8), "★", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, UiStyle.GOLD)
