class_name DelayableProjectile
extends BaseActor

signal expired(projectile: BaseActor)
## 手动测试器按需连接此信号；未连接时不会构造逐帧诊断数据。
signal diagnostic_event(projectile: BaseActor, event: Dictionary)

@export_group("Projectile")
## 发射瞬间的真实初速度，单位为像素/秒；可直接在 Inspector 修改，不再受 Move Speed 限制。
## Acceleration 大于 0 时，后续速度才会逐渐趋近继承属性 Move Speed。
@export_range(0.0, 4000.0, 10.0, "or_greater") var launch_speed: float = 240.0
## 弹体成功命中 Damage Target Group 时造成的基础伤害；蓄力倍率会在生成时乘到此值。
@export_range(0.0, 1000.0, 1.0) var damage: float = 12.0
## 弹体命中时提供的基础硬直；敌人弹默认保持原有约 0.20 秒手感。
@export_range(0.0, 3.0, 0.01) var hit_stun_seconds: float = 0.20
## 弹体命中时的基础水平击退距离；默认值对应玩家原有 280 初速度和 1200 减速度。
@export_range(0.0, 1000.0, 0.5) var knockback_distance: float = 32.7
## 弹体从发射到自动销毁的最长逻辑时间，单位为秒；延迟冻结期间寿命暂停。
@export_range(0.1, 20.0, 0.1) var lifetime_seconds: float = 4.0
## 0 表示只按寿命和碰撞销毁；大于 0 时累计飞行到该距离也会销毁。
@export_range(0.0, 10000.0, 10.0) var max_travel_distance: float = 0.0
## 默认关闭反弹；开启后也只对非伤害目标的物理表面生效。
@export var bounce_enabled: bool = false
## 开启反弹后允许的最大反弹次数；0 表示首次碰到非穿透表面就销毁。
@export_range(0, 10, 1) var max_bounces: int = 0
## 每次反弹后保留的速度比例；1 不损失速度，0.5 表示反弹后速度减半。
@export_range(0.0, 1.0, 0.05) var bounce_velocity_retention: float = 0.9
## 细长弹体只旋转图形和碰撞形状，保持根节点上的延迟文字水平可读。
@export var align_visual_to_travel: bool = false

@export_group("Targeting")
## 只有属于该组的碰撞对象才会尝试受伤；玩家弹通常填 enemy_damage_body，敌弹填 player_damage_body。
@export var damage_target_group: StringName = &"player_damage_body"
## 飞行碰撞会检测的伤害目标物理层；运行时还会额外加入地形层，不能只靠该掩码区分墙和目标。
@export_flags_2d_physics var damage_collision_mask: int = 1
## 真实有效弹体加入的统计组；发射器用同名组限制同屏数量，预览和预测副本不会加入。
@export var authority_projectile_group: StringName = &"hostile_projectiles"

@export_group("Future Penetration")
## 允许穿过的目标/表面数量；0 表示碰到首个目标或墙壁就消失。
## 只有下方物理层或组名允许的对象才会消耗一次穿透次数。
@export_range(0, 20, 1) var max_penetrations: int = 0
## 哪些物理层允许穿透；0 表示不通过物理层授权，仍可由 Penetration Target Groups 授权。
@export_flags_2d_physics var penetration_collision_mask: int = 0
## 哪些场景树组允许穿透；与 Penetration Collision Mask 任一匹配即可穿透。
@export var penetration_target_groups: Array[StringName] = []

@export_group("Charged Tier")
## 法杖一档弹体的射程倍率；以 Max Travel Distance 为基础，0 表示无限射程且不参与缩放。
@export_range(1.0, 5.0, 0.05) var charged_tier_one_distance_multiplier: float = 1.20
## 法杖二档弹体的射程倍率。
@export_range(1.0, 5.0, 0.05) var charged_tier_two_distance_multiplier: float = 1.50
## 法杖三档弹体的射程倍率。
@export_range(1.0, 5.0, 0.05) var charged_tier_three_distance_multiplier: float = 2.0
## 玩家法杖达到二档时保证的最少穿透次数；1 表示可穿过首个敌人后继续飞行。
@export_range(0, 20, 1) var charged_tier_two_penetrations: int = 1
## 玩家法杖达到三档时保证的最少穿透次数；只对目标组为 enemy_damage_body 的弹体生效。
## 0 可关闭三档自动穿透，不会覆盖场景中手动设置得更高的 Max Penetrations。
@export_range(0, 20, 1) var charged_tier_three_penetrations: int = 2

@export_group("Delay Selection")
## 思考时间中鼠标选中弹体所用方形区域的半尺寸，单位为像素；只影响选取，不改变碰撞或伤害范围。
@export_range(4.0, 128.0, 1.0) var delay_selection_radius: float = 18.0

var travel_direction: Vector2 = Vector2.RIGHT
var remaining_lifetime: float = 0.0
var traveled_distance: float = 0.0
var bounce_count: int = 0
var penetration_count: int = 0
var active: bool = false
var damage_enabled: bool = true
var attack_size_multiplier: float = 1.0

@onready var body_visual: Polygon2D = $BodyVisual
@onready var core_visual: Polygon2D = $CoreVisual


func _ready() -> void:
	_update_authority_groups()
	_apply_attack_size()
	_update_visual()


## 由受击者读取并乘以自身硬直倍率。
func get_hit_stun_seconds() -> float:
	return maxf(hit_stun_seconds, 0.0)


func get_knockback_distance() -> float:
	return maxf(knockback_distance, 0.0)


func launch(direction: Vector2) -> void:
	travel_direction = direction.normalized()
	if travel_direction.is_zero_approx():
		travel_direction = Vector2.RIGHT
	velocity = travel_direction * maxf(launch_speed, 0.0)
	remaining_lifetime = lifetime_seconds
	traveled_distance = 0.0
	bounce_count = 0
	penetration_count = 0
	active = true
	_apply_replica_collision_permissions()
	_update_travel_orientation()
	_update_authority_groups()
	_update_visual()
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	var command: Dictionary = capture_delay_command()
	simulate_delay_command(command, delta)


## 弹幕没有玩家或 AI 决策输入；每帧只记录“本帧是否继续推进”。
func capture_delay_command() -> Dictionary:
	return {"advance": active}


func simulate_delay_command(command: Dictionary, delta: float) -> void:
	if not active or not bool(command.get("advance", false)):
		return
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		_expire(&"lifetime")
		return
	var target_velocity: Vector2 = travel_direction * move_speed
	velocity = velocity.move_toward(target_velocity, acceleration * delta)
	var start_position: Vector2 = global_position
	var collision: KinematicCollision2D = move_and_collide(velocity * delta)
	traveled_distance += start_position.distance_to(global_position)
	if max_travel_distance > 0.0 and traveled_distance >= max_travel_distance:
		_expire(&"travel_distance")
		return
	if collision == null:
		return
	var collider: Object = collision.get_collider()
	if collider is Node and (collider as Node).is_in_group(damage_target_group):
		var target: Node = collider as Node
		var diagnostics_enabled: bool = not get_signal_connection_list(&"diagnostic_event").is_empty()
		var health_before: Variant = null
		var invulnerability_before: Variant = null
		var could_receive_before: Variant = null
		if diagnostics_enabled:
			health_before = _get_optional_diagnostic_property(target, &"current_health")
			invulnerability_before = _get_optional_diagnostic_property(
				target, &"_hurt_invulnerability_left")
			if target.has_method("can_receive_hit"):
				could_receive_before = bool(target.call("can_receive_hit"))
		var damage_accepted: bool = false
		if target.has_method("receive_hit") and damage_enabled:
			damage_accepted = bool(target.call("receive_hit", damage, self, 1, travel_direction))
		var did_penetrate: bool = _try_penetrate(target)
		if diagnostics_enabled:
			_emit_collision_diagnostic(collision, start_position, target, {
				"outcome": &"penetrate" if did_penetrate else &"expire_on_target",
				"damage_attempted": target.has_method("receive_hit") and damage_enabled,
				"damage_accepted": damage_accepted,
				"target_health_before": health_before,
				"target_health_after": _get_optional_diagnostic_property(target, &"current_health"),
				"target_invulnerability_before": invulnerability_before,
				"target_invulnerability_after": _get_optional_diagnostic_property(
					target, &"_hurt_invulnerability_left"),
				"target_could_receive_before": could_receive_before,
			})
		if did_penetrate:
			return
		_expire(&"target_collision")
		return
	if collider is Node:
		var surface: Node = collider as Node
		var did_penetrate: bool = _try_penetrate(surface)
		var outcome: StringName = &"penetrate" if did_penetrate else (
			&"bounce" if bounce_enabled and max_bounces > 0 else &"expire_on_surface"
		)
		_emit_collision_diagnostic(collision, start_position, surface, {
			"outcome": outcome,
			"damage_attempted": false,
			"damage_accepted": false,
		})
		if did_penetrate:
			return
	if bounce_enabled and max_bounces > 0:
		_bounce_from_surface(collision.get_normal())
	else:
		_expire(&"surface_collision")


## 发射器在节点进入场景树前配置；速度、伤害、图形和碰撞共同缩放。
func configure_attack_modifiers(speed_multiplier: float, damage_multiplier: float,
		size_multiplier: float) -> void:
	launch_speed *= maxf(speed_multiplier, 0.01)
	move_speed *= maxf(speed_multiplier, 0.01)
	damage *= maxf(damage_multiplier, 0.0)
	attack_size_multiplier = maxf(size_multiplier, 0.1)
	_apply_attack_size()


## 法杖每档增加射程，二档穿透一次、三档穿透两次；其他阵营弹体保持原配置。
func configure_charge_tier(charge_tier: int) -> void:
	if charge_tier <= 0 or damage_target_group != &"enemy_damage_body":
		return
	var resolved_tier: int = clampi(charge_tier, 1, 3)
	var distance_multiplier: float = 1.0
	var penetration_allowance: int = 0
	match resolved_tier:
		1:
			distance_multiplier = charged_tier_one_distance_multiplier
		2:
			distance_multiplier = charged_tier_two_distance_multiplier
			penetration_allowance = charged_tier_two_penetrations
		3:
			distance_multiplier = charged_tier_three_distance_multiplier
			penetration_allowance = charged_tier_three_penetrations
	if max_travel_distance > 0.0:
		max_travel_distance *= distance_multiplier
	if penetration_allowance <= 0:
		return
	max_penetrations = maxi(max_penetrations, penetration_allowance)
	if not penetration_target_groups.has(damage_target_group):
		penetration_target_groups.append(damage_target_group)


func _try_penetrate(target: Node) -> bool:
	if penetration_count >= max_penetrations:
		return false
	var allowed: bool = false
	if target is CollisionObject2D and penetration_collision_mask != 0:
		allowed = ((target as CollisionObject2D).collision_layer & penetration_collision_mask) != 0
	if not allowed:
		for group_name: StringName in penetration_target_groups:
			if target.is_in_group(group_name):
				allowed = true
				break
	if not allowed:
		return false
	penetration_count += 1
	if target is PhysicsBody2D:
		add_collision_exception_with(target as PhysicsBody2D)
	return true


func _bounce_from_surface(surface_normal: Vector2) -> void:
	bounce_count += 1
	if bounce_count > max_bounces:
		_expire(&"bounce_limit")
		return
	velocity = velocity.bounce(surface_normal) * bounce_velocity_retention
	if velocity.is_zero_approx():
		_expire(&"bounce_stopped")
		return
	travel_direction = velocity.normalized()
	_update_travel_orientation()


## 延迟刚开启、历史尚未填满时，本体停在原处；预览体继续展示未来弹道。
func tick_delay_waiting(_delta: float) -> void:
	pass


func get_delay_waiting_deceleration() -> float:
	return 0.0


func get_delay_selection_rect() -> Rect2:
	return Rect2(Vector2.ONE * -delay_selection_radius,
		Vector2.ONE * delay_selection_radius * 2.0)


func capture_simulation_state() -> Dictionary:
	return {
		"travel_direction": travel_direction,
		"remaining_lifetime": remaining_lifetime,
		"traveled_distance": traveled_distance,
		"bounce_count": bounce_count,
		"penetration_count": penetration_count,
		"max_penetrations": max_penetrations,
		"penetration_target_groups": penetration_target_groups.duplicate(),
		"active": active,
		"launch_speed": launch_speed,
		"move_speed": move_speed,
		"max_travel_distance": max_travel_distance,
		"damage": damage,
		"attack_size_multiplier": attack_size_multiplier,
	}


func restore_simulation_state(state: Dictionary) -> void:
	travel_direction = state.get("travel_direction", travel_direction) as Vector2
	remaining_lifetime = float(state.get("remaining_lifetime", remaining_lifetime))
	traveled_distance = float(state.get("traveled_distance", traveled_distance))
	bounce_count = int(state.get("bounce_count", bounce_count))
	penetration_count = int(state.get("penetration_count", penetration_count))
	max_penetrations = int(state.get("max_penetrations", max_penetrations))
	if state.has("penetration_target_groups"):
		penetration_target_groups.clear()
		var restored_penetration_groups: Array = state["penetration_target_groups"] as Array
		for group_name: Variant in restored_penetration_groups:
			penetration_target_groups.append(StringName(group_name))
	active = bool(state.get("active", active))
	launch_speed = float(state.get("launch_speed", launch_speed))
	move_speed = float(state.get("move_speed", move_speed))
	max_travel_distance = float(state.get("max_travel_distance", max_travel_distance))
	damage = float(state.get("damage", damage))
	attack_size_multiplier = float(state.get("attack_size_multiplier", attack_size_multiplier))
	_apply_attack_size()
	_apply_replica_collision_permissions()
	_update_travel_orientation()
	_update_authority_groups()
	_update_visual()


func configure_delay_replica(role: DelayReplicaRole) -> void:
	super.configure_delay_replica(role)
	damage_enabled = role == DelayReplicaRole.AUTHORITY
	# 轮次清理和玩法统计只追踪真实弹幕；预览体、预测体只是控制器内部副本。
	_update_authority_groups()
	_apply_replica_collision_permissions()
	if role == DelayReplicaRole.PREVIEW:
		modulate = Color(0.45, 0.84, 1.0, 0.62)
	elif role == DelayReplicaRole.AUTHORITY:
		modulate = Color.WHITE


func is_active() -> bool:
	return active


func _apply_replica_collision_permissions() -> void:
	if not active:
		collision_layer = 0
		collision_mask = 0
		return
	if delay_replica_role == DelayReplicaRole.AUTHORITY:
		collision_layer = 8
		collision_mask = damage_collision_mask | 2 # 目标阵营层 + 第二层地形。
	else:
		collision_layer = 0
		collision_mask = 2 # 预览与预测只模拟静态地形，绝不接触玩家。


func _expire(reason: StringName = &"unknown") -> void:
	if not active:
		return
	_emit_diagnostic_event(&"expire", {
		"reason": reason,
	})
	active = false
	velocity = Vector2.ZERO
	_apply_replica_collision_permissions()
	_update_authority_groups()
	_update_visual()
	if delay_replica_role == DelayReplicaRole.AUTHORITY:
		expired.emit(self)
		queue_free()


## 只在手动诊断器连接后整理碰撞现场，避免正式运行产生无意义的字典分配。
func _emit_collision_diagnostic(
	collision: KinematicCollision2D,
	start_position: Vector2,
	collider: Node,
	details: Dictionary
) -> void:
	if get_signal_connection_list(&"diagnostic_event").is_empty():
		return
	var event: Dictionary = details.duplicate()
	event["start_position"] = start_position
	event["collision_position"] = collision.get_position()
	event["collision_normal"] = collision.get_normal()
	event["collision_travel"] = collision.get_travel()
	event["collision_remainder"] = collision.get_remainder()
	event["collider_path"] = str(collider.get_path()) if collider.is_inside_tree() else str(collider.name)
	event["collider_class"] = collider.get_class()
	event["collider_groups"] = collider.get_groups()
	if collider is CollisionObject2D:
		event["collider_collision_layer"] = (collider as CollisionObject2D).collision_layer
		event["collider_collision_mask"] = (collider as CollisionObject2D).collision_mask
	_emit_diagnostic_event(&"collision", event)


## 玩家和敌人的受伤状态字段不同；诊断缺失字段返回 null，不得阻断共享弹体伤害。
func _get_optional_diagnostic_property(target: Object, property_name: StringName) -> Variant:
	for property: Dictionary in target.get_property_list():
		if StringName(property.get("name", "")) == property_name:
			return target.get(property_name)
	return null


func _emit_diagnostic_event(event_type: StringName, details: Dictionary) -> void:
	if get_signal_connection_list(&"diagnostic_event").is_empty():
		return
	var event: Dictionary = details.duplicate()
	event["event_type"] = event_type
	event["projectile_id"] = get_instance_id()
	event["projectile_name"] = name
	event["position"] = global_position
	event["velocity"] = velocity
	event["travel_direction"] = travel_direction
	event["remaining_lifetime"] = remaining_lifetime
	event["damage"] = damage
	event["damage_enabled"] = damage_enabled
	event["replica_role"] = int(delay_replica_role)
	event["collision_layer"] = collision_layer
	event["collision_mask"] = collision_mask
	event["bounce_count"] = bounce_count
	event["penetration_count"] = penetration_count
	diagnostic_event.emit(self, event)


func _update_authority_groups() -> void:
	var is_live_authority: bool = active and delay_replica_role == DelayReplicaRole.AUTHORITY
	if is_live_authority:
		if authority_projectile_group != &"":
			add_to_group(authority_projectile_group)
		add_to_group("round_projectiles")
	else:
		if authority_projectile_group != &"":
			remove_from_group(authority_projectile_group)
		remove_from_group("round_projectiles")


func _update_travel_orientation() -> void:
	if not align_visual_to_travel or not is_node_ready():
		return
	var travel_angle: float = travel_direction.angle()
	body_visual.rotation = travel_angle
	core_visual.rotation = travel_angle
	if base_collision != null:
		base_collision.rotation = travel_angle + PI * 0.5


func _update_visual() -> void:
	if not is_node_ready():
		return
	body_visual.visible = active
	core_visual.visible = active


func _apply_attack_size() -> void:
	if not is_node_ready():
		return
	var resolved_scale: Vector2 = Vector2.ONE * attack_size_multiplier
	body_visual.scale = resolved_scale
	core_visual.scale = resolved_scale
	if base_collision != null:
		base_collision.scale = resolved_scale
