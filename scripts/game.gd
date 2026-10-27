extends Control

## 画面の流れ：TITLE →（はじめてなら おはなし）→ PLAY（階）→ REST（空気だまり）→ PLAY … → RESULT
## ルールは Tactics（tactics.gd）、3D のマップは World（world.gd）。ここは画面づくりと演出。
## Tactics が返す events を _run_events で順に見せる。

enum { TITLE, PLAY, REST, RESULT }

const BGS := ["bg_shallow", "bg_mid", "bg_deep", "bg_deep"]
const BGMS := ["shallow", "mid", "deep", "boss"]
const SAVE_PATH := "user://save.cfg"
const HL_MOVE := Color(0.1, 0.75, 1.0, 0.7)
const HL_ATK := Color(1.0, 0.2, 0.25, 0.75)
const HL_SPOT := Color(1.0, 0.4, 0.75, 0.65)

signal _picked(id: String)

var state := TITLE
var run: Tactics
var clears := 0        # クリアした回数（タイトルに出す）
var best_floor := 0
var _story_seen := false

# 層（下から）：背景 → 水の演出 → 3D マップ → 画面 → 演出の文字 → 会話
var _bg: TextureRect
var _bg_shade: ColorRect
var _ocean: OceanFx
var _world_layer: Control
var _ui: Control
var _fx: Control
var _talk_layer: Control

# PLAY の部品
var world: World
var _busy := false
var _hud: Hud
var _hint: RichTextLabel
var _hand_box: Control
var _cards: Array[CardView] = []
var _mode_box: Control
var _end_btn: Button
var _end_tw: Tween
var _speech: PanelContainer
var _sel := -1          # 選んでいる手札
var _mode := "act"      # "act" わざ / "swim" 泳ぐ
var _targets := {}
var _said := {}
var _result := {}
var _rest_picks := 0
var _rest_choices := []

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
	_world_layer = Control.new()
	_world_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_world_layer)
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
	for n in [_bg, _bg_shade, _world_layer, _ui, _fx, _talk_layer]:
		n.position = Vector2.ZERO
		n.size = v
	_ocean.resize(v)
	if world:
		world.size = v
	if _busy:
		# 演出中に組み直すと手札がずれるので、終わってから
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
	for n in [_bg, _bg_shade, _world_layer, _ui, _fx, _talk_layer]:
		n.size = v


func _clear_ui() -> void:
	for c in _ui.get_children():
		c.queue_free()
	_hud = null
	_hint = null
	_cards.clear()
	_hand_box = null
	_mode_box = null
	_end_btn = null
	_speech = null


func _drop_world() -> void:
	if world:
		world.queue_free()
		world = null



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
	_drop_world()
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
	run = Tactics.new()
	_start_stage(run.start_stage())


func _start_stage(ev: Array) -> void:
	state = PLAY
	_said.clear()
	_sel = -1
	var z := run.stage - 1
	_bg.texture = null
	_bg_shade.color = Color(0, 0, 0, 0)
	_ocean.setup(_view(), 0.0)
	Audio.bgm(BGMS[z])
	_drop_world()
	world = World.new()
	world.size = _view()
	_world_layer.add_child(world)
	world.setup(run, z)
	world.cell_tapped.connect(_on_cell)
	_build_play()
	if run.is_boss_stage():
		await _boss_intro()
	_floor_banner()
	var pair: Array = Scenario.pick(Scenario.FLOOR_START[z])
	_say_line(pair[0], "きゅ", pair[1], 1.4)
	_set_hint("")
	if run.stage == 1:
		_set_hint("[color=#ffd75e]カードをタップ[/color] → [color=#7fe8ff]光るマスをタップ[/color]で動く。1ターンに2回まで。\nオレンジの扇は敵の視界。そこで止まると見つかる！")
	if ev.size() > 0:
		_refresh()


## ボスの前：海竜の絵を見せて会話
func _boss_intro() -> void:
	_busy = true
	var v := _view()
	var pic := TextureRect.new()
	pic.texture = load("res://assets/images/ev_boss.jpg")
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	pic.size = v
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pic.z_index = 120
	pic.modulate.a = 0.0
	_ui.add_child(pic)
	var tw := pic.create_tween()
	tw.tween_property(pic, "modulate:a", 1.0, 0.6)
	await tw.finished
	Audio.sfx("roar")
	# ラムダは外の変数を書きかえられないので、配列で受けわたす
	var done := [false]
	_talk(Scenario.BOSS_TALK, func(): done[0] = true)
	while not done[0]:
		await get_tree().process_frame
	var t2 := pic.create_tween()
	t2.tween_property(pic, "modulate:a", 0.0, 0.5)
	t2.tween_callback(pic.queue_free)
	await t2.finished
	_busy = false


func _floor_banner() -> void:
	var v := _view()
	var z := run.stage - 1
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
	_label("%d階　・　深さ %dm" % [run.stage, run.stage * 120] if not run.is_boss_stage() else "最深部　・　深さ ???m", 32, Vector2(0, 90), box, UiStyle.AQUA, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	var tw := box.create_tween()
	tw.tween_property(box, "position:x", 0.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.0)
	tw.tween_property(box, "position:x", v.x, 0.3).set_ease(Tween.EASE_IN)
	tw.tween_callback(box.queue_free)
	Audio.sfx("dive")


## 小さな帯（敵のターンなど）
func _mini_banner(text: String, col: Color) -> void:
	var v := _view()
	var l := UiStyle.label(text, 40, col, 10)
	l.size = Vector2(v.x, 60)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = Vector2(0, v.y * 0.3)
	l.pivot_offset = Vector2(v.x / 2, 30)
	l.scale = Vector2(1.6, 1.6)
	l.modulate.a = 0.0
	_fx.add_child(l)
	var tw := l.create_tween()
	tw.tween_property(l, "scale", Vector2.ONE, 0.18).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(l, "modulate:a", 1.0, 0.18)
	tw.tween_interval(0.45)
	tw.tween_property(l, "modulate:a", 0.0, 0.25)
	tw.tween_callback(l.queue_free)


## 画面の向きに合わせて、情報・手札・ボタンの位置を決める
func _layout() -> Dictionary:
	var v := _view()
	if Screen.portrait:
		var hand_h := 196.0
		return {"hud": Rect2(10, 8, v.x - 20, 104), "hint": Rect2(10, 118, v.x - 20, 70),
			"hand": Rect2(8, v.y - hand_h - 14, v.x - 16, hand_h), "card_w": 128.0,
			"end": Rect2(v.x - 200, v.y - hand_h - 100, 188, 70), "rot": Vector2(14, v.y - hand_h - 94),
			"mode": Rect2(10, v.y - hand_h - 176, v.x - 20, 64), "speech": Vector2(v.x / 2, 200),
			"top": 190.0, "bottom": hand_h + 110.0}
	var hand_h2 := 168.0
	return {"hud": Rect2(10, 8, 500, 104), "hint": Rect2(520, 8, v.x - 530, 70),
		"hand": Rect2(220, v.y - hand_h2 - 10, v.x - 440, hand_h2), "card_w": 112.0,
		"end": Rect2(v.x - 204, v.y - 96, 190, 74), "rot": Vector2(16, v.y - 90),
		"mode": Rect2(220, v.y - hand_h2 - 84, v.x - 440, 62), "speech": Vector2(v.x / 2, 90),
		"top": 80.0, "bottom": hand_h2 + 40.0}


func _build_play() -> void:
	_clear_ui()
	var L := _layout()
	if world:
		world.top_margin = L.top
		world.bottom_margin = L.bottom
	_hud = Hud.new()
	_hud.position = L.hud.position
	_hud.size = L.hud.size
	_hud.game = self
	_ui.add_child(_hud)
	var hp_panel := _panel(L.hint, _ui, Color(0.5, 0.85, 1.0, 0.6), Color(0.02, 0.07, 0.15, 0.82))
	_hint = RichTextLabel.new()
	_hint.bbcode_enabled = true
	_hint.position = Vector2(14, 6)
	_hint.size = L.hint.size - Vector2(28, 10)
	_hint.add_theme_font_size_override("normal_font_size", 20)
	_hint.add_theme_font_size_override("bold_font_size", 20)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.scroll_active = false
	hp_panel.add_child(_hint)
	# カメラを回すボタン
	var rot: Vector2 = L.rot
	var specs := [["◀", 1], ["▶", -1], ["◎", 0]]
	for i in specs.size():
		var dir: int = specs[i][1]
		var b := _button(specs[i][0], func():
			if world:
				if dir == 0:
					world.follow(run.me().pos)
				else:
					world.rotate_view(dir), 30, Color(0.2, 0.3, 0.45))
		b.size = Vector2(64, 64)
		b.position = rot + Vector2(i * 72, 0)
		_ui.add_child(b)
	_end_btn = _button("ターン終了", _on_end_turn, 28, Color(0.75, 0.4, 0.15))
	_end_btn.position = L.end.position
	_end_btn.size = L.end.size
	_end_tw = null
	_ui.add_child(_end_btn)
	_mode_box = Control.new()
	_mode_box.position = L.mode.position
	_mode_box.size = L.mode.size
	_mode_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_mode_box)
	_hand_box = Control.new()
	_hand_box.position = L.hand.position
	_hand_box.size = L.hand.size
	_hand_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_hand_box)
	_rebuild_hand()
	_refresh()


func _rebuild_hand() -> void:
	if _hand_box == null:
		return
	for c in _hand_box.get_children():
		c.queue_free()
	_cards.clear()
	var L := _layout()
	var n := run.hand.size()
	var box: Rect2 = L.hand
	var cw: float = L.card_w
	var gap := 8.0
	if n * (cw + gap) > box.size.x:
		cw = box.size.x / n - gap
	var total := n * (cw + gap) - gap
	for i in n:
		var cv := CardView.new(run.hand[i])
		cv.index = i
		cv.size = Vector2(cw, minf(box.size.y - 8, cw * 1.45))
		cv.position = Vector2(box.size.x / 2 - total / 2 + i * (cw + gap), box.size.y - cv.size.y)
		cv.tapped.connect(_on_card)
		_hand_box.add_child(cv)
		_cards.append(cv)


func _refresh() -> void:
	if run == null or _hud == null:
		return
	_hud.queue_redraw()
	if world:
		world.refresh()
	for cv in _cards:
		cv.playable = run.can_play(cv.index) and not _busy
		cv.selected = cv.index == _sel
	var stuck := not _busy and not _any_playable()
	if _end_btn:
		_end_btn.disabled = _busy
		if stuck and _end_tw == null:
			_end_btn.pivot_offset = _end_btn.size / 2
			_end_tw = _end_btn.create_tween().set_loops()
			_end_tw.tween_property(_end_btn, "scale", Vector2(1.08, 1.08), 0.35)
			_end_tw.tween_property(_end_btn, "scale", Vector2.ONE, 0.35)
		elif not stuck and _end_tw != null:
			_end_tw.kill()
			_end_tw = null
			_end_btn.scale = Vector2.ONE
	_build_mode()


func _any_playable() -> bool:
	for i in run.hand.size():
		if run.can_play(i):
			return true
	return false


func _set_hint(bb: String) -> void:
	if _hint:
		_hint.text = bb if bb != "" else _default_hint()


func _default_hint() -> String:
	if run == null:
		return ""
	if not _any_playable():
		return "このターンはもう動けない。[color=#ffb070]ターン終了[/color]で敵が動く"
	return "[color=#ffd75e]カードをタップ[/color]して使う（このターンあと %d 回）\n[color=#9fb4c8]敵をタップすると、視界と巡回路が見える[/color]" % run.plays_left


# ───────── 操作 ─────────

func _on_card(cv: CardView) -> void:
	if _busy or state != PLAY:
		return
	var i := cv.index
	if _sel == i:
		_select(-1)
		return
	if not run.can_play(i):
		_set_hint("[color=#ff9a7a]このターンはもう動けない[/color]。「ターン終了」を押そう")
		Audio.sfx("bump", -6.0)
		return
	Audio.sfx("card")
	_select(i)


func _select(i: int) -> void:
	_sel = i
	if i < 0:
		_targets = {}
		if world:
			world.set_highlight({})
		_set_hint("")
		_refresh()
		return
	var d := Cards.def(run.hand[i])
	_mode = "act"
	_update_targets()
	_set_hint("[b]%s[/b]　%s　[color=#9fdcff]（空気 %d）[/color]" % [d.name, d.desc.replace("\n", "　"), d.cost])
	_refresh()


func _update_targets() -> void:
	if _sel < 0:
		return
	var d := Cards.def(run.hand[_sel])
	var cells := {}
	if _mode == "swim":
		_targets = run.swim_targets(_sel)
		for p in _targets:
			cells[p] = HL_MOVE
	else:
		_targets = run.targets(_sel)
		var col: Color = {"move": HL_MOVE, "adj": HL_ATK, "line": HL_ATK, "spot": HL_SPOT}.get(d.target, HL_MOVE)
		for p in _targets:
			cells[p] = col
	world.set_highlight(cells)


## カードを選んでいるときの「わざ／泳ぐ」の切りかえ
func _build_mode() -> void:
	if _mode_box == null:
		return
	for c in _mode_box.get_children():
		c.queue_free()
	if _sel < 0 or _busy:
		return
	var d := Cards.def(run.hand[_sel])
	var w: float = minf(_mode_box.size.x / 2 - 8, 300)
	var cx := _mode_box.size.x / 2
	var act_label: String = ("使う：" + d.name) if d.target == "self" else ("わざ：" + d.name)
	var a := _button(act_label, func():
		if d.target == "self":
			_play(run.me().pos)
		else:
			_mode = "act"
			_update_targets()
			_refresh(), 22, Color(0.8, 0.3, 0.3) if d.kind == "atk" else (Color(0.75, 0.35, 0.6) if d.kind == "mira" else Color(0.2, 0.55, 0.45)))
	a.size = Vector2(w, _mode_box.size.y)
	a.position = Vector2(cx - w - 6, 0)
	_mode_box.add_child(a)
	var s := _button("泳ぐ %dマス" % int(d.mv), func():
		_mode = "swim"
		_update_targets()
		_refresh(), 24, Color(0.1, 0.45, 0.8))
	s.size = Vector2(w, _mode_box.size.y)
	s.position = Vector2(cx + 6, 0)
	_mode_box.add_child(s)
	# 今のモードを金のふちで示す
	var on := s if _mode == "swim" else a
	if not (d.target == "self" and _mode == "act"):
		on.add_theme_stylebox_override("normal", on.get_theme_stylebox("hover"))


func _on_cell(p: Vector2i) -> void:
	if _busy or state != PLAY:
		return
	if _sel >= 0:
		if _targets.has(p):
			_play(p)
			return
		if p == run.me().pos and _mode == "act" and Cards.def(run.hand[_sel]).target == "self":
			_play(p)
			return
	var u = run.unit_at(p)
	if u != null and u.id != 0:
		_show_enemy(u)
		return
	if _sel >= 0:
		_select(-1)


func _show_enemy(u: Dictionary) -> void:
	var d: Dictionary = Tactics.ENEMIES[u.kind]
	var st: String = {"patrol": "見張り中", "alert": "[color=#ff6a6a]追いかけてくる！[/color]", "invest": "音を調べに行く",
		"search": "さがしている", "return": "持ち場に戻る", "sleep": "眠っている（近づくと起きる）"}.get(u.state, "")
	if u.stun > 0:
		st = "気絶中（1回休み）"
	var note: String = {"patrol": "決まった道を行ったり来たり", "sentry": "その場で向きを変える", "fixed": "動かない。前とまわりにかみつく",
		"drift": "目が見えない。ふらふら動いて、となりを刺す",
		"boss": "赤く光るマスに次のターン攻撃。泡のブレスか音波で気絶させると止まる。押し出せない"}[u.move]
	_set_hint("[b]%s[/b]　体力 %d/%d　攻撃 %d　%s\n[color=#9fb4c8]%s[/color]" % [d.name, u.hp, u.max_hp, u.atk, st, note])
	var cells := {}
	for q in run.vision(u):
		cells[q] = Color(1, 0.4, 0.2, 0.55)
	if u.move == "patrol":
		for q in u.route:
			if not cells.has(q):
				cells[q] = Color(1, 1, 1, 0.25)
	world.set_highlight(cells)
	_sel = -1
	_refresh()


func _play(at: Vector2i) -> void:
	var i := _sel
	var as_move := _mode == "swim"
	_sel = -1
	world.set_highlight({})
	var ev := run.play(i, as_move, at)
	_rebuild_hand()
	await _act(ev)
	# もう動けないなら自動でターン終了
	if state == PLAY and not _busy and not _any_playable() and not run.exited:
		await _wait(0.35)
		if state == PLAY and not _busy and not _any_playable():
			_on_end_turn()


func _on_end_turn() -> void:
	if _busy or state != PLAY:
		return
	_select(-1)
	_mini_banner("敵のターン", Color(1, 0.6, 0.45))
	var ev := run.end_turn()
	await _act(ev, 0.14)
	if state == PLAY:
		_rebuild_hand()
		_refresh()


func _act(ev: Array, step: float = 0.16) -> void:
	if ev.is_empty():
		_refresh()
		return
	_busy = true
	_refresh()
	await _run_events(ev, step)
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
	if _sel < 0:
		_set_hint("")
	_quips()


func _quips() -> void:
	if run.air <= 5 and not _said.has("air"):
		_said.air = true
		_say(Scenario.SAY_LOW_AIR)
	elif run.hp <= 4 and not _said.has("hp"):
		_said.hp = true
		_say(Scenario.SAY_LOW_HP)


# ───────── 演出 ─────────

func _unit_screen(id: int, h: float = 1.2) -> Vector2:
	var uv := world.view(id)
	if uv == null:
		return _view() / 2
	return world.screen_at3(uv.position + Vector3(0, h, 0))


func _run_events(ev: Array, step: float) -> void:
	for e in ev:
		if world == null or state != PLAY:
			return
		match e.t:
			"move":
				var tw := world.move_unit(e.id, e.path, 0.09 if e.get("fast", false) else step)
				if e.id == 0:
					Audio.sfx("whoosh" if e.get("fast", false) else "swim", -6.0)
					world.follow(e.path[e.path.size() - 1], step * e.path.size() + 0.2)
				if tw:
					await tw.finished
				world.refresh()
			"face":
				world.refresh()
			"attack":
				var tw := world.lunge(e.id, e.to)
				if e.id != 0:
					Audio.sfx("bite", -4.0)
				if tw:
					await tw.finished
			"hit":
				var uv := world.view(e.id)
				if uv:
					uv.hurt()
					var txt := "-%d" % e.dmg
					if e.sneak:
						txt = "不意打ち！ -%d" % e.dmg
					elif e.wall:
						txt = "ドン！ -%d" % e.dmg
					world.pop_text(uv.position, txt, UiStyle.GOLD if e.sneak else Color(1, 0.9, 0.8), 80 if e.sneak else 64)
				Audio.sfx("hit")
				world.shake(0.6 + e.dmg * 0.15)
				if e.sneak and not _said.has("sneak"):
					_said.sneak = true
					_say(Scenario.SAY_SNEAK)
				await _wait(0.18)
			"push":
				var tw := world.push_unit(e.id, e.to)
				if tw:
					await tw.finished
			"die":
				var uv := world.view(e.id)
				if uv:
					world.burst(uv.position, Color(0.85, 0.95, 1.0, 0.85), 18)
				world.kill_unit(e.id)
				Audio.sfx("pop")
				world.view(0).pose(1, 0.8)
				if randf() < 0.35:
					_say(Scenario.SAY_KILL)
				await _wait(0.25)
			"stun":
				var uv := world.view(e.id)
				if uv:
					world.pop_text(uv.position, "ピヨ…", Color(0.7, 0.85, 1.0), 56)
			"phit":
				var me := world.view(0)
				if e.blocked > 0:
					world.pop_text(me.position + Vector3(0, 0.3, 0), "うろこで防いだ %d" % e.blocked, Color(1, 0.95, 0.4), 52)
					Audio.sfx("block")
				if e.dmg > 0:
					me.hurt()
					world.pop_text(me.position, ("息が…… -%d" if e.air else "-%d") % e.dmg, UiStyle.AIR if e.air else UiStyle.HEART, 80)
					world.shake(1.2 + e.dmg * 0.3)
					Audio.sfx("drown" if e.air else "hurt")
					_hud.queue_redraw()
					if not e.air and not _said.has("hit"):
						_said.hit = true
						_say(Scenario.SAY_HIT)
				await _wait(0.3)
			"spot" when e.get("boss", false) or (run.unit_by_id(e.id) != null and run.unit_by_id(e.id).move == "boss"):
				world.refresh()
				var bv := world.view(e.id)
				if bv:
					bv.pose(3, 1.2)
				Audio.sfx("roar")
				world.shake(2.0)
				_mini_banner("海竜が目をさました！", Color(0.6, 0.9, 1.0))
				_say(Scenario.SAY_BOSS_WAKE)
				await _wait(0.9)
			"warn":
				world.set_danger(e.tiles)
				if e.get("cancel", false):
					var bv := world.view(e.id)
					if bv:
						world.pop_text(bv.position + Vector3(0, 1.2, 0), "攻撃を止めた！", UiStyle.GOLD, 72)
					Audio.sfx("block")
					if not _said.has("cancel"):
						_said.cancel = true
						_say(Scenario.SAY_CANCEL)
				elif not e.tiles.is_empty():
					var bv := world.view(e.id)
					if bv:
						bv.pose(3, 0.8)
						world.pop_text(bv.position + Vector3(0, 1.4, 0), Tactics.BOSS_ATTACKS[e.kind].name + "の構え", Color(1, 0.5, 0.45), 64)
					Audio.sfx("warn")
					if not _said.has("warn"):
						_said.warn = true
						_say(Scenario.SAY_WARN)
					await _wait(0.5)
			"boss_atk":
				var bv := world.view(e.id)
				if bv:
					bv.pose(3, 0.8)
				Audio.sfx("breath" if e.kind == "breath" else ("roar" if e.kind == "tail" else "whoosh"))
				for q in e.tiles:
					world.ring(q, 0.7, Color(0.5, 0.9, 1.0, 0.9) if e.kind != "whirl" else Color(0.3, 0.6, 1.0, 0.9), 0.4)
				world.shake(1.5)
				await _wait(0.4)
			"star":
				Audio.sfx("star")
				world.burst(world.cell3(e.at), Color(1, 0.85, 0.4, 0.95), 40)
				world.shake(1.0)
				await _wait(1.2)
			"spot":
				var uv := world.view(e.id)
				world.refresh()
				if uv:
					uv.pose(3, 0.6)
				Audio.sfx("spot" if not e.get("called", false) else "alert", -2.0 if not e.get("called", false) else -8.0)
				if not e.get("called", false):
					world.shake(0.8)
					_mini_banner("見つかった！", Color(1, 0.35, 0.3))
					world.view(0).pose(2, 1.0)
					if not _said.has("spot"):
						_said.spot = true
						_say(Scenario.SAY_SPOTTED)
					await _wait(0.45)
				else:
					await _wait(0.12)
			"hear":
				world.refresh()
				Audio.sfx("mira_q", -12.0, 0.8)
			"lost", "calm":
				world.refresh()
			"noise":
				world.ring(e.at, 4.0, Color(1, 0.6, 0.85, 0.8), 0.6)
			"call":
				await _mira_fly(e.at)
			"beam":
				var col := Color(0.6, 0.9, 1.0, 0.9) if e.kind == "bubble" else Color(0.95, 0.95, 1.0, 0.9)
				Audio.sfx("bubble" if e.kind == "bubble" else "sonar")
				var tw := world.beam(e.from, e.dir, 9, col)
				await tw.finished
			"whirl":
				Audio.sfx("whoosh")
				world.ring(e.at, 1.6, Color(0.5, 0.85, 1.0, 0.9), 0.4)
				world.view(0).pose(3, 0.6)
				await _wait(0.2)
			"sonar":
				Audio.sfx("sonar")
				world.ring(e.at, e.r + 0.6, Color(0.6, 0.95, 1.0, 0.9), 0.6)
				world.view(0).pose(3, 0.6)
				await _wait(0.3)
			"hide":
				world.refresh()
				Audio.sfx("stash")
				world.pop_text(world.view(0).position, "かくれた", Color(0.5, 1.0, 0.7), 56)
				if not _said.has("hide"):
					_said.hide = true
					_say(Scenario.SAY_HIDE)
			"shield":
				Audio.sfx("zap")
				world.pop_text(world.view(0).position, "雷のうろこ", Color(1, 0.95, 0.4), 56)
				world.view(0).pose(3, 0.6)
			"heal":
				if e.n > 0:
					world.pop_text(world.view(0).position, "体力 +%d" % e.n, Color(0.5, 1, 0.6), 64)
					Audio.sfx("block")
				_hud.queue_redraw()
			"air":
				world.pop_text(world.view(0).position, "空気 +%d" % e.n, UiStyle.AIR, 64)
				Audio.sfx("bubble")
				world.burst(world.view(0).position, Color(0.8, 0.95, 1.0, 0.8), 10)
				_hud.queue_redraw()
			"wing":
				await _mira_fly(run.me().pos, true)
			"draw", "reshuffle":
				pass
			"pickup":
				world.remove_item(e.at)
				Audio.sfx("gem" if e.item == "pearl" else "bubble")
				if e.item == "vent" and not _said.has("vent"):
					_said.vent = true
					_say(Scenario.SAY_VENT)
			"chest":
				world.remove_item(e.at)
				Audio.sfx("gem")
				world.view(0).pose(1, 1.0)
				world.burst(world.cell3(e.at), Color(1, 0.85, 0.4, 0.9), 16)
				if not _said.has("chest"):
					_said.chest = true
					_say(Scenario.SAY_CHEST)
				await _choose_card(run.reward_choices(), "宝箱を開けた！", "カードを1枚えらんで、デッキに入れる")
			"exit":
				pass
			"suffocate":
				pass
			"turn":
				_rebuild_hand()
			"faint":
				pass
		_hud.queue_redraw()
	if world:
		world.refresh()


## ミラが飛んでいって鳴いて、戻ってくる
func _mira_fly(at: Vector2i, stay: bool = false) -> void:
	var m := world.view(-1)
	if m == null:
		return
	var home := m.position
	var tw := m.create_tween()
	if not stay:
		tw.tween_property(m, "position", world.cell3(at) + Vector3(0, 0.3, 0), 0.32).set_trans(Tween.TRANS_SINE)
	else:
		tw.tween_property(m, "position:y", home.y + 0.5, 0.15)
	await tw.finished
	m.pose(3 if not stay else 1, 0.7)
	world.pop_text(m.position + Vector3(0, 0.2, 0), "きゅっ！", UiStyle.PINK, 72)
	_mira_cry("きゅっ！", "point")
	if not stay and not _said.has("call"):
		_said.call = true
		_say(Scenario.SAY_CALL)
	await _wait(0.4)
	var back := m.create_tween()
	back.tween_property(m, "position", home, 0.3).set_trans(Tween.TRANS_SINE)
	await back.finished


## カードを1枚えらぶ（宝箱・空気だまり）。えらばないこともできる
func _choose_card(ids: Array, title: String, sub: String) -> void:
	var v := _view()
	var shade := ColorRect.new()
	shade.color = Color(0, 0.02, 0.06, 0.78)
	shade.size = v
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.z_index = 150
	_ui.add_child(shade)
	_label(title, 46, Vector2(0, v.y * 0.2), shade, UiStyle.GOLD, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	_label(sub, 26, Vector2(0, v.y * 0.2 + 64), shade, Color.WHITE, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	var cw := 190.0 if Screen.portrait else 170.0
	var total := ids.size() * (cw + 20) - 20
	var cy := v.y * 0.2 + 120
	for i in ids.size():
		var id: String = ids[i]
		var cv := CardView.new(id)
		cv.size = Vector2(cw, cw * 1.45)
		cv.position = Vector2(v.x / 2 - total / 2 + i * (cw + 20), cy)
		cv.tapped.connect(func(_c):
			Audio.sfx("get")
			_picked.emit(id))
		shade.add_child(cv)
		var d := Cards.def(id)
		var desc := _label(d.desc, 20, Vector2(cv.position.x - 10, cy + cw * 1.45 + 10), shade, Color(0.9, 0.95, 1.0), cw + 20,
			HORIZONTAL_ALIGNMENT_CENTER)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var skip := _button("いらない", func(): _picked.emit(""), 24, Color(0.35, 0.4, 0.5))
	skip.size = Vector2(220, 60)
	skip.position = Vector2(v.x / 2 - 110, cy + cw * 1.45 + 110)
	shade.add_child(skip)
	var id: String = await _picked
	if id != "":
		run.add_card(id)
	shade.queue_free()


func _say(arr: Array) -> void:
	var trip: Array = Scenario.pick(arr)
	_say_line(trip[0], trip[1], trip[2])


func _say_line(text: String, cry: String, motion: String, delay: float = 0.0) -> void:
	if world == null:
		return
	if delay > 0:
		await _wait(delay)
		if world == null:
			return
	if _speech and is_instance_valid(_speech):
		_speech.queue_free()
	var L := _layout()
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UiStyle.panel(UiStyle.AQUA, Color(0.98, 0.99, 1.0, 0.96), 4, 22))
	var l := Label.new()
	l.text = "カノープス「%s」" % text
	l.add_theme_font_size_override("font_size", 22)
	l.add_theme_color_override("font_color", Color(0.05, 0.1, 0.2))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var maxw: float = minf(_view().x - 60, 560)
	l.custom_minimum_size.x = minf(maxw, 22 * l.text.length() + 10)
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
	if world == null:
		return
	var m := world.view(-1)
	if m == null:
		return
	var f: int = {"hop": 1, "spin": 1, "shake": 2, "droop": 2, "point": 3, "slap": 3}.get(motion, 1)
	m.pose(f, 1.0)
	_float(cry, _unit_screen(-1, 1.4), UiStyle.PINK, 24)
	_mira_cry(cry, motion)


# ───────── 階の終わり ─────────

func _on_exit() -> void:
	_busy = true
	var a := world.view(0)
	Audio.sfx("dive")
	var tw := a.create_tween()
	tw.tween_property(a, "position:y", 2.5, 0.6).set_ease(Tween.EASE_IN)
	var m := world.view(-1)
	var mt := m.create_tween()
	mt.tween_interval(0.15)
	mt.tween_property(m, "position", a.position + Vector3(0, 2.5, 0), 0.6).set_ease(Tween.EASE_IN)
	if run.spotted == 0:
		_mini_banner("見つからずに抜けた！", UiStyle.GOLD)
	await _wait(0.9)
	_busy = false
	best_floor = maxi(best_floor, run.stage)
	_save()
	if run.cleared:
		_on_star()
		return
	_rest_picks = 2 if run.spotted == 0 else 1
	_rest_choices = run.reward_choices(3)
	_show_rest()


func _on_star() -> void:
	clears += 1
	best_floor = Tactics.STAGES
	_save()
	_result = {"kind": "clear"}
	Audio.jingle("surface")
	await _wait(1.0)
	_clear_ui()
	_drop_world()
	_set_bg("ev_clear", 0.0, 0.0)
	_talk(Scenario.CLEAR_TALK, _show_result)


func _on_faint() -> void:
	_busy = true
	Audio.jingle("faint")
	world.view(0).pose(2, 2.0)
	world.view(-1).pose(2, 2.0)
	await _wait(1.2)
	_busy = false
	best_floor = maxi(best_floor, run.stage)
	_save()
	_result = {"kind": "faint"}
	_talk(Scenario.FAINT_TALK, _show_result)


## 空気だまり：体力が少し戻り、カードをもらって次の階へ
func _show_rest() -> void:
	state = REST
	_clear_ui()
	_drop_world()
	_set_bg(BGS[mini(run.stage, 3)], 0.45, 0.6)
	Audio.bgm("rest")
	var full := _view()
	var portrait := Screen.portrait
	var left := Control.new()
	left.size = Vector2(full.x if portrait else full.x * 0.42, full.y)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(left)
	var right := Control.new()
	right.position = Vector2(0 if portrait else full.x * 0.42, 0)
	right.size = Vector2(full.x if portrait else full.x * 0.58, full.y)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(right)
	var v := left.size
	var top := 36.0 if portrait else 70.0
	_label("空気だまり", 54, Vector2(0, top), left, UiStyle.AQUA, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	_label("%d階を抜けた！　体力+4・空気満タンで次へ" % run.stage, 22, Vector2(0, top + 72), left, Color.WHITE, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	_label("体力 %d/%d　デッキ %d枚　倒した敵 %d" % [run.hp, run.max_hp, run.owned.size(), run.kills], 24, Vector2(0, top + 112), left,
		UiStyle.GOLD, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	var mini_y := top + 150
	var c := MiniChar.new("canopus")
	c.size = Vector2(150, 150)
	c.position = Vector2(v.x / 2 - 170, mini_y)
	left.add_child(c)
	var m := MiniChar.new("mira", true)
	m.size = Vector2(115, 115)
	m.position = Vector2(v.x / 2 + 40, mini_y + 35)
	left.add_child(m)
	var trip: Array = Scenario.pick(Scenario.REST_TALKS)
	if run.spotted == 0:
		trip = Scenario.SAY_EXIT_CLEAN[0]
	var say := _label("カノープス「%s」" % trip[0], 22, Vector2(20, mini_y + 156), left, Color.WHITE, v.x - 40, HORIZONTAL_ALIGNMENT_CENTER)
	say.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label("ミラ「%s」" % trip[1], 22, Vector2(0, mini_y + 214), left, UiStyle.PINK, v.x, HORIZONTAL_ALIGNMENT_CENTER)
	c.act(MiniChar.HAPPY, 1.2, true)
	m.act(MiniChar.HAPPY, 1.2, true)
	var cy := mini_y + 262 if portrait else 60.0
	v = right.size
	var head := "カードをあと %d 枚えらべる" % _rest_picks if _rest_picks > 0 else "準備ができたら次の階へ"
	if run.spotted == 0 and _rest_picks > 0:
		head = "見つからずに抜けたボーナス！\nカードを %d 枚えらべる" % _rest_picks
	var hl := _label(head, 26, Vector2(10, cy), right, UiStyle.AQUA, v.x - 20, HORIZONTAL_ALIGNMENT_CENTER)
	hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var cw: float = minf(180.0, (v.x - 80) / 3.0)
	var total := _rest_choices.size() * (cw + 16) - 16
	for i in _rest_choices.size():
		var id: String = _rest_choices[i]
		var cv := CardView.new(id)
		cv.size = Vector2(cw, cw * 1.45)
		cv.position = Vector2(v.x / 2 - total / 2 + i * (cw + 16), cy + 76)
		cv.playable = _rest_picks > 0
		cv.tapped.connect(func(_c):
			if _rest_picks <= 0:
				return
			Audio.sfx("get")
			run.add_card(id)
			_rest_picks -= 1
			_rest_choices.remove_at(i)
			_show_rest())
		right.add_child(cv)
		var d := Cards.def(id)
		var desc := _label(d.desc, 18, Vector2(cv.position.x - 6, cv.position.y + cw * 1.45 + 6), right, Color(0.9, 0.95, 1.0), cw + 12,
			HORIZONTAL_ALIGNMENT_CENTER)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var go := _button("次の階へもぐる", func():
		Audio.sfx("dive")
		_start_stage(run.next_stage()), 30, Color(0.1, 0.5, 0.85))
	go.size = Vector2(320, 80)
	go.position = Vector2(v.x / 2 - 160, cy + 76 + cw * 1.45 + 76)
	right.add_child(go)


func _show_result() -> void:
	state = RESULT
	_clear_ui()
	_drop_world()
	var v := _view()
	var kind: String = _result.get("kind", "faint")
	_set_bg("ev_clear" if kind == "clear" else BGS[run.stage - 1], 0.45 if kind == "clear" else 0.35, 0.3)
	var title: String = {"faint": "ミラに助けられた……", "clear": "星のかけらを見つけた！"}[kind]
	var portrait := Screen.portrait
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
	_label("海竜をたおして星を取りもどした" if kind == "clear" else "%s %d階まで" % [Scenario.ZONES[run.stage - 1][0], run.stage], 34, Vector2(0, y), col, UiStyle.AQUA, cw, HORIZONTAL_ALIGNMENT_CENTER)
	_label("倒した敵 %d　見つかった %d回" % [run.kills, run.spotted_total], 30, Vector2(0, y + 56), col, UiStyle.GOLD, cw, HORIZONTAL_ALIGNMENT_CENTER)
	var sub := "クリア %d回目！" % clears if kind == "clear" else ("今までの最高：%d階" % best_floor)
	_label(sub, 30, Vector2(0, y + 116), col, UiStyle.PINK if kind == "clear" else Color.WHITE, cw, HORIZONTAL_ALIGNMENT_CENTER)
	var bw := 300.0
	var again := _button("もう一度もぐる", _start_run, 32, Color(0.1, 0.5, 0.85))
	again.size = Vector2(bw, 84)
	again.position = Vector2(cw / 2 - bw / 2, y + 196)
	col.add_child(again)
	var back := _button("タイトルへ", _show_title, 26, Color(0.35, 0.4, 0.5))
	back.size = Vector2(bw, 64)
	back.position = Vector2(cw / 2 - bw / 2, y + 296)
	col.add_child(back)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		if e.keycode == KEY_M:
			Audio.toggle_mute()
		if state == PLAY and not _busy:
			match e.keycode:
				KEY_Q:
					world.rotate_view(1)
				KEY_E:
					world.rotate_view(-1)
				KEY_SPACE, KEY_ENTER:
					_on_end_turn()
		if OS.is_debug_build() and state == PLAY and not _busy:
			# デバッグ：F1 出口へ / F3 体力1 / F6 気絶 / F7 クリア / F8 カード3枚引く
			match e.keycode:
				KEY_F1:
					run.exited = true
					run.cleared = run.stage >= Tactics.STAGES
					_on_exit()
				KEY_F3:
					run.hp = 1
					_refresh()
				KEY_F6:
					_on_faint()
				KEY_F7:
					_on_star()
				KEY_F10:
					# ボスの階へ
					run.stage = Tactics.STAGES
					_start_stage(run.start_stage())
				KEY_F9:
					# いちばん出口に近づける泳ぎ方を自動で選ぶ（画面確認用）
					_debug_step()
				KEY_F8:
					run._draw(3, [])
					run.plays_left = Tactics.PLAYS
					_rebuild_hand()
					_refresh()


func _debug_step() -> void:
	var exit := Vector2i.ZERO
	for q in run.items:
		if run.items[q] == "exit":
			exit = q
	var b = run.boss()
	if b != null:
		exit = b.pos
		for i in run.hand.size():
			if run.can_play(i) and Cards.def(run.hand[i]).kind == "atk" and run.targets(i).has(b.pos):
				_sel = i
				_mode = "act"
				_play(b.pos)
				return
	var best := -1
	var at := Vector2i.ZERO
	var bd := 999
	for i in run.hand.size():
		if not run.can_play(i):
			continue
		for q in run.swim_targets(i):
			var d: int = run._path(q, exit, false).size()
			if d < bd:
				bd = d
				best = i
				at = q
	if best >= 0:
		_sel = best
		_mode = "swim"
		_play(at)


# ───────── HUD ─────────

## 上の情報：階・体力・空気・行動回数・山札
class Hud extends Control:
	var game: Node

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var run: Tactics = game.run
		if run == null:
			return
		draw_style_box(UiStyle.panel(Color(0.5, 0.85, 1.0, 0.6), Color(0.02, 0.07, 0.15, 0.85)), Rect2(Vector2.ZERO, size))
		var font := get_theme_default_font()
		var t := Time.get_ticks_msec() / 1000.0
		var z := run.stage - 1
		_text(font, "%s %d階" % [Scenario.ZONES[z][0], run.stage], Vector2(16, 34), 24, UiStyle.GOLD)
		_text(font, "ターン %d" % run.turn, Vector2(140, 34), 20, Color(0.85, 0.92, 1.0))
		# 行動回数
		_text(font, "行動", Vector2(size.x - 196, 34), 22, Color(0.85, 0.92, 1.0))
		for i in Tactics.PLAYS:
			var c := Vector2(size.x - 130 + i * 30, 26)
			if i < run.plays_left:
				draw_circle(c, 11 + sin(t * 5.0) * 1.0, UiStyle.GOLD)
			else:
				draw_arc(c, 10, 0, TAU, 16, Color(UiStyle.GOLD, 0.5), 2.0)
		_text(font, "山%d" % run.deck.size(), Vector2(size.x - 66, 34), 18, Color(0.8, 0.88, 1.0))
		var w: float = size.x - 30
		_bar(font, Vector2(16, 48), w, "体力", run.hp, run.max_hp, UiStyle.HEART if run.hp > 4 else Color(1, 0.3 + 0.2 * sin(t * 8.0), 0.3))
		var air_col := UiStyle.AIR if run.air > 5 else Color(1, 0.5 + 0.3 * sin(t * 8.0), 0.5)
		_bar(font, Vector2(16, 74), w, "空気", run.air, maxi(run.air, Tactics.MAX_AIR), air_col)

	func _bar(font: Font, at: Vector2, w: float, name: String, v: int, mx: int, col: Color) -> void:
		_text(font, name, at + Vector2(0, 18), 20, Color(0.85, 0.92, 1.0))
		var r := Rect2(at + Vector2(56, 2), Vector2(w - 140, 18))
		draw_rect(r, Color(0, 0, 0, 0.5))
		var k: float = clampf(float(v) / maxf(mx, 1), 0.0, 1.0)
		draw_rect(Rect2(r.position, Vector2(r.size.x * k, r.size.y)), col)
		draw_rect(r, Color(1, 1, 1, 0.4), false, 1.5)
		_text(font, "%d / %d" % [v, mx], at + Vector2(w - 76, 18), 20, Color.WHITE)

	func _text(font: Font, s: String, at: Vector2, fs: int, col: Color) -> void:
		draw_string_outline(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, UiStyle.INK)
		draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
