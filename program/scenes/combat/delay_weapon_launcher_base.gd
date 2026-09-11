class_name DelayWeaponLauncherBase
extends Node2D

## 玩家携带式发射器的公共最小模型：三份玩家都演算冷却，只有真实本体生成实体。
const DEFAULT_COMBAT_TUNING: CombatTuning = preload("res://resources/combat_tuning.tres")

@export_group("Attack Timing")
## 当前远程武器自身的攻速倍率。最终攻速 = 此值 × Combat Tuning 的全局攻速。
## 它只压缩发射冷却和法杖挥击时间，不改变弹体飞行速度、寿命或伤害脉冲间隔。
@export_range(0.1, 5.0, 0.05) var attack_speed_multiplier: float = 1.0
## 普通攻击的基础发射冷却，单位为逻辑秒。
## 实际冷却 = 此值 × 蓄力冷却倍率（仅蓄力攻击）÷ 最终攻速。
@export_range(0.0, 3.0, 0.01) var cooldown_seconds: float = 0.35

@export_group("Projectile Spawn")
## 左键攻击时实例化的弹体场景；场景根节点必须继承 BaseActor 并实现 launch()。
@export var projectile_scene: PackedScene
## 弹体出生点沿鼠标瞄准方向离玩家中心的距离，单位为世界像素。
@export_range(0.0, 128.0, 1.0) var muzzle_distance: float = 34.0
## 同一武器允许同时存在的真实有效弹体数量；达到上限时本次攻击不会生成弹体。
## 延迟预览体和预测体不占数量，0 表示不限制。
@export_range(0, 128, 1) var max_active_projectiles: int = 1
## 用于统计当前有效弹体数量的场景树组名；应与弹体的 Authority Projectile Group 一致。
## 留空会跳过数量统计，相当于不受 Max Active Projectiles 限制。
@export var active_projectile_group: StringName = &""
## 新弹体加入的父容器组名；找不到该组时会回退到当前场景或场景树根节点。
@export var projectile_container_group: StringName = &"player_projectile_container"

@export_group("Charged Attack")
## 蓄力攻击相对普通攻击的冷却倍率。大于 1 表示蓄力攻击后需要更久才能再次攻击。
@export_range(0.1, 4.0, 0.05) var charged_cooldown_multiplier: float = 1.6
## 一档蓄力攻击使用的弹体速度倍率；零档仍为 1。
@export_range(0.1, 4.0, 0.05) var charged_tier_one_speed_multiplier: float = 1.15
## 二档蓄力攻击使用的弹体速度倍率；默认与旧版一档相同，已有武器不会被自动加速。
@export_range(0.1, 4.0, 0.05) var charged_tier_two_speed_multiplier: float = 1.15
## 三档蓄力攻击使用的弹体速度倍率；同时缩放弹体的初速度和目标飞行速度。
@export_range(0.1, 4.0, 0.05) var charged_speed_multiplier: float = 1.35
## 二档蓄力攻击使用的弹体/近战判定尺寸倍率；零、一档仍为 1。
@export_range(0.5, 3.0, 0.05) var charged_tier_two_size_multiplier: float = 1.15
## 三档蓄力攻击使用的最终尺寸倍率；图形和伤害判定会一起缩放。
@export_range(0.5, 3.0, 0.05) var charged_size_multiplier: float = 1.25

var cooldown_left: float = 0.0
var _replica_role: BaseActor.DelayReplicaRole = BaseActor.DelayReplicaRole.AUTHORITY
var weapon_equipped: bool = false
var charge_pose_active: bool = false
var pose_aim_direction: Vector2 = Vector2.RIGHT
var charge_pose_seconds: float = 0.0
var charge_pose_tier: int = 0
var _time_authority: WorldTimeAuthority


func configure_delay_replica(role: BaseActor.DelayReplicaRole) -> void:
	_replica_role = role


## 由玩家逻辑帧显式驱动；等待延迟历史期间，冷却不会脱离角色时间线自行流逝。
func tick(
	launch_requested: bool,
	aim_direction: Vector2,
	advance_time: bool,
	delta: float,
	charged: bool = false,
	charge_damage_multiplier: float = 1.0,
	charge_tier: int = 0
) -> void:
	if advance_time:
		cooldown_left = maxf(cooldown_left - delta, 0.0)
	if not launch_requested or cooldown_left > 0.0 or not _can_launch_another():
		return
	cooldown_left = get_attack_cooldown(charged)
	# 预览体与预测器只演算冷却；相同指令抵达真实 Body 时才生成权威弹体。
	if _replica_role != BaseActor.DelayReplicaRole.AUTHORITY:
		return
	_perform_launch(aim_direction, charged, charge_damage_multiplier, charge_tier)


## 子类可在生成前增加近战判定；返回后仍由公共冷却与三体权限管理。
func _perform_launch(aim_direction: Vector2, charged: bool,
		charge_damage_multiplier: float, charge_tier: int) -> void:
	_spawn_projectile(aim_direction, charged, charge_damage_multiplier, charge_tier)


func capture_state() -> Dictionary:
	return {"cooldown_left": cooldown_left}


func restore_state(state: Dictionary) -> void:
	cooldown_left = float(state.get("cooldown_left", cooldown_left))


func reset_state() -> void:
	cooldown_left = 0.0
	charge_pose_active = false
	charge_pose_seconds = 0.0
	charge_pose_tier = 0
	queue_redraw()


func set_weapon_pose(equipped: bool, charging: bool, aim_direction: Vector2,
		charge_seconds: float = 0.0, charge_tier: int = 0) -> void:
	weapon_equipped = equipped
	charge_pose_active = equipped and charging
	charge_pose_seconds = charge_seconds if charge_pose_active else 0.0
	charge_pose_tier = charge_tier if charge_pose_active else 0
	if not aim_direction.is_zero_approx():
		pose_aim_direction = aim_direction.normalized()
	visible = equipped
	queue_redraw()


func _can_launch_another() -> bool:
	if max_active_projectiles <= 0 or active_projectile_group == &"":
		return true
	var active_count: int = 0
	for node: Node in get_tree().get_nodes_in_group(active_projectile_group):
		if is_instance_valid(node) and not node.is_queued_for_deletion():
			active_count += 1
	return active_count < max_active_projectiles


## 统一攻击速度只压缩两种远程武器的发射冷却，不改变弹体本身的移动速度。
func get_attack_cooldown(charged: bool = false) -> float:
	var charge_multiplier: float = charged_cooldown_multiplier if charged else 1.0
	return cooldown_seconds * charge_multiplier / get_attack_speed_multiplier()


func get_attack_speed_multiplier() -> float:
	var global_attack_speed: float = get_combat_tuning().attack_speed_multiplier
	return maxf(attack_speed_multiplier * global_attack_speed, 0.01)


func get_combat_tuning() -> CombatTuning:
	if not is_instance_valid(_time_authority):
		_time_authority = get_tree().get_first_node_in_group("world_time_authority") \
			as WorldTimeAuthority
	return _time_authority.get_combat_tuning() \
		if _time_authority != null else DEFAULT_COMBAT_TUNING


func _spawn_projectile(aim_direction: Vector2, charged: bool = false,
		charge_damage_multiplier: float = 1.0, charge_tier: int = 0) -> void:
	if projectile_scene == null:
		push_error("DelayWeaponLauncherBase: projectile_scene is missing")
		return
	var direction: Vector2 = aim_direction.normalized()
	if direction.is_zero_approx():
		direction = Vector2.RIGHT
	var projectile: BaseActor = projectile_scene.instantiate() as BaseActor
	if projectile == null or not projectile.has_method("launch"):
		push_error("DelayWeaponLauncherBase: scene root must be a launchable BaseActor")
		if projectile != null:
			projectile.queue_free()
		return
	if projectile.has_method("configure_attack_modifiers"):
		var speed_multiplier: float = 1.0
		var size_multiplier: float = 1.0
		if charged and charge_tier >= 1:
			if charge_tier >= 3:
				speed_multiplier = charged_speed_multiplier
			elif charge_tier >= 2:
				speed_multiplier = charged_tier_two_speed_multiplier
			else:
				speed_multiplier = charged_tier_one_speed_multiplier
		if charged and charge_tier >= 2:
			size_multiplier = charged_size_multiplier \
				if charge_tier >= 3 else charged_tier_two_size_multiplier
		projectile.call(
			"configure_attack_modifiers",
			speed_multiplier,
			charge_damage_multiplier if charged else 1.0,
			size_multiplier
		)
	if charged and projectile.has_method("configure_charge_tier"):
		projectile.call("configure_charge_tier", charge_tier)
	var container: Node = get_tree().get_first_node_in_group(projectile_container_group)
	if container == null:
		container = get_tree().current_scene
	if container == null:
		container = get_tree().root
	container.add_child(projectile)
	projectile.global_position = global_position + direction * muzzle_distance
	projectile.call("launch", direction)
