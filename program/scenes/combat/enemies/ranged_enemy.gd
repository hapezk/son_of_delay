class_name RangedEnemy
extends MeleeEnemy

signal projectile_fired(projectile: BaseActor)

enum RangedIntent { HOLD, START_CHASE, MOVE, START_SHOT, DISENGAGE }

@export_group("Ranged Attack")
## 远程敌人攻击时实例化的弹体场景；根节点必须是可 launch() 的 BaseActor。
@export var projectile_scene: PackedScene
## 敌人希望与玩家保持的水平距离，单位为世界像素；太远会靠近，太近会后退。
@export_range(80.0, 1000.0, 10.0) var preferred_range: float = 520.0
## 弹体出生点相对敌人脚下原点的偏移；X 会随敌人朝向左右翻转，Y 保持不变。
@export var muzzle_offset: Vector2 = Vector2(28.0, -24.0)

var _ranged_aim_direction: Vector2 = Vector2.LEFT
var _pending_shot_aim: Vector2 = Vector2.LEFT


## 远程敌人同样记录已解析意图；瞄准方向在预览时确定，延迟本体不会重新追踪玩家。
func capture_delay_command() -> Dictionary:
	var target: BaseActor = _get_player_target()
	var has_target: bool = target != null
	var intent: RangedIntent = RangedIntent.HOLD
	var facing: int = attack_facing
	var aim_direction: Vector2 = _ranged_aim_direction
	if has_target:
		var target_position: Vector2 = target.global_position
		var offset: Vector2 = target_position - global_position
		facing = -1 if offset.x < 0.0 else 1
		aim_direction = (target_position - to_global(Vector2(float(facing) * muzzle_offset.x, muzzle_offset.y))).normalized()
		match attack_phase:
			EnemyState.IDLE:
				if offset.length() <= detection_range:
					intent = RangedIntent.START_SHOT if absf(offset.x) <= preferred_range \
						else RangedIntent.START_CHASE
			EnemyState.CHASE:
				if offset.length() > disengage_range:
					intent = RangedIntent.DISENGAGE
				elif absf(offset.x) <= preferred_range:
					intent = RangedIntent.START_SHOT
				else:
					intent = RangedIntent.MOVE
	elif attack_phase == EnemyState.CHASE:
		intent = RangedIntent.DISENGAGE
	var shot_action_id: int = 0
	if intent == RangedIntent.START_SHOT:
		shot_action_id = maxi(_attack_sequence_id, _last_received_attack_action_id) + 1
	return {
		"has_target": has_target,
		"intent": int(intent),
		"facing": facing,
		"aim_direction": aim_direction,
		"shot_action_id": shot_action_id,
	}


func simulate_delay_command(command: Dictionary, delta: float) -> void:
	if attack_phase == EnemyState.DEFEATED:
		_move_dead_body(delta)
		return
	if not attack_enabled:
		_move_with_gravity(delta, 0.0)
		return
	var has_target: bool = bool(command.get("has_target", false))
	var intent: RangedIntent = int(command.get("intent", int(RangedIntent.HOLD))) as RangedIntent
	var facing: int = int(command.get("facing", attack_facing))
	var aim_direction: Vector2 = command.get("aim_direction", _ranged_aim_direction) as Vector2
	var shot_action_id: int = int(command.get("shot_action_id", 0))
	if intent == RangedIntent.START_SHOT:
		if shot_action_id <= 0:
			shot_action_id = maxi(_attack_sequence_id, _last_received_attack_action_id) + 1
		if shot_action_id <= _last_received_attack_action_id:
			intent = RangedIntent.HOLD
		else:
			_last_received_attack_action_id = shot_action_id
			if attack_phase == EnemyState.HURT:
				_pending_attack_action_id = shot_action_id
				_pending_attack_facing = facing
				_pending_shot_aim = aim_direction
				intent = RangedIntent.HOLD
	match attack_phase:
		EnemyState.IDLE:
			_move_with_gravity(delta, 0.0)
			if intent == RangedIntent.START_SHOT:
				_begin_ranged_attack(facing, aim_direction, shot_action_id)
			elif intent == RangedIntent.START_CHASE:
				attack_phase = EnemyState.CHASE
		EnemyState.CHASE:
			_tick_ranged_chase(delta, intent, facing, aim_direction, shot_action_id)
		EnemyState.WINDUP:
			_move_with_gravity(delta, 0.0)
			_phase_time_left = maxf(_phase_time_left - delta, 0.0)
			_update_attack_visual()
			if _phase_time_left <= 0.0:
				_complete_windup()
		EnemyState.RECOVERY:
			_move_with_gravity(delta, 0.0)
			_phase_time_left = maxf(_phase_time_left - delta, 0.0)
			if _phase_time_left <= 0.0:
				attack_phase = EnemyState.CHASE if has_target else EnemyState.IDLE
		EnemyState.HURT:
			_tick_ranged_hurt(delta, has_target)


func _tick_ranged_chase(
	delta: float,
	intent: RangedIntent,
	facing: int,
	aim_direction: Vector2,
	shot_action_id: int
) -> void:
	if intent == RangedIntent.DISENGAGE:
		attack_phase = EnemyState.IDLE
		_move_with_gravity(delta, 0.0)
	elif intent == RangedIntent.START_SHOT:
		_begin_ranged_attack(facing, aim_direction, shot_action_id)
		_move_with_gravity(delta, 0.0)
	elif intent == RangedIntent.MOVE:
		attack_facing = facing
		_move_with_gravity(delta, float(facing) * move_speed)
	else:
		_move_with_gravity(delta, 0.0)


func _tick_ranged_hurt(delta: float, has_target: bool) -> void:
	_hurt_time_left = maxf(_hurt_time_left - delta, 0.0)
	velocity.x = move_toward(velocity.x, 0.0, hurt_deceleration * delta)
	velocity.y += gravity * delta
	move_and_slide()
	if _hurt_time_left > 0.0:
		return
	if _pending_attack_action_id > 0:
		var pending_id: int = _pending_attack_action_id
		var pending_facing: int = _pending_attack_facing
		_pending_attack_action_id = 0
		_begin_ranged_attack(pending_facing, _pending_shot_aim, pending_id)
	else:
		attack_phase = EnemyState.CHASE if has_target else EnemyState.IDLE


func _begin_ranged_attack(facing: int, aim_direction: Vector2, action_id: int) -> void:
	attack_facing = -1 if facing < 0 else 1
	_ranged_aim_direction = aim_direction.normalized()
	if _ranged_aim_direction.is_zero_approx():
		_ranged_aim_direction = Vector2(float(attack_facing), 0.0)
	attack_phase = EnemyState.WINDUP
	velocity.x = 0.0
	_phase_time_left = windup_seconds
	_attack_sequence_id = maxi(_attack_sequence_id + 1, action_id)
	_update_attack_visual()


func _complete_windup() -> void:
	if damage_enabled:
		_spawn_projectile()
	attack_phase = EnemyState.RECOVERY
	_phase_time_left = recovery_seconds
	_update_attack_visual()
	delay_action_ended.emit(true)


func _spawn_projectile() -> void:
	if projectile_scene == null:
		return
	var container: Node = get_tree().get_first_node_in_group("hostile_projectile_container")
	if container == null:
		push_warning("RangedEnemy: hostile projectile container not found")
		return
	var projectile: BaseActor = projectile_scene.instantiate() as BaseActor
	if projectile == null:
		push_error("RangedEnemy: projectile_scene must instantiate BaseActor")
		return
	container.add_child(projectile)
	projectile.global_position = to_global(Vector2(float(attack_facing) * muzzle_offset.x, muzzle_offset.y))
	projectile.call("launch", _ranged_aim_direction)
	projectile_fired.emit(projectile)


func capture_simulation_state() -> Dictionary:
	var state: Dictionary = super.capture_simulation_state()
	state["ranged_aim_direction"] = _ranged_aim_direction
	state["pending_shot_aim"] = _pending_shot_aim
	return state


func restore_simulation_state(state: Dictionary) -> void:
	super.restore_simulation_state(state)
	_ranged_aim_direction = state.get("ranged_aim_direction", _ranged_aim_direction) as Vector2
	_pending_shot_aim = state.get("pending_shot_aim", _pending_shot_aim) as Vector2
	_update_attack_visual()


func _update_attack_visual() -> void:
	if attack_visual == null:
		return
	attack_visual.position = Vector2(float(attack_facing) * muzzle_offset.x, muzzle_offset.y)
	attack_visual.rotation = _ranged_aim_direction.angle()
	attack_visual.polygon = PackedVector2Array([
		Vector2(0.0, -4.0), Vector2(preferred_range, -4.0),
		Vector2(preferred_range, 4.0), Vector2(0.0, 4.0),
	])
	attack_visual.visible = attack_phase == EnemyState.WINDUP
	if attack_visual.visible:
		var progress: float = 1.0 - _phase_time_left / maxf(windup_seconds, 0.001)
		attack_visual.color = Color(0.72, 0.30, 1.0, lerpf(0.12, 0.52, progress))


func _update_counter() -> void:
	var ratio: float = clampf(current_health / maxf(max_health, 1.0), 0.0, 1.0)
	if health_fill != null:
		health_fill.size.x = 82.0 * ratio
		health_fill.color = Color("73df72") if ratio > 0.3 else Color("ef5b5b")
	if counter == null:
		return
	counter.text = "远程追猎者 · HP %.0f / %.0f" % [current_health, max_health]
	if attack_phase == EnemyState.DEFEATED:
		counter.text += "\n已击破"
	elif attack_phase == EnemyState.WINDUP:
		counter.text += "\n瞄准"
	elif attack_phase == EnemyState.RECOVERY:
		counter.text += "\n装填"
	elif attack_phase == EnemyState.CHASE:
		counter.text += "\n寻找射距"
