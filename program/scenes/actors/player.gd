extends BaseActor

signal died
signal weapon_changed(slot: int, weapon_name: String)
signal weapon_unlocked(slot: int, weapon_name: String)
signal charge_mode_changed(active: bool)
## successful_release=false 同时覆盖主动取消、切换武器和受伤打断。
signal charge_action_ended(successful_release: bool)

enum PlayerState { NORMAL, HURT, DEAD }
enum WeaponSlot { SWORD = 1, BOOMERANG = 2, STAFF = 3 }

const WEAPON_NAMES: Dictionary[int, String] = {
	WeaponSlot.SWORD: "剑",
	WeaponSlot.BOOMERANG: "回旋镖",
	WeaponSlot.STAFF: "法杖",
}

@export_group("Weapon Control")
## 进入关卡或重生后默认装备的武器：1 剑、2 回旋镖、3 法杖；游戏中仍可用数字键切换。
@export_enum("剑:1", "回旋镖:2", "法杖:3") var starting_weapon: int = WeaponSlot.SWORD
## 鼠标位于玩家中心左右这段范围内时保持原朝向，瞄准向量本身不受影响。
@export_range(0.0, 32.0, 0.5) var facing_deadzone_x: float = 6.0

@export_group("Jump Assist")
## 自然离开平台后仍可起跳的宽限时间；独立 Timer 会破坏延迟回放，因此按逻辑帧递减。
@export_range(0.0, 0.5, 0.01) var coyote_time_seconds: float = 0.10
## 空中提前按下跳跃后保留请求的时间，落地时会立即消费。
@export_range(0.0, 0.5, 0.01) var jump_request_seconds: float = 0.12

@export_group("Platform Drop")
## 暂时忽略当前单向薄平台的时间；足够让 48 像素高的玩家完全穿过平台。
@export_range(0.05, 1.0, 0.01) var drop_through_seconds: float = 0.35
## 下穿开始时保证的最小向下速度，使按下 S 后立即离开平台而非缓慢滑落。
@export_range(0.0, 1000.0, 10.0) var drop_through_speed: float = 120.0

@export_group("Health")
## 玩家最大生命值；初始化和重生时 Current Health 会恢复到该值。
@export_range(1.0, 1000.0, 1.0) var max_health: float = 100.0
## 一次有效受伤后的无敌时间，单位为逻辑秒；期间 receive_hit() 会直接拒绝后续伤害。
## 它独立于硬直时间，可以比硬直长或短。
@export_range(0.0, 2.0, 0.05) var hurt_invulnerability_seconds: float = 0.35
## 旧伤害来源没有提供 Hit Stun Seconds 时使用的回退硬直，单位为逻辑秒。
## 已接入新接口的敌人、弹体和陷阱会优先使用攻击来源自己的基础硬直。
@export_range(0.0, 1.0, 0.01) var hurt_control_lock_seconds: float = 0.20
## 玩家承受硬直的倍率。最终硬直 = 攻击来源基础硬直 × 此值。
## 0 表示仍受伤并中断当前攻击，但不持续锁定操作；0.5 减半，1 正常，2 翻倍。
@export_range(0.0, 5.0, 0.05) var hurt_stun_multiplier: float = 1.0
## 玩家承受击退的倍率。最终理想距离 = 攻击来源基础距离 × 此值。
## 0 完全抵抗水平击退和上抬，0.5 约一半距离，1 正常，2 约两倍距离。
@export_range(0.0, 5.0, 0.05) var knockback_received_multiplier: float = 1.0
## 旧伤害来源没有提供 Knockback Distance 时使用的回退水平初速度，单位为像素/秒。
## 已接入新接口的攻击不会直接读取它，而是用攻击距离和下方减速度反算初速度。
@export_range(0.0, 1000.0, 10.0) var hurt_knockback_speed: float = 280.0
## 受伤瞬间保证的基础向上速度，单位为像素/秒；最终值会随击退承受倍率变化。
@export_range(0.0, 600.0, 10.0) var hurt_knockback_lift: float = 180.0
## 击退期间水平速度回落到 0 的速率，单位为像素/秒²。
## 使用“击退距离”接口时，增大此值会让起步更猛、停止更快，理想总距离基本不变。
@export_range(0.0, 5000.0, 50.0) var hurt_knockback_deceleration: float = 1200.0
## 血量归零后等待多久再由延迟组统一重生，单位为逻辑秒。
@export_range(0.0, 5.0, 0.05) var death_respawn_delay_seconds: float = 0.75

## 左键按下与长按属于所有武器共享的主攻击状态；新增武器应直接读取这组状态。
var _attack_requested: bool = false
var _attack_held: bool = false
## 剑单独使用长按门槛，防止一次短点按跨过物理帧后被误判为自动续段。
var _attack_hold_elapsed: float = 0.0
var _requested_attack_facing: int = 1
var _requested_aim_rotation: float = 0.0
## 两种发射器仍使用独立指令字段，当前武器把左键路由到对应字段。
var _secondary_attack_requested: bool = false
var _requested_secondary_aim_direction: Vector2 = Vector2.RIGHT
var _straight_shot_requested: bool = false
var _requested_straight_shot_aim_direction: Vector2 = Vector2.RIGHT
## F 只排入玩家输入帧；预览体不会在按键到达时直接改变权威世界。
var _interact_requested: bool = false
var equipped_weapon: int = WeaponSlot.SWORD
## 解锁属于关卡进度，不写入延迟历史；玩家三体由 DelayedActorGroup 在拾取时统一同步。
var _unlocked_weapons: Dictionary[int, bool] = {WeaponSlot.SWORD: true}
var _charge_mode: bool = false
var _charged_attack_requested: bool = false
var _charged_aim_direction: Vector2 = Vector2.RIGHT
var _charge_elapsed_seconds: float = 0.0
## 非蓄力时也逐帧保存鼠标方向，让手持回旋镖和法杖持续朝向准星。
var _weapon_pose_aim_direction: Vector2 = Vector2.RIGHT
var _stable_facing: int = 1
## 顿帧中短暂按下的方向和跳跃，在恢复后的第一有效逻辑帧消费一次。
var _has_buffered_move: bool = false
var _buffered_move_dir: float = 0.0
var _buffered_jump_requested: bool = false
var _buffered_drop_requested: bool = false
## 这两个剩余时间属于模拟状态，延迟预测开始和提交时必须一同复制。
var _coyote_time_left: float = 0.0
var _jump_request_time_left: float = 0.0
## 下穿只临时排除脚下那座单向平台；同碰撞层的地面、墙壁和实体陷阱仍然有效。
var _drop_through_platform: PhysicsBody2D
var _drop_through_time_left: float = 0.0
var _drop_platform_contact: KinematicCollision2D = KinematicCollision2D.new()
## 只有延迟组中的真实 Body 可以受伤；预览体与预测器只负责模拟动作。
var _damage_receiver_enabled: bool = false
var _hurt_invulnerability_left: float = 0.0
var _hurt_state_time_left: float = 0.0
var _is_dead: bool = false
var _death_time_left: float = 0.0
var _respawn_request_sent: bool = false
var _hurt_flash_started_usec: int = 0
var _hurt_flash_duration: float = 0.0
var current_health: float = 0.0

@onready var health_bar: Node2D = get_node_or_null("HealthBar") as Node2D
@onready var health_fill: ColorRect = get_node_or_null("HealthBar/Fill") as ColorRect
@onready var body_sprite: Sprite2D = get_node_or_null("VisualRoot/Graphics/Sprite2D") as Sprite2D
@onready var boomerang_launcher: BoomerangLauncher = get_node_or_null("BoomerangLauncher") as BoomerangLauncher
## 以 Node 保存新挂件，避免全新项目首次扫描时先解析 Player、尚未登记薄适配器类名。
@onready var straight_shot_launcher: Node = get_node_or_null("StraightShotLauncher")


func _ready() -> void:
	current_health = max_health
	_unlocked_weapons = {WeaponSlot.SWORD: true}
	var requested_starting_weapon: int = clampi(
		starting_weapon, WeaponSlot.SWORD, WeaponSlot.STAFF)
	equipped_weapon = requested_starting_weapon \
		if is_weapon_unlocked(requested_starting_weapon) else WeaponSlot.SWORD
	_update_health_visual()
	_update_equipped_weapon_visuals()


## 玩家空中控制读取可热更新的战斗配置；其他 BaseActor 使用自己的通用导出参数。
func get_horizontal_acceleration(grounded: bool) -> float:
	if grounded:
		return acceleration
	var tuning: CombatTuning = weapon.get_combat_tuning() if weapon != null \
		else preload("res://resources/combat_tuning.tres")
	return acceleration * tuning.air_acceleration_multiplier


## 受伤击退与死亡下落不经过延迟输入；等外部运动完整结束后再建立新时间线。
## 否则首条记录会混入受伤状态，一个延迟周期后再次误报 replay_mismatch。
func is_delay_reentry_ready() -> bool:
	return _hurt_state_time_left <= 0.0 and not _is_dead


## 三份玩家共用同一脚本，但只有真实本体保留伤害与武器结算权限。
func configure_delay_replica(role: DelayReplicaRole) -> void:
	super.configure_delay_replica(role)
	var is_authority: bool = role == DelayReplicaRole.AUTHORITY
	# 预览体和预测体仍用掩码 2 模拟地形，但不提供碰撞层，避免敌人弹幕先撞到重叠副本。
	collision_layer = 1 if is_authority else 0
	collision_mask = 2
	set_damage_receiver_enabled(is_authority)
	if weapon != null:
		weapon.damage_enabled = is_authority
		weapon.preview_visual = role == DelayReplicaRole.PREVIEW
	if boomerang_launcher != null:
		boomerang_launcher.configure_delay_replica(role)
	if straight_shot_launcher != null:
		straight_shot_launcher.call("configure_delay_replica", role)
	_update_equipped_weapon_visuals()


## 兼容旧调用；新延迟控制器统一通过 configure_delay_replica() 设置角色。
func set_damage_receiver_enabled(enabled: bool) -> void:
	_damage_receiver_enabled = enabled
	if health_bar != null:
		health_bar.visible = enabled


func can_receive_hit() -> bool:
	return _damage_receiver_enabled and current_health > 0.0 and _hurt_invulnerability_left <= 0.0


## 敌人追踪使用存活状态，不会因为短暂无敌时间而丢失目标。
func is_alive() -> bool:
	return current_health > 0.0 and not _is_dead


## 与武器对木桩使用相同的受击接口；返回值表示这次伤害是否真正生效。
func receive_hit(
	damage: float,
	source: Node,
	_combo: int = 1,
	impact_direction: Vector2 = Vector2.ZERO
) -> bool:
	if not can_receive_hit():
		return false
	current_health = maxf(current_health - maxf(damage, 0.0), 0.0)
	_hurt_invulnerability_left = hurt_invulnerability_seconds
	_hurt_state_time_left = _resolve_hit_stun_seconds(source)
	_cancel_action_input()
	_apply_hurt_knockback(source, impact_direction)
	_update_health_visual()
	_start_hurt_feedback()
	if current_health <= 0.0:
		_enter_dead_state()
	# 玩家适配器选择清空旧未来；角色本身不需要认识 DelayedActorGroup。
	report_delay_external_divergence(&"body_damaged")
	return true


## 新伤害来源主动提供硬直；旧来源仍回退到 Hurt Control Lock Seconds。
func _resolve_hit_stun_seconds(source: Node) -> float:
	var base_hit_stun: float = maxf(hurt_control_lock_seconds, 0.0)
	if source != null and source.has_method("get_hit_stun_seconds"):
		base_hit_stun = maxf(float(source.call("get_hit_stun_seconds")), 0.0)
	return base_hit_stun * maxf(hurt_stun_multiplier, 0.0)


## 未接入新契约的旧来源，按原初速度和当前减速度换算为等效距离。
func _resolve_knockback_distance(source: Node) -> float:
	var deceleration: float = maxf(hurt_knockback_deceleration, 0.0)
	var fallback_distance: float = hurt_knockback_speed * hurt_knockback_speed \
		/ (2.0 * deceleration) if deceleration > 0.0 else 0.0
	if source != null and source.has_method("get_knockback_distance"):
		return maxf(float(source.call("get_knockback_distance")), 0.0)
	return maxf(fallback_distance, 0.0)


## 在线性减速下使用 v²=2ad；减速度为 0 时按硬直时长匀速走完目标距离。
func _get_knockback_speed_for_distance(distance: float, deceleration: float,
		hurt_duration: float) -> float:
	if distance <= 0.0:
		return 0.0
	if deceleration > 0.0:
		return sqrt(2.0 * deceleration * distance)
	return distance / maxf(hurt_duration, 0.01)


## 测试或关卡重置可以显式恢复血量，不把生命值混进延迟动作记录。
func reset_health() -> void:
	current_health = max_health
	_hurt_invulnerability_left = 0.0
	_hurt_state_time_left = 0.0
	_is_dead = false
	_death_time_left = 0.0
	_respawn_request_sent = false
	_hurt_flash_duration = 0.0
	_set_hurt_white_amount(0.0)
	if graphics != null:
		graphics.modulate = Color.WHITE
	_update_health_visual()


## 玩家延迟适配器在这里复位单个角色副本；三份角色会在同一帧调用。
func reset_for_respawn(respawn_global_position: Vector2) -> void:
	_clear_drop_through_platform()
	global_position = respawn_global_position
	global_rotation = 0.0
	velocity = Vector2.ZERO
	graphics.scale.x = 1.0
	_cancel_action_input()
	reset_health()
	if weapon != null:
		weapon.cancel_attack()
	if boomerang_launcher != null:
		boomerang_launcher.reset_state()
	if straight_shot_launcher != null:
		straight_shot_launcher.call("reset_state")
	if state_machine != null and state_machine.current_state != PlayerState.NORMAL:
		state_machine.current_state = PlayerState.NORMAL
	reset_physics_interpolation()


func _process(_delta: float) -> void:
	_update_hurt_white_flash()


func _start_hurt_feedback() -> void:
	var tuning: CombatTuning = weapon.get_combat_tuning() if weapon != null else preload("res://resources/combat_tuning.tres")
	if not tuning.hurt_feedback_enabled:
		return
	_hurt_flash_duration = tuning.hurt_character_flash_seconds
	_hurt_flash_started_usec = Time.get_ticks_usec()
	_set_hurt_white_amount(1.0 if _hurt_flash_duration > 0.0 else 0.0)
	var authority: WorldTimeAuthority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	if authority != null:
		authority.request_player_hurt_feedback()


func _update_hurt_white_flash() -> void:
	if _hurt_flash_duration <= 0.0:
		return
	var elapsed: float = float(Time.get_ticks_usec() - _hurt_flash_started_usec) / 1_000_000.0
	var progress: float = elapsed / _hurt_flash_duration
	if progress >= 1.0:
		_hurt_flash_duration = 0.0
		_set_hurt_white_amount(0.0)
		return
	# 前四分之一保持纯白，随后平滑回到原来的角色颜色。
	var white_amount: float = 1.0 if progress <= 0.25 else 1.0 - (progress - 0.25) / 0.75
	_set_hurt_white_amount(clampf(white_amount, 0.0, 1.0))


func _set_hurt_white_amount(amount: float) -> void:
	if body_sprite == null or not (body_sprite.material is ShaderMaterial):
		return
	(body_sprite.material as ShaderMaterial).set_shader_parameter("white_amount", amount)


## 由 AttackInputBuffer 调用。它在命中顿帧时仍会运行，因此这里不检查 paused。
func begin_attack_input(screen_position: Vector2 = Vector2.INF) -> void:
	if _is_dead or _hurt_state_time_left > 0.0:
		return
	var pointer_offset: Vector2 = _get_pointer_offset(screen_position)
	var aim_direction: Vector2 = pointer_offset.normalized()
	_weapon_pose_aim_direction = aim_direction
	_requested_attack_facing = _resolve_aim_facing(pointer_offset.x)
	_requested_aim_rotation = _get_aim_rotation(aim_direction, _requested_attack_facing)
	if _charge_mode:
		_charged_aim_direction = aim_direction
		_charged_attack_requested = true
		_attack_held = false
		_attack_hold_elapsed = 0.0
		return
	# 普通主攻击统一保存按下与长按；具体武器只负责把该状态映射到自身动作。
	_attack_held = true
	_attack_hold_elapsed = 0.0
	_attack_requested = true
	match equipped_weapon:
		WeaponSlot.SWORD:
			pass
		WeaponSlot.BOOMERANG:
			_requested_secondary_aim_direction = aim_direction
			_secondary_attack_requested = true
		WeaponSlot.STAFF:
			_requested_straight_shot_aim_direction = aim_direction
			_straight_shot_requested = true


## 输入缓冲器在受伤恢复或延迟输入角色切换后调用；已在长按时不会重置计时。
func resume_held_attack_input(screen_position: Vector2 = Vector2.INF) -> bool:
	if _attack_held or _is_dead or _hurt_state_time_left > 0.0:
		return false
	begin_attack_input(screen_position)
	return _attack_held


## 松开统一由输入缓冲器广播，防止延迟切换后旧即时角色留下长按状态。
func release_attack_input() -> void:
	_attack_held = false
	_attack_hold_elapsed = 0.0
	# 保留尚未被物理帧消费的首段请求，快速点击也要能出一刀。


## 拾取与攻击一样进入延迟输入流，由真实本体消费对应 Recording 时执行。
func begin_interact_input() -> void:
	if _is_dead or _hurt_state_time_left > 0.0:
		return
	_interact_requested = true


## 教学控制器只读这个状态，确认玩家确实从单向薄平台发起了下穿。
func is_dropping_through_platform() -> bool:
	return _drop_through_time_left > 0.0


## 兼容旧的脚本调用；实际右键输入现在统一走 toggle_charge_mode()。
func begin_secondary_attack_input(screen_position: Vector2 = Vector2.INF) -> void:
	toggle_charge_mode(screen_position)


## 兼容诊断脚本的直接调用；正式输入已改为先选法杖再按左键。
func begin_straight_shot_input(screen_position: Vector2 = Vector2.INF) -> void:
	if _is_dead or _hurt_state_time_left > 0.0:
		return
	if not select_weapon(WeaponSlot.STAFF):
		return
	_requested_straight_shot_aim_direction = _get_projectile_aim_direction(screen_position)
	_straight_shot_requested = true


## 右键第一次进入蓄力，再次右键取消；切换状态本身也会进入延迟输入时间线。
func toggle_charge_mode(screen_position: Vector2 = Vector2.INF) -> void:
	if _is_dead or _hurt_state_time_left > 0.0:
		return
	var was_charging: bool = _charge_mode
	_charge_mode = not _charge_mode
	_charged_attack_requested = false
	_charge_elapsed_seconds = 0.0
	_attack_held = false
	_attack_hold_elapsed = 0.0
	if _charge_mode:
		_charged_aim_direction = _get_projectile_aim_direction(screen_position)
		_weapon_pose_aim_direction = _charged_aim_direction
		_cancel_current_weapon_action()
	charge_mode_changed.emit(_charge_mode)
	if was_charging and not _charge_mode:
		charge_action_ended.emit(false)
	_update_equipped_weapon_visuals()


## 正常游戏中的 1 / 2 / 3 调用此入口；未拾取的武器会拒绝切换。
func select_weapon(slot: int) -> bool:
	if slot < WeaponSlot.SWORD or slot > WeaponSlot.STAFF or not is_weapon_unlocked(slot):
		return false
	if slot == equipped_weapon:
		return true
	var charge_was_active: bool = _charge_mode
	equipped_weapon = slot
	_charge_mode = false
	_charged_attack_requested = false
	_charge_elapsed_seconds = 0.0
	_cancel_current_weapon_action()
	_update_equipped_weapon_visuals()
	weapon_changed.emit(equipped_weapon, get_equipped_weapon_name())
	charge_mode_changed.emit(false)
	if charge_was_active:
		charge_action_ended.emit(false)
	return true


func unlock_weapon(slot: int) -> bool:
	if slot < WeaponSlot.SWORD or slot > WeaponSlot.STAFF or is_weapon_unlocked(slot):
		return false
	_unlocked_weapons[slot] = true
	weapon_unlocked.emit(slot, get_weapon_name_for_slot(slot))
	return true


func is_weapon_unlocked(slot: int) -> bool:
	return bool(_unlocked_weapons.get(slot, false))


func get_weapon_unlock_summary() -> String:
	var unlocked_names: PackedStringArray = PackedStringArray()
	for slot: int in [WeaponSlot.SWORD, WeaponSlot.BOOMERANG, WeaponSlot.STAFF]:
		var weapon_name: String = get_weapon_name_for_slot(slot)
		unlocked_names.append(weapon_name if is_weapon_unlocked(slot) \
			else "%s（未解锁）" % weapon_name)
	return " / ".join(unlocked_names)


func get_weapon_name_for_slot(slot: int) -> String:
	return WEAPON_NAMES.get(slot, "未知武器") as String


func get_equipped_weapon_name() -> String:
	return get_weapon_name_for_slot(equipped_weapon)


## 属性面板读取“全局攻速 × 当前武器攻速”的最终倍率。
func get_equipped_attack_speed_multiplier() -> float:
	match equipped_weapon:
		WeaponSlot.SWORD:
			return weapon.get_attack_speed_multiplier() if weapon != null else 1.0
		WeaponSlot.BOOMERANG:
			return boomerang_launcher.get_attack_speed_multiplier() \
				if boomerang_launcher != null else 1.0
		WeaponSlot.STAFF:
			return float(straight_shot_launcher.call("get_attack_speed_multiplier")) \
				if straight_shot_launcher != null else 1.0
	return 1.0


func is_charge_mode_active() -> bool:
	return _charge_mode


func get_charge_elapsed_seconds() -> float:
	return _charge_elapsed_seconds


## 负延迟结算只快进当前蓄力计时，不直接触发攻击，也不会超过配置的蓄力上限。
func advance_charge_time(seconds: float) -> bool:
	if not _charge_mode or seconds <= 0.0:
		return false
	var tuning: CombatTuning = weapon.get_combat_tuning() if weapon != null \
		else preload("res://resources/combat_tuning.tres")
	_charge_elapsed_seconds = minf(
		_charge_elapsed_seconds + seconds,
		tuning.charge_max_seconds
	)
	_update_equipped_weapon_visuals()
	return true


## 动作负延迟只在普通延迟已经归零后接管蓄力资料，不改变本体的位置和速度。
func capture_charge_acceleration_state() -> Dictionary:
	return {
		"equipped_weapon": equipped_weapon,
		"charge_mode": _charge_mode,
		"charged_aim_direction": _charged_aim_direction,
		"charge_elapsed_seconds": _charge_elapsed_seconds,
		"weapon_pose_aim_direction": _weapon_pose_aim_direction,
		"stable_facing": _stable_facing,
	}


func restore_charge_acceleration_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	equipped_weapon = int(state.get("equipped_weapon", equipped_weapon))
	_cancel_current_weapon_action()
	_charge_mode = bool(state.get("charge_mode", _charge_mode))
	_charged_attack_requested = false
	_charged_aim_direction = state.get(
		"charged_aim_direction", _charged_aim_direction) as Vector2
	_charge_elapsed_seconds = float(state.get(
		"charge_elapsed_seconds", _charge_elapsed_seconds))
	_weapon_pose_aim_direction = state.get(
		"weapon_pose_aim_direction", _weapon_pose_aim_direction) as Vector2
	_stable_facing = int(state.get("stable_facing", _stable_facing))
	_attack_held = false
	_attack_hold_elapsed = 0.0
	_update_equipped_weapon_visuals()


func get_charge_tier() -> int:
	var tuning: CombatTuning = weapon.get_combat_tuning() if weapon != null \
		else preload("res://resources/combat_tuning.tres")
	return tuning.get_charge_tier(_charge_elapsed_seconds)


func get_charge_damage_multiplier() -> float:
	var tuning: CombatTuning = weapon.get_combat_tuning() if weapon != null \
		else preload("res://resources/combat_tuning.tres")
	return tuning.get_charge_damage_multiplier(_charge_elapsed_seconds)


func _get_projectile_aim_direction(screen_position: Vector2) -> Vector2:
	var aim_direction: Vector2 = _get_pointer_offset(screen_position)
	return aim_direction.normalized()


func _get_pointer_offset(screen_position: Vector2) -> Vector2:
	var aim_direction: Vector2 = Vector2.ZERO
	if screen_position != Vector2.INF:
		aim_direction = get_global_transform_with_canvas().affine_inverse() * screen_position
	else:
		aim_direction = get_global_mouse_position() - global_position
	if aim_direction.is_zero_approx():
		aim_direction = Vector2(-1.0 if graphics.scale.x < 0.0 else 1.0, 0.0)
	return aim_direction


func _resolve_aim_facing(aim_x: float) -> int:
	if absf(aim_x) > facing_deadzone_x:
		_stable_facing = -1 if aim_x < 0.0 else 1
	return _stable_facing


func _cancel_current_weapon_action() -> void:
	_attack_requested = false
	_secondary_attack_requested = false
	_straight_shot_requested = false
	if weapon != null:
		weapon.cancel_attack()


func _update_equipped_weapon_visuals() -> void:
	if not is_node_ready():
		return
	if weapon != null:
		weapon.visible = equipped_weapon == WeaponSlot.SWORD
	if boomerang_launcher != null:
		boomerang_launcher.call("set_weapon_pose",
			equipped_weapon == WeaponSlot.BOOMERANG, _charge_mode, _weapon_pose_aim_direction,
			_charge_elapsed_seconds, get_charge_tier())
	if straight_shot_launcher != null:
		straight_shot_launcher.call("set_weapon_pose",
			equipped_weapon == WeaponSlot.STAFF, _charge_mode, _weapon_pose_aim_direction,
			_charge_elapsed_seconds, get_charge_tier())


## 由 AttackInputBuffer 在命中顿帧中调用；不读取当前 Input，保留短点按。
func buffer_hit_stop_input(action: StringName) -> void:
	if _is_dead or _hurt_state_time_left > 0.0:
		return
	match action:
		&"ui_left":
			_has_buffered_move = true
			_buffered_move_dir = -1.0
		&"ui_right":
			_has_buffered_move = true
			_buffered_move_dir = 1.0
		&"ui_up":
			_buffered_jump_requested = true
		&"ui_down":
			_buffered_drop_requested = true


## 瞄准始终使用玩家中心到鼠标的真实方向；朝向死区只影响图形翻面，不改瞄准向量。
func _get_mouse_aim(mouse_local: Vector2 = Vector2.INF) -> Vector2:
	if mouse_local == Vector2.INF:
		mouse_local = to_local(get_global_mouse_position())
	return mouse_local if not mouse_local.is_zero_approx() else Vector2(float(_stable_facing), 0.0)


func _get_aim_rotation(aim: Vector2, facing: int) -> float:
	return wrapf(aim.angle() - (PI if facing < 0 else 0.0), -PI, PI)


func get_next_state(current: int) -> int:
	if _is_dead:
		return PlayerState.DEAD if current != PlayerState.DEAD else state_machine.KEEP_CURRENT
	if _hurt_state_time_left > 0.0:
		return PlayerState.HURT if current != PlayerState.HURT else state_machine.KEEP_CURRENT
	if current != PlayerState.NORMAL:
		return PlayerState.NORMAL
	return state_machine.KEEP_CURRENT

func transition_state(_from: int, to: int) -> void:
	if to == PlayerState.DEAD:
		graphics.modulate = Color(0.48, 0.48, 0.52, 1.0)
	elif to == PlayerState.NORMAL:
		graphics.modulate = Color.WHITE

func tick_physics(current: int, delta: float) -> void:
	assert(preview_system != null, "未成功获取预览系统节点！")
	_hurt_invulnerability_left = maxf(_hurt_invulnerability_left - delta, 0.0)
	if _is_dead or current == PlayerState.DEAD:
		_tick_drop_through(delta)
		_tick_dead_state(delta)
		return
	if _hurt_state_time_left > 0.0 or current == PlayerState.HURT:
		_tick_drop_through(delta)
		_tick_hurt_state(delta)
		return
	var dir: float = 0.0
	var jump_pressed: bool = false
	var drop_pressed: bool = false
	var attack_pressed: bool = false
	var interact_pressed: bool = false
	var secondary_attack_pressed: bool = false
	var straight_shot_pressed: bool = false
	var replayed_slot: Recording = null
	var attack_facing: int = -1 if graphics.scale.x < 0.0 else 1
	var aim_rotation: float = weapon.aim_rotation if weapon != null else 0.0
	var secondary_aim_direction: Vector2 = _requested_secondary_aim_direction
	var straight_shot_aim_direction: Vector2 = _requested_straight_shot_aim_direction
	var weapon_slot_for_frame: int = equipped_weapon
	var charge_mode_for_frame: bool = _charge_mode
	var charged_attack_pressed: bool = false
	var charged_aim_direction: Vector2 = _charged_aim_direction
	var tuning: CombatTuning = weapon.get_combat_tuning() if weapon != null \
		else preload("res://resources/combat_tuning.tres")
	var charge_elapsed_for_frame: float = _charge_elapsed_seconds
	var charge_tier_for_frame: int = tuning.get_charge_tier(charge_elapsed_for_frame)
	var charge_damage_multiplier: float = tuning.get_charge_damage_multiplier(charge_elapsed_for_frame)
	# 本体和预测器只有读到历史帧，才推进这一帧的竖直运动。
	var advance_vertical_motion: bool = inputed
	if inputed:
		# 命中顿帧会暂停普通角色的输入回调；若这段时间松开左键，
		# 通过 Input 的真实状态在恢复首帧清掉滞留的长按标记。
		if _attack_held and not Input.is_action_pressed("attack"):
			_attack_held = false
			_attack_hold_elapsed = 0.0
		# 方向缓冲只覆盖恢复后的第一帧，之后回到连续输入；跳跃缓冲与 just_pressed 合并。
		dir = _buffered_move_dir if _has_buffered_move else Input.get_axis("ui_left", "ui_right")
		jump_pressed = _buffered_jump_requested or Input.is_action_just_pressed("ui_up")
		# S 是持续意图：提前按住后落到任意单向平台，也应立即继续向下穿过。
		drop_pressed = _buffered_drop_requested or Input.is_action_pressed("ui_down")
		interact_pressed = _interact_requested
		# 普通武器共享连续主攻击；剑额外等待门槛，避免短点按被续成第二段。
		if _attack_held and equipped_weapon == WeaponSlot.SWORD and not _charge_mode:
			_attack_hold_elapsed += delta
		var repeating_primary_attack: bool = _attack_held and not _charge_mode
		var primary_attack_pressed: bool = _attack_requested or repeating_primary_attack
		var hold_repeat_active: bool = _attack_held \
			and equipped_weapon == WeaponSlot.SWORD \
			and not _charge_mode \
			and _attack_hold_elapsed >= tuning.hold_repeat_delay
		attack_pressed = equipped_weapon == WeaponSlot.SWORD and not _charge_mode \
			and (_attack_requested or hold_repeat_active)
		secondary_attack_pressed = equipped_weapon == WeaponSlot.BOOMERANG and not _charge_mode \
			and (_secondary_attack_requested or primary_attack_pressed)
		secondary_aim_direction = _requested_secondary_aim_direction
		straight_shot_pressed = equipped_weapon == WeaponSlot.STAFF and not _charge_mode \
			and (_straight_shot_requested or primary_attack_pressed)
		straight_shot_aim_direction = _requested_straight_shot_aim_direction
		weapon_slot_for_frame = equipped_weapon
		charge_mode_for_frame = _charge_mode
		charged_attack_pressed = _charged_attack_requested and _charge_mode
		charged_aim_direction = _charged_aim_direction
		var aim: Vector2 = _get_mouse_aim()
		var live_aim_direction: Vector2 = aim.normalized()
		_weapon_pose_aim_direction = live_aim_direction
		attack_facing = _requested_attack_facing if _attack_requested and not _attack_held \
			else _resolve_aim_facing(aim.x)
		aim_rotation = _requested_aim_rotation if _attack_requested and not _attack_held else _get_aim_rotation(aim, attack_facing)
		if _charge_mode:
			_charge_elapsed_seconds = minf(
				_charge_elapsed_seconds + delta, tuning.charge_max_seconds)
			charged_aim_direction = live_aim_direction
			_charged_aim_direction = charged_aim_direction
			charge_elapsed_for_frame = _charge_elapsed_seconds
			charge_tier_for_frame = tuning.get_charge_tier(charge_elapsed_for_frame)
			charge_damage_multiplier = tuning.get_charge_damage_multiplier(charge_elapsed_for_frame)
			# 默认蓄力倍率为 0 时也禁止新起跳或主动下穿；空中已有重力仍正常推进。
			if is_zero_approx(tuning.charge_move_multiplier):
				jump_pressed = false
				drop_pressed = false
		elif equipped_weapon == WeaponSlot.BOOMERANG:
			# 点击帧保留事件坐标；其余帧才用实时鼠标刷新手持朝向。
			if not _secondary_attack_requested:
				_requested_secondary_aim_direction = live_aim_direction
				secondary_aim_direction = live_aim_direction
		elif equipped_weapon == WeaponSlot.STAFF:
			if not _straight_shot_requested:
				_requested_straight_shot_aim_direction = live_aim_direction
				straight_shot_aim_direction = live_aim_direction
		_has_buffered_move = false
		_buffered_jump_requested = false
		_buffered_drop_requested = false
	else:
		var slot: Recording = null
		if self == group.predictor:
			slot = preview_system.predict_consume()
		else:
			slot = preview_system.consume()
		if slot != null:
			replayed_slot = slot
			dir = slot.move_dir
			jump_pressed = slot.jump_pressed
			drop_pressed = slot.drop_pressed
			interact_pressed = slot.interact_pressed
			attack_pressed = slot.attack_pressed
			attack_facing = slot.attack_facing
			aim_rotation = slot.attack_aim_rotation
			secondary_attack_pressed = slot.secondary_attack_pressed
			secondary_aim_direction = slot.secondary_aim_direction
			straight_shot_pressed = slot.straight_shot_pressed
			straight_shot_aim_direction = slot.straight_shot_aim_direction
			weapon_slot_for_frame = slot.weapon_slot
			charge_mode_for_frame = slot.charge_mode
			charged_attack_pressed = slot.charged_attack_pressed
			charged_aim_direction = slot.charged_aim_direction
			charge_elapsed_for_frame = slot.charge_elapsed_seconds
			charge_tier_for_frame = tuning.get_charge_tier(charge_elapsed_for_frame)
			charge_damage_multiplier = tuning.get_charge_damage_multiplier(charge_elapsed_for_frame)
			# 切换武器或首次进入蓄力会取消旧动作；本体回放必须复制即时输入体的状态跃迁。
			if weapon_slot_for_frame != equipped_weapon \
					or (charge_mode_for_frame and not _charge_mode):
				_cancel_current_weapon_action()
			equipped_weapon = weapon_slot_for_frame
			_charge_mode = charge_mode_for_frame
			_charged_aim_direction = charged_aim_direction
			_charge_elapsed_seconds = charge_elapsed_for_frame
			if charge_mode_for_frame:
				_weapon_pose_aim_direction = charged_aim_direction
			elif weapon_slot_for_frame == WeaponSlot.BOOMERANG:
				_weapon_pose_aim_direction = secondary_aim_direction
			elif weapon_slot_for_frame == WeaponSlot.STAFF:
				_weapon_pose_aim_direction = straight_shot_aim_direction
			advance_vertical_motion = true
	# 切换即时输入角色时，旧角色未消费的点击不会滞留到下一次切换。
	_attack_requested = false
	_interact_requested = false
	_secondary_attack_requested = false
	_straight_shot_requested = false
	_charged_attack_requested = false
			
	graphics.scale.x = float(attack_facing)
	if advance_vertical_motion:
		_tick_drop_through(delta)
	var on_ground: bool = is_grounded_for_simulation()
	var started_drop_through: bool = advance_vertical_motion \
		and drop_pressed \
		and _try_begin_drop_through()
	if started_drop_through:
		# S 与 W 同帧时以下穿为准，避免先排除平台又立刻向上起跳。
		on_ground = false
		jump_pressed = false
	var will_jump: bool = _consume_jump_request(jump_pressed, on_ground, delta) if advance_vertical_motion else false
	# 起跳当帧立即按空中规则处理，避免先被地面攻击速度上限截断惯性。
	var grounded_movement: bool = on_ground and not will_jump
	var movement_multiplier: float = tuning.charge_move_multiplier if charge_mode_for_frame else 1.0
	if not charge_mode_for_frame and equipped_weapon == WeaponSlot.SWORD and weapon != null:
		movement_multiplier = weapon.get_movement_multiplier(
			attack_pressed, advance_vertical_motion, grounded_movement)
	var speed_limit: float = move_speed * movement_multiplier
	if movement_multiplier < 1.0 and not charge_mode_for_frame:
		# 立即限制已有惯性，避免虽然降低目标速度，挥剑时仍然高速滑行。
		velocity.x = clampf(velocity.x, -speed_limit, speed_limit)
	# 蓄力默认把目标速度降到 0，但不再直接清空已有水平惯性；
	# 地面和空中分别使用玩家原有加速度，自然滑行到目标速度。
	velocity.x = move_toward(velocity.x, dir * speed_limit, get_horizontal_acceleration(grounded_movement) * delta)
	if advance_vertical_motion:
		velocity.y += gravity * delta
	if will_jump:
		velocity.y = jump_velocity
	# 蓄力剑在释放帧把鼠标方向直接转换成动量；向上是升龙，其他方向是突进。
	if advance_vertical_motion and charged_attack_pressed \
			and weapon_slot_for_frame == WeaponSlot.SWORD:
		velocity += charged_aim_direction.normalized() \
			* tuning.get_charged_sword_impulse(charge_tier_for_frame)

	# 等待历史帧时，已有的上升/下落速度也不能继续产生位移。
	# 暂存竖直速度供回放恢复使用，水平方向仍保留原有减速与碰撞。
	var saved_vertical_velocity: float = velocity.y
	if not advance_vertical_motion:
		velocity.y = 0.0
	move_and_slide()
	if not advance_vertical_motion:
		velocity.y = saved_vertical_velocity
	# 预览体和预测器都不产生拾取副作用；只有本体消费到 F 所在帧后执行。
	if interact_pressed and self == group.body and group.has_method("try_pick_up_nearest"):
		group.call("try_pick_up_nearest")
	if weapon != null:
		# 移动完成后在当前角色位置挥剑；武器等待与重力等待使用同一逻辑帧。
		weapon.tick(
			attack_pressed and weapon_slot_for_frame == WeaponSlot.SWORD,
			attack_facing,
			advance_vertical_motion,
			is_grounded_for_simulation(),
			aim_rotation,
			charged_attack_pressed and weapon_slot_for_frame == WeaponSlot.SWORD,
			charge_mode_for_frame and weapon_slot_for_frame == WeaponSlot.SWORD,
			charged_aim_direction,
			charge_elapsed_for_frame,
			charge_damage_multiplier,
			charge_tier_for_frame
		)
		# 每段攻击开始后重新计算长按时间。第二段、第三段需要各自按住足够久，
		# 避免第二段刚开始时松手，已提前缓存的自动第三段仍然打出。
		if _attack_held and _did_start_attack_this_frame():
			_attack_hold_elapsed = 0.0
	if boomerang_launcher != null:
		# 发射器与移动、剑击共享同一逻辑帧：本体等待历史时冷却也不会偷跑。
		boomerang_launcher.tick(
			secondary_attack_pressed or (charged_attack_pressed and weapon_slot_for_frame == WeaponSlot.BOOMERANG),
			charged_aim_direction if charged_attack_pressed else secondary_aim_direction,
			advance_vertical_motion,
			delta,
			charged_attack_pressed and weapon_slot_for_frame == WeaponSlot.BOOMERANG,
			charge_damage_multiplier,
			charge_tier_for_frame
		)
	if straight_shot_launcher != null:
		straight_shot_launcher.call(
			"tick",
			straight_shot_pressed or (charged_attack_pressed and weapon_slot_for_frame == WeaponSlot.STAFF),
			charged_aim_direction if charged_attack_pressed else straight_shot_aim_direction,
			advance_vertical_motion,
			delta,
			charged_attack_pressed and weapon_slot_for_frame == WeaponSlot.STAFF,
			charge_damage_multiplier,
			charge_tier_for_frame
		)
	if charged_attack_pressed:
		_charge_mode = false
		_charge_elapsed_seconds = 0.0
		if inputed:
			charge_mode_changed.emit(false)
			charge_action_ended.emit(true)
	_update_equipped_weapon_visuals()

	# 仅真实本体核对回放结果；预览体负责生产 expected，预测器只是临时演算。
	if replayed_slot != null and self == group.body:
		group.check_replay_divergence(self, replayed_slot)

	if self == group.preview_body and inputed:
		preview_system.record(Recording.new(
			dir,
			jump_pressed,
			global_position,
			velocity,
			attack_pressed,
			attack_facing,
			aim_rotation,
			secondary_attack_pressed,
			secondary_aim_direction,
			straight_shot_pressed,
			straight_shot_aim_direction,
			drop_pressed,
			weapon_slot_for_frame,
			charge_mode_for_frame,
			charged_attack_pressed,
			charged_aim_direction,
			charge_elapsed_for_frame,
			interact_pressed,
		))


## 只查询脚下紧贴的碰撞体；公共契约或碰撞形状必须明确标记为单向平台。
func _get_drop_through_platform_underfoot() -> PhysicsBody2D:
	var touches_floor: bool = test_move(
		global_transform,
		-up_direction * 0.5,
		_drop_platform_contact,
		safe_margin,
		true
	)
	if not touches_floor \
		or _drop_platform_contact.get_normal().dot(up_direction) < cos(floor_max_angle):
		return null
	var collider: Object = _drop_platform_contact.get_collider()
	if not (collider is PhysicsBody2D):
		return null
	var platform: PhysicsBody2D = collider as PhysicsBody2D
	if not _is_drop_through_platform(platform):
		return null
	return platform


## 脚本契约用于可复用机关；静态关卡块则直接读取发生碰撞的 CollisionShape2D 配置。
func _is_drop_through_platform(platform: PhysicsBody2D) -> bool:
	if platform.has_method("is_drop_through_platform"):
		return bool(platform.call("is_drop_through_platform"))
	var shape_index: int = _drop_platform_contact.get_collider_shape_index()
	if shape_index < 0:
		return false
	var shape_owner_id: int = platform.shape_find_owner(shape_index)
	if shape_owner_id < 0:
		return false
	var shape_owner: Object = platform.shape_owner_get_owner(shape_owner_id)
	return shape_owner is CollisionShape2D \
		and (shape_owner as CollisionShape2D).one_way_collision


func _try_begin_drop_through() -> bool:
	var platform: PhysicsBody2D = _get_drop_through_platform_underfoot()
	if platform == null:
		return false
	_set_drop_through_platform(platform, drop_through_seconds)
	velocity.y = maxf(velocity.y, drop_through_speed)
	_coyote_time_left = 0.0
	_jump_request_time_left = 0.0
	return true


## 每个玩家副本独立持有碰撞例外；计时使用模拟 delta，等待延迟历史时不会提前结束。
func _tick_drop_through(delta: float) -> void:
	if _drop_through_time_left <= 0.0:
		return
	if not is_instance_valid(_drop_through_platform):
		_drop_through_platform = null
		_drop_through_time_left = 0.0
		return
	_drop_through_time_left = maxf(_drop_through_time_left - delta, 0.0)
	if _drop_through_time_left <= 0.0:
		_clear_drop_through_platform()


func _set_drop_through_platform(platform: PhysicsBody2D, duration: float) -> void:
	if platform != _drop_through_platform:
		_clear_drop_through_platform()
		_drop_through_platform = platform
		add_collision_exception_with(platform)
	_drop_through_time_left = maxf(duration, 0.0)


func _clear_drop_through_platform() -> void:
	var previous_platform: PhysicsBody2D = _drop_through_platform
	_drop_through_platform = null
	_drop_through_time_left = 0.0
	if is_instance_valid(previous_platform):
		remove_collision_exception_with(previous_platform)


## 同时处理郊狼时间与落地前跳跃请求；只有实际起跳时才清空两个窗口。
func _consume_jump_request(jump_pressed: bool, on_ground: bool, delta: float) -> bool:
	if on_ground:
		_coyote_time_left = coyote_time_seconds
	if jump_pressed:
		_jump_request_time_left = jump_request_seconds

	var has_jump_request: bool = jump_pressed or _jump_request_time_left > 0.0
	var can_jump_now: bool = on_ground or _coyote_time_left > 0.0
	var will_jump: bool = has_jump_request and can_jump_now
	if will_jump:
		_coyote_time_left = 0.0
		_jump_request_time_left = 0.0
		return true

	if not on_ground:
		_coyote_time_left = maxf(_coyote_time_left - delta, 0.0)
	_jump_request_time_left = maxf(_jump_request_time_left - delta, 0.0)
	return false


## 预测器从真实本体开始演算时，必须继承跳跃窗口及尚未结束的平台下穿状态。
func capture_simulation_state() -> Dictionary:
	var drop_platform_id: int = _drop_through_platform.get_instance_id() \
		if is_instance_valid(_drop_through_platform) else 0
	return {
		"coyote_time_left": _coyote_time_left,
		"jump_request_time_left": _jump_request_time_left,
		"drop_through_time_left": _drop_through_time_left,
		"drop_through_platform_id": drop_platform_id,
		"hurt_state_time_left": _hurt_state_time_left,
		"is_dead": _is_dead,
		"death_time_left": _death_time_left,
		"equipped_weapon": equipped_weapon,
		"charge_mode": _charge_mode,
		"charged_aim_direction": _charged_aim_direction,
		"charge_elapsed_seconds": _charge_elapsed_seconds,
		"weapon_pose_aim_direction": _weapon_pose_aim_direction,
		"stable_facing": _stable_facing,
	}


func restore_simulation_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	_coyote_time_left = float(state.get("coyote_time_left", 0.0))
	_jump_request_time_left = float(state.get("jump_request_time_left", 0.0))
	var restored_drop_time: float = float(state.get("drop_through_time_left", 0.0))
	var restored_platform_id: int = int(state.get("drop_through_platform_id", 0))
	var restored_platform_object: Object = instance_from_id(restored_platform_id) \
		if restored_platform_id > 0 else null
	if restored_drop_time > 0.0 and restored_platform_object is PhysicsBody2D:
		_set_drop_through_platform(restored_platform_object as PhysicsBody2D, restored_drop_time)
	else:
		_clear_drop_through_platform()
	_hurt_state_time_left = float(state.get("hurt_state_time_left", 0.0))
	_is_dead = bool(state.get("is_dead", false))
	_death_time_left = float(state.get("death_time_left", 0.0))
	equipped_weapon = int(state.get("equipped_weapon", equipped_weapon))
	_charge_mode = bool(state.get("charge_mode", _charge_mode))
	_charged_aim_direction = state.get("charged_aim_direction", _charged_aim_direction) as Vector2
	_charge_elapsed_seconds = float(state.get("charge_elapsed_seconds", _charge_elapsed_seconds))
	_weapon_pose_aim_direction = state.get(
		"weapon_pose_aim_direction", _weapon_pose_aim_direction) as Vector2
	_stable_facing = int(state.get("stable_facing", _stable_facing))
	_update_equipped_weapon_visuals()


## 武器与发射器属于玩家适配层；BaseActor 只负责调用钩子，不依赖具体类型。
func capture_delay_attachment_state() -> Dictionary:
	var state: Dictionary = {}
	if weapon != null:
		state["weapon"] = weapon.capture_state()
	if boomerang_launcher != null:
		state["boomerang_launcher"] = boomerang_launcher.capture_state()
	if straight_shot_launcher != null:
		state["straight_shot_launcher"] = straight_shot_launcher.call("capture_state")
	return state


func restore_delay_attachment_state(state: Dictionary) -> void:
	if weapon != null and state.has("weapon"):
		weapon.restore_state(state["weapon"] as Dictionary)
	if boomerang_launcher != null and state.has("boomerang_launcher"):
		boomerang_launcher.restore_state(state["boomerang_launcher"] as Dictionary)
	if straight_shot_launcher != null and state.has("straight_shot_launcher"):
		straight_shot_launcher.call("restore_state", state["straight_shot_launcher"] as Dictionary)


## 受伤状态只执行击退与重力；持续按键由输入层保留，并在恢复控制后重新接管。
func _tick_hurt_state(delta: float) -> void:
	_hurt_state_time_left = maxf(_hurt_state_time_left - delta, 0.0)
	velocity.x = move_toward(velocity.x, 0.0, hurt_knockback_deceleration * delta)
	velocity.y += gravity * delta
	move_and_slide()


## 死亡期间保留基础碰撞，让尸体落回地面；计时结束后只由真实本体请求重生。
func _tick_dead_state(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, hurt_knockback_deceleration * delta)
	velocity.y += gravity * delta
	move_and_slide()
	_death_time_left = maxf(_death_time_left - delta, 0.0)
	if _death_time_left > 0.0 or _respawn_request_sent:
		return
	if delay_replica_role == DelayReplicaRole.AUTHORITY and delay_controller != null:
		_respawn_request_sent = true
		request_delay_body_respawn()


func _apply_hurt_knockback(source: Node, impact_direction: Vector2) -> void:
	var horizontal_direction: float = signf(impact_direction.x)
	if is_zero_approx(horizontal_direction) and source is Node2D:
		horizontal_direction = signf(global_position.x - (source as Node2D).global_position.x)
	if is_zero_approx(horizontal_direction):
		horizontal_direction = -1.0 if graphics.scale.x > 0.0 else 1.0
	var received_multiplier: float = maxf(knockback_received_multiplier, 0.0)
	var knockback_distance: float = _resolve_knockback_distance(source) * received_multiplier
	velocity.x = horizontal_direction * _get_knockback_speed_for_distance(
		knockback_distance, hurt_knockback_deceleration, _hurt_state_time_left)
	# 竖直速度按倍率平方根缩放，使理想抬升高度也近似按同一倍率变化。
	velocity.y = minf(velocity.y, -hurt_knockback_lift * sqrt(received_multiplier))


func _enter_dead_state() -> void:
	_is_dead = true
	_hurt_state_time_left = 0.0
	_death_time_left = death_respawn_delay_seconds
	_respawn_request_sent = false
	graphics.modulate = Color(0.48, 0.48, 0.52, 1.0)
	died.emit()


## 清掉当前动作、移动边沿与连段缓存；输入层仍可在硬直结束后恢复持续按住的指令。
func _cancel_action_input() -> void:
	var charge_was_active: bool = _charge_mode
	_attack_requested = false
	_secondary_attack_requested = false
	_straight_shot_requested = false
	_interact_requested = false
	_charged_attack_requested = false
	_charge_mode = false
	_charge_elapsed_seconds = 0.0
	_attack_held = false
	_attack_hold_elapsed = 0.0
	_has_buffered_move = false
	_buffered_move_dir = 0.0
	_buffered_jump_requested = false
	_buffered_drop_requested = false
	_coyote_time_left = 0.0
	_jump_request_time_left = 0.0
	if weapon != null:
		weapon.cancel_attack()
	if charge_was_active:
		charge_mode_changed.emit(false)
		charge_action_ended.emit(false)
		_update_equipped_weapon_visuals()


func _update_health_visual() -> void:
	if health_fill == null:
		return
	var ratio: float = clampf(current_health / maxf(max_health, 1.0), 0.0, 1.0)
	health_fill.size.x = 50.0 * ratio
	health_fill.color = Color("6de06f") if ratio > 0.3 else Color("ef5b5b")


## SwordWeapon 在起手首帧会把剩余帧数从完整时长减一，借此识别每段只出现一次的起手点。
func _did_start_attack_this_frame() -> bool:
	if weapon == null or weapon.phase != SwordWeapon.Phase.WINDUP:
		return false
	return weapon.frames_left == weapon.get_combo_windup_duration(weapon.combo_index) - 1
