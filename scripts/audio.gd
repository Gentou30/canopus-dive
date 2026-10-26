extends Node

## BGM と効果音（Autoload `Audio`）。音源は tools/make_audio.py で合成した assets/audio/*.wav。
## ブラウザは最初の操作まで音を出せないが、Godot が自動で再開するので気にしなくてよい。

const BGM_DB := -8.0
const SFX_DB := -4.0
const FADE_SEC := 0.4

var muted := false
var _bgm: AudioStreamPlayer
var _bgm_name := ""
var _sfx: Array[AudioStreamPlayer] = []
var _next := 0
var _cache := {}
var _fade: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_bgm = AudioStreamPlayer.new()
	_bgm.volume_db = BGM_DB
	add_child(_bgm)
	# 同時に鳴らせる効果音の数
	for i in 10:
		var p := AudioStreamPlayer.new()
		p.volume_db = SFX_DB
		add_child(p)
		_sfx.append(p)


func _load(name: String) -> AudioStream:
	if not _cache.has(name):
		_cache[name] = load("res://assets/audio/%s.wav" % name)
	return _cache[name]


## name: "play" / "title" / "shop"。空文字で止める。同じ曲なら続けて流す
func bgm(name: String, pitch: float = 1.0) -> void:
	_bgm.pitch_scale = pitch
	if name == _bgm_name:
		return
	_bgm_name = name
	if _fade:
		_fade.kill()
	if name == "":
		_bgm.stop()
		return
	_bgm.stream = _load("bgm_" + name)
	_bgm.volume_db = BGM_DB - 20.0
	_bgm.play()
	_fade = create_tween()
	_fade.tween_property(_bgm, "volume_db", BGM_DB, FADE_SEC)


## BGM の速さ（ピッチ）だけ変える。残り時間が少ないときに急かす
func bgm_pitch(pitch: float) -> void:
	_bgm.pitch_scale = pitch


## ジングルは BGM を止めてから鳴らす
func jingle(name: String) -> void:
	bgm("")
	sfx("jingle_" + name, 0.0)


func sfx(name: String, db: float = SFX_DB, pitch: float = 1.0) -> void:
	if muted:
		return
	var p := _sfx[_next]
	_next = (_next + 1) % _sfx.size()
	p.stream = _load(name if name.begins_with("jingle_") else "sfx_" + name)
	p.volume_db = db
	p.pitch_scale = pitch
	p.play()


func toggle_mute() -> void:
	muted = not muted
	AudioServer.set_bus_mute(0, muted)
