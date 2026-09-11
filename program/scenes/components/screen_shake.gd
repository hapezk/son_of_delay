class_name ScreenShake
extends Node

## 只改变画面，不移动物理角色；由 WorldTimeAuthority 在暂停期间继续调用。
var current_offset: Vector2 = Vector2.ZERO
var _active: bool = false
var _duration: float = 0.0
var _strength: float = 0.0
var _frequency: float = 0.0
var _base_transform: Transform2D = Transform2D.IDENTITY


func start(duration: float, strength: float, frequency: float) -> void:
	stop()
	if duration <= 0.0 or strength <= 0.0:
		return
	_base_transform = get_viewport().global_canvas_transform
	_duration = duration
	_strength = strength
	_frequency = frequency
	_active = true
	tick(0.0)


## elapsed 由时间控制器的顿帧计时器提供，保证晃动与顿帧同步结束。
func tick(elapsed: float) -> void:
	if not _active:
		return
	if elapsed >= _duration:
		stop()
		return
	var decay: float = 1.0 - elapsed / _duration
	# 不使用全局随机数，避免画面反馈影响预测过程中的随机序列。
	var angle: float = elapsed * TAU * _frequency
	current_offset = Vector2(sin(angle + 0.8), sin(angle * 1.3 + 2.1)) * _strength * decay
	var transform: Transform2D = _base_transform
	transform.origin += current_offset
	get_viewport().global_canvas_transform = transform


func stop() -> void:
	if _active and is_inside_tree():
		get_viewport().global_canvas_transform = _base_transform
	_active = false
	current_offset = Vector2.ZERO


func _exit_tree() -> void:
	stop()
