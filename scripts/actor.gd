class_name Actor
extends Node2D

## 盤の上のキャラ（ドット絵、assets/images/px/<kind>.png の 192px×4コマ）。
## カノープス・ミラ: 0 待機 / 1 喜ぶ / 2 あせる / 3 決めポーズ
## 敵: 0 待機 / 1 待機2（交互に動かす） / 2 やられ / 3 攻撃（絵は左向き）
## position はマスの中心。ふわふわ浮いて見えるよう上下にゆれる。

const CELL := 192.0

var kind := ""
var size := 80.0          # 描く大きさ（px）
var flip := false
var frame := 0
var enemy := false
var bob := 1.0            # ゆれの強さ
var flash := 0.0          # 白く光る（ダメージ）
var alpha := 1.0
var hop := 0.0
var _t := randf() * 5.0
var _tex: Texture2D
var _act: Tween


func _init(k: String, s: float, is_enemy: bool) -> void:
	kind = k
	size = s
	enemy = is_enemy
	var p := "res://assets/images/px/%s.png" % k
	_tex = load(p) if ResourceLoader.exists(p) else null


func _process(delta: float) -> void:
	_t += delta
	flash = max(flash - delta * 4.0, 0.0)
	queue_redraw()


## しばらくポーズをとって戻る
func act(f: int, sec: float = 0.8, jump: bool = false) -> void:
	frame = f
	if _act:
		_act.kill()
	_act = create_tween()
	if jump:
		_act.tween_property(self, "hop", 1.0, 0.12).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		_act.tween_property(self, "hop", 0.0, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BOUNCE)
	_act.tween_interval(sec)
	_act.tween_callback(func(): frame = 0)


func _draw() -> void:
	# 影（海底に落ちる丸い影）
	draw_set_transform(Vector2(0, size * 0.42), 0.0, Vector2(1, 0.28))
	draw_circle(Vector2.ZERO, size * 0.32 * (1.0 - hop * 0.2), Color(0, 0.02, 0.06, 0.35 * alpha))
	if _tex == null:
		draw_set_transform(Vector2.ZERO)
		draw_circle(Vector2.ZERO, size * 0.3, Color.MAGENTA)
		return
	var f := frame
	if enemy and frame == 0 and int(_t * 2.2) % 2 == 1:
		f = 1
	var y := sin(_t * 2.4) * size * 0.04 * bob - hop * size * 0.25
	var sx := -1.0 if flip else 1.0
	# 待機中は呼吸するように少し伸び縮み
	var br := sin(_t * 2.4 + 1.0) * 0.03 * bob
	draw_set_transform(Vector2(0, y + size * 0.45), 0.0, Vector2(sx * (1.0 - br), 1.0 + br))
	var mod := Color(1, 1, 1, alpha)
	draw_texture_rect_region(_tex, Rect2(-size / 2, -size, size, size), Rect2(f * CELL, 0, CELL, CELL), mod)
	if flash > 0:
		# ダメージのときは白く光らせる（加算っぽく同じ絵を白で重ねる）
		draw_texture_rect_region(_tex, Rect2(-size / 2, -size, size, size), Rect2(f * CELL, 0, CELL, CELL),
			Color(3, 3, 3, flash * alpha))
	draw_set_transform(Vector2.ZERO)
