class_name FallingTrap
extends BaseActor

signal state_changed(new_state: TrapState)
signal target_hit(target: Node, damage: float)

enum TrapState { ARMED, FALLING, LANDED, RETURNING }

@export_group("Trigger")
## 只有真实玩家进入陷阱下方区域才会生成下落命令；敌人不能主动触发机关。
@export var trigger_target_group: StringName = &"player_damage_body"
## 触发区域查询的玩家物理层；通常只勾选权威玩家身体所在的第一层。
@export_flags_2d_physics var trigger_collision_mask: int = 1
## 以陷阱中心为基准，左右各自允许触发的距离，单位为世界像素。
@export_range(20.0, 600.0, 5.0) var trigger_half_width: float = 110.0
## 触发区域从起始偏移向下延伸的总深度，单位为世界像素。
@export_range(40.0, 1000.0, 10.0) var trigger_depth: float = 480.0
## 触发区域顶边相对陷阱原点向下的偏移，避免玩家与机关同高时误触发。
@export_range(0.0, 200.0, 5.0) var trigger_start_offset: float = 24.0

@export_group("Motion")
## 下落阶段允许达到的最大竖直速度，单位为像素/秒。
@export_range(100.0, 3000.0, 10.0) var max_fall_speed: float = 900.0
## 落地停留结束后回升到初始位置的速度，单位为像素/秒。
@export_range(10.0, 1000.0, 5.0) var return_speed: float = 90.0
## 碰到地面后保持不动再开始回升的时间，单位为逻辑秒。
@export_range(0.0, 3.0, 0.05) var landed_hold_seconds: float = 0.20

@export_group("Damage")
## 坠落陷阱每次有效接触造成的基础伤害。
@export_range(0.0, 1000.0, 1.0) var damage: float = 18.0
## 命中提供的基础硬直秒数；最终值会乘受击者的 Hurt Stun Multiplier。
@export_range(0.0, 3.0, 0.01) var hit_stun_seconds: float = 0.20
## 命中的基础水平击退距离，单位为世界像素；最终值会乘受击者的击退倍率。
@export_range(0.0, 1000.0, 0.5) var knockback_distance: float = 32.7
## 同一目标持续接触伤害区域时，两次有效伤害之间的最短逻辑秒数。
@export_range(0.05, 5.0, 0.05) var repeat_hit_seconds: float = 0.60
## 伤害区域检测的物理层；默认同时检测玩家和敌人的权威身体层。
@export_flags_2d_physics var damage_collision_mask: int = 5
## 与固定地刺一致，真实坠落陷阱敌我不分；蓝色预览与隐藏预测体没有伤害权限。
@export var damage_target_groups: Array[StringName] = [
	&"player_damage_body",
	&"enemy_damage_body",
]

@export_group("Lifecycle")
## 玩家死亡重生时是否回到初始位置并重置为等待触发状态。
@export var reset_on_player_respawn: bool = true

var current_state: TrapState = TrapState.ARMED
var damage_enabled: bool = true
var _home_global_position: Vector2 = Vector2.ZERO
var _landed_time_left: float = 0.0
var _hit_cooldowns: Dictionary[int, float] = {}

@onready var trigger_area: Area2D = $TriggerArea
@onready var trigger_shape: CollisionShape2D = $TriggerArea/TriggerShape
@onready var damage_area: Area2D = $DamageArea
@onready var housing_visual: Polygon2D = $VisualRoot/Housing
@onready var spike_visual: Polygon2D = $VisualRoot/Spikes


func _ready() -> void:
	_home_global_position = global_position
	_apply_trigger_configuration()
	# 带延迟控制器的实例从第一帧起只允许公共命令回放层推进。
	if has_node("FallingTrapDelayController"):
		set_physics_process(false)
	_apply_replica_permissions()
	_update_authority_groups()
	_update_state_visuals()


func _physics_process(delta: float) -> void:
	simulate_delay_command(capture_delay_command(), delta)


## 触发判断也作为命令记录；延迟本体稍后执行的是当时已经确定的下落事件。
func capture_delay_command() -> Dictionary:
	return {
		"trigger_fall": current_state == TrapState.ARMED and _has_trigger_target(),
	}


func simulate_delay_command(command: Dictionary, delta: float) -> void:
	if delay_replica_role == DelayReplicaRole.AUTHORITY:
		_tick_hit_cooldowns(delta)
	if current_state == TrapState.ARMED and bool(command.get("trigger_fall", false)):
		_set_state(TrapState.FALLING)

	match current_state:
		TrapState.ARMED:
			velocity = Vector2.ZERO
		TrapState.FALLING:
			_tick_falling(delta)
		TrapState.LANDED:
			_tick_landed(delta)
		TrapState.RETURNING:
			_tick_returning(delta)


func _tick_falling(delta: float) -> void:
	velocity.x = 0.0
	velocity.y = minf(velocity.y + gravity * delta, max_fall_speed)
	move_and_slide()
	if damage_enabled:
		_damage_overlapping_targets()
	if is_on_floor():
		velocity = Vector2.ZERO
		_landed_time_left = landed_hold_seconds
		_set_state(TrapState.LANDED)


func _tick_landed(delta: float) -> void:
	velocity = Vector2.ZERO
	if damage_enabled:
		_damage_overlapping_targets()
	_landed_time_left = maxf(_landed_time_left - delta, 0.0)
	if _landed_time_left <= 0.0:
		_set_state(TrapState.RETURNING)


func _tick_returning(delta: float) -> void:
	var to_home: Vector2 = _home_global_position - global_position
	var step_distance: float = return_speed * delta
	if to_home.length() <= step_distance:
		global_position = _home_global_position
		velocity = Vector2.ZERO
		# 到达原位的这一物理步仍属于回升阶段，接触尖刺需要结算伤害。
		if damage_enabled:
			_damage_overlapping_targets()
		_set_state(TrapState.ARMED)
		reset_physics_interpolation()
		return
	velocity = to_home.normalized() * return_speed
	move_and_collide(velocity * delta)
	if damage_enabled:
		_damage_overlapping_targets()


## 开启延迟、历史尚未到达时完全冻结本体；预览体仍继续演示坠落或回升。
func tick_delay_waiting(_delta: float) -> void:
	pass


func get_delay_waiting_deceleration() -> float:
	return 0.0


## 陷阱沿用伤害来源契约，受击者再乘自己的硬直倍率。
func get_hit_stun_seconds() -> float:
	return maxf(hit_stun_seconds, 0.0)


func get_knockback_distance() -> float:
	return maxf(knockback_distance, 0.0)


func capture_simulation_state() -> Dictionary:
	return {
		"current_state": int(current_state),
		"home_global_position": _home_global_position,
		"landed_time_left": _landed_time_left,
	}


func restore_simulation_state(state: Dictionary) -> void:
	current_state = int(state.get("current_state", int(current_state))) as TrapState
	_home_global_position = state.get("home_global_position", _home_global_position) as Vector2
	_landed_time_left = float(state.get("landed_time_left", _landed_time_left))
	_update_state_visuals()


func configure_delay_replica(role: DelayReplicaRole) -> void:
	super.configure_delay_replica(role)
	damage_enabled = role == DelayReplicaRole.AUTHORITY
	_apply_replica_permissions()
	_update_authority_groups()
	if role == DelayReplicaRole.PREVIEW:
		modulate = Color(0.45, 0.84, 1.0, 0.62)
	else:
		modulate = Color.WHITE


## 每个关卡实例可覆盖运动与检测范围，控制器生成的两个副本必须继承这些配置。
func copy_delay_configuration_to(replica: BaseActor) -> void:
	if not replica is FallingTrap:
		return
	var trap_replica: FallingTrap = replica as FallingTrap
	trap_replica.trigger_target_group = trigger_target_group
	trap_replica.trigger_collision_mask = trigger_collision_mask
	trap_replica.trigger_half_width = trigger_half_width
	trap_replica.trigger_depth = trigger_depth
	trap_replica.trigger_start_offset = trigger_start_offset
	trap_replica.gravity = gravity
	trap_replica.max_fall_speed = max_fall_speed
	trap_replica.return_speed = return_speed
	trap_replica.landed_hold_seconds = landed_hold_seconds
	trap_replica.damage = damage
	trap_replica.hit_stun_seconds = hit_stun_seconds
	trap_replica.knockback_distance = knockback_distance
	trap_replica.repeat_hit_seconds = repeat_hit_seconds
	trap_replica.damage_collision_mask = damage_collision_mask
	trap_replica.damage_target_groups = damage_target_groups.duplicate()
	trap_replica.reset_on_player_respawn = reset_on_player_respawn
	trap_replica._apply_trigger_configuration()
	trap_replica._apply_replica_permissions()


func reset_combat(_clear_statistics: bool = false) -> void:
	global_position = _home_global_position
	velocity = Vector2.ZERO
	_landed_time_left = 0.0
	_hit_cooldowns.clear()
	_set_state(TrapState.ARMED)
	reset_physics_interpolation()
	if delay_replica_role == DelayReplicaRole.AUTHORITY:
		notify_delay_body_reset()


func get_delay_ui_anchor_offset() -> Vector2:
	return Vector2(0.0, -54.0)


func get_delay_selection_rect() -> Rect2:
	return Rect2(Vector2(-58.0, -36.0), Vector2(116.0, 82.0))


func _has_trigger_target() -> bool:
	if trigger_area == null or not trigger_area.monitoring:
		return false
	for target: Node2D in trigger_area.get_overlapping_bodies():
		if target.is_in_group(trigger_target_group):
			return true
	return false


func _damage_overlapping_targets() -> void:
	if damage_area == null or not damage_area.monitoring:
		return
	for target: Node2D in damage_area.get_overlapping_bodies():
		if not _is_damage_target(target) or not target.has_method("receive_hit"):
			continue
		var instance_id: int = target.get_instance_id()
		if _hit_cooldowns.has(instance_id):
			continue
		var horizontal_direction: float = signf(target.global_position.x - global_position.x)
		if is_zero_approx(horizontal_direction):
			horizontal_direction = 1.0
		var impact_direction: Vector2 = Vector2(horizontal_direction, 0.65).normalized()
		var accepted: bool = bool(target.call("receive_hit", damage, self, 1, impact_direction))
		if not accepted:
			continue
		_hit_cooldowns[instance_id] = repeat_hit_seconds
		target_hit.emit(target, damage)


func _is_damage_target(target: Node) -> bool:
	for target_group: StringName in damage_target_groups:
		if target.is_in_group(target_group):
			return true
	return false


func _tick_hit_cooldowns(delta: float) -> void:
	for instance_id: int in _hit_cooldowns.keys():
		var time_left: float = maxf(float(_hit_cooldowns[instance_id]) - delta, 0.0)
		if time_left <= 0.0:
			_hit_cooldowns.erase(instance_id)
		else:
			_hit_cooldowns[instance_id] = time_left


func _set_state(new_state: TrapState) -> void:
	if current_state == new_state:
		_update_state_visuals()
		return
	current_state = new_state
	_update_state_visuals()
	state_changed.emit(current_state)


func _apply_trigger_configuration() -> void:
	if trigger_shape == null:
		return
	var rectangle: RectangleShape2D = trigger_shape.shape.duplicate() as RectangleShape2D
	if rectangle == null:
		rectangle = RectangleShape2D.new()
	rectangle.size = Vector2(trigger_half_width * 2.0, trigger_depth)
	trigger_shape.shape = rectangle
	trigger_shape.position = Vector2(0.0, trigger_start_offset + trigger_depth * 0.5)


func _apply_replica_permissions() -> void:
	if not is_node_ready():
		return
	var is_authority: bool = delay_replica_role == DelayReplicaRole.AUTHORITY
	# 真实陷阱是双向实体地形，角色从下方跳起也不能像单向平台一样穿过。
	collision_layer = 2 if is_authority else 0
	collision_mask = 2 # 三个副本都只与关卡地形做运动学碰撞。
	if base_collision != null:
		base_collision.one_way_collision = false
	var can_read_trigger: bool = delay_replica_role != DelayReplicaRole.PREDICTOR
	trigger_area.monitoring = can_read_trigger
	trigger_area.collision_mask = trigger_collision_mask if can_read_trigger else 0
	damage_area.monitoring = damage_enabled
	damage_area.collision_mask = damage_collision_mask if damage_enabled else 0


func _update_authority_groups() -> void:
	var is_authority: bool = delay_replica_role == DelayReplicaRole.AUTHORITY
	if is_authority:
		add_to_group("traps")
		add_to_group("falling_traps")
		if reset_on_player_respawn:
			add_to_group("player_respawn_reset")
		return
	remove_from_group("traps")
	remove_from_group("falling_traps")
	remove_from_group("player_respawn_reset")


func _update_state_visuals() -> void:
	if not is_node_ready():
		return
	match current_state:
		TrapState.ARMED:
			housing_visual.color = Color(0.34, 0.15, 0.18, 1.0)
			spike_visual.color = Color(0.96, 0.34, 0.29, 1.0)
		TrapState.FALLING:
			housing_visual.color = Color(0.50, 0.12, 0.12, 1.0)
			spike_visual.color = Color(1.0, 0.23, 0.18, 1.0)
		TrapState.LANDED:
			housing_visual.color = Color(0.62, 0.25, 0.08, 1.0)
			spike_visual.color = Color(1.0, 0.62, 0.16, 1.0)
		TrapState.RETURNING:
			housing_visual.color = Color(0.24, 0.28, 0.34, 1.0)
			spike_visual.color = Color(0.58, 0.67, 0.75, 1.0)
