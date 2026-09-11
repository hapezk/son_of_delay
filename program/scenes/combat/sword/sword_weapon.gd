class_name SwordWeapon
extends Node2D

## 三连斩仅由角色的有效逻辑帧推进，不使用独立 Timer 或实时动画计时。
enum Phase { IDLE, WINDUP, ACTIVE, RECOVERY, LINK }
const PHASE_NAMES: Array[StringName] = [&"idle", &"windup", &"active", &"recovery", &"link"]
const STAGE_NAMES: Array[String] = ["正斩", "反斩", "重劈"]
const PHASE_LABELS: Array[String] = ["", "起手", "生效", "收招", "可续击"]
const DEFAULT_TUNING: CombatTuning = preload("res://resources/combat_tuning.tres")

@export_category("Sword Balance")
@export_group("Attack Speed")
## 剑自身的攻速倍率。最终攻速 = 此值 × Combat Tuning 的全局攻速。
## 它会等比例压缩普通三段和蓄力斩的前摇、生效、收招帧数，但每个阶段至少保留 1 帧。
@export_range(0.1, 5.0, 0.05) var attack_speed_multiplier: float = 1.0

@export_group("Combo Timing")
## 普通三连斩每一段的前摇持续帧数，X/Y/Z 对应第一/第二/第三段。
## 前摇期间剑只播放起手动作，不产生伤害。单位为 100 TPS 下的逻辑帧，10 帧约等于 0.10 秒。
@export var combo_windup_frames: Vector3i = Vector3i(8, 10, 16)
## 普通三连斩每一段的伤害判定持续帧数，X/Y/Z 对应第一/第二/第三段。
## 生效期间每个逻辑帧都会扫掠剑经过的区域，但同一目标在同一段中最多受伤一次。
@export var combo_active_frames: Vector3i = Vector3i(6, 7, 10)
## 普通三连斩每一段的收招持续帧数，X/Y/Z 对应第一/第二/第三段。
## 收招期间不再造成伤害；已缓存的下一段会在收招结束后立即起手。
@export var combo_recovery_frames: Vector3i = Vector3i(16, 18, 30)
## 第一、二段收招结束后，仍可补按左键衔接下一段的宽限帧数。
## 若下一段已在前摇/生效/收招期间缓存，就不会等待此窗口；第三段和空中攻击也不会进入此窗口。
## 当前该窗口不随攻速倍率缩放。0 表示必须提前缓存下一段，否则连段立即结束。
@export_range(0, 120, 1) var combo_link_frames: int = 25

@export_group("Combo Damage And Reach")
## 普通三连斩每段的基础伤害，X/Y/Z 对应第一/第二/第三段；蓄力斩伤害不读取此值。
@export var combo_damages: Vector3 = Vector3(10.0, 12.0, 20.0)
## 普通第一、第二段的攻击半径，X/Y 分别对应两段，单位为世界像素。
## 实际判定不会超过可见剑身长度；第三段范围由 Combat Tuning 的 Heavy Reach 控制。
@export var light_reaches: Vector2 = Vector2(84.0, 94.0)
## 普通第一、第二段相对鼠标瞄准方向的起始角度，X/Y 分别对应两段，单位为度。
## 第三段起始角度由 Combat Tuning 的 Heavy Start Degrees 控制。
@export var light_start_degrees: Vector2 = Vector2(-68.75, 60.16)
## 普通第一、第二段相对鼠标瞄准方向的结束角度，X/Y 分别对应两段，单位为度。
## 起止角度的顺序决定挥砍方向；第三段读取 Combat Tuning 的 Heavy End Degrees。
@export var light_end_degrees: Vector2 = Vector2(60.16, -68.75)

@export_group("Hit Reaction")
## 普通三连斩给目标施加的基础硬直秒数，X/Y/Z 对应第一/第二/第三段。
## 最终硬直 = 此值 × 目标的 Hurt Stun Multiplier；它与命中顿帧 Hit Stop 是两套独立时间。
@export var combo_hit_stun_seconds: Vector3 = Vector3(0.16, 0.16, 0.16)
## 蓄力拔刀斩给目标施加的基础硬直秒数，不使用普通第三段的 Z 值。
@export_range(0.0, 3.0, 0.01) var charged_hit_stun_seconds: float = 0.16
## 普通三连斩的基础水平击退距离，X/Y/Z 对应第一/第二/第三段，单位为世界像素。
## 最终理想距离 = 此值 × 目标的 Knockback Received Multiplier；墙体和提前恢复会缩短实际位移。
@export var combo_knockback_distances: Vector3 = Vector3(16.2, 16.2, 16.2)
## 蓄力拔刀斩的基础水平击退距离，不使用普通第三段的 Z 值，单位为世界像素。
@export_range(0.0, 1000.0, 0.5) var charged_knockback_distance: float = 16.2

@export_group("Charged Slash")
## 松开蓄力并按左键释放后，拔刀斩的额外前摇持续帧数；蓄力等待时间不包含在这里。
## 单位为 100 TPS 逻辑帧，并受剑自身与全局攻速倍率缩放。
@export_range(1, 120, 1) var charged_windup_frames: int = 3
## 蓄力拔刀斩的伤害判定持续帧数；同一目标在一次拔刀斩中最多受伤一次。
@export_range(1, 120, 1) var charged_active_frames: int = 7
## 蓄力拔刀斩命中阶段结束后的收招持续帧数；收招结束后直接回到待机，不进入续段窗口。
@export_range(1, 120, 1) var charged_recovery_frames: int = 18
## 蓄力拔刀斩相对鼠标瞄准方向的起始角度，单位为度；画面和伤害判定共用此角度。
## 起始值大于结束值时会形成当前这种从下向上的逆向挑斩。
@export_range(-180.0, 180.0, 1.0) var charged_slash_start_degrees: float = 105.0
## 蓄力拔刀斩相对鼠标瞄准方向的结束角度，单位为度；与起始角度之差决定挥动弧度。
@export_range(-180.0, 180.0, 1.0) var charged_slash_end_degrees: float = -115.0

## 由 DelayedActorGroup 按角色身份配置；这些权限不属于可复制的武器状态。
var damage_enabled: bool = false
var preview_visual: bool = false
var phase: Phase = Phase.IDLE
var combo_index: int = 0
var frames_left: int = 0
var attack_facing: int = 1
## 每段起手时锁定的鼠标角度；攻击过程中移动鼠标不扭转已挥出的剑。
var aim_rotation: float = 0.0
var _queued_attack: bool = false
var _queued_facing: int = 1
var _queued_aim_rotation: float = 0.0
## 空中起手或离地后，本次第一段结束不开放续击；落地也不会恢复旧连段。
var _air_attack: bool = false
var _hit_targets: Dictionary = {}
## 一段攻击即使命中多个目标，也只触发一次顿帧和晃动。
var _feedback_sent: bool = false
var _charged_attack: bool = false
var _charge_pose_active: bool = false
var _charged_damage_multiplier: float = 1.0
var _charged_reach: float = 84.0
var _charged_tier: int = 0
var _charge_pose_seconds: float = 0.0
var _charge_pose_tier: int = 0
var _time_authority: WorldTimeAuthority
var _sweep_shape: ConvexPolygonShape2D = ConvexPolygonShape2D.new()
var _query: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()

@onready var visual: SwordVisual = $Visual
@onready var status_label: Label = $StatusLabel


func _ready() -> void:
	_query.shape = _sweep_shape
	_query.collision_mask = 4 # 第三层：受击区域。
	_query.collide_with_areas = true
	# 练习木桩升级为 CharacterBody2D 后仍使用相同的受击层。
	_query.collide_with_bodies = true
	_update_visual(false)



## 受击者会再乘自己的硬直倍率；这里仅返回本次剑攻击提供的基础值。
func get_hit_stun_seconds() -> float:
	if _charged_attack:
		return maxf(charged_hit_stun_seconds, 0.0)
	var stage_index: int = clampi(combo_index, 0, 2)
	return maxf(combo_hit_stun_seconds[stage_index], 0.0)


## 受击者会再乘自己的击退倍率，并结合自身减速度反算初速度。
func get_knockback_distance() -> float:
	if _charged_attack:
		return maxf(charged_knockback_distance, 0.0)
	var stage_index: int = clampi(combo_index, 0, 2)
	return maxf(combo_knockback_distances[stage_index], 0.0)


## 每个有效逻辑帧只调用一次；无历史帧时不计时、不续击、不结算命中。
func tick(
	pressed: bool,
	facing: int,
	advance: bool,
	grounded: bool = true,
	aim: float = 0.0,
	charged_pressed: bool = false,
	charge_pose: bool = false,
	charge_aim: Vector2 = Vector2.RIGHT,
	charge_seconds: float = 0.0,
	charge_damage_multiplier: float = 1.0,
	charge_tier: int = 0
) -> void:
	_charge_pose_active = charge_pose and not charged_pressed
	if _charge_pose_active:
		_charge_pose_seconds = charge_seconds
		_charge_pose_tier = charge_tier
		attack_facing = -1 if facing < 0 else 1
		aim_rotation = charge_aim.angle() - (PI if attack_facing < 0 else 0.0)
		_update_visual(not advance)
		return
	if not advance:
		_update_visual(true)
		return
	if not grounded and not _charged_attack:
		_queued_attack = false
		_air_attack = true
		# 离地打断后续段及续击窗口，防止跳起后继续执行地面重斩。
		if phase == Phase.LINK or combo_index > 0:
			phase = Phase.IDLE
			combo_index = 0
			frames_left = 0
	var started_next_stage: bool = false
	if phase != Phase.IDLE and frames_left <= 0:
		_advance_phase()
		# 由上一段的缓存进入新段时，当前 held 信号属于上一段，不能立即缓存再下一段。
		started_next_stage = phase == Phase.WINDUP
	if phase == Phase.IDLE:
		attack_facing = facing
		aim_rotation = aim
	if charged_pressed and phase == Phase.IDLE:
		_start_charged_attack(facing, charge_aim, charge_damage_multiplier, charge_tier)
	elif pressed:
		if phase == Phase.IDLE:
			_start_attack(0, facing, not grounded, aim)
		elif phase == Phase.LINK:
			_start_attack(combo_index + 1, facing, false, aim)
		elif grounded and not started_next_stage and not _air_attack and combo_index < 2 and not _queued_attack:
			# 最多缓存下一段；不能在第一段内连点并预订第三段。
			_queued_attack = true
			_queued_facing = facing
			_queued_aim_rotation = aim
	if phase == Phase.ACTIVE and damage_enabled:
		_resolve_hits()
	if phase != Phase.IDLE:
		frames_left -= 1
	_update_visual(false)


func _start_attack(index: int, facing: int, airborne: bool = false, aim: float = 0.0) -> void:
	combo_index = index
	attack_facing = -1 if facing < 0 else 1
	aim_rotation = aim
	_air_attack = airborne
	_queued_attack = false
	_hit_targets.clear()
	_feedback_sent = false
	_charged_attack = false
	phase = Phase.WINDUP
	frames_left = get_scaled_attack_frames(combo_windup_frames[index])


## 蓄力释放锁定真实瞄准方向，使用独立阶段时长，不进入普通三连斩的续段窗口。
func _start_charged_attack(facing: int, charge_aim: Vector2,
		charge_damage_multiplier: float, charge_tier: int) -> void:
	combo_index = 2
	attack_facing = -1 if facing < 0 else 1
	var safe_aim: Vector2 = charge_aim.normalized()
	if safe_aim.is_zero_approx():
		safe_aim = Vector2(float(attack_facing), 0.0)
	aim_rotation = safe_aim.angle() - (PI if attack_facing < 0 else 0.0)
	_air_attack = true
	_queued_attack = false
	_hit_targets.clear()
	_feedback_sent = false
	_charged_attack = true
	_charge_pose_active = false
	_charged_damage_multiplier = maxf(charge_damage_multiplier, 1.0)
	_charged_tier = clampi(charge_tier, 0, 3)
	_charged_reach = get_combat_tuning().get_charged_sword_reach(_charged_tier)
	phase = Phase.WINDUP
	frames_left = get_scaled_attack_frames(charged_windup_frames)


## 受伤、死亡与关卡重置共用的攻击中断入口；不会触发伤害或命中反馈。
func cancel_attack() -> void:
	phase = Phase.IDLE
	combo_index = 0
	frames_left = 0
	_queued_attack = false
	_queued_facing = attack_facing
	_queued_aim_rotation = 0.0
	_air_attack = false
	_charged_attack = false
	_charge_pose_active = false
	_charged_damage_multiplier = 1.0
	_charged_reach = get_combat_tuning().charged_sword_base_reach
	_charged_tier = 0
	_charge_pose_seconds = 0.0
	_charge_pose_tier = 0
	_feedback_sent = false
	_hit_targets.clear()
	aim_rotation = 0.0
	_update_visual(false)


func _advance_phase() -> void:
	match phase:
		Phase.WINDUP:
			phase = Phase.ACTIVE
			frames_left = get_scaled_attack_frames(charged_active_frames) \
				if _charged_attack else get_scaled_attack_frames(combo_active_frames[combo_index])
		Phase.ACTIVE:
			phase = Phase.RECOVERY
			frames_left = get_scaled_attack_frames(charged_recovery_frames) \
				if _charged_attack else get_scaled_attack_frames(combo_recovery_frames[combo_index])
		Phase.RECOVERY:
			if _charged_attack or combo_index == 2 or _air_attack:
				phase = Phase.IDLE
				_charged_attack = false
			elif _queued_attack:
				_start_attack(combo_index + 1, _queued_facing, false, _queued_aim_rotation)
			else:
				phase = Phase.LINK
				frames_left = combo_link_frames
		Phase.LINK:
			phase = Phase.IDLE


## 使用这一帧剑刃扫过的扇形查询，避免高速挥剑漏过目标。
func _resolve_hits() -> void:
	var duration: int = get_scaled_attack_frames(charged_active_frames) \
		if _charged_attack else get_scaled_attack_frames(combo_active_frames[combo_index])
	var elapsed: int = duration - frames_left
	var start: float = get_swing_angle(float(elapsed) / duration)
	var end: float = get_swing_angle(float(elapsed + 1) / duration)
	var origin: Vector2 = visual.get_grip_origin(_charged_attack, attack_facing)
	var impact_direction: Vector2 = _get_swing_direction(lerpf(start, end, 0.5))
	var points: PackedVector2Array = PackedVector2Array([origin])
	for index: int in range(5):
		var direction: Vector2 = _get_swing_direction(lerpf(start, end, float(index) / 4.0))
		points.append(origin + direction * get_attack_reach())
	_sweep_shape.points = points
	_query.transform = global_transform
	for hit: Dictionary in get_world_2d().direct_space_state.intersect_shape(_query, 64):
		var target: Node = hit["collider"] as Node
		if target == null or not target.has_method("receive_hit"):
			continue
		var target_id: int = target.get_instance_id()
		if _hit_targets.has(target_id):
			continue
		# 第四个参数是受击特效的来向；受击对象可据此把火花放在正确一侧。
		var hit_damage: float = get_combat_tuning().charged_sword_damage * _charged_damage_multiplier \
			if _charged_attack else maxf(combo_damages[combo_index], 0.0)
		var accepted: bool = bool(target.call(
			"receive_hit", hit_damage, self, 4 if _charged_attack else combo_index + 1, impact_direction
		))
		if not accepted:
			continue
		_hit_targets[target_id] = true
		if not _feedback_sent:
			_feedback_sent = true
			get_combat_tuning() # 同时补齐可能晚进入场景树的时间控制器引用。
			if is_instance_valid(_time_authority):
				_time_authority.request_hit_feedback(2 if _charged_attack else combo_index)


func _get_swing_direction(angle: float) -> Vector2:
	var direction: Vector2 = Vector2.from_angle(angle)
	direction.x *= attack_facing
	return direction.rotated(aim_rotation).normalized()


## 只复制战斗进度；不复制节点、伤害权限，也不回放已经发生的伤害。
func capture_state() -> Dictionary:
	return {
		"phase": phase, "combo_index": combo_index, "frames_left": frames_left,
		"attack_facing": attack_facing, "queued_attack": _queued_attack,
		"queued_facing": _queued_facing, "feedback_sent": _feedback_sent,
		"aim_rotation": aim_rotation, "queued_aim_rotation": _queued_aim_rotation,
		"air_attack": _air_attack,
		"charged_attack": _charged_attack, "charge_pose_active": _charge_pose_active,
		"charged_damage_multiplier": _charged_damage_multiplier,
		"charged_reach": _charged_reach, "charged_tier": _charged_tier,
		"charge_pose_seconds": _charge_pose_seconds, "charge_pose_tier": _charge_pose_tier,
	}


func restore_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	phase = int(state["phase"]) as Phase
	combo_index = int(state["combo_index"])
	frames_left = int(state["frames_left"])
	attack_facing = int(state["attack_facing"])
	_queued_attack = bool(state["queued_attack"])
	_queued_facing = int(state["queued_facing"])
	_feedback_sent = bool(state.get("feedback_sent", false))
	aim_rotation = float(state.get("aim_rotation", 0.0))
	_queued_aim_rotation = float(state.get("queued_aim_rotation", 0.0))
	_air_attack = bool(state.get("air_attack", false))
	_charged_attack = bool(state.get("charged_attack", false))
	_charge_pose_active = bool(state.get("charge_pose_active", false))
	_charged_damage_multiplier = float(state.get("charged_damage_multiplier", 1.0))
	_charged_reach = float(state.get("charged_reach", get_combat_tuning().charged_sword_base_reach))
	_charged_tier = int(state.get("charged_tier", 0))
	_charge_pose_seconds = float(state.get("charge_pose_seconds", 0.0))
	_charge_pose_tier = int(state.get("charge_pose_tier", 0))
	_hit_targets.clear()
	_update_visual(false)


func _update_visual(waiting: bool) -> void:
	if not is_node_ready():
		return
	var duration: int = 1
	match phase:
		Phase.WINDUP: duration = get_scaled_attack_frames(charged_windup_frames) \
			if _charged_attack else get_scaled_attack_frames(combo_windup_frames[combo_index])
		Phase.ACTIVE: duration = get_scaled_attack_frames(charged_active_frames) \
			if _charged_attack else get_scaled_attack_frames(combo_active_frames[combo_index])
		Phase.RECOVERY: duration = get_scaled_attack_frames(charged_recovery_frames) \
			if _charged_attack else get_scaled_attack_frames(combo_recovery_frames[combo_index])
		Phase.LINK: duration = maxi(combo_link_frames, 1)
	var progress: float = 1.0 - float(frames_left) / duration
	var tuning: CombatTuning = get_combat_tuning()
	var blade_length: float = tuning.blade_length
	# 长度由阶段和进度直接计算，预测恢复、等待历史帧时也能得到一致外观。
	# 待机始终使用普通长度，不依赖上一段 combo_index 是否已清零。
	if _charged_attack:
		blade_length = _charged_reach
	elif combo_index == 2:
		match phase:
			Phase.WINDUP:
				blade_length = lerpf(tuning.blade_length, tuning.heavy_blade_length, clampf(progress, 0.0, 1.0))
			Phase.ACTIVE:
				blade_length = tuning.heavy_blade_length
			Phase.RECOVERY:
				blade_length = lerpf(tuning.heavy_blade_length, tuning.blade_length, clampf(progress, 0.0, 1.0))
	var visual_phase: StringName = PHASE_NAMES[phase]
	if _charge_pose_active:
		visual_phase = &"charge"
	elif _charged_attack:
		match phase:
			Phase.WINDUP: visual_phase = &"charged_windup"
			Phase.ACTIVE: visual_phase = &"charged_active"
			Phase.RECOVERY: visual_phase = &"charged_recovery"
	var use_charged_slash_angles: bool = _charge_pose_active or _charged_attack
	var visual_start_angle: float = deg_to_rad(charged_slash_start_degrees) \
		if use_charged_slash_angles else get_swing_angle(0.0)
	var visual_end_angle: float = deg_to_rad(charged_slash_end_degrees) \
		if use_charged_slash_angles else get_swing_angle(1.0)
	visual.show_pose(visual_phase, progress, attack_facing, preview_visual,
		get_attack_reach(), visual_start_angle, visual_end_angle, blade_length, aim_rotation,
		_charge_pose_seconds, _charge_pose_tier)
	status_label.visible = phase != Phase.IDLE or _charge_pose_active
	status_label.text = "蓄力 %.1fs · %d档" % [_charge_pose_seconds, _charge_pose_tier] \
		if _charge_pose_active else (
		"蓄力斩 · %s%s" % [PHASE_LABELS[phase], " / 等待" if waiting else ""]
		if _charged_attack else "%d %s · %s%s%s" % [combo_index + 1, STAGE_NAMES[combo_index],
			PHASE_LABELS[phase], " →" if _queued_attack else "", " / 等待" if waiting else ""])
	status_label.modulate = Color("76dbff") if preview_visual else Color("ffc978")


func get_combat_tuning() -> CombatTuning:
	if not is_instance_valid(_time_authority):
		_time_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	return _time_authority.get_combat_tuning() if _time_authority != null else DEFAULT_TUNING


## 攻速倍率通过压缩逻辑帧生效；至少保留一帧，避免极高攻速跳过伤害阶段。
func get_scaled_attack_frames(base_frames: int) -> int:
	var attack_speed: float = get_attack_speed_multiplier()
	return maxi(roundi(float(maxi(base_frames, 1)) / attack_speed), 1)


func get_attack_speed_multiplier() -> float:
	var global_attack_speed: float = get_combat_tuning().attack_speed_multiplier
	return maxf(attack_speed_multiplier * global_attack_speed, 0.01)


func get_combo_windup_duration(index: int) -> int:
	return get_scaled_attack_frames(combo_windup_frames[clampi(index, 0, 2)])


func get_attack_reach() -> float:
	if _charged_attack:
		return _charged_reach
	if combo_index == 2:
		var tuning: CombatTuning = get_combat_tuning()
		# 防止调参后再次出现剑尖之外的大范围重斩判定。
		return minf(tuning.heavy_reach, tuning.heavy_blade_length)
	# 普通两段也不允许刀光/命中扇形超过当前可见剑尖。
	return minf(maxf(light_reaches[combo_index], 0.0), get_combat_tuning().blade_length)


func get_swing_angle(progress: float) -> float:
	if _charged_attack:
		return lerpf(deg_to_rad(charged_slash_start_degrees),
			deg_to_rad(charged_slash_end_degrees),
			clampf(progress, 0.0, 1.0))
	var tuning: CombatTuning = get_combat_tuning()
	var start: float = deg_to_rad(tuning.heavy_start_degrees) \
		if combo_index == 2 else deg_to_rad(light_start_degrees[combo_index])
	var end: float = deg_to_rad(tuning.heavy_end_degrees) \
		if combo_index == 2 else deg_to_rad(light_end_degrees[combo_index])
	return lerpf(start, end, clampf(progress, 0.0, 1.0))


## 在移动前预判本帧的攻击阶段，保证按下攻击的第一帧就减速。
func get_movement_multiplier(pressed: bool, advance: bool, grounded: bool = true) -> float:
	if not grounded:
		return 1.0
	var attacking: bool = phase in [Phase.WINDUP, Phase.ACTIVE, Phase.RECOVERY]
	if advance and phase == Phase.RECOVERY and frames_left <= 0:
		attacking = combo_index < 2 and _queued_attack and not _air_attack
	if pressed and advance:
		attacking = true
	return get_combat_tuning().attack_move_multiplier if attacking else 1.0
