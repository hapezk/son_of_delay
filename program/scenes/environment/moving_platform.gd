class_name MovingPlatform
extends AnimatableBody2D

signal endpoint_reached(at_end: bool)

@export_group("Route")
## 相对场景中摆放位置的终点偏移；横向、纵向和斜向平台使用同一套逻辑。
@export var travel_offset: Vector2 = Vector2(320.0, 0.0)
@export_range(0.0, 2000.0, 5.0) var travel_speed: float = 120.0
@export_range(0.0, 10.0, 0.05) var endpoint_wait_seconds: float = 0.35
## 启用后，场景启动时从偏移终点向摆放原点返回。
@export var start_at_end: bool = false
@export var movement_enabled: bool = true

@export_group("Lifecycle")
@export var reset_on_player_respawn: bool = true

@export_group("Collision")
## 默认允许玩家从下方穿过；关闭后就是普通的双面移动实体。
@export var one_way_collision: bool = true
@export_range(0.0, 32.0, 0.5) var one_way_margin: float = 4.0

var _start_position: Vector2 = Vector2.ZERO
var _end_position: Vector2 = Vector2.ZERO
var _moving_to_end: bool = true
var _wait_time_left: float = 0.0

@onready var platform_collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	add_to_group("moving_platforms")
	if reset_on_player_respawn:
		add_to_group("player_respawn_reset")
	_start_position = position
	_end_position = _start_position + travel_offset
	_moving_to_end = not start_at_end
	if start_at_end:
		position = _end_position
	platform_collision.one_way_collision = one_way_collision
	platform_collision.one_way_collision_margin = one_way_margin
	reset_physics_interpolation()


## 使用物理逻辑时间推进；思考时间与命中顿帧暂停 SceneTree 时，平台会一起停止。
func _physics_process(delta: float) -> void:
	simulate_route(delta)


## 供延迟外壳逐帧驱动；普通平台仍由自己的 _physics_process 调用同一实现。
func simulate_route(delta: float) -> void:
	if not movement_enabled or travel_speed <= 0.0 or travel_offset.is_zero_approx():
		return
	if _wait_time_left > 0.0:
		_wait_time_left = maxf(_wait_time_left - delta, 0.0)
		return
	var target_position: Vector2 = _end_position if _moving_to_end else _start_position
	position = position.move_toward(target_position, travel_speed * delta)
	if not position.is_equal_approx(target_position):
		return
	position = target_position
	var reached_end: bool = _moving_to_end
	_moving_to_end = not _moving_to_end
	_wait_time_left = endpoint_wait_seconds
	endpoint_reached.emit(reached_end)


## 延迟平台的外壳在自身 ready 后通过此入口复制检查器配置并重建局部路线。
func configure_route(
	new_travel_offset: Vector2,
	new_travel_speed: float,
	new_wait_seconds: float,
	new_start_at_end: bool,
	new_movement_enabled: bool,
	new_one_way_collision: bool,
	new_one_way_margin: float
) -> void:
	travel_offset = new_travel_offset
	travel_speed = new_travel_speed
	endpoint_wait_seconds = new_wait_seconds
	start_at_end = new_start_at_end
	movement_enabled = new_movement_enabled
	one_way_collision = new_one_way_collision
	one_way_margin = new_one_way_margin
	_end_position = _start_position + travel_offset
	platform_collision.one_way_collision = one_way_collision
	platform_collision.one_way_collision_margin = one_way_margin
	reset_motion()


## 平台轨迹状态进入 BaseActor 快照；真实碰撞层不属于预测数据。
func capture_motion_state() -> Dictionary:
	return {
		"position": position,
		"moving_to_end": _moving_to_end,
		"wait_time_left": _wait_time_left,
	}


func restore_motion_state(state: Dictionary) -> void:
	position = state.get("position", position) as Vector2
	_moving_to_end = bool(state.get("moving_to_end", _moving_to_end))
	_wait_time_left = float(state.get("wait_time_left", _wait_time_left))
	reset_physics_interpolation()


## 三体平台只有权威副本保留地形碰撞；蓝色副本只显示未来位置。
func configure_collision_authority(is_authority: bool, is_preview: bool = false) -> void:
	collision_layer = 2 if is_authority else 0
	collision_mask = 0
	# 权威体需要物理同步来稳定载人；离线预测必须立即写入变换，不能等待物理服务器发布。
	sync_to_physics = is_authority
	platform_collision.disabled = not is_authority
	modulate = Color(0.40, 0.82, 1.0, 0.58) if is_preview else Color.WHITE


## Player 只会对明确开放此契约的单向薄平台启用下穿，普通地面与实体陷阱不受影响。
func is_drop_through_platform() -> bool:
	return platform_collision != null \
		and not platform_collision.disabled \
		and platform_collision.one_way_collision


## 关卡重开或机关复位时回到检查器指定的初始端点。
func reset_motion() -> void:
	position = _end_position if start_at_end else _start_position
	_moving_to_end = not start_at_end
	_wait_time_left = 0.0
	reset_physics_interpolation()


## 接入现有轮次复位契约；参数与敌人的 reset_combat 保持兼容。
func reset_combat(_clear_statistics: bool = false) -> void:
	reset_motion()


func get_route_start() -> Vector2:
	return _start_position


func get_route_end() -> Vector2:
	return _end_position
