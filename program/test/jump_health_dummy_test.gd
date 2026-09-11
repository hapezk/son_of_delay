extends SceneTree

## 跳跃宽限、玩家受伤和木桩生命闭环：
## --headless --path program --script res://test/jump_health_dummy_test.gd
var _scene: Node
var _group: DelayedActorGroup
var _authority: WorldTimeAuthority
var _player: BaseActor
var _dummy: CharacterBody2D
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _run() -> void:
	_scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(_scene)
	_group = _scene.get_node("Actors/BodyGroup") as DelayedActorGroup
	_authority = _scene.get_node("WorldTimeAuthority") as WorldTimeAuthority
	_authority.thinking_entry_duration = 0.0
	_player = _group.body
	_dummy = _scene.get_node("Enemies/MeleeEnemyA") as CharacterBody2D
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	for target: Node in _scene.get_node("Enemies").get_children():
		target.set_physics_process(false)
	for delay_controller: Node in get_nodes_in_group("enemy_delay_controller"):
		delay_controller.set_physics_process(false)
	await physics_frame
	_test_jump_windows()
	await _test_health_and_dummy_attack()
	_test_delay_reentry_after_airborne_damage()
	_test_replay_mismatch_recovery()
	await _test_hurt_state_and_respawn()
	_test_dummy_health()
	await _test_continuous_input_after_hurt()
	if _failures.is_empty():
		print("JUMP_HEALTH_DUMMY_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("JUMP_HEALTH_DUMMY_TEST_FAIL: " + failure)
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)


func _test_jump_windows() -> void:
	_player.restore_simulation_state({"coyote_time_left": 0.08, "jump_request_time_left": 0.0})
	_check(bool(_player.call("_consume_jump_request", true, false, 0.01)),
		"Jump pressed during coyote time must start a jump")

	_player.restore_simulation_state({"coyote_time_left": 0.0, "jump_request_time_left": 0.0})
	_check(not bool(_player.call("_consume_jump_request", true, false, 0.01)),
		"Airborne jump press must wait when coyote time has expired")
	_check(bool(_player.call("_consume_jump_request", false, true, 0.01)),
		"A buffered airborne request must fire immediately on landing")
	_player.restore_simulation_state({"coyote_time_left": 0.0, "jump_request_time_left": 0.0})
	_player.call("_consume_jump_request", true, false, 0.01)
	for frame: int in range(20):
		_player.call("_consume_jump_request", false, false, 0.01)
	_check(not bool(_player.call("_consume_jump_request", false, true, 0.01)),
		"An expired landing request must not cause a late automatic jump")

	_player.restore_simulation_state({"coyote_time_left": 0.07, "jump_request_time_left": 0.05})
	_group.sync_predictor_to_body()
	_check(_group.predictor.capture_simulation_state() == _player.capture_simulation_state(),
		"Predictor must inherit both jump-assist timers from the body")
	print("PASS: coyote jump, landing request and predictor state copy")


## 持续按住的输入不会重新产生 pressed 事件；受伤恢复后必须由缓冲器主动接回。
func _test_continuous_input_after_hurt() -> void:
	_group._setting_delay_internally = true
	_group.delay_time = 0.0
	_group._setting_delay_internally = false
	_group._pending_delay = -1.0
	_group.body.inputed = true
	_player.call("reset_health")
	_player.velocity = Vector2.ZERO
	var input_buffer: AttackInputBuffer = _group.get_node("AttackInputBuffer") as AttackInputBuffer
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = Vector2(900.0, 360.0)
	press.pressed = true
	Input.action_press("attack")
	root.push_input(press, true)
	_check(bool(_player.get("_attack_held")),
		"Accepted left-button press must enter the continuous attack state")
	_player.call("receive_hit", 1.0, _dummy, 1, Vector2.LEFT)
	_check(not bool(_player.get("_attack_held")),
		"Hurt interruption must cancel the current weapon action")
	_player.set("_hurt_state_time_left", 0.0)
	input_buffer.call("_process", 0.0)
	_check(bool(_player.get("_attack_held")) and bool(_player.get("_attack_requested")),
		"Still-held left button must automatically resume attacking after hurt")
	Input.action_press("ui_right")
	_player.velocity = Vector2.ZERO
	_player.tick_physics(0, 0.01)
	_check(_player.velocity.x > 0.0,
		"Still-held movement direction must resume on the first controllable frame after hurt")
	Input.action_release("ui_right")
	Input.action_release("attack")
	var release: InputEventMouseButton = press.duplicate() as InputEventMouseButton
	release.pressed = false
	root.push_input(release, true)
	await process_frame
	print("PASS: held attack and movement resume after hurt interruption")


func _test_health_and_dummy_attack() -> void:
	_player.call("reset_health")
	_player.global_position = Vector2(350.0, 624.9)
	_group.preview_body.global_position = Vector2(650.0, 624.9)
	_dummy.set("attack_damage", 20.0)
	_dummy.set("attack_enabled", true)
	_dummy.call("reset_combat", true)
	# reset_combat 会回到正式关卡出生点；测试随后放回近战距离。
	_dummy.global_position = Vector2(420.0, 649.0)
	await physics_frame
	_dummy.call("_physics_process", 0.01)
	_check(int(_dummy.get("attack_phase")) == 1 and _dummy.get_node("AttackVisual").visible,
		"A nearby player must start the dummy windup and show its warning area")
	for frame: int in range(80):
		if int(_dummy.get("attack_phase")) != 1:
			break
		_dummy.call("_physics_process", 0.01)
	_check(int(_dummy.get("attack_phase")) == 2,
		"Dummy windup must transition to the active attack phase")
	_dummy.call("_physics_process", 0.01)
	_check(is_equal_approx(float(_player.get("current_health")), 80.0),
		"One active dummy attack must remove 20 health from the real body")
	_check(is_zero_approx(_group.delay_time)
		and is_equal_approx(_group.get_requested_delay(), _group.natural_delay_time)
		and _group.last_divergence_reason == &"body_damaged",
		"Damage must temporarily return authority to the body while preserving the delay setting")
	_check(_group.preview_system.read_head == -1 and _group.preview_system.write_head == -1,
		"Damage divergence must clear old recorded input")
	_check(_group.preview_body.visible and int(_group.get("_divergence_flashback_frames_left")) > 0,
		"Invalid preview must remain visible briefly while flashing back")
	_check(not _group.request_delay_change(1.0),
		"Player delay requests outside thinking time must be rejected")
	_group.call("_physics_process", 0.01)
	_check(is_zero_approx(_group.delay_time)
		and is_equal_approx(_group.get_requested_delay(), _group.natural_delay_time),
		"The preserved setting must wait until the visible flashback has finished")
	_dummy.call("_physics_process", 0.01)
	_check(is_equal_approx(float(_player.get("current_health")), 80.0),
		"Player invulnerability must reject repeated active-frame damage")
	_check(not bool(_group.preview_body.call("can_receive_hit")) and not bool(_group.predictor.call("can_receive_hit")),
		"Preview and predictor must never accept real damage")
	for frame: int in range(_group.divergence_flashback_frames - 1):
		_group.call("_physics_process", 0.01)
	_check(is_zero_approx(_group.delay_time) and not _player.is_delay_reentry_ready(),
		"Flashback completion must keep body authority until hurt knockback has ended")
	_player.set("_hurt_state_time_left", 0.0)
	_group.call("_physics_process", 0.01)
	_check(is_equal_approx(_group.delay_time, _group.natural_delay_time)
		and _group.preview_body.visible and _group.preview_body.inputed
		and not _player.inputed,
		"Hurt completion must rebuild the preserved delay and return input to the preview")
	_dummy.set("attack_enabled", false)
	print("PASS: dummy damage, invulnerability and real-body authority")


func _test_replay_mismatch_recovery() -> void:
	_group._setting_delay_internally = true
	_group.delay_time = 0.5
	_group._setting_delay_internally = false
	_group.body.inputed = false
	_group.preview_body.inputed = true
	_group.preview_body.global_position = _player.global_position + Vector2(200.0, 0.0)
	var expected: Recording = Recording.new(
		0.0, false, _player.global_position + Vector2(10.0, 0.0), _player.velocity
	)
	_check(_group.check_replay_divergence(_player, expected),
		"A replay position outside tolerance must trigger generic divergence recovery")
	_check(_group.last_divergence_reason == &"replay_mismatch" and is_equal_approx(_group.last_divergence_position_error, 10.0),
		"Generic divergence must retain its reason and measured position error")
	_check(is_zero_approx(_group.delay_time), "Generic divergence must also return control to zero delay")
	print("PASS: replay mismatch detection and recovery")


## 受击清空历史后，若本体仍在空中高速移动，重新施加延迟的第一条记录也必须从
## “减速后的未来起点”写入，不能先记录旧位置再于下一帧瞬移。
func _test_delay_reentry_after_airborne_damage() -> void:
	# 独立验证 0 -> 正延迟重入；前一项已覆盖受伤后自动恢复持续设置。
	_group.preview_system.reset_to_initial_state()
	_group.set_delay_time_immediate(0.0)
	_group._pending_delay = -1.0
	_group.body.inputed = true
	_group.preview_body.inputed = false
	_group.preview_body.hide()
	var body_collision_mask: int = _group.body.collision_mask
	var preview_collision_mask: int = _group.preview_body.collision_mask
	_group.body.collision_mask = 0
	_group.preview_body.collision_mask = 0
	_group.body.restore_simulation_state({
		"coyote_time_left": 0.0,
		"jump_request_time_left": 0.0,
		"hurt_state_time_left": 0.0,
		"is_dead": false,
		"death_time_left": 0.0,
	})
	_group.body.global_position = Vector2(600.0, 300.0)
	_group.body.velocity = Vector2(-320.0, -72.0)
	_group.call("_sync_hidden_preview_to_body", true)
	var start_position: Vector2 = _group.body.global_position
	var divergences_before: int = _group.divergence_count

	Input.action_press("ui_left")
	# 1 秒延迟需要 100 个等待帧；再推进两帧，让 Body 确实消费到 slot 0。
	_authority.enter_thinking_time()
	_check(_group.request_delay_change(1.0),
		"Player delay reentry must be accepted during thinking time")
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	_authority.call("_finish_pending_resume")
	for frame: int in range(102):
		_group.call("_physics_process", 0.01)
		_group.body.tick_physics(0, 0.01)
		_group.preview_body.tick_physics(0, 0.01)
	Input.action_release("ui_left")

	var first_record: Recording = _group.preview_system.slots[0]
	_check(first_record != null and absf(first_record.pos.x - start_position.x) > 10.0,
		"The first reentry record must use the corrected future start instead of the body's old position")
	_check(_group.divergence_count == divergences_before and is_equal_approx(_group.delay_time, 1.0),
		"Airborne moving delay reentry must survive its first replayed frame without false divergence")

	_group.body.collision_mask = body_collision_mask
	_group.preview_body.collision_mask = preview_collision_mask
	_group.respawn_player()
	print("PASS: airborne moving delay reentry after damage reset")


func _test_hurt_state_and_respawn() -> void:
	# 先清掉上一项分歧测试留下的闪回，再以场景初始点作为本轮出生点。
	_group.respawn_player()
	var spawn_position: Vector2 = _player.global_position
	_player.call("reset_for_respawn", spawn_position)
	_player.set("_attack_held", true)
	_player.set("_attack_requested", true)
	_player.weapon.tick(true, 1, true, true)
	_check(_player.weapon.phase != SwordWeapon.Phase.IDLE,
		"Precondition: player must be attacking before hurt interruption")

	# 攻击来源提供 0.40 秒，玩家倍率 0.50，最终控制锁定应为 0.20 秒。
	_dummy.set("attack_hit_stun_seconds", 0.40)
	_dummy.set("attack_knockback_distance", 45.0)
	_player.set("hurt_stun_multiplier", 0.50)
	_player.set("knockback_received_multiplier", 0.50)
	var accepted: bool = bool(_player.call("receive_hit", 20.0, _dummy, 1, Vector2.LEFT))
	_check(accepted and is_equal_approx(float(_player.get("current_health")), 80.0),
		"A valid hit must enter hurt state and remove health")
	_check(is_equal_approx(float(_player.get("_hurt_state_time_left")), 0.20),
		"Player hit stun must multiply the attack source duration by the receiver coefficient")
	var expected_player_knockback_speed: float = sqrt(2.0 * 1200.0 * 22.5)
	_check(is_equal_approx(absf(_player.velocity.x), expected_player_knockback_speed),
		"Player knockback must convert source distance and receiver coefficient into initial speed")
	_check(float(_player.get("_hurt_state_time_left")) > 0.0
		and _player.velocity.x < 0.0 and _player.velocity.y < 0.0,
		"Hurt state must apply directional horizontal knockback and a small lift")
	_check(_player.get_next_state(0) == 1,
		"State machine must transition from normal movement into hurt")
	_check(_player.weapon.phase == SwordWeapon.Phase.IDLE
		and not bool(_player.get("_attack_held")) and not bool(_player.get("_attack_requested")),
		"Taking damage must cancel the active combo and stale attack input")

	Input.action_press("ui_right")
	_player.tick_physics(1, 0.01)
	Input.action_release("ui_right")
	_check(_player.velocity.x < 0.0,
		"Movement input must not reverse knockback while hurt control is locked")
	for frame: int in range(30):
		_player.tick_physics(1, 0.01)
	_check(is_zero_approx(float(_player.get("_hurt_state_time_left"))),
		"Hurt control lock must end after its configured logical duration")
	_check(_player.get_next_state(1) == 0,
		"State machine must return from hurt to normal after the lock expires")

	# 死亡前制造旧历史和被击破木桩，确认重生会把整个战斗沙盒一起清理。
	_player.call("reset_for_respawn", spawn_position + Vector2(70.0, 0.0))
	_dummy.set("max_health", 42.0)
	_dummy.call("reset_combat", true)
	_dummy.call("receive_hit", 42.0, _player, 3, Vector2.RIGHT)
	_group._setting_delay_internally = true
	_group.delay_time = 0.5
	_group._setting_delay_internally = false
	_group.preview_system.record(Recording.new(1.0, false, _player.global_position, _player.velocity))
	_player.set("current_health", 20.0)
	_player.call("_update_health_visual")
	_player.weapon.tick(true, 1, true, true)
	var respawns_before: int = _group.respawn_count
	_player.call("receive_hit", 20.0, _dummy, 1, Vector2.RIGHT)
	_check(bool(_player.get("_is_dead")) and is_zero_approx(float(_player.get("current_health")))
		and not bool(_player.call("can_receive_hit")),
		"Zero health must enter an invulnerable dead state")
	_check(_player.get_next_state(0) == 2,
		"State machine must transition into dead when health reaches zero")
	_check(_player.weapon.phase == SwordWeapon.Phase.IDLE,
		"Death must also interrupt the active weapon immediately")
	for frame: int in range(80):
		_player.tick_physics(2, 0.01)
	await process_frame
	_check(_group.respawn_count == respawns_before + 1,
		"Death countdown must request exactly one group-level respawn")
	_check(_player.global_position.is_equal_approx(spawn_position)
		and _player.velocity.is_zero_approx()
		and is_equal_approx(float(_player.get("current_health")), float(_player.get("max_health"))),
		"Respawn must restore the real body position, velocity and health")
	_check(_group.preview_body.global_position.is_equal_approx(spawn_position)
		and _group.predictor.global_position.is_equal_approx(spawn_position)
		and _group.preview_body.visible,
		"Respawn must synchronize all replicas and show the natural-delay preview")
	_check(is_equal_approx(_group.delay_time, _group.natural_delay_time)
		and not _player.inputed and _group.preview_body.inputed
		and _group.preview_system.read_head == -1 and _group.preview_system.write_head == -1,
		"Respawn must clear history and restore the initial natural-delay control state")
	_check(is_equal_approx(float(_dummy.get("current_health")), float(_dummy.get("max_health")))
		and int(_dummy.get("attack_phase")) == 0,
		"Respawn must restore resettable combat targets to idle at full health")
	print("PASS: hurt interruption, knockback, death countdown and synchronized respawn")


func _test_dummy_health() -> void:
	_dummy.set("max_health", 42.0)
	_dummy.call("reset_combat", true)
	_player.weapon.combo_index = 0
	_player.weapon.combo_hit_stun_seconds = Vector3(0.40, 0.30, 0.20)
	_player.weapon.combo_knockback_distances = Vector3(40.0, 30.0, 20.0)
	_dummy.set("hurt_stun_multiplier", 0.50)
	_dummy.set("knockback_received_multiplier", 0.50)
	_dummy.call("receive_hit", 10.0, _player.weapon, 1, Vector2.RIGHT)
	_check(is_equal_approx(float(_dummy.get("_hurt_time_left")), 0.20),
		"Enemy hit stun must use the current weapon stage and the receiver coefficient")
	_check(is_equal_approx(_dummy.velocity.x, 200.0),
		"Enemy knockback must use the current weapon stage distance and receiver coefficient")
	_dummy.call("receive_hit", 12.0, _player, 2, Vector2.RIGHT)
	_dummy.call("receive_hit", 20.0, _player, 3, Vector2.RIGHT)
	_check(is_zero_approx(float(_dummy.get("current_health"))),
		"A full 10+12+20 combo must empty the default dummy health")
	_check(int(_dummy.get("attack_phase")) == 4 and _dummy.collision_layer == 0,
		"Defeated dummy must stop attacking and leave the sword hurtbox layer")
	var fill: ColorRect = _dummy.get_node("HealthBar/Fill") as ColorRect
	_check(is_zero_approx(fill.size.x), "Defeated dummy health bar must be empty")
	print("PASS: dummy health bar and defeat state")
