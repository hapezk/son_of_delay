class_name DelayableBoomerang
extends BaseActor

signal expired(boomerang: BaseActor)

enum TravelPhase { OUTBOUND, RETURNING, INACTIVE }
## 当前程序图形和场景碰撞圆都是以 20 像素为基础半径制作。
const BASE_VISUAL_RADIUS: float = 20.0

@export_group("Flight")
## 去程基础飞行速度，单位为世界像素/逻辑秒；蓄力弹速倍率会在生成时继续乘到此值。
@export_range(20.0, 2000.0, 10.0) var flight_speed: float = 650.0
## 去程累计飞行达到该距离后开始返航，单位为世界像素；撞到地形也会提前返航。
@export_range(20.0, 1600.0, 10.0) var max_distance: float = 520.0
## 从投出到强制销毁允许存在的最长逻辑时间，单位为秒；去程和返程共用这段寿命。
@export_range(0.1, 20.0, 0.1) var lifetime_seconds: float = 6.0
## 返程时回旋镖中心进入玩家多近就算接住并销毁，单位为世界像素。
@export_range(8.0, 128.0, 1.0) var catch_radius: float = 34.0
## 程序图形每逻辑秒旋转的弧度；绝对值越大转得越快，负数会反向旋转。
@export_range(-50.0, 50.0, 0.5) var spin_speed: float = 26.0
## 返程速度相对 Flight Speed 的倍率；1 表示往返同速，2 表示返程速度翻倍。
@export_range(0.1, 5.0, 0.05) var return_speed_multiplier: float = 1.0

@export_group("Damage")
## 每次伤害脉冲对范围内每个目标造成的基础伤害；蓄力伤害倍率会在生成时继续乘到此值。
@export_range(1.0, 1000.0, 1.0) var damage: float = 4.0
## 外缘图形半径与伤害半径共用此值，升级范围时不会出现“空气命中”。
@export_range(8.0, 160.0, 1.0) var damage_radius: float = 20.0
## 两次范围伤害脉冲之间的逻辑秒数；越小，同一目标受到伤害的频率越高。
## 回旋镖被延迟冻结时仍按此间隔结算，因此可形成持续伤害点。
@export_range(0.02, 2.0, 0.01) var damage_interval_seconds: float = 0.06
## 每次伤害脉冲提供的基础硬直秒数；最终值还会乘目标的 Hurt Stun Multiplier。
## 若小于 Damage Interval Seconds，敌人可能在两次脉冲之间恢复行动。
@export_range(0.0, 3.0, 0.01) var hit_stun_seconds: float = 0.16
## 每次伤害脉冲的基础水平击退距离，单位为世界像素；最终值还会乘目标的击退倍率。
## 设为 0 可保留伤害和硬直，但不产生水平击退。
@export_range(0.0, 1000.0, 0.5) var knockback_distance: float = 16.2

@export_group("Targeting")
## 去程可碰撞的地形物理层；命中这些层会提前转入返程，返程阶段会忽略地形。
@export_flags_2d_physics var terrain_collision_mask: int = 2
## 范围伤害查询会检查的物理层；通常应指向敌人受击身体所在层。
@export_flags_2d_physics var damage_collision_mask: int = 4
## 只有同时属于该组的碰撞对象才会受到回旋镖伤害，用于区分敌我和排除预览体。
@export var damage_target_group: StringName = &"enemy_damage_body"
## 返程追踪并执行接取判定的目标组；正常情况下是权威玩家身体组。
@export var return_target_group: StringName = &"player_damage_body"
## 真实有效回旋镖加入的统计组；发射器依靠同名组执行同屏数量上限。
@export var authority_projectile_group: StringName = &"player_boomerangs"

@export_group("Charged Tiers")
## 一档蓄力时 Max Distance 的倍率；零档不乘倍率。
@export_range(1.0, 3.0, 0.05) var charged_tier_one_distance_multiplier: float = 1.20
## 二档蓄力时 Max Distance 的倍率；它是直接使用的最终倍率，不会再乘一档值。
@export_range(1.0, 3.0, 0.05) var charged_tier_two_distance_multiplier: float = 1.45
## 三档蓄力时 Max Distance 的最终倍率；它不会与前两档倍率叠乘。
@export_range(1.0, 3.0, 0.05) var charged_tier_three_distance_multiplier: float = 1.75
## 三档蓄力时 Damage Interval Seconds 的倍率；小于 1 会提高伤害脉冲频率。
@export_range(0.1, 1.0, 0.05) var charged_tier_three_interval_multiplier: float = 0.65

@export_group("Rotating Trail")
## 是否绘制随回旋镖旋转的程序化拖尾；只影响显示，不影响伤害判定。
@export var trail_enabled: bool = true
## 拖尾起始透明度；越接近 1 越明显，尾端仍会按段数逐渐淡出。
@export_range(0.0, 1.0, 0.05) var trail_opacity: float = 0.42
## 拖尾线条宽度，单位为像素。
@export_range(1.0, 20.0, 0.5) var trail_width: float = 4.0
## 拖尾覆盖的旋转弧长，单位为弧度；数值越大，尾巴绕中心延伸得越长。
@export_range(0.2, 4.0, 0.1) var trail_arc_radians: float = 1.5
## 拖尾弧线的采样段数；越高越平滑，也会略增加绘制开销。
@export_range(4, 48, 1) var trail_segments: int = 18
## 拖尾使用的基础颜色，最终透明度还会乘 Trail Opacity 和分段渐隐。
@export var trail_color: Color = Color(0.22, 1.0, 0.82, 1.0)

var travel_phase: TravelPhase = TravelPhase.INACTIVE
var travel_direction: Vector2 = Vector2.RIGHT
var traveled_distance: float = 0.0
var remaining_lifetime: float = 0.0
var damage_tick_left: float = 0.0
var active: bool = false
var damage_enabled: bool = true
var attack_size_multiplier: float = 1.0

var _damage_shape: CircleShape2D = CircleShape2D.new()
var _damage_query: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()

@onready var body_visual: Polygon2D = $BodyVisual
@onready var core_visual: Polygon2D = $CoreVisual


func _ready() -> void:
	_damage_shape.radius = damage_radius
	_damage_query.shape = _damage_shape
	_damage_query.collision_mask = damage_collision_mask
	_damage_query.collide_with_areas = false
	_damage_query.collide_with_bodies = true
	_apply_attack_size()
	_apply_replica_permissions()
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
	travel_phase = TravelPhase.OUTBOUND
	traveled_distance = 0.0
	remaining_lifetime = lifetime_seconds
	damage_tick_left = 0.0
	active = true
	velocity = travel_direction * flight_speed
	_apply_replica_permissions()
	_update_authority_groups()
	_update_visual()
	reset_physics_interpolation()


## 蓄力与升级统一修改速度、伤害及“图形=伤害范围”的尺寸参数。
func configure_attack_modifiers(speed_multiplier: float, damage_multiplier: float,
		size_multiplier: float) -> void:
	flight_speed *= maxf(speed_multiplier, 0.01)
	move_speed *= maxf(speed_multiplier, 0.01)
	damage *= maxf(damage_multiplier, 0.0)
	attack_size_multiplier = maxf(size_multiplier, 0.1)
	_apply_attack_size()


func configure_charge_tier(charge_tier: int) -> void:
	match clampi(charge_tier, 0, 3):
		1: max_distance *= charged_tier_one_distance_multiplier
		2: max_distance *= charged_tier_two_distance_multiplier
		3:
			max_distance *= charged_tier_three_distance_multiplier
			damage_interval_seconds *= charged_tier_three_interval_multiplier


func _physics_process(delta: float) -> void:
	var command: Dictionary = capture_delay_command()
	simulate_delay_command(command, delta)


## 返回阶段把“朝玩家的方向”和“是否接住”先解析进命令，回放时不读取未来玩家位置。
func capture_delay_command() -> Dictionary:
	var resolved_direction: Vector2 = travel_direction
	var should_catch: bool = false
	if active and travel_phase == TravelPhase.RETURNING:
		var target_position: Vector2 = _get_return_target_position()
		var to_target: Vector2 = target_position - global_position
		should_catch = to_target.length() <= catch_radius
		if not to_target.is_zero_approx():
			resolved_direction = to_target.normalized()
	return {
		"advance": active,
		"move_direction": resolved_direction,
		"should_catch": should_catch,
	}


func simulate_delay_command(command: Dictionary, delta: float) -> void:
	if not active or not bool(command.get("advance", false)):
		return
	if travel_phase == TravelPhase.RETURNING and bool(command.get("should_catch", false)):
		_expire()
		return
	remaining_lifetime = maxf(remaining_lifetime - delta, 0.0)
	if remaining_lifetime <= 0.0:
		_expire()
		return

	var resolved_direction: Vector2 = command.get("move_direction", travel_direction) as Vector2
	if not resolved_direction.is_zero_approx():
		travel_direction = resolved_direction.normalized()
	var resolved_speed: float = flight_speed * return_speed_multiplier \
		if travel_phase == TravelPhase.RETURNING else flight_speed
	velocity = travel_direction * resolved_speed
	var start_position: Vector2 = global_position
	var collision: KinematicCollision2D = move_and_collide(velocity * delta)
	_spin_visuals(delta)
	if travel_phase == TravelPhase.OUTBOUND:
		traveled_distance += start_position.distance_to(global_position)
		if collision != null or traveled_distance >= max_distance:
			travel_phase = TravelPhase.RETURNING
			_apply_replica_permissions()
	_tick_damage(delta)


## 填充延迟历史时不推进飞行与寿命，但真实本体继续在冻结点脉冲伤害。
func tick_delay_waiting(delta: float) -> void:
	if not active:
		return
	_spin_visuals(delta)
	_tick_damage(delta)


func get_delay_waiting_deceleration() -> float:
	return 0.0


func get_delay_selection_rect() -> Rect2:
	var extent: float = damage_radius * attack_size_multiplier
	return Rect2(Vector2(-extent, -extent), Vector2.ONE * extent * 2.0)


func capture_simulation_state() -> Dictionary:
	return {
		"travel_phase": travel_phase,
		"travel_direction": travel_direction,
		"traveled_distance": traveled_distance,
		"remaining_lifetime": remaining_lifetime,
		"damage_tick_left": damage_tick_left,
		"active": active,
		"flight_speed": flight_speed,
		"max_distance": max_distance,
		"move_speed": move_speed,
		"damage": damage,
		"damage_interval_seconds": damage_interval_seconds,
		"attack_size_multiplier": attack_size_multiplier,
	}


func restore_simulation_state(state: Dictionary) -> void:
	travel_phase = int(state.get("travel_phase", travel_phase)) as TravelPhase
	travel_direction = state.get("travel_direction", travel_direction) as Vector2
	traveled_distance = float(state.get("traveled_distance", traveled_distance))
	remaining_lifetime = float(state.get("remaining_lifetime", remaining_lifetime))
	damage_tick_left = float(state.get("damage_tick_left", damage_tick_left))
	active = bool(state.get("active", active))
	flight_speed = float(state.get("flight_speed", flight_speed))
	max_distance = float(state.get("max_distance", max_distance))
	move_speed = float(state.get("move_speed", move_speed))
	damage = float(state.get("damage", damage))
	damage_interval_seconds = float(state.get("damage_interval_seconds", damage_interval_seconds))
	attack_size_multiplier = float(state.get("attack_size_multiplier", attack_size_multiplier))
	_apply_attack_size()
	_apply_replica_permissions()
	_update_authority_groups()
	_update_visual()


func configure_delay_replica(role: DelayReplicaRole) -> void:
	super.configure_delay_replica(role)
	damage_enabled = role == DelayReplicaRole.AUTHORITY
	_apply_replica_permissions()
	_update_authority_groups()
	if role == DelayReplicaRole.PREVIEW:
		modulate = Color(0.45, 0.84, 1.0, 0.62)
	elif role == DelayReplicaRole.AUTHORITY:
		modulate = Color.WHITE


func is_active() -> bool:
	return active


func _get_return_target_position() -> Vector2:
	var target: Node = get_tree().get_first_node_in_group(return_target_group)
	return (target as Node2D).global_position if target is Node2D else global_position


func _tick_damage(delta: float) -> void:
	if not damage_enabled or delay_replica_role != DelayReplicaRole.AUTHORITY:
		return
	damage_tick_left -= delta
	while damage_tick_left <= 0.0 and active:
		_apply_damage_pulse()
		damage_tick_left += maxf(damage_interval_seconds, 0.01)


## 只旋转图形，不旋转角色根节点；中央的延迟文字因此始终保持水平可读。
func _spin_visuals(delta: float) -> void:
	body_visual.rotation += spin_speed * delta
	core_visual.rotation += spin_speed * delta
	queue_redraw()


func _apply_damage_pulse() -> void:
	_damage_shape.radius = damage_radius * attack_size_multiplier
	_damage_query.transform = Transform2D(0.0, global_position)
	var hits: Array[Dictionary] = get_world_2d().direct_space_state.intersect_shape(_damage_query, 16)
	for hit: Dictionary in hits:
		var collider: Variant = hit.get("collider")
		if not (collider is Node) or not is_instance_valid(collider):
			continue
		var target: Node = collider as Node
		if target.is_in_group(damage_target_group) and target.has_method("receive_hit"):
			target.call("receive_hit", damage, self, 1, travel_direction)


func _apply_replica_permissions() -> void:
	if not active:
		collision_layer = 0
		collision_mask = 0
		return
	collision_layer = 8 if delay_replica_role == DelayReplicaRole.AUTHORITY else 0
	# 去程碰到地形便提前折返；回程穿过地形，避免被平台背面卡住。
	collision_mask = terrain_collision_mask if travel_phase == TravelPhase.OUTBOUND else 0


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


func _expire() -> void:
	if not active:
		return
	active = false
	travel_phase = TravelPhase.INACTIVE
	velocity = Vector2.ZERO
	_apply_replica_permissions()
	_update_authority_groups()
	_update_visual()
	if delay_replica_role == DelayReplicaRole.AUTHORITY:
		expired.emit(self)
		queue_free()


func _update_visual() -> void:
	if not is_node_ready():
		return
	body_visual.visible = active
	core_visual.visible = active
	queue_redraw()


func _apply_attack_size() -> void:
	_damage_shape.radius = damage_radius * attack_size_multiplier
	if not is_node_ready():
		return
	# Damage Radius 同时缩放图形、物理碰撞和伤害查询，保持所见即所得。
	var resolved_scale: Vector2 = Vector2.ONE \
		* attack_size_multiplier * damage_radius / BASE_VISUAL_RADIUS
	body_visual.scale = resolved_scale
	core_visual.scale = resolved_scale
	if base_collision != null:
		base_collision.scale = resolved_scale


## 程序化旋转残影跟随真实旋转角，不依赖额外贴图；参数可直接在 Inspector 调整。
func _draw() -> void:
	if not active or not trail_enabled:
		return
	var radius: float = damage_radius * attack_size_multiplier
	var end_angle: float = body_visual.rotation
	var start_angle: float = end_angle - signf(spin_speed) * trail_arc_radians
	for index: int in range(3):
		var offset: float = TAU * float(index) / 3.0
		draw_arc(
			Vector2.ZERO,
			radius * (0.72 + 0.12 * index),
			start_angle + offset,
			end_angle + offset,
			trail_segments,
			Color(trail_color, trail_opacity * (1.0 - 0.18 * index)),
			trail_width,
			true
		)
