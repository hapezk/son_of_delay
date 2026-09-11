class_name BaseActor
extends CharacterBody2D

## AUTHORITY 是唯一能影响真实世界的本体；其余角色只负责显示和离线预测。
enum DelayReplicaRole { AUTHORITY, PREVIEW, PREDICTOR }
const SOLID_OBSTACLE_ESCAPE_MARGIN: float = 2.0

@onready var graphics: Node2D = get_node_or_null("VisualRoot/Graphics") as Node2D
@onready var animation_player: AnimationPlayer = get_node_or_null("VisualRoot/AnimationPlayer") as AnimationPlayer
@onready var state_machine: StateMachine = get_node_or_null("%StateMachine") as StateMachine
@onready var base_collision: CollisionShape2D = get_node_or_null("BaseCollision") as CollisionShape2D
## 武器随角色场景实例化；无武器的角色可以不添加这个节点。
@onready var weapon: SwordWeapon = get_node_or_null("VisualRoot/SwordWeapon") as SwordWeapon

## 延迟系统内部使用的“本帧是否拿到有效历史输入”标记；不是角色手感参数，通常不要在 Inspector 手动修改。
@export var inputed: bool = false
## 角色的水平目标速度；对通用弹体则是加速完成后的目标飞行速度，单位为世界像素/秒。
@export var move_speed: float = 320.0
## 水平速度趋近 Move Speed 的加速度；弹体也用它从 Launch Speed 过渡到目标速度，单位为像素/秒²。
@export var acceleration: float = 1600
## 空中水平加速度相对 Acceleration 的倍率；玩家脚本会改为读取 Combat Tuning 中的同名配置。
@export_range(0.0, 1.0, 0.05) var air_acceleration_multiplier: float = 0.45
## 起跳瞬间写入的竖直速度，单位为像素/秒；Godot 2D 向上为负，因此正常跳跃应填负数。
@export var jump_velocity: float = -600.0
## 每秒施加到竖直速度上的向下加速度，单位为像素/秒²；0 表示不受重力影响。
@export var gravity: float = 1600.0
var preview_system: PreviewSystem
@onready var group: Node = get_parent()
var delay_replica_role: DelayReplicaRole = DelayReplicaRole.AUTHORITY
## 保持为 Node 类型以避免基础角色反向依赖某个具体玩家或敌人控制器类。
var delay_controller: Node
## 仅由实体障碍的安全移动入口写入；控制器据此区分正常碰撞与预测分歧。
var _solid_obstacle_motion_blocked: bool = false
## 地面检测在 100 TPS 和预测循环中调用频繁；复用结果对象，避免每次查询产生临时分配。
var _ground_contact: KinematicCollision2D = KinematicCollision2D.new()


## 用当前位置检测地面，避免预测器传送后沿用 CharacterBody2D 上一帧的着地缓存。
func is_grounded_for_simulation() -> bool:
	return test_move(
		global_transform,
		-up_direction * 0.1,
		_ground_contact,
		safe_margin,
		true
	) and _ground_contact.get_normal().dot(up_direction) >= cos(floor_max_angle)


## 本体、预览和延迟切换的停止距离估算共用同一个空中加速度。
func get_horizontal_acceleration(grounded: bool) -> float:
	if grounded:
		return acceleration
	return acceleration * air_acceleration_multiplier


## 开启延迟时，本体先按对象自己的运动规则停下；控制器不读取具体脚本字段。
func get_delay_waiting_deceleration() -> float:
	return get_horizontal_acceleration(is_grounded_for_simulation())


## 外部状态结束后才允许恢复正延迟，避免把尚未结束的受伤/死亡运动录进新时间线。
## 普通角色始终可恢复；有特殊外部状态的角色覆盖此契约。
func is_delay_reentry_ready() -> bool:
	return true


## 延迟控制器只依赖以下公共契约，不需要知道对象是玩家、敌人、友军还是物理道具。
func capture_delay_command() -> Dictionary:
	return {}


func simulate_delay_command(_command: Dictionary, _delta: float) -> void:
	pass


## 脚本驱动的实体障碍必须扫掠移动，不能直接写位置穿进玩家。
## 蓝色预览和隐藏预测体没有碰撞权威，仍按目标位移演算未来轨迹。
func move_solid_obstacle_safely(motion: Vector2) -> KinematicCollision2D:
	_solid_obstacle_motion_blocked = false
	if motion.is_zero_approx():
		return null
	if delay_replica_role != DelayReplicaRole.AUTHORITY:
		global_position += motion
		return null
	var collision: KinematicCollision2D = move_and_collide(motion)
	_solid_obstacle_motion_blocked = collision != null
	return collision


func was_solid_obstacle_motion_blocked() -> bool:
	return _solid_obstacle_motion_blocked


## 被脚本驱动的实体障碍夹住时，优先沿障碍运动的垂直方向移到最近安全侧。
## 候选位置必须通过真实物理空间查询；不会把角色传送进另一面墙或地面。
func resolve_solid_obstacle_entrapment(
	obstacle_bounds: Rect2,
	obstacle_motion: Vector2,
	preferred_horizontal_direction: int = 0
) -> bool:
	if delay_replica_role != DelayReplicaRole.AUTHORITY or base_collision == null \
			or base_collision.shape == null or get_world_2d() == null:
		return false
	var half_extents: Vector2 = _get_base_collision_half_extents()
	var obstacle_center: Vector2 = obstacle_bounds.get_center()
	var left_position: Vector2 = Vector2(
		obstacle_bounds.position.x - half_extents.x - SOLID_OBSTACLE_ESCAPE_MARGIN,
		global_position.y)
	var right_position: Vector2 = Vector2(
		obstacle_bounds.end.x + half_extents.x + SOLID_OBSTACLE_ESCAPE_MARGIN,
		global_position.y)
	var above_position: Vector2 = Vector2(
		global_position.x,
		obstacle_bounds.position.y - half_extents.y - SOLID_OBSTACLE_ESCAPE_MARGIN)
	var below_position: Vector2 = Vector2(
		global_position.x,
		obstacle_bounds.end.y + half_extents.y + SOLID_OBSTACLE_ESCAPE_MARGIN)

	var prefer_left: bool = preferred_horizontal_direction < 0 \
		if preferred_horizontal_direction != 0 else global_position.x < obstacle_center.x
	if preferred_horizontal_direction == 0 \
			and is_equal_approx(global_position.x, obstacle_center.x):
		# 正向移动通常表示角色从左侧进入；静止时默认退回左侧，避免借门脱困穿过谜题。
		prefer_left = velocity.x >= 0.0
	var horizontal_candidates: Array[Vector2] = [
		left_position if prefer_left else right_position,
		right_position if prefer_left else left_position,
	]
	var vertical_candidates: Array[Vector2] = [above_position, below_position]
	var candidates: Array[Vector2] = []
	if absf(obstacle_motion.y) >= absf(obstacle_motion.x):
		candidates.append_array(horizontal_candidates)
		candidates.append_array(vertical_candidates)
	else:
		candidates.append_array(vertical_candidates)
		candidates.append_array(horizontal_candidates)

	for candidate: Vector2 in candidates:
		if not _is_solid_obstacle_escape_position_free(candidate):
			continue
		global_position = candidate
		velocity.x = 0.0
		reset_physics_interpolation()
		report_delay_external_divergence(&"solid_obstacle_escape")
		return true
	return false


func _get_base_collision_half_extents() -> Vector2:
	var shape_scale: Vector2 = base_collision.global_scale.abs()
	if base_collision.shape is RectangleShape2D:
		return (base_collision.shape as RectangleShape2D).size * shape_scale * 0.5
	if base_collision.shape is CapsuleShape2D:
		var capsule: CapsuleShape2D = base_collision.shape as CapsuleShape2D
		return Vector2(capsule.radius, capsule.height * 0.5) * shape_scale
	if base_collision.shape is CircleShape2D:
		var radius: float = (base_collision.shape as CircleShape2D).radius
		return Vector2(radius, radius) * shape_scale
	return get_delay_selection_rect().size * global_scale.abs() * 0.5


func _is_solid_obstacle_escape_position_free(candidate: Vector2) -> bool:
	var query: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()
	query.shape = base_collision.shape
	query.collision_mask = collision_mask
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [get_rid()]
	query.transform = base_collision.global_transform
	query.transform.origin += candidate - global_position
	var overlaps: Array[Dictionary] = get_world_2d().direct_space_state.intersect_shape(
		query, 1)
	return overlaps.is_empty()


## 公共快照只保存模拟必需状态，不包含生命值等真实世界权威数据。
func capture_delay_snapshot() -> Dictionary:
	var snapshot: Dictionary = {
		"global_position": global_position,
		"global_rotation": global_rotation,
		"velocity": velocity,
		"simulation_state": capture_simulation_state(),
		"attachment_state": capture_delay_attachment_state(),
	}
	if graphics != null:
		snapshot["graphics_scale"] = graphics.scale
	return snapshot


func restore_delay_snapshot(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	global_position = snapshot.get("global_position", global_position) as Vector2
	global_rotation = float(snapshot.get("global_rotation", global_rotation))
	velocity = snapshot.get("velocity", velocity) as Vector2
	if graphics != null and snapshot.has("graphics_scale"):
		graphics.scale = snapshot["graphics_scale"] as Vector2
	var simulation_state: Variant = snapshot.get("simulation_state", {})
	if simulation_state is Dictionary:
		restore_simulation_state(simulation_state as Dictionary)
	var attachment_state: Variant = snapshot.get("attachment_state", {})
	if attachment_state is Dictionary:
		restore_delay_attachment_state(attachment_state as Dictionary)


## 武器、携带物等子系统通过这对钩子加入快照，BaseActor 不需要理解它们。
func capture_delay_attachment_state() -> Dictionary:
	return {}


func restore_delay_attachment_state(_state: Dictionary) -> void:
	pass


## 角色自行决定预览体需要关闭哪些碰撞、伤害、生命值 UI 等真实权限。
func configure_delay_replica(role: DelayReplicaRole) -> void:
	delay_replica_role = role


func bind_delay_controller(controller: Node) -> void:
	delay_controller = controller


## 延迟文字默认放在角色原点；脚底原点或异形碰撞体可覆盖并返回自身视觉中心。
func get_delay_ui_anchor_offset() -> Vector2:
	return Vector2.ZERO


## 延迟选择默认使用角色中心的 64 像素方框；不同体型只覆盖本地矩形。
func get_delay_selection_rect() -> Rect2:
	return Rect2(Vector2(-32.0, -32.0), Vector2(64.0, 64.0))


func is_delay_selection_point(world_point: Vector2) -> bool:
	return get_delay_selection_rect().has_point(to_local(world_point))


## 外部碰撞、伤害等让旧未来失效时，角色只发通知；控制器决定清空还是重算。
func report_delay_external_divergence(reason: StringName) -> void:
	if delay_controller != null and delay_controller.has_method("report_external_divergence"):
		delay_controller.call("report_external_divergence", reason)


func notify_delay_body_reset() -> void:
	if delay_controller != null and delay_controller.has_method("on_body_reset"):
		delay_controller.call("on_body_reset")


func notify_delay_body_defeated() -> void:
	if delay_controller != null and delay_controller.has_method("on_body_defeated"):
		delay_controller.call("on_body_defeated")


func request_delay_body_respawn() -> void:
	if delay_replica_role == DelayReplicaRole.AUTHORITY and delay_controller != null \
			and delay_controller.has_method("on_body_respawn_requested"):
		delay_controller.call_deferred("on_body_respawn_requested")


## 默认等待行为适用于会受墙体碰撞的普通 CharacterBody2D；特殊对象可以覆盖。
func tick_delay_waiting(delta: float) -> void:
	var grounded: bool = is_grounded_for_simulation()
	velocity.x = move_toward(velocity.x, 0.0, get_horizontal_acceleration(grounded) * delta)
	var saved_vertical_velocity: float = velocity.y
	velocity.y = 0.0
	move_and_slide()
	velocity.y = saved_vertical_velocity


## 延迟预测复制角色自身的短期逻辑状态；具体角色按需覆盖。
func capture_simulation_state() -> Dictionary:
	return {}


## 与 capture_simulation_state 配对，默认角色没有额外状态需要恢复。
func restore_simulation_state(_state: Dictionary) -> void:
	pass


# —— StateMachine 回调：基类只留空壳，状态逻辑全在子类 ——
func get_next_state(current: int) -> int:
	return state_machine.KEEP_CURRENT

func transition_state(from: int, to: int) -> void:
	pass

func tick_physics(current: int, delta: float) -> void:
	pass
