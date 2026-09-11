class_name DelayFrame
extends RefCounted

## 所有延迟对象共用的最小帧信封。
## command 是稍后由真实本体重新执行的命令；其余字段只用于预测、显示与分歧校验。
var command: Dictionary = {}
var pos: Vector2 = Vector2.ZERO
var vel: Vector2 = Vector2.ZERO
var state: Dictionary = {}


func _init(
	_command: Dictionary = {},
	_pos: Vector2 = Vector2.ZERO,
	_vel: Vector2 = Vector2.ZERO,
	_state: Dictionary = {}
) -> void:
	command = _command.duplicate(true)
	pos = _pos
	vel = _vel
	state = _state.duplicate(true)
