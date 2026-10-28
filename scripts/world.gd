class_name World
extends SubViewportContainer

## 3D の海底マップ（HD-2D 風）。地形は箱の 3D、キャラはドット絵の板（Sprite3D）を立てる。
## マス (x, y) は 3D の (x, 0, y)。床の上面が y=0。
## 操作：タップでマスを選ぶ（cell_tapped）／ドラッグでカメラを動かす／rotate_view で 90° 回す。
##   タップは床のマスを優先する（光っている＝選べるマスなら、キャラや岩の後ろでも選べる）。
##   光っていないマスをキャラの絵の上で押したときだけ、そのキャラのマスにする。
##   マウスでは、指しているマスに枠を出す（岩の陰でも見える）。
## 演出は game.gd から呼ぶ（move_unit などは Tween を返すので await できる）。

signal cell_tapped(p: Vector2i)

const PITCH := deg_to_rad(52.0)
const ROCK_COLORS := [
	[Color(0.55, 0.38, 0.42), Color(0.95, 0.62, 0.62)],   # さんご礁：ピンクがかった岩
	[Color(0.42, 0.45, 0.5), Color(0.7, 0.74, 0.72)],     # 遺跡：灰色の石
	[Color(0.18, 0.2, 0.3), Color(0.35, 0.4, 0.6)],       # 深海：黒い岩
	[Color(0.2, 0.16, 0.32), Color(0.45, 0.38, 0.7)],     # 最深部：星明かりの紫
]
const SAND_COLORS := [
	[Color(0.78, 0.7, 0.54), Color(0.72, 0.64, 0.49)],
	[Color(0.6, 0.62, 0.6), Color(0.55, 0.57, 0.56)],
	[Color(0.3, 0.33, 0.45), Color(0.27, 0.3, 0.42)],
	[Color(0.33, 0.3, 0.48), Color(0.29, 0.26, 0.44)],
]
const FOG := [Color(0.1, 0.45, 0.62), Color(0.05, 0.22, 0.38), Color(0.02, 0.06, 0.16), Color(0.05, 0.03, 0.14)]

var t: Tactics
var zone := 0
var yaw := 0.0
var focus := Vector3.ZERO
var dist := 13.0
var top_margin := 0.0      # 画面の上と下で UI に隠れる高さ（px）。カメラの中心をずらす
var bottom_margin := 0.0

var _vp: SubViewport
var _root: Node3D
var _map: Node3D
var _cam: Camera3D
var _units := {}           # id -> UnitView
var _items := {}           # Vector2i -> Node3D
var _cone_mesh: MeshInstance3D
var _hi_mesh: MeshInstance3D
var _hi_mat: StandardMaterial3D
var _sel_mesh: MeshInstance3D
var _danger_mesh: MeshInstance3D
var _danger_mat: StandardMaterial3D
var _hover_mesh: MeshInstance3D
var _hover := Vector2i(-1, -1)
var _pickable := {}        # 光っているマス（タップで優先する）
var _mouse := Vector2(-1, -1)
var _rocks := []           # [{mi, corners, center, deco, faded}] カメラとキャラの間に入ったら半透明にする
var _rock_mat: ShaderMaterial
var _rock_fade: ShaderMaterial
var _press := Vector2.ZERO
var _pressing := false
var _dragged := false
var _focus_tw: Tween
var _yaw_tw: Tween
var _shake := 0.0
var _time := 0.0

static var _font: Font
static var _shaders := {}


func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_2X
	_vp.handle_input_locally = false
	add_child(_vp)
	_root = Node3D.new()
	_vp.add_child(_root)
	_cam = Camera3D.new()
	_cam.fov = 38.0
	_root.add_child(_cam)
	if _font == null:
		_font = load("res://assets/fonts/MPLUSRounded1c-Bold.ttf")


func setup(tac: Tactics, z: int) -> void:
	t = tac
	zone = z
	if _map:
		_map.queue_free()
	_units.clear()
	_items.clear()
	_rocks.clear()
	_map = Node3D.new()
	_root.add_child(_map)
	_build_env()
	_build_terrain()
	for u in t.units:
		_add_unit(u)
	# ミラ（盤の上のユニットではない。カノープスの後ろをついてくる）
	var mira := UnitView.new("mira", 1.05, false)
	mira.position = _cell3(t.me().pos) + Vector3(-0.45, 0, -0.35)
	mira.fly = 0.35
	_map.add_child(mira)
	_units[-1] = mira
	for p in t.items:
		_add_item(p, t.items[p])
	_cone_mesh = MeshInstance3D.new()
	_cone_mesh.material_override = _overlay_mat()
	_map.add_child(_cone_mesh)
	_hi_mesh = MeshInstance3D.new()
	_hi_mat = _overlay_mat()
	_hi_mesh.material_override = _hi_mat
	_map.add_child(_hi_mesh)
	_sel_mesh = MeshInstance3D.new()
	_sel_mesh.material_override = _overlay_mat()
	_map.add_child(_sel_mesh)
	_danger_mesh = MeshInstance3D.new()
	_danger_mat = _overlay_mat()
	_danger_mesh.material_override = _danger_mat
	_map.add_child(_danger_mesh)
	_hover_mesh = MeshInstance3D.new()
	var hm := _overlay_mat()
	hm.no_depth_test = true
	hm.render_priority = 3
	_hover_mesh.material_override = hm
	_map.add_child(_hover_mesh)
	_hover = Vector2i(-1, -1)
	_pickable = {}
	yaw = 0.0
	focus = _cell3(t.me().pos) + Vector3(0, 0, 2.5)
	_clamp_focus()
	refresh()


func _process(delta: float) -> void:
	_time += delta
	_shake = maxf(_shake - delta * 3.0, 0.0)
	if _hi_mat:
		_hi_mat.albedo_color = Color(1, 1, 1, 0.75 + 0.25 * sin(_time * 5.0))
	if _danger_mat:
		_danger_mat.albedo_color = Color(1, 1, 1, 0.55 + 0.45 * absf(sin(_time * 6.0)))
	_place_camera()
	_fade_rocks()
	# ドット絵の向き：画面の右を向いているか
	var right := _cam.global_transform.basis.x
	for id in _units:
		var uv: UnitView = _units[id]
		if uv.facing != Vector2i.ZERO:
			var d := Vector3(uv.facing.x, 0, uv.facing.y)
			var r := d.dot(right)
			if absf(r) > 0.1:
				uv.face_right(r > 0)


func _place_camera() -> void:
	if t == null:
		return
	var off := Basis(Vector3.UP, yaw) * Vector3(0, sin(PITCH), -cos(PITCH)) * dist
	var sh := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * _shake * 0.12
	_cam.position = focus + off
	_cam.look_at(focus, Vector3.UP)
	_cam.position += _cam.basis * sh
	# 縦長の画面では横幅に合わせる
	_cam.keep_aspect = Camera3D.KEEP_WIDTH if size.y > size.x else Camera3D.KEEP_HEIGHT
	# UI に隠れる分だけ、絵の中心をずらす
	var h := maxf(size.y, 1.0)
	var span := 2.0 * dist * tan(deg_to_rad(_cam.fov) / 2.0)
	if _cam.keep_aspect == Camera3D.KEEP_WIDTH:
		span *= h / maxf(size.x, 1.0)
	_cam.v_offset = (bottom_margin - top_margin) / 2.0 / h * span


func _build_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = FOG[zone]
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = [Color(0.55, 0.75, 0.85), Color(0.45, 0.55, 0.7), Color(0.35, 0.4, 0.65), Color(0.5, 0.42, 0.75)][zone]
	env.ambient_light_energy = [0.75, 0.65, 0.6, 0.65][zone]
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = FOG[zone]
	env.fog_depth_begin = 12.0
	env.fog_depth_end = 34.0
	env.fog_density = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	_map.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-60), deg_to_rad(30), 0)
	sun.light_color = [Color(1.0, 0.97, 0.88), Color(0.8, 0.9, 1.0), Color(0.6, 0.7, 1.0), Color(1.0, 0.85, 0.6)][zone]
	sun.light_energy = [1.0, 0.75, 0.5, 0.55][zone]
	_map.add_child(sun)


func _build_terrain() -> void:
	var W := Tactics.W
	var H := Tactics.H
	# 砂の床（1枚の板。シェーダーで市松の濃淡と、光のゆらぎ）
	var floor_mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(W, 0.6, H)
	floor_mi.mesh = bm
	floor_mi.position = Vector3((W - 1) / 2.0, -0.3, (H - 1) / 2.0)
	var fm := ShaderMaterial.new()
	fm.shader = _shader("floor")
	fm.set_shader_parameter("col_a", SAND_COLORS[zone][0])
	fm.set_shader_parameter("col_b", SAND_COLORS[zone][1])
	fm.set_shader_parameter("caustic", [0.28, 0.18, 0.08, 0.12][zone])
	floor_mi.material_override = fm
	_map.add_child(floor_mi)
	# まわりの海底（暗くして霧に溶かす）
	var bed := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80, 80)
	bed.mesh = pm
	bed.position = Vector3((W - 1) / 2.0, -0.62, (H - 1) / 2.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = SAND_COLORS[zone][1].darkened(0.55)
	bed.material_override = bmat
	_map.add_child(bed)
	# 岩と海藻
	var rng := RandomNumberGenerator.new()
	rng.seed = t.stage * 977 + t.turn
	var rmat := ShaderMaterial.new()
	rmat.shader = _shader("rock")
	rmat.set_shader_parameter("side_col", ROCK_COLORS[zone][0])
	rmat.set_shader_parameter("top_col", ROCK_COLORS[zone][1])
	_rock_mat = rmat
	_rock_fade = ShaderMaterial.new()
	_rock_fade.shader = _shader("rock_fade")
	_rock_fade.set_shader_parameter("side_col", ROCK_COLORS[zone][0])
	_rock_fade.set_shader_parameter("top_col", ROCK_COLORS[zone][1])
	var wmat := ShaderMaterial.new()
	wmat.shader = _shader("weed")
	wmat.set_shader_parameter("col", [Color(0.25, 0.75, 0.35), Color(0.3, 0.6, 0.4), Color(0.3, 0.45, 0.7), Color(0.55, 0.4, 0.8)][zone])
	var coral: Texture2D = load("res://assets/images/obj/coral.png")
	for p in t.all_cells():
		var c := _cell3(p)
		match t.tile(p):
			Tactics.ROCK:
				var h := rng.randf_range(0.8, 1.5) if zone != 1 else rng.randf_range(1.0, 1.3)
				var rm := MeshInstance3D.new()
				var b := BoxMesh.new()
				var sz := 0.98 if zone == 1 else rng.randf_range(0.86, 0.98)
				b.size = Vector3(sz, h, sz)
				rm.mesh = b
				rm.position = c + Vector3(0, h / 2.0, 0)
				if zone != 1:
					rm.rotation.y = rng.randf_range(-0.12, 0.12)
				rm.material_override = rmat
				_map.add_child(rm)
				var deco: Node3D = null
				# 浅瀬の岩にはさんごを生やす
				if zone == 0 and rng.randf() < 0.45 and coral:
					var s := _billboard(coral, 0.55)
					s.position = c + Vector3(rng.randf_range(-0.2, 0.2), h, rng.randf_range(-0.2, 0.2))
					_map.add_child(s)
					deco = s
				var corners := PackedVector3Array()
				for cx in [-0.5, 0.5]:
					for cy in [0.0, h]:
						for cz in [-0.5, 0.5]:
							corners.append(c + Vector3(cx, cy, cz))
				_rocks.append({"mi": rm, "corners": corners, "center": c + Vector3(0, h / 2.0, 0), "deco": deco, "faded": false})
			Tactics.WEED:
				for k in 5:
					var blade := MeshInstance3D.new()
					var q := QuadMesh.new()
					var bh := rng.randf_range(0.7, 1.15)
					q.size = Vector2(0.22, bh)
					blade.mesh = q
					blade.material_override = wmat
					blade.position = c + Vector3(rng.randf_range(-0.34, 0.34), bh / 2.0, rng.randf_range(-0.34, 0.34))
					blade.rotation.y = rng.randf() * PI
					_map.add_child(blade)
	# 最深部：海竜が抱いていた星の光
	if t.is_boss_stage():
		var b = t.boss()
		if b != null:
			var star := _label3d("★", 220, Color(1, 0.85, 0.35))
			star.position = _cell3(b.pos) + Vector3(0, 0.6, 0.9)
			star.no_depth_test = false
			_map.add_child(star)
			var tw := star.create_tween().set_loops()
			tw.tween_property(star, "modulate", Color(1, 0.95, 0.6), 0.8).set_trans(Tween.TRANS_SINE)
			tw.tween_property(star, "modulate", Color(1, 0.75, 0.25), 0.8).set_trans(Tween.TRANS_SINE)
			var col := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.6
			cm.bottom_radius = 0.6
			cm.height = 4.0
			cm.cap_top = false
			cm.cap_bottom = false
			col.mesh = cm
			col.position = star.position + Vector3(0, 1.4, 0)
			var pm2 := ShaderMaterial.new()
			pm2.shader = _shader("pillar")
			col.material_override = pm2
			_map.add_child(col)
	# 光の筋（上から差しこむ半透明の板）
	if zone < 2:
		var lmat := ShaderMaterial.new()
		lmat.shader = _shader("ray")
		lmat.set_shader_parameter("strength", [0.12, 0.07][zone])
		for k in 4:
			var ray := MeshInstance3D.new()
			var q := QuadMesh.new()
			q.size = Vector2(rng.randf_range(0.8, 1.8), 12)
			ray.mesh = q
			ray.material_override = lmat
			ray.position = Vector3(rng.randf_range(0, W), 5.0, rng.randf_range(0, H))
			ray.rotation = Vector3(0, rng.randf() * PI, deg_to_rad(18))
			_map.add_child(ray)


func _add_item(p: Vector2i, kind: String) -> void:
	var n := Node3D.new()
	n.position = _cell3(p)
	_map.add_child(n)
	_items[p] = n
	var tex: Texture2D = load("res://assets/images/obj/%s.png" % ("chest" if kind == "gchest" else kind))
	var sz: float = {"chest": 0.75, "gchest": 0.85, "pearl": 0.45, "vent": 0.7, "exit": 0.9, "coin": 0.5}.get(kind, 0.6)
	if kind == "exit":
		# 出口：光の柱
		var col := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.42
		cm.bottom_radius = 0.42
		cm.height = 3.0
		cm.cap_top = false
		cm.cap_bottom = false
		col.mesh = cm
		col.position.y = 1.5
		var m := ShaderMaterial.new()
		m.shader = _shader("pillar")
		col.material_override = m
		n.add_child(col)
		var lbl := _label3d("出口", 64, UiStyle.GOLD)
		lbl.position.y = 1.5
		n.add_child(lbl)
		return
	if tex:
		var s := _billboard(tex, sz)
		s.position.y = 0.04 if kind != "pearl" else 0.15
		n.add_child(s)
		if kind == "gchest":
			# 金の宝箱：金色に光る
			s.modulate = Color(1.0, 0.85, 0.35)
			var star := _label3d("★", 90, UiStyle.GOLD)
			star.position.y = 1.1
			n.add_child(star)
		if kind in ["pearl", "chest", "gchest", "coin"]:
			var tw := s.create_tween().set_loops()
			tw.tween_property(s, "position:y", s.position.y + 0.12, 0.9).set_trans(Tween.TRANS_SINE)
			tw.tween_property(s, "position:y", s.position.y, 0.9).set_trans(Tween.TRANS_SINE)


func remove_item(p: Vector2i) -> void:
	if _items.has(p):
		var n: Node3D = _items[p]
		_items.erase(p)
		var tw := n.create_tween()
		tw.tween_property(n, "scale", Vector3(1.4, 1.4, 1.4), 0.12)
		tw.tween_property(n, "scale", Vector3(0.01, 0.01, 0.01), 0.2)
		tw.tween_callback(n.queue_free)


func add_unit(u: Dictionary) -> UnitView:
	return _add_unit(u)


func _add_unit(u: Dictionary) -> UnitView:
	var kind: String = u.kind
	var sz: float = {"canopus": 1.45, "same": 1.7, "ankou": 1.4, "kani": 1.35, "kurage": 1.1, "utsubo": 1.35, "ryu": 2.8,
		"ika": 1.35, "tako": 1.2, "ei": 1.6, "uni": 1.0}.get(kind, 1.2)
	if u.get("elite", false):
		sz *= 1.25
	var uv := UnitView.new(kind, sz, u.id != 0)
	uv.elite = u.get("elite", false)
	uv.position = _cell3(u.pos)
	uv.facing = u.dir
	_map.add_child(uv)
	_units[u.id] = uv
	return uv


func view(id: int) -> UnitView:
	return _units.get(id)


## 敵の頭の上の表示（体力・状態）と、視界の扇を描き直す
func refresh() -> void:
	if t == null:
		return
	for u in t.enemies():
		var uv: UnitView = _units.get(u.id)
		if uv == null:
			continue
		uv.set_info(u.hp, u.max_hp, u.state, u.stun)
		uv.facing = u.dir
	var me: UnitView = _units.get(0)
	if me:
		me.facing = t.me().dir
		me.hidden_look = t.hidden or t.tile(t.me().pos) == Tactics.WEED
	var quads := []
	for u in t.enemies():
		if u.stun > 0:
			continue
		var col := Color(1.0, 0.15, 0.1, 0.62) if u.state == "alert" else Color(1.0, 0.45, 0.0, 0.5)
		for p in t.vision(u):
			quads.append([p, col])
	_cone_mesh.mesh = _quads(quads, 0.015, 0.02)


## 海竜の攻撃が来るマス（赤く点滅）
func set_danger(cells: Array) -> void:
	var quads := []
	for p in cells:
		quads.append([p, Color(1.0, 0.05, 0.1, 0.7)])
	_danger_mesh.mesh = _quads(quads, 0.06, 0.03)


## カメラとキャラの間にある岩を半透明にする（キャラが隠れないように）
func _fade_rocks() -> void:
	if _rocks.is_empty() or t == null:
		return
	var targets := []
	for id in _units:
		if id < 0:
			continue
		var uv: UnitView = _units[id]
		if not is_instance_valid(uv):
			continue
		var foot := _cam.unproject_position(uv.position)
		var head := _cam.unproject_position(uv.position + Vector3(0, uv.height, 0))
		var w := absf(foot.y - head.y) * 0.3
		var depth := (uv.position - _cam.global_position).dot(-_cam.global_transform.basis.z)
		targets.append([Rect2(foot.x - w, head.y, w * 2, foot.y - head.y), depth])
	# マウスで指しているマスも見えるように
	if t.inside(_hover):
		var c := _cell3(_hover)
		var a := _cam.unproject_position(c + Vector3(-0.5, 0, -0.5))
		var r2 := Rect2(a, Vector2.ZERO)
		for v in [Vector3(0.5, 0, -0.5), Vector3(0.5, 0, 0.5), Vector3(-0.5, 0, 0.5)]:
			r2 = r2.expand(_cam.unproject_position(c + v))
		targets.append([r2, (c - _cam.global_position).dot(-_cam.global_transform.basis.z)])
	for r in _rocks:
		var rect := Rect2()
		var first := true
		for v in r.corners:
			var sp := _cam.unproject_position(v)
			if first:
				rect = Rect2(sp, Vector2.ZERO)
				first = false
			else:
				rect = rect.expand(sp)
		var rd: float = (r.center - _cam.global_position).dot(-_cam.global_transform.basis.z)
		var fade := false
		for tg in targets:
			if rd < tg[1] - 0.2 and rect.intersects(tg[0]):
				fade = true
				break
		if fade != r.faded:
			r.faded = fade
			var mi: MeshInstance3D = r.mi
			mi.material_override = _rock_fade if fade else _rock_mat
			if r.deco != null:
				(r.deco as Node3D).visible = not fade


## 泡のカーテン：その場に海藻のしげみを生やす
func add_weed(p: Vector2i) -> void:
	var wmat := ShaderMaterial.new()
	wmat.shader = _shader("weed")
	wmat.set_shader_parameter("col", [Color(0.25, 0.75, 0.35), Color(0.3, 0.6, 0.4), Color(0.3, 0.45, 0.7), Color(0.55, 0.4, 0.8)][zone])
	var c := _cell3(p)
	for k in 5:
		var blade := MeshInstance3D.new()
		var q := QuadMesh.new()
		var bh := randf_range(0.7, 1.15)
		q.size = Vector2(0.22, bh)
		blade.mesh = q
		blade.material_override = wmat
		blade.position = c + Vector3(randf_range(-0.34, 0.34), bh / 2.0, randf_range(-0.34, 0.34))
		blade.rotation.y = randf() * PI
		blade.scale = Vector3(1, 0.01, 1)
		_map.add_child(blade)
		var tw := blade.create_tween()
		tw.tween_interval(k * 0.05)
		tw.tween_property(blade, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## 選べるマスを光らせる。cells: {マス: 色}
func set_highlight(cells: Dictionary) -> void:
	_pickable = cells
	if _mouse.x >= 0:
		_hover = Vector2i(-9, -9)
		_set_hover(cell_at(_mouse))
	var quads := []
	for p in cells:
		quads.append([p, cells[p]])
	_hi_mesh.mesh = _quads(quads, 0.03, 0.06)


func set_selected(cells: Array, col: Color) -> void:
	var quads := []
	for p in cells:
		quads.append([p, col])
	_sel_mesh.mesh = _quads(quads, 0.045, 0.16)


## マウスで指しているマスの枠
func _set_hover(p: Vector2i) -> void:
	if p == _hover:
		return
	_hover = p
	if not t.inside(p):
		_hover_mesh.mesh = null
		return
	var col := Color(1, 0.95, 0.5, 0.95) if _pickable.has(p) else Color(1, 1, 1, 0.55)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := _cell3(p) + Vector3(0, 0.05, 0)
	var o := 0.48
	var i := 0.38
	var outer := [Vector3(-o, 0, -o), Vector3(o, 0, -o), Vector3(o, 0, o), Vector3(-o, 0, o)]
	var inner := [Vector3(-i, 0, -i), Vector3(i, 0, -i), Vector3(i, 0, i), Vector3(-i, 0, i)]
	for k in 4:
		var n := (k + 1) % 4
		for v in [outer[k], outer[n], inner[n], outer[k], inner[n], inner[k]]:
			st.set_color(col)
			st.add_vertex(c + v)
	_hover_mesh.mesh = st.commit()


func _quads(list: Array, y: float, inset: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for q in list:
		var p: Vector2i = q[0]
		var col: Color = q[1]
		var c := _cell3(p) + Vector3(0, y, 0)
		var h := 0.5 - inset
		var v := [c + Vector3(-h, 0, -h), c + Vector3(h, 0, -h), c + Vector3(h, 0, h), c + Vector3(-h, 0, h)]
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_color(col)
			st.add_vertex(v[i])
		any = true
	if not any:
		return null
	return st.commit()


func _overlay_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	m.render_priority = 1
	return m


# ───────── カメラ ─────────

func rotate_view(step: int) -> void:
	if _yaw_tw:
		_yaw_tw.kill()
	var goal := snappedf(yaw, PI / 2) + step * PI / 2
	_yaw_tw = create_tween()
	_yaw_tw.tween_property(self, "yaw", goal, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func follow(p: Vector2i, sec: float = 0.4) -> void:
	var goal := _clamped(_cell3(p))
	if _focus_tw:
		_focus_tw.kill()
	_focus_tw = create_tween()
	_focus_tw.tween_property(self, "focus", goal, sec).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func shake(power: float = 1.0) -> void:
	_shake = maxf(_shake, power)


func _clamped(v: Vector3) -> Vector3:
	return Vector3(clampf(v.x, 1.0, Tactics.W - 2.0), 0, clampf(v.z, 2.0, Tactics.H - 3.0))


func _clamp_focus() -> void:
	focus = _clamped(focus)


## 画面の点 → マス。床のマスを優先し、光っていないマスをキャラの絵の上で押したときだけ、そのキャラのマス
func cell_at(screen: Vector2) -> Vector2i:
	var ground := _ground_cell(screen)
	if _pickable.has(ground):
		return ground
	var sprite := _sprite_cell(screen)
	return sprite if t.inside(sprite) else ground


func _ground_cell(screen: Vector2) -> Vector2i:
	var o := _cam.project_ray_origin(screen)
	var d := _cam.project_ray_normal(screen)
	if absf(d.y) < 0.001:
		return Vector2i(-1, -1)
	var k := -o.y / d.y
	var hit := o + d * k
	return Vector2i(roundi(hit.x), roundi(hit.z))


func _sprite_cell(screen: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := 1e9
	for id in _units:
		if id < 0 or t.unit_by_id(id) == null:
			continue
		var uv: UnitView = _units[id]
		var foot := _cam.unproject_position(uv.position)
		var head := _cam.unproject_position(uv.position + Vector3(0, uv.height, 0))
		var w := absf(foot.y - head.y) * 0.4
		if screen.x > foot.x - w and screen.x < foot.x + w and screen.y < foot.y + w * 0.3 and screen.y > head.y:
			var d := _cam.global_position.distance_to(uv.position)
			if d < best_d:
				best_d = d
				best = t.unit_by_id(id).pos
	return best


## マス → 画面の点（UI の吹き出しなど）
func screen_at(p: Vector2i, height: float = 0.0) -> Vector2:
	return _cam.unproject_position(_cell3(p) + Vector3(0, height, 0))


func screen_at3(v: Vector3) -> Vector2:
	return _cam.unproject_position(v)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press = mb.position
				_pressing = true
				_dragged = false
			else:
				if _pressing and not _dragged:
					var c := cell_at(mb.position)
					if t and t.inside(c):
						cell_tapped.emit(c)
				_pressing = false
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = clampf(dist - 0.8, 8.0, 18.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = clampf(dist + 0.8, 8.0, 18.0)
	elif e is InputEventMouseMotion and not _pressing:
		_mouse = (e as InputEventMouseMotion).position
		if t:
			_set_hover(cell_at(_mouse))
	elif e is InputEventMouseMotion and _pressing:
		var mm := e as InputEventMouseMotion
		if not _dragged and mm.position.distance_to(_press) > 18.0:
			_dragged = true
			if _focus_tw:
				_focus_tw.kill()
		if _dragged:
			# 画面のドラッグを床の上の動きに直す
			var k := dist * 0.0022
			var right := _cam.global_transform.basis.x
			var fwd := Vector3(-right.z, 0, right.x)
			focus -= right * mm.relative.x * k
			focus += fwd * mm.relative.y * k * 1.4
			_clamp_focus()
	elif e is InputEventMagnifyGesture:
		dist = clampf(dist / (e as InputEventMagnifyGesture).factor, 8.0, 18.0)


# ───────── 演出 ─────────

func _cell3(p: Vector2i) -> Vector3:
	return Vector3(p.x, 0, p.y)


func cell3(p: Vector2i) -> Vector3:
	return _cell3(p)


## ユニットを道に沿って動かす。Tween を返す
func move_unit(id: int, path: Array, step_sec: float = 0.16) -> Tween:
	var uv: UnitView = _units.get(id)
	if uv == null or path.is_empty():
		return null
	var tw := uv.create_tween()
	var prev := uv.position
	for p in path:
		var to := _cell3(p)
		var d := to - prev
		tw.tween_callback(func(): uv.facing = Vector2i(roundi(d.x), roundi(d.z)))
		tw.tween_property(uv, "position", to, step_sec).set_trans(Tween.TRANS_SINE)
		prev = to
	if id == 0:
		# ミラがついてくる
		var mira: UnitView = _units.get(-1)
		var last: Vector2i = path[path.size() - 1]
		var behind: Vector3 = _cell3(path[path.size() - 2]) if path.size() > 1 else uv.position
		var goal := behind.lerp(_cell3(last), 0.2) + Vector3(0.45, 0, -0.45)
		var mt := mira.create_tween()
		mt.tween_interval(step_sec * 0.6)
		mt.tween_callback(func():
			var dd := goal - mira.position
			mira.facing = Vector2i(signi(roundi(dd.x)), signi(roundi(dd.z))))
		mt.tween_property(mira, "position", goal, step_sec * path.size()).set_trans(Tween.TRANS_SINE)
	return tw


func lunge(id: int, to: Vector2i) -> Tween:
	var uv: UnitView = _units.get(id)
	if uv == null:
		return null
	var base := uv.position
	var dir := (_cell3(to) - base)
	uv.facing = Vector2i(roundi(signf(dir.x)), roundi(signf(dir.z)))
	var tw := uv.create_tween()
	tw.tween_property(uv, "position", base + dir * 0.45, 0.08).set_ease(Tween.EASE_IN)
	tw.tween_property(uv, "position", base, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	uv.pose(3, 0.5)
	return tw


func push_unit(id: int, to: Vector2i) -> Tween:
	var uv: UnitView = _units.get(id)
	if uv == null:
		return null
	var tw := uv.create_tween()
	tw.tween_property(uv, "position", _cell3(to), 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	return tw


func kill_unit(id: int) -> void:
	var uv: UnitView = _units.get(id)
	if uv == null:
		return
	_units.erase(id)
	uv.die()


## 3D の上に浮かぶ文字（ダメージなど）
func pop_text(p: Vector3, text: String, col: Color, size: int = 72) -> void:
	var l := _label3d(text, size, col)
	l.position = p + Vector3(0, 1.3, 0)
	_map.add_child(l)
	l.scale = Vector3(0.4, 0.4, 0.4)
	var tw := l.create_tween()
	tw.tween_property(l, "scale", Vector3.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(l, "position:y", l.position.y + 0.7, 0.8)
	tw.tween_property(l, "modulate:a", 0.0, 0.25)
	tw.tween_callback(l.queue_free)


## 広がる輪（音波・鳴き声・渦）
func ring(p: Vector2i, radius: float, col: Color, sec: float = 0.5) -> void:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.85
	tm.outer_radius = 1.0
	mi.mesh = tm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = col
	m.render_priority = 2
	mi.material_override = m
	mi.position = _cell3(p) + Vector3(0, 0.3, 0)
	mi.scale = Vector3(0.2, 0.2, 0.2)
	_map.add_child(mi)
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3(radius, 0.3, radius), sec).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(m, "albedo_color:a", 0.0, sec)
	tw.tween_callback(mi.queue_free)


## まっすぐ飛ぶ泡・群れ
func beam(from: Vector2i, dir: Vector2i, n: int, col: Color) -> Tween:
	var tw := create_tween()
	for k in range(1, n + 1):
		var p := from + dir * k
		if not t.walkable_tile(p):
			break
		tw.tween_callback(func(): ring(p, 0.5, col, 0.3))
		tw.tween_interval(0.04)
	return tw


## 泡のつぶ（敵がやられたとき・空気をとったとき）
func burst(p: Vector3, col: Color, count: int = 14) -> void:
	var pt := CPUParticles3D.new()
	pt.one_shot = true
	pt.emitting = true
	pt.amount = count
	pt.lifetime = 0.8
	pt.explosiveness = 0.9
	pt.direction = Vector3.UP
	pt.spread = 70.0
	pt.initial_velocity_min = 1.5
	pt.initial_velocity_max = 3.0
	pt.gravity = Vector3(0, 1.5, 0)
	pt.scale_amount_min = 0.6
	pt.scale_amount_max = 1.2
	var sm := SphereMesh.new()
	sm.radius = 0.07
	sm.height = 0.14
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.material = m
	pt.mesh = sm
	pt.position = p + Vector3(0, 0.6, 0)
	_map.add_child(pt)
	get_tree().create_timer(1.5).timeout.connect(pt.queue_free)


func _billboard(tex: Texture2D, height: float) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = tex
	s.pixel_size = height / tex.get_height()
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	s.shaded = false
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	s.centered = true
	s.offset = Vector2(0, tex.get_height() / 2.0)
	return s


static func _label3d(text: String, size: int, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = _font
	l.font_size = size
	l.outline_size = 18
	l.modulate = col
	l.outline_modulate = Color(0.02, 0.05, 0.1, 0.95)
	l.pixel_size = 0.006
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.render_priority = 5
	l.outline_render_priority = 4
	return l


static func _shader(name: String) -> Shader:
	if _shaders.has(name):
		return _shaders[name]
	var s := Shader.new()
	match name:
		"floor":
			s.code = """
shader_type spatial;
uniform vec3 col_a : source_color;
uniform vec3 col_b : source_color;
uniform float caustic = 0.4;
varying vec3 wpos;
varying vec3 wnrm;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}
void fragment() {
	vec2 c = floor(wpos.xz + 0.5);
	float chk = mod(c.x + c.y, 2.0);
	vec3 col = mix(col_a, col_b, chk);
	vec2 g = abs(fract(wpos.xz + 0.5) - 0.5);
	float edge = smoothstep(0.455, 0.5, max(g.x, g.y));
	col *= 1.0 - edge * 0.22;
	vec2 p = wpos.xz * 1.4;
	float t = TIME * 0.7;
	float k = sin(p.x * 2.1 + t) + sin(p.y * 2.6 - t * 1.3) + sin((p.x + p.y) * 1.6 + t * 0.8);
	k = pow(abs(sin(k * 1.3)), 8.0);
	col += vec3(0.6, 0.9, 1.0) * k * caustic * step(0.5, wnrm.y);
	ALBEDO = col;
	ROUGHNESS = 1.0;
}
"""
		"rock":
			s.code = """
shader_type spatial;
uniform vec3 side_col : source_color;
uniform vec3 top_col : source_color;
varying vec3 wpos;
varying vec3 wnrm;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}
void fragment() {
	float top = smoothstep(0.5, 0.9, wnrm.y);
	float n = fract(sin(dot(floor(wpos * 6.0), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	vec3 col = mix(side_col, top_col, top) * (0.9 + n * 0.14);
	col *= mix(0.7, 1.0, clamp(wpos.y * 0.9 + 0.2, 0.0, 1.0));
	ALBEDO = col;
	ROUGHNESS = 0.95;
}
"""
		"rock_fade":
			s.code = """
shader_type spatial;
render_mode depth_draw_never, cull_back;
uniform vec3 side_col : source_color;
uniform vec3 top_col : source_color;
varying vec3 wnrm;
void vertex() {
	wnrm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}
void fragment() {
	float top = smoothstep(0.5, 0.9, wnrm.y);
	ALBEDO = mix(side_col, top_col, top);
	ALPHA = 0.28;
	ROUGHNESS = 0.95;
}
"""
		"weed":
			s.code = """
shader_type spatial;
render_mode cull_disabled;
uniform vec3 col : source_color;
void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float up = UV.y;
	float bend = (1.0 - up) * (1.0 - up);
	VERTEX.x += sin(TIME * 1.8 + w.x * 1.7 + w.z * 1.3) * 0.16 * bend;
	VERTEX.z += cos(TIME * 1.4 + w.z * 2.1) * 0.08 * bend;
}
void fragment() {
	float half_w = 0.5 * (0.35 + 0.65 * UV.y);
	if (abs(UV.x - 0.5) > half_w * 0.9) { discard; }
	ALBEDO = mix(col * 1.35, col * 0.45, UV.y);
	ROUGHNESS = 0.8;
}
"""
		"ray":
			s.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;
uniform float strength = 0.2;
void fragment() {
	float edge = 1.0 - abs(UV.x - 0.5) * 2.0;
	float fade = smoothstep(1.0, 0.3, UV.y) * smoothstep(0.0, 0.3, UV.y);
	float flick = 0.75 + 0.25 * sin(TIME * 0.8 + UV.y * 3.0);
	ALBEDO = vec3(0.6, 0.9, 1.0) * edge * edge * fade * strength * flick;
}
"""
		"pillar":
			s.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;
void fragment() {
	float fade = pow(1.0 - UV.y, 0.5) * (1.0 - pow(1.0 - UV.y, 6.0));
	fade = UV.y;
	float a = (1.0 - fade) * (0.55 + 0.25 * sin(TIME * 3.0 - fade * 8.0));
	ALBEDO = vec3(1.0, 0.82, 0.35) * a;
}
"""
	_shaders[name] = s
	return s


## マップの上のキャラ1体（ドット絵の板＋影＋頭の上の表示）
class UnitView extends Node3D:
	const CELL := 192.0
	var kind := ""
	var enemy := false
	var facing := Vector2i.ZERO
	var fly := 0.0
	var hidden_look := false
	var elite := false
	var height := 1.0
	var sprite: Sprite3D
	var shadow: MeshInstance3D
	var info: Label3D
	var mark: Label3D
	var frame := 0
	var _t := randf() * 5.0
	var _pose_tw: Tween
	var _hit := 0.0
	var _dead := false

	func _init(k: String, h: float, is_enemy: bool) -> void:
		kind = k
		enemy = is_enemy
		height = h
		sprite = Sprite3D.new()
		var tex: Texture2D = load("res://assets/images/px/%s.png" % k)
		sprite.texture = tex
		sprite.hframes = 4
		sprite.pixel_size = h / CELL
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sprite.shaded = false
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		sprite.offset = Vector2(0, CELL / 2.0 - 8.0)
		add_child(sprite)
		shadow = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(0.7, 0.7) * clampf(h, 0.8, 1.5)
		shadow.mesh = pm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var g := GradientTexture2D.new()
		g.fill = GradientTexture2D.FILL_RADIAL
		g.fill_from = Vector2(0.5, 0.5)
		g.fill_to = Vector2(1.0, 0.5)
		g.gradient = Gradient.new()
		g.gradient.set_color(0, Color(0, 0.02, 0.06, 0.5))
		g.gradient.set_color(1, Color(0, 0.02, 0.06, 0.0))
		m.albedo_texture = g
		shadow.material_override = m
		shadow.position.y = 0.02
		add_child(shadow)
		info = World._label3d("", 40, Color.WHITE)
		info.position.y = h + 0.25
		info.visible = is_enemy
		add_child(info)
		mark = World._label3d("", 96, Color.WHITE)
		mark.position.y = h + 0.7
		add_child(mark)

	func _process(delta: float) -> void:
		_t += delta
		_hit = maxf(_hit - delta * 3.0, 0.0)
		if _dead:
			return
		var bob := sin(_t * 2.4) * 0.05 + fly + sin(_t * 1.7) * fly * 0.3
		sprite.position.y = bob
		var f := frame
		if enemy and frame == 0 and int(_t * 2.2) % 2 == 1:
			f = 1
		sprite.frame = f
		var tint := Color(1, 0.9, 0.6) if elite else Color(1, 1, 1)
		if _hit > 0:
			tint = Color(1, 1 - _hit * 0.8, 1 - _hit * 0.8)
		if hidden_look:
			tint.a = 0.55
		sprite.modulate = tint
		var s := 1.0 + _hit * 0.15
		sprite.scale = Vector3(s, 1.0 / s, 1.0)
		if mark.text != "":
			mark.position.y = info.position.y + 0.45 + absf(sin(_t * 4.0)) * 0.12

	func face_right(right: bool) -> void:
		# カノープスとミラの絵は右向き、敵の絵は左向き
		sprite.flip_h = (not right) if not enemy else right

	func pose(f: int, sec: float) -> void:
		frame = f
		if _pose_tw:
			_pose_tw.kill()
		_pose_tw = create_tween()
		_pose_tw.tween_interval(sec)
		_pose_tw.tween_callback(func(): frame = 0)

	func hurt() -> void:
		_hit = 1.0
		if enemy:
			pose(2, 0.4)
		else:
			pose(2, 0.7)

	func set_info(hp: int, max_hp: int, state: String, stun: int) -> void:
		var hearts := ""
		if max_hp > 8:
			hearts = "体力 %d/%d" % [hp, max_hp]
		else:
			for i in max_hp:
				hearts += "●" if i < hp else "○"
		info.text = ("ぬし " if elite else "") + hearts
		info.modulate = Color(1, 0.45, 0.45) if state == "alert" else Color(1, 0.9, 0.85)
		if stun > 0:
			set_mark("zz", Color(0.7, 0.85, 1.0))
		elif state == "alert":
			set_mark("！", Color(1, 0.3, 0.25))
		elif state in ["invest", "search"]:
			set_mark("？", Color(1, 0.85, 0.3))
		elif state == "sleep":
			set_mark("zzz", Color(0.7, 0.85, 1.0))
		else:
			set_mark("", Color.WHITE)

	func set_mark(s: String, col: Color) -> void:
		if s != "" and mark.text != s:
			mark.scale = Vector3(1.8, 1.8, 1.8)
			var tw := mark.create_tween()
			tw.tween_property(mark, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		mark.text = s
		mark.modulate = col

	func die() -> void:
		_dead = true
		frame = 2
		sprite.frame = 2
		info.visible = false
		mark.text = ""
		var tw := create_tween()
		tw.tween_property(sprite, "modulate", Color(1, 0.4, 0.4, 1), 0.1)
		tw.tween_property(sprite, "position:y", 0.9, 0.5).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(sprite, "modulate:a", 0.0, 0.5)
		tw.parallel().tween_property(shadow, "scale", Vector3(0.01, 1, 0.01), 0.4)
		tw.tween_callback(queue_free)
