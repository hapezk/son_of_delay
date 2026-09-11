class_name StraightShotLauncher
extends "res://scenes/combat/delay_weapon_launcher_base.gd"

## 法杖直线弹适配器；行为参数由场景配置，公共发射流程由基类实现。

@export_group("Staff")
## 法杖从玩家中心到杖头的长度，单位为像素；同时决定近身接触判定的长度。
@export_range(16.0, 96.0, 1.0) var staff_length: float = 46.0
## 法杖程序图形和近身矩形判定的宽度，单位为像素。
@export_range(2.0, 20.0, 1.0) var staff_width: float = 6.0
## 左键攻击时法杖从起始角扫到结束角所需的基础逻辑秒数；实际值会除以最终攻速。
@export_range(0.0, 0.3, 0.01) var swing_seconds: float = 0.10
## 法杖挥击相对鼠标瞄准方向的起始角度，单位为度；只影响攻击时的程序动画。
@export_range(-180.0, 180.0, 1.0) var swing_start_degrees: float = -24.0
## 法杖挥击相对鼠标瞄准方向的结束角度，单位为度；起止差决定挥击弧度和方向。
@export_range(-180.0, 180.0, 1.0) var swing_end_degrees: float = 19.5
## 杖身近战矩形查询检查的物理层；通常应指向敌人受击身体所在层。
@export_flags_2d_physics var contact_collision_mask: int = 4
## 近战矩形碰到的对象还必须属于该组才算有效目标，用来排除地形和预览体。
@export var contact_target_group: StringName = &"enemy_damage_body"
## 杖身直接碰到敌人时造成的基础伤害；成功命中后不会再生成法术弹。
## 蓄力近战命中时，该值还会乘当前蓄力伤害倍率。
@export_range(1.0, 1000.0, 1.0) var contact_damage: float = 14.0
## 杖身直接命中时的基础硬直；法术弹体的硬直在弹体场景中单独配置。
@export_range(0.0, 3.0, 0.01) var contact_hit_stun_seconds: float = 0.16
## 杖身近战直接命中时的基础水平击退距离。
@export_range(0.0, 1000.0, 0.5) var contact_knockback_distance: float = 16.2

@export_group("Staff Visual")
## 普通持杖和普通挥击时的杖身颜色。
@export var staff_color: Color = Color("9a6b48")
## 进入蓄力模式后杖身使用的颜色。
@export var charged_staff_color: Color = Color("ffe575")
## 普通状态下杖头魔力球的颜色。
@export var magic_color: Color = Color("65e7ff")
## 蓄力状态下杖头魔力球和进度圆环的基准颜色。
@export var charged_magic_color: Color = Color("fff2a3")
## 杖头魔力球半径相对 Staff Width 的倍率。
@export_range(0.1, 5.0, 0.1) var tip_radius_multiplier: float = 1.4
## 第一圈蓄力圆环半径相对 Staff Width 的倍率。
@export_range(0.1, 10.0, 0.1) var charge_ring_base_multiplier: float = 2.4
## 后续每一档圆环在基础半径上增加的 Staff Width 倍数。
@export_range(0.0, 5.0, 0.05) var charge_ring_spacing_multiplier: float = 1.15

var _swing_left: float = 0.0
var _staff_shape: RectangleShape2D = RectangleShape2D.new()
var _staff_query: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()


func _ready() -> void:
	_staff_query.shape = _staff_shape
	_staff_query.collision_mask = contact_collision_mask
	_staff_query.collide_with_areas = true
	_staff_query.collide_with_bodies = true


## 仅用于法杖近身挥击；弹体会把自己作为伤害来源并返回自己的硬直值。
func get_hit_stun_seconds() -> float:
	return maxf(contact_hit_stun_seconds, 0.0)


func get_knockback_distance() -> float:
	return maxf(contact_knockback_distance, 0.0)


func tick(launch_requested: bool, aim_direction: Vector2, advance_time: bool,
		delta: float, charged: bool = false, charge_damage_multiplier: float = 1.0,
		charge_tier: int = 0) -> void:
	if advance_time:
		_swing_left = maxf(_swing_left - delta, 0.0)
	super.tick(launch_requested, aim_direction, advance_time, delta, charged,
		charge_damage_multiplier, charge_tier)
	queue_redraw()


## 杖身矩形就是近战判定矩形；命中时直接结算法术伤害，并跳过弹体生成。
func _perform_launch(aim_direction: Vector2, charged: bool,
		charge_damage_multiplier: float, charge_tier: int) -> void:
	var direction: Vector2 = aim_direction.normalized()
	if direction.is_zero_approx():
		direction = Vector2.RIGHT
	pose_aim_direction = direction
	_swing_left = get_scaled_swing_seconds()
	if _replica_role == BaseActor.DelayReplicaRole.AUTHORITY \
			and _try_staff_contact(direction, charged, charge_damage_multiplier, charge_tier):
		return
	_spawn_projectile(direction, charged, charge_damage_multiplier, charge_tier)


func _try_staff_contact(direction: Vector2, charged: bool,
		charge_damage_multiplier: float, charge_tier: int) -> bool:
	var reach_multiplier: float = 1.0
	if charged and charge_tier >= 2:
		reach_multiplier = charged_size_multiplier \
			if charge_tier >= 3 else charged_tier_two_size_multiplier
	var resolved_length: float = staff_length * reach_multiplier
	var resolved_width: float = staff_width * reach_multiplier
	_staff_shape.size = Vector2(resolved_length, resolved_width)
	var center: Vector2 = global_position + direction * resolved_length * 0.5
	_staff_query.transform = Transform2D(direction.angle(), center)
	for hit: Dictionary in get_world_2d().direct_space_state.intersect_shape(_staff_query, 16):
		var target: Node = hit.get("collider") as Node
		if target == null or not target.is_in_group(contact_target_group) \
				or not target.has_method("receive_hit"):
			continue
		var resolved_damage: float = contact_damage * (charge_damage_multiplier if charged else 1.0)
		if bool(target.call("receive_hit", resolved_damage, self, 4 if charged else 1, direction)):
			return true
	return false


func capture_state() -> Dictionary:
	var state: Dictionary = super.capture_state()
	state["swing_left"] = _swing_left
	return state


func restore_state(state: Dictionary) -> void:
	super.restore_state(state)
	_swing_left = float(state.get("swing_left", 0.0))
	queue_redraw()


func reset_state() -> void:
	super.reset_state()
	_swing_left = 0.0


## 法杖挥击和实际发射冷却读取同一攻击速度，避免数值变快但画面仍拖沓。
func get_scaled_swing_seconds() -> float:
	return swing_seconds / get_attack_speed_multiplier()


func _draw() -> void:
	if not weapon_equipped:
		return
	var direction: Vector2 = pose_aim_direction.normalized()
	var swing_progress: float = 1.0 - _swing_left / maxf(get_scaled_swing_seconds(), 0.001)
	var swing_angle: float = lerpf(deg_to_rad(swing_start_degrees),
		deg_to_rad(swing_end_degrees), clampf(swing_progress, 0.0, 1.0)) \
		if _swing_left > 0.0 else 0.0
	direction = direction.rotated(swing_angle)
	var tip: Vector2 = direction * staff_length
	var normal: Vector2 = direction.orthogonal() * staff_width * 0.5
	var color: Color = charged_staff_color if charge_pose_active else staff_color
	draw_colored_polygon(PackedVector2Array([normal, tip + normal, tip - normal, -normal]), color)
	draw_circle(tip, staff_width * tip_radius_multiplier,
		charged_magic_color if charge_pose_active else magic_color)
	if charge_pose_active:
		for tier_index: int in range(3):
			var radius: float = staff_width * (charge_ring_base_multiplier
				+ tier_index * charge_ring_spacing_multiplier)
			var tier_progress: float = clampf(charge_pose_seconds - float(tier_index), 0.0, 1.0)
			draw_arc(tip, radius, -PI, PI, 20, Color(1.0, 0.9, 0.35, 0.18), 1.0, true)
			if tier_progress > 0.0:
				draw_arc(tip, radius, -PI * 0.5, -PI * 0.5 + TAU * tier_progress,
					20, Color(1.0, 0.9, 0.35, 0.78), 2.0, true)
