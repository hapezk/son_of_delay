class_name SideScrollCamera
extends Camera2D

## 横板镜头：角色位于屏幕死区内时保持稳定，越过边缘后才指数平滑跟随。
@export var target_path: NodePath
@export_range(0.51, 0.95, 0.01) var right_trigger_ratio: float = 0.68
@export_range(0.05, 0.49, 0.01) var left_trigger_ratio: float = 0.32
@export_range(0.1, 30.0, 0.1) var follow_speed: float = 6.0
@export var level_left: float = 0.0
@export var level_right: float = 3840.0
@export var fixed_y: float = 360.0

var target: Node2D
var _player_group: DelayedActorGroup
var _desired_x: float = 0.0


func _ready() -> void:
	target = get_node_or_null(target_path) as Node2D
	_resolve_player_group()
	_desired_x = global_position.x
	global_position.y = fixed_y
	make_current()
	reset_smoothing()


func _physics_process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		target = get_node_or_null(target_path) as Node2D
		if target == null:
			return
		_resolve_player_group()
	var focus_position: Vector2 = _get_focus_position()
	var viewport_width: float = get_viewport_rect().size.x / maxf(zoom.x, 0.001)
	var half_width: float = viewport_width * 0.5
	var target_screen_x: float = focus_position.x - global_position.x + half_width
	var right_trigger_x: float = viewport_width * right_trigger_ratio
	var left_trigger_x: float = viewport_width * left_trigger_ratio
	if target_screen_x > right_trigger_x:
		_desired_x = focus_position.x - (right_trigger_x - half_width)
	elif target_screen_x < left_trigger_x:
		_desired_x = focus_position.x - (left_trigger_x - half_width)
	_desired_x = _clamp_camera_center(_desired_x, half_width)
	# 指数权重不依赖帧率；数值仍是标准 lerp，follow_speed 表示追随收敛速度。
	var follow_weight: float = 1.0 - exp(-follow_speed * maxf(delta, 0.0))
	global_position.x = lerpf(global_position.x, _desired_x, follow_weight)
	global_position.y = fixed_y


func _resolve_player_group() -> void:
	_player_group = null
	if target != null:
		_player_group = target.get_parent() as DelayedActorGroup


func _get_focus_position() -> Vector2:
	if _player_group != null and is_instance_valid(_player_group) \
			and _player_group.has_method("get_camera_focus_position"):
		return _player_group.call("get_camera_focus_position") as Vector2
	return target.global_position


func _clamp_camera_center(value: float, half_width: float) -> float:
	var minimum_center: float = level_left + half_width
	var maximum_center: float = level_right - half_width
	if maximum_center < minimum_center:
		return (level_left + level_right) * 0.5
	return clampf(value, minimum_center, maximum_center)
