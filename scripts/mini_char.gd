class_name MiniChar
extends Control

## ドット絵のミニキャラ（assets/images/px/<name>.png、192px のマスが横に4コマ）。
## コマ: 0 待機 / 1 喜ぶ / 2 あせる / 3 決めポーズ。待機中はゆらゆら揺れ、act() で一時的にポーズを取る。
## 足元を Control の下辺の中央にそろえて描く。

enum { IDLE, HAPPY, PANIC, SPECIAL }

const CELL := 192.0

static var _cache := {}

var who := ""
var flip := false
var frame := IDLE
var _t := 0.0
var _hop := 0.0        # 跳ねている高さ（0〜1）
var _shake := 0.0
var _act_tween: Tween
var _seed := randf() * 10.0


func _init(name: String = "", flipped: bool = false) -> void:
	who = name
	flip = flipped
	mouse_filter = Control.MOUSE_FILTER_IGNORE


static func sheet(name: String) -> Texture2D:
	if not _cache.has(name):
		var p := "res://assets/images/px/%s.png" % name
		_cache[name] = load(p) if ResourceLoader.exists(p) else null
	return _cache[name]


func _process(delta: float) -> void:
	_t += delta
	_shake = max(_shake - delta * 3.0, 0.0)
	queue_redraw()


## ポーズを sec 秒とって待機に戻る。hop で跳ねる、shake で震える
func act(f: int, sec: float = 1.2, hop: bool = false, shake: bool = false) -> void:
	frame = f
	if _act_tween:
		_act_tween.kill()
	_act_tween = create_tween()
	if hop:
		_act_tween.tween_property(self, "_hop", 1.0, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_act_tween.tween_property(self, "_hop", 0.0, 0.2).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	if shake:
		_shake = 1.0
	_act_tween.tween_interval(max(sec - (0.34 if hop else 0.0), 0.05))
	_act_tween.tween_callback(func(): frame = IDLE)


func _draw() -> void:
	var tex := sheet(who)
	if tex == null:
		return
	var s: float = min(size.x, size.y) / CELL
	var w := CELL * s
	# 待機中は呼吸するように少し伸び縮み、あせっているときは小刻みに震える
	var breathe := sin(_t * 2.6 + _seed) * 0.025 if frame == IDLE else 0.0
	var sx := 1.0 - breathe
	var sy := 1.0 + breathe
	var lift := _hop * size.y * 0.22
	var jitter := Vector2.ZERO
	if frame == PANIC or _shake > 0:
		jitter = Vector2(sin(_t * 60.0) * 2.5 * max(_shake, 0.5), 0)
	var foot := Vector2(size.x / 2, size.y) + jitter - Vector2(0, lift)
	draw_set_transform(foot, 0.0, Vector2(sx * (-1.0 if flip else 1.0), sy))
	# 影
	draw_set_transform(Vector2(size.x / 2, size.y - 2), 0.0, Vector2(1, 0.25))
	draw_circle(Vector2.ZERO, w * 0.3 * (1.0 - _hop * 0.3), Color(0, 0, 0, 0.35))
	draw_set_transform(foot, 0.0, Vector2(sx * (-1.0 if flip else 1.0), sy))
	draw_texture_rect_region(tex, Rect2(-w / 2, -w, w, w), Rect2(frame * CELL, 0, CELL, CELL))
	draw_set_transform(Vector2.ZERO)
