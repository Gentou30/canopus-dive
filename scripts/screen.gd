extends Node

## 画面の向きの管理（Autoload: Screen）。
## 横向きなら 1280x720、縦向きなら 720x1280 を基準解像度にして、どちらでも文字が同じ大きさで見えるようにする。
## レイアウトは layout_changed を受けて組み直す。

signal layout_changed

const LANDSCAPE := Vector2i(1280, 720)
const PORTRAIT := Vector2i(720, 1280)

var portrait := false


func _ready() -> void:
	get_tree().root.size_changed.connect(_update)
	_update()


func view_size() -> Vector2:
	return get_tree().root.get_visible_rect().size


func _update() -> void:
	var root := get_tree().root
	portrait = root.size.y > root.size.x
	var target := PORTRAIT if portrait else LANDSCAPE
	if root.content_scale_size != target:
		root.content_scale_size = target
	# 基準解像度の変更が反映されてから組み直す
	layout_changed.emit.call_deferred()
