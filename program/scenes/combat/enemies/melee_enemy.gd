class_name MeleeEnemy
extends BaseActor

## 第一只基础敌人：只在当前水平地面追击，不做寻路；保留木桩时期的命中统计便于调试。
const DEFAULT_COMBAT_TUNING: CombatTuning = preload("res://resources/combat_tuning.tres")
const BODY_CENTER_Y: float = -24.0
signal defeated(enemy: CharacterBody2D)
## 供动作级负延迟释放临时负载；受伤打断属于 unsuccessful。
signal delay_action_ended(successful: bool)

# 保留原攻击阶段的 0～4 数值，旧测试和调试面板不需要跟着改编号。
enum EnemyState { IDLE = 0, WINDUP = 1, ACTIVE = 2, RECOVERY = 3, DEFEATED = 4, CHASE = 5, HURT = 6 }
## 延迟帧记录已经完成判断的操作，避免预览和本体因微小位置差在距离边界做出不同决定。
enum DelayIntent { HOLD, START_CHASE, MOVE, START_ATTACK, DISENGAGE }

@export_group("Health")
## 10 + 12 + 20，正好让一套完整三连斩击破默认木桩。
@export_range(1.0, 1000.0, 1.0) var max_health: float = 42.0

@export_group("Attack")
## 是否允许该敌人搜索玩家、追击并进入攻击阶段；关闭后可作为纯受击木桩。
@export var attack_enabled: bool = true
## 敌人预览体仍运行攻击阶段，但关闭真实伤害，只给玩家看未来威胁。
@export var damage_enabled: bool = true
## 敌人近战判定成功时对玩家造成的基础伤害。
@export_range(1.0, 1000.0, 1.0) var attack_damage: float = 20.0
## 敌人近战命中玩家时提供的基础硬直；远程弹体使用弹体自己的值。
@export_range(0.0, 3.0, 0.01) var attack_hit_stun_seconds: float = 0.20
## 敌人近战命中玩家时的基础水平击退距离。
@export_range(0.0, 1000.0, 0.5) var attack_knockback_distance: float = 32.7
## 敌人开始感知和追击玩家的最大水平距离，单位为世界像素。
@export_range(20.0, 1000.0, 1.0) var detection_range: float = 480.0
## 玩家离开该水平距离后敌人放弃追击；应大于 Detection Range，避免在边界反复切换。
@export_range(20.0, 1500.0, 1.0) var disengage_range: float = 640.0
## 敌人近战矩形从身体向前延伸的距离，单位为世界像素。
@export_range(20.0, 300.0, 1.0) var attack_reach: float = 112.0
## 进入这个水平距离后停下并起手，略小于实际判定范围。
@export_range(10.0, 300.0, 1.0) var attack_stop_distance: float = 88.0
## 敌人感知与近战判定允许的上下高度差，单位为世界像素。
@export_range(20.0, 300.0, 1.0) var attack_height: float = 100.0
## 进入攻击范围后，从显示预警到伤害判定生效的前摇时间，单位为逻辑秒。
@export_range(0.05, 2.0, 0.05) var windup_seconds: float = 0.55
## 近战伤害判定保持有效的时间，单位为逻辑秒；一轮攻击最多命中玩家一次。
@export_range(0.01, 1.0, 0.01) var active_seconds: float = 0.12
## 攻击判定结束后的收招时间，单位为逻辑秒；期间不能开始下一轮攻击。
@export_range(0.05, 3.0, 0.05) var recovery_seconds: float = 0.80

@export_group("Movement")
## 敌人水平速度趋近目标追击速度或 0 的加速度，单位为像素/秒²。
@export_range(0.0, 3000.0, 25.0) var move_acceleration: float = 700.0

@export_group("Hurt")
## 旧伤害来源没有提供 Hit Stun Seconds 时使用的回退硬直，单位为逻辑秒。
@export_range(0.0, 1.0, 0.01) var hurt_seconds: float = 0.16
## 敌人承受硬直的倍率。最终硬直 = 攻击来源基础硬直 × 此值；0 表示不保留持续硬直。
@export_range(0.0, 5.0, 0.05) var hurt_stun_multiplier: float = 1.0
## 敌人承受击退的倍率。最终理想距离 = 攻击来源基础距离 × 此值；0 表示完全抵抗。
@export_range(0.0, 5.0, 0.05) var knockback_received_multiplier: float = 1.0
## 旧伤害来源没有提供 Knockback Distance 时使用的回退水平初速度，单位为像素/秒。
@export_range(0.0, 1000.0, 10.0) var hurt_knockback_speed: float = 180.0
## 受伤瞬间保证的基础向上速度，单位为像素/秒；最终值会随击退承受倍率变化。
@export_range(0.0, 600.0, 10.0) var hurt_knockback_lift: float = 100.0
## 受击水平速度回落到 0 的速率，单位为像素/秒²；越高表现越短促、起步越猛烈。
@export_range(0.0, 5000.0, 50.0) var hurt_deceleration: float = 1000.0

var hit_count: int = 0
var total_damage: float = 0.0
var last_combo: int = 0
var current_health: float = 0.0
var attack_phase: EnemyState = EnemyState.IDLE
var attack_facing: int = 1
var _flash_left: float = 0.0
var _phase_time_left: float = 0.0
var _hurt_time_left: float = 0.0
var _attack_connected: bool = false
## 每次起手递增；延迟本体据此判断是不是一轮新攻击，避免重复结算同一击。
var _attack_sequence_id: int = 0
## 一次性攻击输入带有编号；受伤期间到达时先挂起，恢复后仍会执行一次。
var _last_received_attack_action_id: int = 0
var _pending_attack_action_id: int = 0
var _pending_attack_facing: int = 1
var _attack_resolution_attempted_this_frame: bool = false
var _spawn_global_position: Vector2 = Vector2.ZERO
var _attack_shape: RectangleShape2D = RectangleShape2D.new()
var _attack_query: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()

@onready var body_visual: Polygon2D = $Body
@onready var band_visual: Polygon2D = $Band
@onready var counter: Label = $Counter
@onready var health_fill: ColorRect = $HealthBar/Fill
@onready var attack_visual: Polygon2D = $AttackVisual
## 以 Node2D 保存，避免外部场景在全局脚本类尚未登记时出现解析顺序问题。
@onready var hit_spark: Node2D = $HitSpark


func get_delay_waiting_deceleration() -> float:
	return move_acceleration


## 敌人作为近战伤害来源时，由玩家读取这个基础硬直值。
func get_hit_stun_seconds() -> float:
	return maxf(attack_hit_stun_seconds, 0.0)


func get_knockback_distance() -> float:
	return maxf(attack_knockback_distance, 0.0)


## 训练敌人的场景原点位于脚下，碰撞体中心才是人物中心。
func get_delay_ui_anchor_offset() -> Vector2:
	return Vector2(0.0, BODY_CENTER_Y)


func get_delay_selection_rect() -> Rect2:
	return Rect2(Vector2(-32.0, -56.0), Vector2(64.0, 64.0))


func _ready() -> void:
	# 玩家重生时由战斗房间的玩家适配器统一复位，避免残留半套攻击或已击破状态。
	add_to_group("player_respawn_reset")
	add_to_group("enemy_damage_body")
	_spawn_global_position = global_position
	_attack_query.shape = _attack_shape
	_attack_query.collision_mask = 1 # 第一层：玩家角色身体。
	_attack_query.collide_with_areas = false
	_attack_query.collide_with_bodies = true
	reset_combat()


## 测试和后续关卡重置共用同一个公开入口；可选清空累计命中统计。
func reset_combat(clear_statistics: bool = false) -> void:
	var canceled_windup: bool = attack_phase == EnemyState.WINDUP
	if clear_statistics:
		hit_count = 0
		total_damage = 0.0
		last_combo = 0
	global_position = _spawn_global_position
	velocity = Vector2.ZERO
	current_health = max_health
	attack_phase = EnemyState.IDLE
	_phase_time_left = 0.0
	_hurt_time_left = 0.0
	_attack_connected = false
	_attack_sequence_id = 0
	_last_received_attack_action_id = 0
	_pending_attack_action_id = 0
	_pending_attack_facing = 1
	_attack_resolution_attempted_this_frame = false
	collision_layer = 4
	if is_node_ready():
		body_visual.modulate = Color.WHITE
		band_visual.color = Color("ff6b57")
		attack_visual.visible = false
	_update_counter()
	notify_delay_body_reset()
	if canceled_windup:
		delay_action_ended.emit(false)


## impact_direction 表示攻击由武器朝目标挥来的方向；没有提供时根据攻击者位置回退计算。
func receive_hit(damage: float, source: Node, combo: int, impact_direction: Vector2 = Vector2.ZERO) -> bool:
	if attack_phase == EnemyState.DEFEATED:
		return false
	var canceled_windup: bool = attack_phase == EnemyState.WINDUP
	hit_count += 1
	total_damage += damage
	last_combo = combo
	current_health = maxf(current_health - maxf(damage, 0.0), 0.0)
	_flash_left = 0.14
	_show_hit_effect(source, combo, impact_direction)
	if current_health <= 0.0:
		_enter_defeated()
	else:
		_enter_hurt(source, impact_direction)
	_update_counter()
	# 受伤和击退立即生效；普通受伤只重算未来，击破才结束这一轮延迟时间线。
	if attack_phase == EnemyState.DEFEATED:
		notify_delay_body_defeated()
	else:
		report_delay_external_divergence(&"body_damaged")
	if canceled_windup:
		delay_action_ended.emit(false)
	return true


func _process(delta: float) -> void:
	_flash_left = maxf(_flash_left - delta, 0.0)
	if attack_phase != EnemyState.DEFEATED:
		body_visual.modulate = Color("ffe2a1") if _flash_left > 0.0 else Color.WHITE


## 所有阶段使用世界逻辑时间；暂停、慢动作和固定 100 TPS 下都保持一致。
func _physics_process(delta: float) -> void:
	var command: Dictionary = capture_delay_command()
	simulate_delay_command(command, delta)


## AI 的“输入帧”与玩家的移动/攻击输入一样，保存已经解析完成的操作意图。
## 目标位置只在预览体采样时参与判断，本体回放时不会再次比较距离。
func capture_delay_command() -> Dictionary:
	var target: BaseActor = _get_player_target()
	var has_target: bool = target != null
	var intent: DelayIntent = DelayIntent.HOLD
	var facing: int = attack_facing
	if has_target:
		var target_position: Vector2 = target.global_position
		facing = -1 if target_position.x < global_position.x else 1
		match attack_phase:
			EnemyState.IDLE:
				if _is_position_in_detection_range(target_position):
					intent = DelayIntent.START_ATTACK if _is_position_in_attack_range(target_position) \
						else DelayIntent.START_CHASE
			EnemyState.CHASE:
				if global_position.distance_to(target_position) > disengage_range:
					intent = DelayIntent.DISENGAGE
				elif _is_position_in_attack_range(target_position):
					intent = DelayIntent.START_ATTACK
				else:
					intent = DelayIntent.MOVE
	elif attack_phase == EnemyState.CHASE:
		intent = DelayIntent.DISENGAGE
	# START_ATTACK 是边沿事件而不是连续状态，用稳定编号保证重算或受伤缓冲不会重复执行。
	var attack_action_id: int = 0
	if intent == DelayIntent.START_ATTACK:
		attack_action_id = maxi(_attack_sequence_id, _last_received_attack_action_id) + 1
	return {
		"has_target": has_target,
		"intent": int(intent),
		"facing": facing,
		"attack_action_id": attack_action_id,
	}


## 唯一的敌人物理入口：实时 AI、蓝色预览、延迟本体和隐藏预测器全走这里。
func simulate_delay_command(command: Dictionary, delta: float) -> void:
	_attack_resolution_attempted_this_frame = false
	if attack_phase == EnemyState.DEFEATED:
		_move_dead_body(delta)
		return
	if not attack_enabled:
		_move_with_gravity(delta, 0.0)
		return
	var has_target: bool = bool(command.get("has_target", false))
	var intent: DelayIntent = int(command.get("intent", int(DelayIntent.HOLD))) as DelayIntent
	var command_facing: int = int(command.get("facing", attack_facing))
	var attack_action_id: int = int(command.get("attack_action_id", 0))
	if intent == DelayIntent.START_ATTACK:
		# 兼容没有编号的旧记录和测试命令，同时过滤重算时可能再次遇到的同一事件。
		if attack_action_id <= 0:
			attack_action_id = maxi(_attack_sequence_id, _last_received_attack_action_id) + 1
		if attack_action_id <= _last_received_attack_action_id:
			intent = DelayIntent.HOLD
		else:
			_last_received_attack_action_id = attack_action_id
			if attack_phase == EnemyState.HURT:
				_pending_attack_action_id = attack_action_id
				_pending_attack_facing = command_facing
				intent = DelayIntent.HOLD
	match attack_phase:
		EnemyState.IDLE:
			_tick_idle(delta, intent, command_facing, attack_action_id)
		EnemyState.CHASE:
			_tick_chase(delta, intent, command_facing, attack_action_id)
		EnemyState.WINDUP:
			_move_with_gravity(delta, 0.0)
			_phase_time_left = maxf(_phase_time_left - delta, 0.0)
			_update_attack_visual()
			if _phase_time_left <= 0.0:
				_complete_windup()
		EnemyState.ACTIVE:
			_move_with_gravity(delta, 0.0)
			if not _attack_connected:
				_attack_resolution_attempted_this_frame = true
				if damage_enabled:
					_resolve_attack_hit()
			_phase_time_left = maxf(_phase_time_left - delta, 0.0)
			if _phase_time_left <= 0.0:
				attack_phase = EnemyState.RECOVERY
				_phase_time_left = recovery_seconds
				_update_attack_visual()
		EnemyState.RECOVERY:
			_move_with_gravity(delta, 0.0)
			_phase_time_left = maxf(_phase_time_left - delta, 0.0)
			if _phase_time_left <= 0.0:
				attack_phase = EnemyState.CHASE if has_target else EnemyState.IDLE
		EnemyState.HURT:
			_tick_hurt(delta, has_target)


func _tick_idle(
	delta: float,
	intent: DelayIntent,
	command_facing: int,
	attack_action_id: int
) -> void:
	_move_with_gravity(delta, 0.0)
	if intent == DelayIntent.START_ATTACK:
		_begin_attack_facing(command_facing, attack_action_id)
	elif intent == DelayIntent.START_CHASE:
		attack_phase = EnemyState.CHASE


func _tick_chase(
	delta: float,
	intent: DelayIntent,
	command_facing: int,
	attack_action_id: int
) -> void:
	if intent == DelayIntent.DISENGAGE:
		attack_phase = EnemyState.IDLE
		_move_with_gravity(delta, 0.0)
		return
	if intent == DelayIntent.START_ATTACK:
		_begin_attack_facing(command_facing, attack_action_id)
		_move_with_gravity(delta, 0.0)
		return
	if intent == DelayIntent.MOVE:
		attack_facing = command_facing
		_move_with_gravity(delta, float(command_facing) * move_speed)
		return
	_move_with_gravity(delta, 0.0)


func _tick_hurt(delta: float, has_target: bool) -> void:
	_hurt_time_left = maxf(_hurt_time_left - delta, 0.0)
	velocity.x = move_toward(velocity.x, 0.0, hurt_deceleration * delta)
	velocity.y += gravity * delta
	move_and_slide()
	if _hurt_time_left <= 0.0:
		if _pending_attack_action_id > 0:
			var pending_action_id: int = _pending_attack_action_id
			var pending_facing: int = _pending_attack_facing
			_pending_attack_action_id = 0
			_begin_attack_facing(pending_facing, pending_action_id)
		else:
			attack_phase = EnemyState.CHASE if has_target else EnemyState.IDLE


func _move_with_gravity(delta: float, target_velocity_x: float) -> void:
	velocity.x = move_toward(velocity.x, target_velocity_x, move_acceleration * delta)
	velocity.y += gravity * delta
	move_and_slide()


func _move_dead_body(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, hurt_deceleration * delta)
	velocity.y += gravity * delta
	move_and_slide()


func _begin_attack_facing(command_facing: int, attack_action_id: int = 0) -> void:
	attack_facing = -1 if command_facing < 0 else 1
	attack_phase = EnemyState.WINDUP
	velocity.x = 0.0
	_phase_time_left = windup_seconds
	_attack_connected = false
	_attack_sequence_id = maxi(_attack_sequence_id + 1, attack_action_id)
	_update_attack_visual()


func is_delay_acceleratable_action_active() -> bool:
	return attack_phase == EnemyState.WINDUP and _phase_time_left > 0.0


func get_delay_acceleratable_seconds() -> float:
	return _phase_time_left if is_delay_acceleratable_action_active() else 0.0


## 负延迟只削减当前一次前摇，不影响移动、受伤或后续攻击循环。
func advance_delay_action_time(seconds: float) -> float:
	if not is_delay_acceleratable_action_active() or seconds <= 0.0:
		return 0.0
	var applied_seconds: float = minf(seconds, _phase_time_left)
	_phase_time_left = maxf(_phase_time_left - applied_seconds, 0.0)
	if _phase_time_left <= 0.0:
		_complete_windup()
	else:
		_update_attack_visual()
	return applied_seconds


## 近战前摇结束即视为动作成功；真正伤害仍在下一次 ACTIVE 物理帧结算。
func _complete_windup() -> void:
	attack_phase = EnemyState.ACTIVE
	_phase_time_left = active_seconds
	_update_attack_visual()
	delay_action_ended.emit(true)

## 延迟历史只记录模拟状态；生命值与命中统计始终归真实本体所有。
func capture_simulation_state() -> Dictionary:
	return {
		"attack_phase": int(attack_phase),
		"attack_facing": attack_facing,
		"phase_time_left": _phase_time_left,
		"hurt_time_left": _hurt_time_left,
		"attack_sequence_id": _attack_sequence_id,
		"last_received_attack_action_id": _last_received_attack_action_id,
		"pending_attack_action_id": _pending_attack_action_id,
		"pending_attack_facing": _pending_attack_facing,
		"attack_connected": _attack_connected,
		"attack_resolution_attempted": _attack_resolution_attempted_this_frame,
		"attack_enabled": attack_enabled,
	}


## 只用于给预览体或隐藏预测器同步演算起点；真实本体绝不从历史快照还原。
func restore_simulation_state(snapshot: Dictionary) -> void:
	attack_phase = int(snapshot.get("attack_phase", int(attack_phase)))
	attack_facing = int(snapshot.get("attack_facing", attack_facing))
	_phase_time_left = float(snapshot.get("phase_time_left", _phase_time_left))
	_hurt_time_left = float(snapshot.get("hurt_time_left", _hurt_time_left))
	attack_enabled = bool(snapshot.get("attack_enabled", attack_enabled))
	_attack_sequence_id = int(snapshot.get("attack_sequence_id", _attack_sequence_id))
	_last_received_attack_action_id = int(snapshot.get(
		"last_received_attack_action_id", _last_received_attack_action_id
	))
	_pending_attack_action_id = int(snapshot.get(
		"pending_attack_action_id", _pending_attack_action_id
	))
	_pending_attack_facing = int(snapshot.get("pending_attack_facing", _pending_attack_facing))
	_attack_connected = bool(snapshot.get("attack_connected", false))
	_attack_resolution_attempted_this_frame = bool(
		snapshot.get("attack_resolution_attempted", false)
	)
	_update_attack_visual()


## 延迟刚开启或被增加时，本体和玩家一样等待历史：不推进重力与攻击计时，只水平刹停。
func tick_delay_waiting(delta: float) -> void:
	_attack_resolution_attempted_this_frame = false
	# 受伤是外部世界立即施加的状态，不因延迟历史尚未填满而冻结其击退和硬直计时。
	if attack_phase == EnemyState.HURT:
		_tick_hurt(delta, _get_player_target() != null)
		return
	if attack_phase == EnemyState.DEFEATED:
		_move_dead_body(delta)
		return
	var deceleration: float = hurt_deceleration if attack_phase in [EnemyState.HURT, EnemyState.DEFEATED] \
		else move_acceleration
	velocity.x = move_toward(velocity.x, 0.0, deceleration * delta)
	var saved_vertical_velocity: float = velocity.y
	velocity.y = 0.0
	move_and_slide()
	velocity.y = saved_vertical_velocity


## 蓝色敌人只负责展示实时 AI 结果，不进入伤害、碰撞或战斗房间统计。
func configure_as_delay_preview() -> void:
	configure_delay_replica(DelayReplicaRole.PREVIEW)


## 敌人适配器保留自己的受伤策略，但副本权限统一通过 BaseActor 角色配置。
func configure_delay_replica(role: DelayReplicaRole) -> void:
	super.configure_delay_replica(role)
	if role == DelayReplicaRole.AUTHORITY:
		add_to_group("enemy_damage_body")
		return
	damage_enabled = false
	set_physics_process(false)
	remove_from_group("player_respawn_reset")
	remove_from_group("enemy_damage_body")
	collision_layer = 0
	collision_mask = 2 # 只与地形相撞，不被玩家武器查询，也不挤开真实敌人。
	modulate = Color(0.40, 0.82, 1.0, 0.58)
	z_index = 1
	counter.visible = false
	$HealthBar.visible = false
	hit_spark.visible = false


func _resolve_attack_hit() -> void:
	_attack_shape.size = Vector2(attack_reach, attack_height)
	var center: Vector2 = global_position + Vector2(
		float(attack_facing) * attack_reach * 0.5,
		-attack_height * 0.5
	)
	_attack_query.transform = Transform2D(0.0, center)
	for hit: Dictionary in get_world_2d().direct_space_state.intersect_shape(_attack_query, 16):
		var target: Node = hit.get("collider") as Node
		if target == null or not target.is_in_group("player_damage_body") or not target.has_method("receive_hit"):
			continue
		var accepted: Variant = target.call(
			"receive_hit", attack_damage, self, 1, Vector2(float(attack_facing), 0.0)
		)
		if bool(accepted):
			_attack_connected = true
			break


func _get_player_target() -> BaseActor:
	var node: Node = get_tree().get_first_node_in_group("player_damage_body")
	if node is BaseActor and node.has_method("is_alive") and bool(node.call("is_alive")):
		return node as BaseActor
	return null


func _is_position_in_detection_range(target_position: Vector2) -> bool:
	var offset: Vector2 = target_position - global_position
	return absf(offset.x) <= detection_range and absf(offset.y - BODY_CENTER_Y) <= attack_height


func _is_position_in_attack_range(target_position: Vector2) -> bool:
	var offset: Vector2 = target_position - global_position
	return absf(offset.x) <= attack_stop_distance and absf(offset.y - BODY_CENTER_Y) <= attack_height


func _update_attack_visual() -> void:
	attack_visual.polygon = PackedVector2Array([
		Vector2(0.0, -attack_height),
		Vector2(attack_reach, -attack_height),
		Vector2(attack_reach, 0.0),
		Vector2.ZERO,
	])
	attack_visual.scale.x = float(attack_facing)
	attack_visual.visible = attack_phase in [EnemyState.WINDUP, EnemyState.ACTIVE]
	if attack_phase == EnemyState.WINDUP:
		var progress: float = 1.0 - _phase_time_left / maxf(windup_seconds, 0.001)
		attack_visual.color = Color(1.0, 0.72, 0.20, lerpf(0.14, 0.42, progress))
	elif attack_phase == EnemyState.ACTIVE:
		attack_visual.color = Color(1.0, 0.20, 0.16, 0.62)


func _enter_hurt(source: Node, impact_direction: Vector2) -> void:
	attack_phase = EnemyState.HURT
	_phase_time_left = 0.0
	_hurt_time_left = _resolve_hit_stun_seconds(source)
	_attack_connected = false
	attack_visual.visible = false
	var horizontal_direction: float = signf(impact_direction.x)
	if is_zero_approx(horizontal_direction) and source is Node2D:
		horizontal_direction = signf(global_position.x - (source as Node2D).global_position.x)
	if is_zero_approx(horizontal_direction):
		horizontal_direction = 1.0
	var received_multiplier: float = maxf(knockback_received_multiplier, 0.0)
	var knockback_distance: float = _resolve_knockback_distance(source) * received_multiplier
	velocity.x = horizontal_direction * _get_knockback_speed_for_distance(
		knockback_distance, hurt_deceleration, _hurt_time_left)
	# 竖直速度按倍率平方根缩放，使理想抬升高度也近似按同一倍率变化。
	velocity.y = minf(velocity.y, -hurt_knockback_lift * sqrt(received_multiplier))


## 新伤害来源主动提供硬直；旧来源仍安全回退到 Hurt Seconds。
func _resolve_hit_stun_seconds(source: Node) -> float:
	var base_hit_stun: float = maxf(hurt_seconds, 0.0)
	if source != null and source.has_method("get_hit_stun_seconds"):
		base_hit_stun = maxf(float(source.call("get_hit_stun_seconds")), 0.0)
	return base_hit_stun * maxf(hurt_stun_multiplier, 0.0)


## 未接入新契约的旧来源，按原初速度和当前减速度换算为等效距离。
func _resolve_knockback_distance(source: Node) -> float:
	var deceleration: float = maxf(hurt_deceleration, 0.0)
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


func _enter_defeated() -> void:
	attack_phase = EnemyState.DEFEATED
	_phase_time_left = 0.0
	_hurt_time_left = 0.0
	_pending_attack_action_id = 0
	attack_visual.visible = false
	# 从剑的受击查询层移除，尸体不会继续吃伤害或挡住后续挥砍。
	collision_layer = 0
	body_visual.modulate = Color("686868")
	band_visual.color = Color("555555")
	defeated.emit(self)


func is_defeated() -> bool:
	return attack_phase == EnemyState.DEFEATED


func _update_counter() -> void:
	var ratio: float = clampf(current_health / maxf(max_health, 1.0), 0.0, 1.0)
	if health_fill != null:
		health_fill.size.x = 82.0 * ratio
		health_fill.color = Color("73df72") if ratio > 0.3 else Color("ef5b5b")
	var display_name: String = "追猎者" if attack_enabled else "训练假人"
	counter.text = "%s · HP %.0f / %.0f\n命中 %d 次 · 伤害 %.0f" % [
		display_name, current_health, max_health, hit_count, total_damage
	]
	if hit_count > 0:
		counter.text += "\n上次：第 %d 段" % last_combo
	if attack_phase == EnemyState.DEFEATED:
		counter.text += "\n已击破"
	elif attack_phase == EnemyState.CHASE:
		counter.text += "\n追击"
	elif attack_phase == EnemyState.HURT:
		counter.text += "\n受伤"


func _show_hit_effect(source: Node, combo: int, impact_direction: Vector2) -> void:
	var tuning: CombatTuning = _get_combat_tuning(source)
	if not tuning.hit_effect_enabled:
		return
	var direction: Vector2 = impact_direction.normalized()
	if direction.is_zero_approx() and source is Node2D:
		direction = (global_position - (source as Node2D).global_position).normalized()
	if direction.is_zero_approx():
		direction = Vector2.RIGHT
	# 小方块碰撞体中心在本地 y=-24；沿来向略向外偏移，使火花落在接触侧。
	hit_spark.position = Vector2(0.0, BODY_CENTER_Y) - Vector2(direction.x * 20.0, direction.y * 20.0)
	var size: float = tuning.heavy_hit_effect_size if combo >= 3 else tuning.hit_effect_size
	hit_spark.call("play", direction, combo, tuning.hit_effect_seconds, size,
		tuning.hit_effect_outline_width, tuning.hit_effect_grow_seconds, tuning.hit_effect_start_scale,
		tuning.hit_effect_width_multiplier, tuning.hit_effect_final_opacity)


func _get_combat_tuning(source: Node) -> CombatTuning:
	if source != null and source.has_method("get_combat_tuning"):
		var source_tuning: Variant = source.call("get_combat_tuning")
		if source_tuning is CombatTuning:
			return source_tuning as CombatTuning
	var authority: WorldTimeAuthority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	return authority.get_combat_tuning() if authority != null else DEFAULT_COMBAT_TUNING
