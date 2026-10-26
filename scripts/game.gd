extends Control

## 画面の流れ：TITLE →（はじめてなら おはなし）→ PLAY（階）→ REST（空気だまり）→ PLAY … → RESULT
## ルールは Sweep（sweep.gd）。ここは画面づくりと演出。Sweep が返す events を _run_events で順に見せる。

enum { TITLE, PLAY, REST, RESULT }

const BGS := ["bg_shallow", "bg_mid", "bg_deep"]
const SAVE_PATH := "user://save.cfg"

var state := TITLE
var run: Sweep
var clears := 0        # クリアした回数（タイトルに出す）
var best_floor := 0
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
var _busy := false
var _hud: Hud
var _hint: RichTextLabel
var _skills := {}      # 名前 -> SkillButton
var _lv_btn: Button
var _lv_tween: Tween
var _speech: PanelContainer
var _confirm := Vector2i(-1, -1)   # もう一度タップで実行するマス
var _said := {}        # この階で言ったセリフ（同じことを何度も言わない）
var _result := {}      # 終わり方（RESULT 画面用）
var _perk_choices := []

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
		clears = int(cf.get_value("run", "clears", 0))
		best_floor = int(cf.get_value("run", "best_floor", 0))
		_story_seen = bool(cf.get_value("run", "story", false))


func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("run", "clears", clears)
	cf.set_value("run", "best_floor", best_floor)
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
	_skills.clear()
	_hud = null
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
	_label(("クリア %d回" % clears) if clears > 0 else (("最高 %d階" % best_floor) if best_floor > 0 else ""), 26, Vector2(0, top + 160), _ui, Color(1, 1, 1, 0.9), v.x, HORIZONTAL_ALIGNMENT_CENTER)
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
	run = Sweep.new()
	_start_floor()


func _start_floor() -> void:
	state = PLAY
	_said.clear()
	var ev := run.start_floor()
	var z := run.floor_no - 1
	_set_bg(BGS[z], 0.25 + z * 0.1, [1.0, 0.4, 0.0][z])
	Audio.bgm(["shallow", "mid", "deep"][z])
	_build_play()
	board.pop(ev[0].cells)
	_floor_banner()
	var pair: Array = Scenario.pick(Scenario.FLOOR_START[z])
	_say_line(pair[0], "きゅ", pair[1], 1.4)
	if run.floor_no == 1:
		_set_hint("[color=#7fe8ff]光るマスをタップ[/color]で照らす。数字＝[b]まわり8マスの敵の強さの合計[/b]")


func _floor_banner() -> void:
	var v := _view()
	var z := run.floor_no - 1
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
	_label("%d階　・　深さ %dm" % [run.floor_no, run.floor_no * 120], 32, Vector2(0, 90), box, UiStyle.AQUA, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	var tw := box.create_tween()
	tw.tween_property(box, "position:x", 0.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.0)
	tw.tween_property(box, "position:x", v.x, 0.3).set_ease(Tween.EASE_IN)
	tw.tween_callback(box.queue_free)
	Audio.sfx("dive")


## 画面の向きに合わせて、盤・情報・技ボタンの位置を決める
func _layout() -> Dictionary:
	var v := _view()
	if Screen.portrait:
		var cs: float = min((v.x - 24) / Sweep.W, (v.y - 360) / Sweep.H)
		var bw := cs * Sweep.W
		var by := 162.0
		var bottom := by + cs * Sweep.H
		return {"cs": cs, "board": Vector2((v.x - bw) / 2, by), "hud": Rect2(10, 8, v.x - 20, 144),
			"hint": Rect2(10, bottom + 12, v.x - 20, 58), "skills": Rect2(10, bottom + 80, v.x - 20, v.y - bottom - 88),
			"speech": Vector2(v.x / 2, by + 10)}
	var cs2: float = min((v.y - 40) / Sweep.H, (v.x - 700) / Sweep.W)
	var right := 24 + cs2 * Sweep.W + 36
	var rw := v.x - right - 20
	return {"cs": cs2, "board": Vector2(24, 20), "hud": Rect2(right, 16, rw, 144),
		"hint": Rect2(right, 172, rw, 78), "skills": Rect2(right, v.y - 190, rw, 176),
		"speech": Vector2(right + rw / 2, 270)}


func _build_play() -> void:
	_clear_ui()
	_confirm = Vector2i(-1, -1)
	var L := _layout()
	board = Board.new()
	board.position = L.board
	_ui.add_child(board)
	board.setup(run, L.cs)
	board.cell_tapped.connect(_on_cell)
	_hud = Hud.new()
	_hud.position = L.hud.position
	_hud.size = L.hud.size
	_hud.game = self
	_ui.add_child(_hud)
	# レベルアップのボタン（たまったら光る）
	_lv_btn = _button("Lv UP!", _on_level_up, 26, Color(0.85, 0.55, 0.1))
	_lv_tween = null
	_lv_btn.size = Vector2(150, 64)
	_lv_btn.position = L.hud.position + Vector2(L.hud.size.x - 162, L.hud.size.y - 72)
	_ui.add_child(_lv_btn)
	var hp_panel := _panel(L.hint, _ui, Color(0.5, 0.85, 1.0, 0.6), Color(0.02, 0.07, 0.15, 0.82))
	_hint = RichTextLabel.new()
	_hint.bbcode_enabled = true
	_hint.position = Vector2(14, 6)
	_hint.size = L.hint.size - Vector2(28, 10)
	_hint.add_theme_font_size_override("normal_font_size", 21)
	_hint.add_theme_font_size_override("bold_font_size", 21)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.scroll_active = false
	hp_panel.add_child(_hint)
	# 技と持ち物
	var r: Rect2 = L.skills
	var specs := [["sonar", "音波", UiStyle.AQUA], ["mira", "ミラのカン", UiStyle.PINK], ["memo", "メモ", Color(1, 0.6, 0.3)],
		["pearl", "真珠", Color(1, 0.95, 0.9)], ["bottle", "空気の結晶", UiStyle.AIR]]
	var bw := (r.size.x - 8 * (specs.size() - 1)) / specs.size()
	var bh: float = min(r.size.y, bw * 1.25)
	for i in specs.size():
		var sb := SkillButton.new()
		sb.id = specs[i][0]
		sb.title = specs[i][1]
		sb.color = specs[i][2]
		sb.position = r.position + Vector2(i * (bw + 8), r.size.y - bh)
		sb.size = Vector2(bw, bh)
		sb.pressed.connect(_on_skill)
		_ui.add_child(sb)
		_skills[sb.id] = sb
	_speech = null
	_refresh()


func _refresh() -> void:
	if run == null or board == null:
		return
	_hud.queue_redraw()
	board.sync()
	_lv_btn.disabled = not run.can_level_up() or _busy
	_lv_btn.modulate = Color.WHITE if run.can_level_up() else Color(1, 1, 1, 0.55)
	if run.can_level_up() and _lv_tween == null:
		_lv_btn.pivot_offset = _lv_btn.size / 2
		_lv_tween = _lv_btn.create_tween().set_loops()
		_lv_tween.tween_property(_lv_btn, "scale", Vector2(1.08, 1.08), 0.35)
		_lv_tween.tween_property(_lv_btn, "scale", Vector2.ONE, 0.35)
	elif not run.can_level_up() and _lv_tween != null:
		_lv_tween.kill()
		_lv_tween = null
		_lv_btn.scale = Vector2.ONE
	var counts := {"sonar": run.sonar_left, "mira": run.mira_left, "memo": -1,
		"pearl": run.items.pearl, "bottle": run.items.bottle}
	for k in _skills:
		var sb: SkillButton = _skills[k]
		sb.count = counts[k]
		sb.active = board.mode == k
		sb.queue_redraw()


func _set_hint(bb: String) -> void:
	if _hint:
		_hint.text = bb


# ───────── 操作 ─────────

func _on_skill(id: String) -> void:
	if _busy or state != PLAY:
		return
	_confirm = Vector2i(-1, -1)
	match id:
		"sonar", "mira", "memo":
			if board.mode == id:
				board.mode = ""
				_set_hint("")
			elif (id == "sonar" and run.sonar_left <= 0) or (id == "mira" and run.mira_left <= 0):
				_set_hint("[color=#ff7a7a]この階ではもう使えない[/color]")
				return
			else:
				board.mode = id
				Audio.sfx("card")
				_set_hint({"sonar": "[color=#7fe8ff]音波[/color]：照らしたい所をタップ（そのまわり3×3が安全に見える）",
					"mira": "[color=#ff8cc8]ミラのカン[/color]：照らしていないマスをタップ。何がいるか教えてくれる",
					"memo": "[color=#ffa060]メモ[/color]：あやしいマスをタップして「！」を付ける／外す"}[id])
		"pearl", "bottle":
			var ev := run.use_item(id)
			if ev.is_empty():
				_set_hint("[color=#ff7a7a]持っていない[/color]")
				return
			Audio.sfx("bubble")
			await _run_events(ev)
	_refresh()


func _on_level_up() -> void:
	if _busy or not run.can_level_up():
		return
	var ev := run.level_up()
	await _run_events(ev)
	_refresh()


func _on_cell(p: Vector2i) -> void:
	if _busy or state != PLAY:
		return
	var c := run.cell(p)
	match board.mode:
		"memo":
			if not c.seen:
				if board.marks.has(p):
					board.marks.erase(p)
				else:
					board.marks[p] = true
				Audio.sfx("click", -8.0)
			return
		"sonar":
			board.mode = ""
			_act(run.sonar(p))
			return
		"mira":
			if c.seen:
				_set_hint("[color=#ff8cc8]まだ照らしていないマス[/color]をタップしてね")
				return
			board.mode = ""
			_act(run.mira_hint(p))
			return
	if not run.reachable(p):
		if c.seen and c.enemy > 0 and c.alive:
			_set_hint(_enemy_info(p) + "\n[color=#9fb4c8]まだ届かない[/color]")
		else:
			_set_hint("[color=#9fb4c8]照らせるのは、照らしたマスの隣だけ[/color]")
		return
	# 間違えて押しやすい所は、もう一度タップで実行
	var warn := ""
	if c.seen and c.enemy > 0 and c.alive and c.enemy >= run.hp:
		warn = "[color=#ff7a7a]今の体力（%d）では負ける！[/color]　もう一度タップで挑む" % run.hp
	elif not c.seen and board.marks.has(p):
		warn = "[color=#ffa060]「！」を付けたマス[/color]。もう一度タップで照らす"
	elif c.seen and c.item == "exit":
		var hidden := run.all_cells().filter(func(q): return not run.cell(q).seen).size()
		warn = "[b]次の階へ進む？[/b]　もう一度タップで出口に入る" + ("（まだ %d マス照らしていない）" % hidden if hidden > 0 else "")
	elif not c.seen and run.air <= 0:
		warn = "[color=#ff7a7a]空気がない！[/color]　照らすと体力が1減る。もう一度タップで照らす"
	if warn != "" and _confirm != p:
		_confirm = p
		_set_hint(warn)
		if c.seen and c.enemy > 0 and c.alive:
			board.flash_tiles([p], UiStyle.DANGER, 0.4)
		Audio.sfx("alert", -8.0)
		return
	_confirm = Vector2i(-1, -1)
	if c.seen and c.enemy > 0 and c.alive:
		_set_hint(_enemy_info(p))
	_act(run.tap(p))


func _enemy_info(p: Vector2i) -> String:
	var kind := run.enemy_kind(p)
	var note: String = Sweep.NOTES.get(kind, "")
	return "[b]%s[/b]　強さ %d（倒すと体力-%d、経験値+%d）%s" % [Sweep.NAMES[kind], run.cell(p).enemy, run.cell(p).enemy,
		run.cell(p).enemy, ("\n" + note) if note != "" else ""]


func _act(ev: Array) -> void:
	if ev.is_empty():
		return
	_busy = true
	_refresh()
	await _run_events(ev)
	_busy = false
	if state != PLAY:
		return
	for e in ev:
		match e.t:
			"faint":
				_on_faint()
				return
			"exit":
				_on_exit()
				return
			"star":
				_on_star()
				return
	_refresh()
	_quips()


func _quips() -> void:
	if run.air <= 3 and not _said.has("air"):
		_said.air = true
		_say(Scenario.SAY_LOW_AIR)
		board.canopus.act(2, 1.4)
	elif run.hp <= 2 and not _said.has("hp"):
		_said.hp = true
		_say(Scenario.SAY_LOW_HP)
	# 海竜が見えたら一度だけ
	for p in board.actors:
		if run.cell(p).enemy == 10 and run.cell(p).seen and not _said.has("boss"):
			_said.boss = true
			_say(Scenario.SAY_BOSS)


# ───────── 演出 ─────────

func _cell_pos(p: Vector2i) -> Vector2:
	return board.global_position + board.center(p)


## カノープスを p へ泳がせ、ミラも少し遅れてついてくる
func _swim_to(p: Vector2i, lunge: bool = false) -> void:
	var a := board.canopus
	var to := board.center(p)
	if lunge:
		# 敵には体当たりして、手前で止まる
		to = a.position.lerp(to, 0.7)
	if a.position.distance_to(to) < 2:
		return
	var left := to.x < a.position.x - 1
	if absf(to.x - a.position.x) > 1:
		a.flip = left
	var tw := a.create_tween()
	tw.tween_property(a, "position", to, 0.16).set_trans(Tween.TRANS_SINE)
	var mt := board.mira.create_tween()
	mt.tween_interval(0.08)
	mt.tween_property(board.mira, "position", board.mira_spot(p, a.flip), 0.22).set_trans(Tween.TRANS_SINE)
	board.mira.flip = a.flip
	Audio.sfx("swim", -6.0)
	await tw.finished


func _run_events(ev: Array) -> void:
	for e in ev:
		if board == null:
			return
		match e.t:
			"open":
				board.pop(e.cells)
				board.sync()
				if e.cells.size() == 1:
					await _swim_to(e.cells[0])
				Audio.sfx("bubble" if e.cells.size() > 3 else "click", -6.0)
				await _wait(0.05)
			"air":
				if e.n > 0:
					_float("空気 +%d" % e.n, _cell_pos(run.canopus) + Vector2(0, -50), UiStyle.AIR, 30)
					Audio.sfx("bubble")
			"drown":
				_float("息が……！ -1", _cell_pos(run.canopus) + Vector2(0, -60), UiStyle.AIR, 30)
				board.canopus.act(2, 1.0)
				board.canopus.flash = 1.0
				Audio.sfx("drown")
				await _wait(0.3)
			"fight":
				var p: Vector2i = e.at
				var foe: Actor = board.actors.get(p)
				if foe:
					foe.visible = true
					foe.act(3, 0.5)
				await _swim_to(p, true)
				if e.dmg > 0:
					board.canopus.flash = 1.0
					board.canopus.act(2, 0.6)
					_float("-%d" % e.dmg, _cell_pos(p) + Vector2(0, -40), UiStyle.HEART, 40)
					_shake(4 + e.dmg * 2)
					Audio.sfx("hurt" if e.dmg >= 3 else "hit")
				else:
					Audio.sfx("hit")
				board.canopus.act(3, 0.4)
				if foe:
					foe.flash = 1.0
				_hud.queue_redraw()
				await _wait(0.3)
			"kill":
				var p: Vector2i = e.at
				var foe: Actor = board.actors.get(p)
				if foe:
					foe.act(2, 1.0)
					var tw := foe.create_tween()
					tw.tween_property(foe, "alpha", 0.0, 0.4)
					tw.parallel().tween_property(foe, "position:y", foe.position.y - 30, 0.4)
					tw.tween_callback(func(): foe.visible = false)
				_float("経験値 +%d" % e.xp, _cell_pos(p) + Vector2(0, -10), UiStyle.GOLD, 28)
				Audio.sfx("pop")
				await _swim_to(p)
				_hud.queue_redraw()
				if randf() < 0.3:
					_say(Scenario.SAY_KILL)
			"ink":
				board.flash_tiles(e.cells + [e.at], Color(0.05, 0.02, 0.1), 0.6)
				board.pop(e.cells)
				_float("墨が晴れた！", _cell_pos(e.at) + Vector2(0, -60), Color(0.85, 0.85, 1.0), 26)
				Audio.sfx("whoosh")
				await _wait(0.3)
			"item":
				var p: Vector2i = e.at
				await _swim_to(p)
				var text := ""
				match e.item:
					"coin":
						text = "金貨　経験値 +%d" % e.xp
						if not _said.has("coin"):
							_said.coin = true
							_say(Scenario.SAY_PICKUP)
					"pearl":
						text = "真珠を拾った"
					"bottle":
						text = "空気の結晶を拾った"
					"chest":
						text = {"pearl": "宝箱：真珠！", "bottle": "宝箱：空気の結晶！", "coin3": "宝箱：金貨の山！　経験値 +5"}[e.got]
				_float(text, _cell_pos(p) + Vector2(0, -40), UiStyle.GOLD, 28)
				Audio.sfx("gem" if e.item == "chest" else "coin")
				board.canopus.act(1, 0.8, true)
				board.mira.act(1, 0.8, true)
				if e.item in ["pearl", "bottle", "chest"] and not _said.has("item"):
					_said.item = true
					_say(Scenario.SAY_ITEM)
				_hud.queue_redraw()
				await _wait(0.3)
			"vent":
				await _swim_to(e.at)
				board.ring(e.at, 0.8, Color(0.85, 1, 1))
				_float("空気 +%d" % e.air, _cell_pos(e.at) + Vector2(0, -40), UiStyle.AIR, 32)
				Audio.sfx("bubble")
				if not _said.has("vent"):
					_said.vent = true
					_say(Scenario.SAY_VENT)
				await _wait(0.3)
			"exit":
				await _swim_to(e.at)
			"sonar":
				board.ring(e.at, 2.0)
				board.pop(e.cells)
				board.sync()
				board.canopus.act(3, 0.6)
				Audio.sfx("sonar")
				if not _said.has("sonar"):
					_said.sonar = true
					_say(Scenario.SAY_SONAR)
				await _wait(0.45)
			"hint":
				await _mira_scout(e.at, e.info)
			"levelup":
				_level_banner(e.lv)
				board.canopus.act(1, 1.4, true)
				board.mira.act(1, 1.2, true)
				board.mira.flip = not board.mira.flip
				board.ring(run.canopus, 1.2, UiStyle.GOLD)
				Audio.sfx("gem")
				_say(Scenario.SAY_LEVEL)
				_hud.queue_redraw()
				await _wait(0.5)
			"heal":
				_float("体力 +%d" % e.n, _cell_pos(run.canopus) + Vector2(0, -50), UiStyle.HEART, 30)
				Audio.sfx("block")
				_hud.queue_redraw()
			"star":
				board.ring(run.canopus, 3.0, UiStyle.GOLD)
				Audio.jingle("surface")
				await _wait(1.0)
	if board:
		board.sync()


## ミラが飛んでいって、そのマスに何がいるか体で教える
func _mira_scout(p: Vector2i, info: String) -> void:
	var m := board.mira
	var home := m.position
	var tw := m.create_tween()
	tw.tween_property(m, "position", board.center(p) + Vector2(0, -board.cs * 0.2), 0.3).set_trans(Tween.TRANS_SINE)
	await tw.finished
	var key := info
	if info.begins_with("lv"):
		key = "strong" if int(info.substr(2)) >= run.hp else "weak"
	var line: Array = Scenario.MIRA_HINT[key]
	var f: int = {"safe": 1, "item": 1, "weak": 3, "strong": 2}[key]
	m.act(f, 0.9, key in ["safe", "item", "weak"])
	_float(line[1], _cell_pos(p) + Vector2(0, -board.cs * 0.8), UiStyle.PINK, 26)
	_mira_cry(line[1], line[2])
	if key == "strong":
		_shake(4)
	await _wait(0.7)
	var back := m.create_tween()
	back.tween_property(m, "position", board.mira_spot(run.canopus, board.canopus.flip), 0.3).set_trans(Tween.TRANS_SINE)
	_say_line(line[0], "", "")
	await back.finished


func _level_banner(lv: int) -> void:
	var v := _view()
	var l := UiStyle.label("レベルアップ！　Lv %d" % lv, 56, UiStyle.GOLD, 12)
	l.size = Vector2(v.x, 80)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = Vector2(0, v.y * 0.4)
	l.pivot_offset = Vector2(v.x / 2, 40)
	l.scale = Vector2(0.3, 0.3)
	_fx.add_child(l)
	var sub := UiStyle.label("体力が全回復！", 32, UiStyle.AQUA)
	sub.size = Vector2(v.x, 50)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.position = Vector2(0, v.y * 0.4 + 80)
	_fx.add_child(sub)
	var tw := l.create_tween()
	tw.tween_property(l, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.0)
	tw.tween_property(l, "modulate:a", 0.0, 0.3)
	tw.tween_callback(l.queue_free)
	var t2 := sub.create_tween()
	t2.tween_interval(1.25)
	t2.tween_property(sub, "modulate:a", 0.0, 0.3)
	t2.tween_callback(sub.queue_free)


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
	if cry == "":
		return
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
	var a := board.canopus
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
	best_floor = max(best_floor, run.floor_no)
	_save()
	_perk_choices = run.perk_choices()
	_show_rest()


func _on_star() -> void:
	clears += 1
	best_floor = Sweep.FLOORS
	_save()
	_result = {"kind": "clear"}
	_talk(Scenario.CLEAR_TALK, _show_result)


func _on_faint() -> void:
	_busy = true
	Audio.jingle("faint")
	board.canopus.act(2, 2.0)
	board.mira.act(2, 2.0)
	await _wait(1.0)
	_busy = false
	best_floor = max(best_floor, run.floor_no)
	_save()
	_result = {"kind": "faint"}
	_talk(Scenario.FAINT_TALK, _show_result)


## 空気だまり：体力が全回復し、強化を1つ選んで次の階へ
func _show_rest() -> void:
	state = REST
	_clear_ui()
	Audio.bgm("rest")
	var full := _view()
	var portrait := Screen.portrait
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
	_label("%d階を抜けた！　体力が全回復する" % run.floor_no, 28, Vector2(0, top + 72), left, Color.WHITE, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	_label("Lv %d　　体力 %d　　敵を %d 体倒した" % [run.lv, run.max_hp, run.kills], 28, Vector2(0, top + 120), left, UiStyle.GOLD,
		v.x, HORIZONTAL_ALIGNMENT_CENTER)
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
	var say := _label("カノープス「%s」" % trip[0], 22, Vector2(20, mini_y + 176), left, Color.WHITE, v.x - 40, HORIZONTAL_ALIGNMENT_CENTER)
	say.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label("ミラ「%s」" % trip[1], 22, Vector2(0, mini_y + 238), left, UiStyle.PINK, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	c.act(MiniChar.HAPPY, 1.2, true)
	m.act(MiniChar.HAPPY, 1.2, true)
	var cy := mini_y + 280 if portrait else 110.0
	v = right.size
	_label("強化を1つ選ぶ", 30, Vector2(0, cy), right, UiStyle.AQUA, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	var bw: float = min(v.x - 60, 560)
	for i in _perk_choices.size():
		var id: String = _perk_choices[i]
		var info: Array = Sweep.PERKS[id]
		var b := _button("%s\n%s" % info, func():
			Audio.sfx("get")
			run.next_floor(id)
			_start_floor(), 26, [Color(0.15, 0.45, 0.8), Color(0.65, 0.3, 0.6), Color(0.2, 0.55, 0.45)][i])
		b.size = Vector2(bw, 100)
		b.position = Vector2(v.x / 2 - bw / 2, cy + 56 + i * 116)
		right.add_child(b)


func _show_result() -> void:
	state = RESULT
	_clear_ui()
	var v := _view()
	var kind: String = _result.get("kind", "faint")
	if kind == "clear":
		_set_bg("bg_deep", 0.3, 0.0)
	var title: String = {"faint": "ミラに助けられた……", "clear": "星のかけらを見つけた！"}[kind]
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
	_label("%s %d階まで" % [Scenario.ZONES[run.floor_no - 1][0], run.floor_no], 34, Vector2(0, y), col, UiStyle.AQUA, cw, HORIZONTAL_ALIGNMENT_CENTER)
	_label("Lv %d　敵を %d 体倒した" % [run.lv, run.kills], 34, Vector2(0, y + 56), col, UiStyle.GOLD, cw, HORIZONTAL_ALIGNMENT_CENTER)
	var sub := "クリア %d回目！" % clears if kind == "clear" else ("今までの最高：%d階" % best_floor)
	_label(sub, 30, Vector2(0, y + 120), col, UiStyle.PINK if kind == "clear" else Color.WHITE, cw, HORIZONTAL_ALIGNMENT_CENTER)
	var bw := 300.0
	var again := _button("もう一度もぐる", _start_run, 32, Color(0.1, 0.5, 0.85))
	again.size = Vector2(bw, 84)
	again.position = Vector2(cw / 2 - bw / 2, y + 200)
	col.add_child(again)
	var back := _button("タイトルへ", _show_title, 26, Color(0.35, 0.4, 0.5))
	back.size = Vector2(bw, 64)
	back.position = Vector2(cw / 2 - bw / 2, y + 300)
	col.add_child(back)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		if e.keycode == KEY_M:
			Audio.toggle_mute()
		if OS.is_debug_build() and state == PLAY and not _busy:
			# デバッグ：F1 出口へ / F2 空気1 / F3 体力1 / F4 安全なマスを1つ照らす / F6 気絶 / F7 最下層クリア / F8 経験値+20
			match e.keycode:
				KEY_F1:
					_on_exit()
				KEY_F2:
					run.air = 1
					_refresh()
				KEY_F3:
					run.hp = 1
					_refresh()
				KEY_F4:
					for p in run.all_cells():
						var c := run.cell(p)
						if not c.seen and run.reachable(p) and c.enemy == 0:
							_act(run.tap(p))
							break
				KEY_F6:
					_on_faint()
				KEY_F7:
					_on_star()
				KEY_F8:
					run.xp += 20
					_refresh()


# ───────── HUD ─────────

## 上の情報：階・体力・経験値・空気
class Hud extends Control:
	var game: Node

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var run: Sweep = game.run
		if run == null:
			return
		draw_style_box(UiStyle.panel(Color(0.5, 0.85, 1.0, 0.6), Color(0.02, 0.07, 0.15, 0.85)), Rect2(Vector2.ZERO, size))
		var font := get_theme_default_font()
		var t := Time.get_ticks_msec() / 1000.0
		var z := run.floor_no - 1
		_text(font, "%s %d階" % [Scenario.ZONES[z][0], run.floor_no], Vector2(16, 34), 26, UiStyle.GOLD)
		# 3つの階の丸（最後は星）
		for i in Sweep.FLOORS:
			var c := Vector2(170 + i * 34, 25)
			if i + 1 < run.floor_no:
				draw_circle(c, 9, UiStyle.AQUA)
			elif i + 1 == run.floor_no:
				draw_circle(c, 11 + sin(t * 5.0) * 1.5, UiStyle.GOLD)
			else:
				draw_arc(c, 9, 0, TAU, 16, Color(UiStyle.AQUA, 0.6), 2.0)
		_text(font, "★", Vector2(170 + 3 * 34 - 10, 34), 22, UiStyle.GOLD)
		_text(font, "Lv %d" % run.lv, Vector2(330, 36), 30, Color.WHITE)
		var w: float = size.x - 190
		# 体力
		_bar(font, Vector2(16, 58), w, "体力", run.hp, run.max_hp, UiStyle.HEART if run.hp > 2 else Color(1, 0.3 + 0.2 * sin(t * 8.0), 0.3))
		# 経験値
		var need := run.xp_need()
		_bar(font, Vector2(16, 84), w, "経験", mini(run.xp, need), need, UiStyle.GOLD if run.xp < need else Color(1, 0.9, 0.4 + 0.3 * sin(t * 6.0)))
		# 空気
		var air_col := UiStyle.AIR if run.air > 3 else Color(1, 0.5 + 0.3 * sin(t * 8.0), 0.5)
		_bar(font, Vector2(16, 110), w, "空気", run.air, max(run.air, Sweep.START_AIR + (10 if run.has_perk("lung") else 0)), air_col)

	func _bar(font: Font, at: Vector2, w: float, name: String, v: int, mx: int, col: Color) -> void:
		_text(font, name, at + Vector2(0, 18), 20, Color(0.85, 0.92, 1.0))
		var r := Rect2(at + Vector2(56, 2), Vector2(w - 140, 18))
		draw_rect(r, Color(0, 0, 0, 0.5))
		var k: float = clamp(float(v) / max(mx, 1), 0.0, 1.0)
		draw_rect(Rect2(r.position, Vector2(r.size.x * k, r.size.y)), col)
		draw_rect(r, Color(1, 1, 1, 0.4), false, 1.5)
		_text(font, "%d / %d" % [v, mx], at + Vector2(w - 76, 18), 20, Color.WHITE)

	func _text(font: Font, s: String, at: Vector2, fs: int, col: Color) -> void:
		draw_string_outline(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, UiStyle.INK)
		draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


## 下の技・持ち物ボタン。絵と名前と残り回数
class SkillButton extends Control:
	signal pressed(id: String)
	const ICONS := {"sonar": 2, "mira": 9, "memo": -1, "pearl": -1, "bottle": 5}
	static var _icons: Texture2D
	static var _pearl: Texture2D
	var id := ""
	var title := ""
	var color := Color.WHITE
	var count := 0
	var active := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		if _icons == null:
			_icons = load("res://assets/images/ui/icons.png")
			_pearl = load("res://assets/images/obj/pearl.png")

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit(id)
			accept_event()

	func _draw() -> void:
		var usable := count != 0
		var bg := Color(color.darkened(0.6), 0.92) if usable else Color(0.1, 0.12, 0.16, 0.85)
		var edge := UiStyle.GOLD if active else Color(color, 0.9 if usable else 0.3)
		var sb := UiStyle.panel(edge, bg, 10 if active else 2, 16)
		sb.set_border_width_all(4 if active else 2)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		var font := get_theme_default_font()
		var art := Rect2(size.x * 0.18, 8, size.x * 0.64, size.x * 0.64)
		var mod := Color.WHITE if usable else Color(0.45, 0.45, 0.5)
		var ix: int = ICONS[id]
		if id == "memo":
			var fs := int(size.x * 0.5)
			var w := font.get_string_size("！", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string_outline(font, Vector2(size.x / 2 - w / 2, art.get_center().y + fs * 0.36), "！", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, UiStyle.INK)
			draw_string(font, Vector2(size.x / 2 - w / 2, art.get_center().y + fs * 0.36), "！", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)
		elif id == "pearl" and _pearl:
			draw_texture_rect(_pearl, art, false, mod)
		elif _icons:
			var cell := _icons.get_size().x / 4
			draw_texture_rect_region(_icons, art, Rect2((ix % 4) * cell, (ix / 4) * cell, cell, cell), mod)
		var fs2: int = min(22, int((size.x - 8) / max(title.length(), 1)))
		var tw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x
		draw_string_outline(font, Vector2(size.x / 2 - tw / 2, size.y - 12), title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, 5, UiStyle.INK)
		draw_string(font, Vector2(size.x / 2 - tw / 2, size.y - 12), title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, Color.WHITE)
		if count >= 0:
			var c := Vector2(size.x - 16, 16)
			draw_circle(c, 14, UiStyle.INK)
			draw_circle(c, 12, color if usable else Color(0.3, 0.3, 0.35))
			var s := str(count)
			var cw := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
			draw_string(font, c + Vector2(-cw / 2, 7), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, UiStyle.INK)
