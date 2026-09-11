class_name DelayableLiftGate
extends BaseActor

@export_group("Switch")
## 通过分组查找开关，使控制器生成的蓝色预览与隐藏预测体也能读取同一真实输入。
@export var pressure_switch_group: StringName = &"tutorial_gate_switch"

@export_group("Gate Dimensions")
@export_range(16.0, 240.0, 1.0) var gate_width: float = 64.0
@export_range(200.0, 1200.0, 1.0) var gate_height: float = 760.0

@export_group("Motion")
## 完全开启时整扇门上移自身高度，门底也会离开可玩区域。
@export var open_offset: Vector2 = Vector2(0.0, -760.0)
@export_range(10.0, 2000.0, 10.0) var opening_speed: float = 760.0
@export_range(10.0, 2000.0, 10.0) var closing_speed: float = 900.0
@export_range(0.1, 8.0, 0.1) var position_tolerance: float = 2.0

@export_group("Safety")
## 0 自动选择最近侧；-1 固定退向左侧；1 固定退向右侧，适合单向机关防止借脱困穿门。
@export_enum("自动:0", "左侧:-1", "右侧:1") var obstruction_escape_direction: int = 0

@export_group("Lifecycle")
@export var reset_on_player_respawn: bool = false

var _closed_global_position: Vector2 = Vector2.ZERO

@onready var door_visual: Polygon2D = $VisualRoot/Graphics/Door
@onready var center_glow: Polygon2D = $VisualRoot/Graphics/CenterGlow


func _ready() -> void:
	_closed_global_position = global_position
	_apply_dimensions()
	# 带控制器的实例从首帧起只由公共命令回放层推进。
	if has_node("LiftGateDelayController"):
		set_physics_process(false)
	_update_authority_groups()


func _physics_process(delta: float) -> void:
	simulate_delay_command(capture_delay_command(), delta)


func capture_delay_command() -> Dictionary:
	return {"switch_pressed": _is_pressure_switch_pressed()}


func simulate_delay_command(command: Dictionary, delta: float) -> void:
	var should_open: bool = bool(command.get("switch_pressed", false))
	var target_position: Vector2 = _closed_global_position + open_offset \
		if should_open else _closed_global_position
	var motion_speed: float = opening_speed if should_open else closing_speed
	var previous_position: Vector2 = global_position
	var requested_position: Vector2 = global_position.move_toward(
		target_position, motion_speed * delta)
	# 实体门使用扫掠碰撞：遇到玩家就停在接触面，玩家离开后再继续移动。
	var requested_motion: Vector2 = requested_position - global_position
	var blocking_collision: KinematicCollision2D = move_solid_obstacle_safely(
		requested_motion)
	if blocking_collision != null:
		_try_release_blocking_actor(blocking_collision, requested_motion)
	velocity = (global_position - previous_position) / maxf(delta, 0.0001)
	if global_position.is_equal_approx(target_position):
		velocity = Vector2.ZERO
	_update_motion_visual(should_open)


## 延迟历史填充期间真实门保持原位；蓝色门继续即时响应开关。
func tick_delay_waiting(_delta: float) -> void:
	velocity = Vector2.ZERO


func get_delay_waiting_deceleration() -> float:
	return 0.0


func capture_simulation_state() -> Dictionary:
	return {"closed_global_position": _closed_global_position}


func restore_simulation_state(state: Dictionary) -> void:
	_closed_global_position = state.get(
		"closed_global_position", _closed_global_position) as Vector2


func configure_delay_replica(role: DelayReplicaRole) -> void:
	super.configure_delay_replica(role)
	var is_authority: bool = role == DelayReplicaRole.AUTHORITY
	collision_layer = 2 if is_authority else 0
	collision_mask = 1 if is_authority else 0
	if base_collision != null:
		base_collision.disabled = not is_authority
	modulate = Color(0.40, 0.82, 1.0, 0.58) \
		if role == DelayReplicaRole.PREVIEW else Color.WHITE
	_update_authority_groups()


## 控制器动态创建的两个副本需要继承关卡实例上的尺寸、速度和开关分组。
func copy_delay_configuration_to(replica: BaseActor) -> void:
	if not replica is DelayableLiftGate:
		return
	var gate_replica: DelayableLiftGate = replica as DelayableLiftGate
	gate_replica.pressure_switch_group = pressure_switch_group
	gate_replica.gate_width = gate_width
	gate_replica.gate_height = gate_height
	gate_replica.open_offset = open_offset
	gate_replica.opening_speed = opening_speed
	gate_replica.closing_speed = closing_speed
	gate_replica.position_tolerance = position_tolerance
	gate_replica.obstruction_escape_direction = obstruction_escape_direction
	gate_replica.reset_on_player_respawn = reset_on_player_respawn
	gate_replica._closed_global_position = _closed_global_position
	gate_replica._apply_dimensions()


func reset_combat(_clear_statistics: bool = false) -> void:
	global_position = _closed_global_position
	velocity = Vector2.ZERO
	reset_physics_interpolation()
	if delay_replica_role == DelayReplicaRole.AUTHORITY:
		notify_delay_body_reset()


func is_fully_open() -> bool:
	return global_position.distance_to(_closed_global_position + open_offset) \
		<= position_tolerance


func is_fully_closed() -> bool:
	return global_position.distance_to(_closed_global_position) <= position_tolerance


## 从完全开启开始，门底落到站立玩家头顶所需时间；教学测试用它验证无延迟路线必败。
func get_grounded_block_time(player_height: float) -> float:
	var open_bottom_y: float = _closed_global_position.y + open_offset.y + gate_height * 0.5
	var grounded_player_top_y: float = _closed_global_position.y + gate_height * 0.5 \
		- maxf(player_height, 0.0)
	var blocking_travel: float = maxf(grounded_player_top_y - open_bottom_y, 0.0)
	return blocking_travel / maxf(closing_speed, 0.001)


func get_delay_ui_anchor_offset() -> Vector2:
	return Vector2.ZERO


## 延迟文字固定在门关闭时的门洞中心，不随实际门板升降。
func get_fixed_delay_ui_global_position() -> Vector2:
	return _closed_global_position


func get_delay_selection_rect() -> Rect2:
	return Rect2(
		Vector2(-gate_width * 0.5, -gate_height * 0.5),
		Vector2(gate_width, gate_height)
	)


## 门板升起后仍可在关闭位置的整块门洞范围内选择；可见门板本身也继续响应。
func is_delay_selection_point(world_point: Vector2) -> bool:
	var selection_rect: Rect2 = get_delay_selection_rect()
	if selection_rect.has_point(to_local(world_point)):
		return true
	var closed_gate_transform: Transform2D = global_transform
	closed_gate_transform.origin = _closed_global_position
	return selection_rect.has_point(
		closed_gate_transform.affine_inverse() * world_point)


## 门先停在接触面，再把受夹角色放到最近的可用侧；找不到安全位置时保持停止。
func _try_release_blocking_actor(
	collision: KinematicCollision2D,
	requested_motion: Vector2
) -> void:
	var collider: Variant = collision.get_collider()
	if not (collider is BaseActor) or not is_instance_valid(collider):
		return
	var blocking_actor: BaseActor = collider as BaseActor
	var gate_size: Vector2 = Vector2(gate_width, gate_height) * global_scale.abs()
	var gate_bounds: Rect2 = Rect2(global_position - gate_size * 0.5, gate_size)
	blocking_actor.resolve_solid_obstacle_entrapment(
		gate_bounds, requested_motion, obstruction_escape_direction)


func _is_pressure_switch_pressed() -> bool:
	var switch_node: Node = get_tree().get_first_node_in_group(pressure_switch_group)
	return switch_node != null and switch_node.has_method("is_pressed") \
		and bool(switch_node.call("is_pressed"))


func _apply_dimensions() -> void:
	if base_collision != null and base_collision.shape is RectangleShape2D:
		(base_collision.shape as RectangleShape2D).size = Vector2(gate_width, gate_height)
	if door_visual != null:
		door_visual.polygon = PackedVector2Array([
			Vector2(-gate_width * 0.5, -gate_height * 0.5),
			Vector2(gate_width * 0.5, -gate_height * 0.5),
			Vector2(gate_width * 0.5, gate_height * 0.5),
			Vector2(-gate_width * 0.5, gate_height * 0.5),
		])
	if center_glow != null:
		center_glow.polygon = PackedVector2Array([
			Vector2(-5.0, -gate_height * 0.5),
			Vector2(5.0, -gate_height * 0.5),
			Vector2(5.0, gate_height * 0.5),
			Vector2(-5.0, gate_height * 0.5),
		])


func _update_motion_visual(opening: bool) -> void:
	center_glow.color = Color(0.28, 1.55, 1.20, 1.0) if opening \
		else Color(0.25, 0.82, 0.78, 0.9)


func _update_authority_groups() -> void:
	if delay_replica_role == DelayReplicaRole.AUTHORITY:
		add_to_group("delayable_lift_gates")
		if reset_on_player_respawn:
			add_to_group("player_respawn_reset")
		return
	remove_from_group("delayable_lift_gates")
	remove_from_group("player_respawn_reset")
