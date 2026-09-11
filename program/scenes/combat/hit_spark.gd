class_name HitSpark
extends Node2D

## 可复用的程序化受击闪光：白色菱形配深色描边，不依赖贴图，并以真实时间运行。
var _started_usec: int = 0
var _duration: float = 0.22
var _grow_seconds: float = 0.035
var _start_scale: float = 0.35
var _size: float = 34.0
var _outline_width: float = 1.5
var _width_multiplier: float = 0.75
var _final_opacity: float = 0.30
var _is_heavy: bool = false
var _playing: bool = false


func _ready() -> void:
	# 命中后的顿帧会暂停普通节点；火花必须继续刷新，才能完成弹出和渐隐。
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false


## direction 表示武器朝目标挥来的方向；先快速弹出，再在剩余时间渐隐。
func play(
	direction: Vector2,
	combo: int,
	seconds: float,
	size: float,
	outline_width: float = 1.5,
	grow_seconds: float = 0.035,
	start_scale: float = 0.35,
	width_multiplier: float = 0.75,
	final_opacity: float = 0.30
) -> void:
	_duration = maxf(seconds, 0.01)
	_size = maxf(size, 1.0)
	_outline_width = maxf(outline_width, 1.0)
	_grow_seconds = clampf(grow_seconds, 0.0, _duration)
	_start_scale = clampf(start_scale, 0.05, 1.0)
	_width_multiplier = clampf(width_multiplier, 0.10, 2.0)
	_final_opacity = clampf(final_opacity, 0.0, 1.0)
	_is_heavy = combo >= 3
	_started_usec = Time.get_ticks_usec()
	rotation = direction.angle()
	_playing = true
	visible = true
	queue_redraw()


func is_playing() -> bool:
	return _playing


## 供回归测试和后续特效组合读取，不依赖受 time_scale 影响的 delta。
func get_elapsed() -> float:
	if not _playing:
		return _duration
	return minf(float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0, _duration)


func _process(_delta: float) -> void:
	if not _playing:
		return
	if get_elapsed() >= _duration:
		_playing = false
		visible = false
		queue_redraw()
		return
	queue_redraw()


func _draw() -> void:
	if not _playing:
		return
	var elapsed: float = get_elapsed()
	var grow_progress: float = elapsed / _grow_seconds if _grow_seconds > 0.0 else 1.0
	var grow_scale: float = lerpf(_start_scale, 1.0, ease(clampf(grow_progress, 0.0, 1.0), -4.0))
	var fade_duration: float = maxf(_duration - _grow_seconds, 0.001)
	var fade_progress: float = clampf((elapsed - _grow_seconds) / fade_duration, 0.0, 1.0)
	# 弹出结束后才开始淡出，并在结束前保留指定不透明度，再由节点直接隐藏。
	var fade_weight: float = 1.0 - pow(1.0 - fade_progress, 0.65)
	var alpha: float = lerpf(1.0, _final_opacity, fade_weight)
	var radius: float = _size * grow_scale
	# x 轴始终朝攻击来向，细长菱形因此会顺着挥砍方向延展。
	var length: float = radius * (2.05 if _is_heavy else 1.78)
	var half_width: float = radius * (0.34 if _is_heavy else 0.23) * _width_multiplier
	var diamond: PackedVector2Array = PackedVector2Array([
		Vector2(-length, 0.0), Vector2(0.0, half_width),
		Vector2(length, 0.0), Vector2(0.0, -half_width),
	])
	var closed_diamond: PackedVector2Array = PackedVector2Array([
		diamond[0], diamond[1], diamond[2], diamond[3], diamond[0],
	])
	# 先画整圈深描边，再画纯白填充，任何背景和木桩颜色上都能清楚辨认。
	draw_colored_polygon(diamond, Color(0.035, 0.045, 0.07, alpha))
	draw_polyline(closed_diamond, Color(0.015, 0.02, 0.04, alpha), _outline_width, true)
	# 中心区域使用完整白色并扩大占比，让菱形主体更亮、描边只保留轮廓作用。
	var inner_scale: float = 0.92
	var inner_diamond: PackedVector2Array = PackedVector2Array([
		Vector2(-length * inner_scale, 0.0), Vector2(0.0, half_width * inner_scale),
		Vector2(length * inner_scale, 0.0), Vector2(0.0, -half_width * inner_scale),
	])
	draw_colored_polygon(inner_diamond, Color(1.0, 1.0, 1.0, alpha))
