extends SceneTree

## 无头回归：--headless --path program --script res://test/sword_weapon_test.gd
class RejectingHitTarget:
	extends StaticBody2D
	var attempts: int = 0

	func receive_hit(
		_damage: float,
		_source: Node,
		_combo: int,
		_impact_direction: Vector2 = Vector2.ZERO
	) -> bool:
		attempts += 1
		return false

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _scene: Node
var _group: DelayedActorGroup
var _authority: WorldTimeAuthority
var _dummy: CharacterBody2D
var _idle: Dictionary


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _run() -> void:
	_scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(_scene)
	# 此测试手动快进逻辑帧；真实顿帧与晃动另由 combat_feedback_test 验证。
	_authority = _scene.get_node("WorldTimeAuthority") as WorldTimeAuthority
	_authority.combat_tuning = _authority.get_combat_tuning().duplicate() as CombatTuning
	_authority.combat_tuning.hit_stop_enabled = false
	_authority.thinking_entry_duration = 0.0
	_group = _scene.get_node("Actors/BodyGroup") as DelayedActorGroup
	_dummy = _scene.get_node("Enemies/MeleeEnemyA") as CharacterBody2D
	# 武器回归只验证玩家输出；关闭木桩反击并抬高血量，避免不同用例互相消耗目标。
	for target: Node in _scene.get_node("Enemies").get_children():
		target.set("attack_enabled", false)
		target.set("max_health", 100000.0)
		target.call("reset_combat", true)
		target.set_physics_process(false)
	for delay_controller: Node in get_nodes_in_group("enemy_delay_controller"):
		delay_controller.set_physics_process(false)
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	_idle = _group.body.weapon.capture_state()
	await physics_frame
	_test_combo_rules()
	_test_hold_repeat()
	_test_tap_vs_hold_input()
	_test_charge_controls()
	_test_air_combo_rules()
	_reset(0.1)
	await physics_frame
	_test_input_and_delayed_damage()
	await _test_hit_stop_input_buffer()
	_reset(0.0)
	await physics_frame
	_test_direction_and_hit_window()
	await _test_aim_hit_geometry()
	await _test_rejected_hit_has_no_feedback()
	_reset(0.1)
	await physics_frame
	_test_delay_changes()
	_reset(0.1)
	await physics_frame
	_test_mouse_aim_replay()
	_test_slot_reuse()
	await _test_gui_input()
	if _failures.is_empty():
		print("SWORD_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("SWORD_TEST_FAIL: " + failure)
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)


## 直接驱动武器测试节奏，不让非本体的测试武器查询真实伤害。
func _test_combo_rules() -> void:
	var sword: SwordWeapon = _group.preview_body.weapon
	var starts: Array[int] = []
	var heavy_length_seen: float = 0.0
	var recovery_shrank: bool = false
	var tuning: CombatTuning = sword.get_combat_tuning()
	for frame: int in range(180):
		sword.tick(frame in [0, 5, 35], 1, true)
		if sword.combo_index == 2:
			var drawn_length: float = float(sword.visual.get("_blade_length"))
			if sword.phase == SwordWeapon.Phase.ACTIVE:
				heavy_length_seen = drawn_length
			elif sword.phase == SwordWeapon.Phase.RECOVERY:
				recovery_shrank = recovery_shrank or (drawn_length > tuning.blade_length and drawn_length < tuning.heavy_blade_length)
		if sword.phase == SwordWeapon.Phase.WINDUP and sword.frames_left == sword.combo_windup_frames[sword.combo_index] - 1:
			starts.append(sword.combo_index + 1)
	_check(starts == [1, 2, 3], "Three timed clicks must produce exactly 1/2/3")
	_check(is_equal_approx(heavy_length_seen, tuning.heavy_blade_length), "Heavy swing must temporarily use the longer sword")
	_check(recovery_shrank, "Heavy recovery must gradually shrink the sword")
	_check(sword.phase == SwordWeapon.Phase.IDLE and is_equal_approx(float(sword.visual.get("_blade_length")), tuning.blade_length),
		"Completed heavy combo must restore normal sword length without another attack")
	sword.restore_state(_idle)
	starts.clear()
	for frame: int in range(140):
		sword.tick(frame < 8, 1, true)
		if sword.phase == SwordWeapon.Phase.WINDUP and sword.frames_left == sword.combo_windup_frames[sword.combo_index] - 1:
			starts.append(sword.combo_index + 1)
	_check(starts == [1, 2], "Mashing first attack can buffer only the second")
	sword.restore_state(_idle)
	for frame: int in range(40):
		sword.tick(frame == 0, 1, true)
	sword.tick(true, -1, true)
	_check(sword.combo_index == 1 and sword.attack_facing == -1, "Link window accepts second attack with its own direction")
	for frame: int in range(100):
		sword.tick(false, 1, true)
	sword.tick(true, 1, true)
	_check(sword.combo_index == 0, "Expired link window resets combo")
	var saved: Dictionary = sword.capture_state()
	for frame: int in range(30):
		sword.tick(true, -1, false)
	_check(sword.capture_state() == saved, "Waiting frames must freeze weapon and ignore clicks")
	print("PASS: combo timing, one-click buffer, link timeout and waiting")


func _test_charge_controls() -> void:
	_reset(0.0)
	var player: BaseActor = _group.body
	var screen_aim: Vector2 = player.get_global_transform_with_canvas() * Vector2(120.0, 0.0)
	player.call("select_weapon", 1)
	player.call("toggle_charge_mode", screen_aim)
	player.velocity = Vector2(180.0, 0.0)
	var grounded_before_charge: bool = player.is_grounded_for_simulation()
	var expected_charge_velocity_x: float = move_toward(
		180.0, 0.0, player.get_horizontal_acceleration(grounded_before_charge) * 0.01)
	player.tick_physics(0, 0.01)
	var velocity_after_charge_tick: float = player.velocity.x
	_check(bool(player.call("is_charge_mode_active"))
		and is_equal_approx(velocity_after_charge_tick, expected_charge_velocity_x)
		and velocity_after_charge_tick > 0.0
		and player.weapon.visual.get("_phase") == &"charge",
		"Charge mode must approach zero through the regular ground/air acceleration formula")
	player.call("begin_attack_input", screen_aim)
	player.tick_physics(0, 0.01)
	_check(not bool(player.call("is_charge_mode_active"))
		and bool(player.weapon.get("_charged_attack"))
		and player.velocity.x > 0.0
		and player.velocity.x < velocity_after_charge_tick,
		"Releasing before tier one must preserve the remaining smoothly decelerating inertia "
		+ "(charge=%s charged_attack=%s velocity=%s)" % [
			player.call("is_charge_mode_active"), player.weapon.get("_charged_attack"),
			str(player.velocity),
		])
	var charged_start_direction: Vector2 = Vector2.from_angle(player.weapon.get_swing_angle(0.0))
	var charged_middle_direction: Vector2 = Vector2.from_angle(player.weapon.get_swing_angle(0.5))
	var charged_end_direction: Vector2 = Vector2.from_angle(player.weapon.get_swing_angle(1.0))
	_check(charged_start_direction.y > 0.0 and charged_middle_direction.x > 0.9
		and charged_end_direction.y < 0.0,
		"Charged sword must sweep from below through the aimed direction and finish above")
	_check(player.weapon.charged_windup_frames == 4
		and player.weapon.charged_active_frames == 7
		and player.weapon.charged_recovery_frames == 30,
		"Charged sword release must keep its authored 4/7/30-frame draw timing")
	_reset(0.0)
	player.global_position = Vector2(350.0, 400.0)
	player.velocity = Vector2(180.0, -250.0)
	player.call("toggle_charge_mode", screen_aim)
	var expected_air_velocity_x: float = move_toward(
		180.0, 0.0, player.get_horizontal_acceleration(false) * 0.01)
	player.tick_physics(0, 0.01)
	_check(bool(player.call("is_charge_mode_active"))
		and is_equal_approx(player.velocity.x, expected_air_velocity_x)
		and is_equal_approx(player.velocity.y, -250.0 + player.gravity * 0.01),
		"Airborne charge must brake horizontally with air acceleration while gravity continues")
	player.call("toggle_charge_mode", screen_aim)
	_reset(0.0)
	var original_attack_speed: float = player.weapon.attack_speed_multiplier
	player.weapon.attack_speed_multiplier = 2.0
	_check(player.weapon.get_scaled_attack_frames(player.weapon.combo_windup_frames.x) == 4
		and player.weapon.get_scaled_attack_frames(player.weapon.combo_active_frames.z) == 4,
		"Attack-speed multiplier must shorten sword phase frames without skipping a phase")
	var original_global_attack_speed: float = player.weapon.get_combat_tuning().attack_speed_multiplier
	player.weapon.get_combat_tuning().attack_speed_multiplier = 1.5
	_check(is_equal_approx(player.weapon.get_attack_speed_multiplier(), 3.0),
		"Global and sword-specific attack-speed multipliers must combine multiplicatively")
	player.weapon.get_combat_tuning().attack_speed_multiplier = original_global_attack_speed
	player.weapon.attack_speed_multiplier = original_attack_speed
	var measured_tiers: Array[int] = []
	var measured_impulses: Array[float] = []
	var measured_reaches: Array[float] = []
	var measured_damage_multipliers: Array[float] = []
	for charge_frames: int in [100, 200, 300]:
		_reset(0.0)
		player.call("_cancel_action_input")
		player.call("select_weapon", 1)
		player.call("toggle_charge_mode", screen_aim)
		for frame: int in range(charge_frames):
			player.tick_physics(0, 0.01)
		measured_tiers.append(int(player.call("get_charge_tier")))
		player.call("begin_attack_input", screen_aim)
		player.tick_physics(0, 0.01)
		measured_impulses.append(player.velocity.length())
		measured_reaches.append(float(player.weapon.get("_charged_reach")))
		measured_damage_multipliers.append(float(player.weapon.get("_charged_damage_multiplier")))
	_check(measured_tiers == [1, 2, 3]
		and measured_impulses[0] >= 240.0 and measured_impulses[1] >= 420.0
		and measured_impulses[2] >= 600.0,
		"One, two and three seconds must unlock increasing charged-sword impulse tiers "
		+ "(tiers=%s impulses=%s)" % [str(measured_tiers), str(measured_impulses)])
	_check(is_equal_approx(measured_reaches[0], 84.0)
		and measured_reaches[1] > measured_reaches[0]
		and measured_reaches[2] > measured_reaches[1]
		and measured_damage_multipliers[0] < measured_damage_multipliers[1]
		and measured_damage_multipliers[1] < measured_damage_multipliers[2],
		"Charge tiers must increase sword reach at tiers two/three and damage continuously")
	player.set("_stable_facing", 1)
	_check(int(player.call("_resolve_aim_facing", 2.0)) == 1
		and int(player.call("_resolve_aim_facing", -20.0)) == -1
		and int(player.call("_resolve_aim_facing", 2.0)) == -1,
		"Facing deadzone must suppress center jitter without changing the stored aim vector")
	player.weapon.restore_state(_idle)
	_reset(0.1)
	var preview: BaseActor = _group.preview_body
	var preview_screen_aim: Vector2 = preview.get_global_transform_with_canvas() * Vector2(80.0, -30.0)
	preview.call("toggle_charge_mode", preview_screen_aim)
	_tick_pair()
	var charge_record: Recording = _group.preview_system.slots[_group.preview_system.write_head]
	preview.call("begin_attack_input", preview_screen_aim)
	_tick_pair()
	var release_record: Recording = _group.preview_system.slots[_group.preview_system.write_head]
	_check(charge_record != null and charge_record.charge_mode
		and release_record != null and release_record.charge_mode
		and release_record.charged_attack_pressed
		and not release_record.charged_aim_direction.is_zero_approx()
		and release_record.charge_elapsed_seconds > charge_record.charge_elapsed_seconds,
		"Charge state, elapsed time, release edge and exact aim must all be serialized into delayed input frames")
	_reset(0.0)
	print("PASS: charge time, smooth ground/air braking, three sword tiers and facing deadzone")


## 按住时每个有效逻辑帧都请求攻击，武器会自动循环完整地面三段。
func _test_hold_repeat() -> void:
	var sword: SwordWeapon = _group.preview_body.weapon
	sword.restore_state(_idle)
	var starts: Array[int] = []
	for frame: int in range(320):
		sword.tick(true, 1, true, true)
		if sword.phase == SwordWeapon.Phase.WINDUP and sword.frames_left == sword.combo_windup_frames[sword.combo_index] - 1:
			starts.append(sword.combo_index + 1)
	_check(starts.size() >= 6 and starts.slice(0, 6) == [1, 2, 3, 1, 2, 3],
		"Holding attack on ground must automatically repeat 1/2/3 combos")
	for frame: int in range(100):
		sword.tick(false, 1, true, true)
	_check(sword.phase == SwordWeapon.Phase.IDLE, "Releasing attack must stop automatic combo repetition")
	sword.restore_state(_idle)
	starts.clear()
	for frame: int in range(150):
		sword.tick(true, 1, true, false)
		if sword.phase == SwordWeapon.Phase.WINDUP and sword.frames_left == sword.combo_windup_frames[sword.combo_index] - 1:
			starts.append(sword.combo_index + 1)
	_check(starts.size() >= 3 and starts.slice(0, 3) == [1, 1, 1],
		"Holding attack in air must repeat only first swings")
	print("PASS: held attack repeats ground combos and air first swings")


## 输入层区分点按和长按：短按只发首段，超过阈值后才开始自动续段。
func _test_tap_vs_hold_input() -> void:
	_reset(0.1)
	var preview: BaseActor = _group.preview_body
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = Vector2(1100, 621)
	press.pressed = true
	Input.action_press("attack")
	root.push_input(press, true)
	var early_requests: int = 0
	for frame: int in range(10):
		_tick_pair()
		var record: Recording = _group.preview_system.slots[_group.preview_system.write_head]
		early_requests += 1 if record.attack_pressed else 0
	_check(early_requests == 1, "Short held duration must emit only the initial attack request")
	var repeated_requests: int = 0
	var second_started: bool = false
	var third_queued_on_second_start: bool = false
	var requests_after_second_start: int = 0
	var second_stage_frames: int = 0
	for frame: int in range(90):
		_tick_pair()
		var record: Recording = _group.preview_system.slots[_group.preview_system.write_head]
		repeated_requests += 1 if record.attack_pressed else 0
		var preview_weapon: SwordWeapon = preview.weapon
		if preview_weapon.combo_index == 1 and preview_weapon.phase == SwordWeapon.Phase.WINDUP \
			and preview_weapon.frames_left == preview_weapon.combo_windup_frames[1] - 1:
			second_started = true
			third_queued_on_second_start = bool(preview_weapon.get("_queued_attack"))
		elif second_started and second_stage_frames < 10:
			requests_after_second_start += 1 if record.attack_pressed else 0
			second_stage_frames += 1
	_check(repeated_requests > 0, "Holding past repeat delay must begin automatic attack requests")
	_check(second_started, "Holding attack must still transition from first to second swing")
	_check(not third_queued_on_second_start, "Second start must not inherit an already queued third swing")
	_check(requests_after_second_start == 0, "Second swing must restart hold delay before it can queue third swing")
	var release: InputEventMouseButton = press.duplicate() as InputEventMouseButton
	release.pressed = false
	Input.action_release("attack")
	root.push_input(release, true)
	_tick_pair()
	var released_record: Recording = _group.preview_system.slots[_group.preview_system.write_head]
	_check(not released_record.attack_pressed and not bool(preview.get("_attack_held")), "Release must stop automatic requests immediately")
	print("PASS: tap only starts one swing and hold activates delayed repetition")


func _reset(delay: float) -> void:
	_group._setting_delay_internally = true
	_group.delay_time = delay
	_group._setting_delay_internally = false
	_group._pending_delay = -1.0
	_group.preview_system.reset_to_initial_state()
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.global_position = Vector2(350, 624.9)
		actor.velocity = Vector2.ZERO
		actor.graphics.scale = Vector2.ONE
		actor.weapon.restore_state(_idle)
	_group.configure()
	_dummy.call("reset_combat", true)
	# 正式关卡出生点已右移；武器判定测试继续使用固定的 70 像素近战距离。
	_dummy.global_position = Vector2(420.0, 649.0)


func _enter_thinking_time_for_test() -> void:
	_authority.enter_thinking_time()


func _exit_thinking_time_for_test() -> void:
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	_authority.call("_finish_pending_resume")


func _click(position: Vector2 = Vector2(1150, 621)) -> void:
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = position
	click.pressed = true
	root.push_input(click, true)
	var release: InputEventMouseButton = click.duplicate() as InputEventMouseButton
	release.pressed = false
	root.push_input(release, true)


func _push_action(action: StringName, pressed: bool) -> void:
	var input: InputEventAction = InputEventAction.new()
	input.action = action
	input.pressed = pressed
	root.push_input(input, true)


func _tick_pair() -> void:
	_group.body.tick_physics(0, 0.01)
	_group.preview_body.tick_physics(0, 0.01)


func _test_input_and_delayed_damage() -> void:
	for frame: int in range(180):
		if frame in [0, 5, 35]:
			_click()
		_tick_pair()
		if frame == 9:
			_check(_group.preview_body.weapon.phase == SwordWeapon.Phase.ACTIVE, "Left click drives preview first")
			_check(int(_dummy.get("hit_count")) == 0, "Preview swing must not damage dummy")
	_check(int(_dummy.get("hit_count")) == 3, "Body must hit exactly once per combo stage")
	_check(is_equal_approx(float(_dummy.get("total_damage")), 42.0), "Full combo must deal 10+12+20")
	var recorded_clicks: int = 0
	for record: Recording in _group.preview_system.slots:
		if record != null and record.attack_pressed:
			recorded_clicks += 1
	_check(recorded_clicks == 3, "Each mouse click must be recorded once")
	paused = true
	_click()
	paused = false
	_check(not bool(_group.preview_body.get("_attack_requested")), "Thinking-time clicks must not queue attacks")
	print("PASS: real mouse input, delayed three hits, preview isolation and paused input")


## 命中顿帧时普通角色不处理输入；AttackInputBuffer 必须仍能缓存一次短点按。
func _test_hit_stop_input_buffer() -> void:
	_reset(0.1)
	await physics_frame
	# _reset 刚修改位置，先走一个空逻辑帧建立 CharacterBody2D 的地面接触缓存。
	_group.preview_body.tick_physics(0, 0.01)
	_check(_group.preview_body.is_grounded_for_simulation(), "Hit-stop movement test must begin grounded")
	_authority.combat_tuning.hit_stop_enabled = true
	_authority.combat_tuning.hit_stop_seconds = 0.2
	_authority.request_hit_feedback(0)
	var deadline: int = Time.get_ticks_msec() + 1000
	while not _authority.is_in_hit_stop() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_authority.is_in_hit_stop() and paused, "Test setup must enter real hit stop")
	_click()
	_check(bool(_group.preview_body.get("_attack_requested")), "Click during hit stop must be buffered on delayed preview")
	_check(not bool(_group.preview_body.get("_attack_held")), "Release during hit stop must clear hold state but keep initial request")
	_push_action(&"ui_right", true)
	_push_action(&"ui_right", false)
	_push_action(&"ui_up", true)
	_push_action(&"ui_up", false)
	_check(bool(_group.preview_body.get("_has_buffered_move")) and bool(_group.preview_body.get("_buffered_jump_requested")),
		"Right and jump pressed during hit stop must be buffered on delayed preview")
	_authority._finish_hit_stop()
	_group.preview_body.tick_physics(0, 0.01)
	_check(_group.preview_body.weapon.phase == SwordWeapon.Phase.WINDUP, "Buffered hit-stop click must start attack after resume")
	_check(_group.preview_body.velocity.x > 0.0 and _group.preview_body.velocity.y < 0.0,
		"Buffered hit-stop movement and jump must apply on first resumed frame")
	_authority.combat_tuning.hit_stop_enabled = false
	print("PASS: hit-stop input buffer preserves delayed click and release")


func _test_delay_changes() -> void:
	_click()
	for frame: int in range(14):
		_tick_pair()
	var body_state: Dictionary = _group.body.weapon.capture_state()
	var hit_count: int = int(_dummy.get("hit_count"))
	_enter_thinking_time_for_test()
	_check(_group.request_delay_change(0.5),
		"Increasing player delay must be accepted during thinking time")
	_exit_thinking_time_for_test()
	_group._physics_process(0.01)
	_check(_group.preview_body.weapon.capture_state() == _group.predictor.weapon.capture_state(), "Increasing delay must transfer predicted weapon state")
	for frame: int in range(20):
		_tick_pair()
	_check(_group.body.weapon.capture_state() == body_state, "Increased delay stalls current attack")
	_check(int(_dummy.get("hit_count")) == hit_count, "Waiting and prediction must not produce damage")
	_enter_thinking_time_for_test()
	_check(_group.request_delay_change(0.05),
		"Reducing player delay must be accepted during thinking time")
	_group.get_delay_preview_sample(0.05)
	_group.run_queued_delay_prediction()
	var predicted_state: Dictionary = _group.predictor.weapon.capture_state()
	_exit_thinking_time_for_test()
	_check(_group.preview_body.weapon.capture_state() == predicted_state, "Thinking reduction must commit weapon state")
	_check(_group.body.weapon.capture_state() == body_state, "Reduction must preserve current body attack")
	_check(int(_dummy.get("hit_count")) == hit_count, "Cached prediction must remain harmless")
	_enter_thinking_time_for_test()
	_check(_group.request_delay_change(0.0),
		"Clearing player delay must be accepted during thinking time")
	_exit_thinking_time_for_test()
	_group._physics_process(0.01)
	for frame: int in range(150):
		_tick_pair()
	_check(int(_dummy.get("hit_count")) == 1, "Reset must finish current swing without duplicate damage")
	_check(_group.preview_body.weapon.damage_enabled == false and _group.predictor.weapon.damage_enabled == false, "State copy must not transfer damage permission")
	print("PASS: increase, cached reduction, zero delay and damage authority")


func _test_slot_reuse() -> void:
	var ps: PreviewSystem = _group.preview_system
	ps.reset_to_initial_state()
	ps.record(Recording.new(0, false, Vector2.ZERO, Vector2.ZERO, true, -1, 0.8))
	for frame: int in range(ps.capacity):
		ps.record(Recording.new(0, false, Vector2.ZERO, Vector2.ZERO, false, 1))
	_check(not ps.slots[0].attack_pressed and ps.slots[0].attack_facing == 1, "Ring buffer reuse must overwrite old attack input")
	_check(is_zero_approx(ps.slots[0].attack_aim_rotation), "Reused record must not retain an old mouse angle")


func _test_air_combo_rules() -> void:
	var sword: SwordWeapon = _group.preview_body.weapon
	sword.restore_state(_idle)
	var stages: Array[int] = []
	for frame: int in range(100):
		sword.tick(frame in [0, 5, 35], 1, true, false)
		if sword.phase == SwordWeapon.Phase.WINDUP and sword.frames_left == sword.combo_windup_frames[sword.combo_index] - 1:
			stages.append(sword.combo_index + 1)
	_check(stages == [1, 1], "Air clicks must only start independent first swings and ignore combo buffering")
	sword.restore_state(_idle)
	for frame: int in range(40):
		sword.tick(frame in [0, 5, 20], 1, true, frame >= 10)
	_check(sword.phase == SwordWeapon.Phase.IDLE, "Landing mid-air-attack must not reopen that attack's combo window")
	sword.tick(true, 1, true, true)
	_check(sword.combo_index == 0 and sword.phase == SwordWeapon.Phase.WINDUP, "New grounded click must restart from first swing")
	sword.tick(true, 1, true, true)
	sword.tick(false, 1, true, false)
	for frame: int in range(40):
		sword.tick(false, 1, true, true)
	_check(sword.phase == SwordWeapon.Phase.IDLE, "Leaving ground must discard a previously buffered ground combo")
	print("PASS: airborne single swings, landing reset and takeoff buffer cancellation")


## 鼠标在左上方、移动输入朝右；回放和预测应保持点击时的角度。
func _test_mouse_aim_replay() -> void:
	Input.action_press("ui_right")
	_click(Vector2(230, 500))
	_tick_pair()
	Input.action_release("ui_right")
	var record: Recording = _group.preview_system.slots[_group.preview_system.write_head]
	var saved_aim: float = record.attack_aim_rotation
	_check(record.attack_facing == -1 and saved_aim > 0.5, "Mouse position must aim left/up independently of right movement")
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = Vector2(1100, 700)
	root.push_input(motion, true)
	for frame: int in range(12):
		_tick_pair()
	_check(_group.body.weapon.attack_facing == -1 and is_equal_approx(_group.body.weapon.aim_rotation, saved_aim),
		"Delayed swing must use recorded mouse angle after mouse moves elsewhere")
	_group.sync_predictor_to_body()
	_check(is_equal_approx(_group.predictor.weapon.aim_rotation, saved_aim), "Predictor state copy must preserve locked aim")
	print("PASS: mouse-directed attack and recorded aim across delayed playback")


func _test_direction_and_hit_window() -> void:
	var sword: SwordWeapon = _group.body.weapon
	for frame: int in range(70):
		sword.tick(frame == 0, -1 if frame == 0 else 1, true)
	_check(int(_dummy.get("hit_count")) == 0, "Left-facing swing must not hit target on right, even after turning")
	# 空中挥剑仍使用同一套连段；起手和收招不产生额外伤害。
	_group.body.position.y = 575.0
	for frame: int in range(8):
		sword.tick(frame == 0, 1, true)
	_check(int(_dummy.get("hit_count")) == 0, "Windup must not damage target")
	for frame: int in range(6):
		sword.tick(false, 1, true)
	_check(int(_dummy.get("hit_count")) == 1, "Airborne active swing should hit once")
	for frame: int in range(90):
		sword.tick(false, 1, true)
	_check(int(_dummy.get("hit_count")) == 1, "Recovery must not repeat damage")
	print("PASS: locked direction, front-only hit window and airborne attack")


func _test_gui_input() -> void:
	var blocker: Control = Control.new()
	blocker.size = Vector2(1280, 720)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(blocker)
	await process_frame
	_click()
	_check(not bool(_group.body.get("_attack_requested")), "GUI-consumed click must not attack")
	root.remove_child(blocker)
	blocker.queue_free()


## 同一个上方目标：朝下挥剑不能命中，朝上挥剑应命中，验证判定随瞄准旋转。
func _test_aim_hit_geometry() -> void:
	var original_target: Vector2 = _dummy.position
	var sword: SwordWeapon = _group.body.weapon
	_group.body.position = Vector2(350, 450)
	_dummy.position = Vector2(368, 430)
	_dummy.set("hit_count", 0)
	await physics_frame
	sword.restore_state(_idle)
	for frame: int in range(20):
		sword.tick(frame == 0, 1, true, false, PI / 2.0)
	_check(int(_dummy.get("hit_count")) == 0, "Downward aim must not hit a target above the sword")
	sword.restore_state(_idle)
	for frame: int in range(20):
		sword.tick(frame == 0, 1, true, false, -PI / 2.0)
	_check(int(_dummy.get("hit_count")) == 1, "Upward aim must rotate the actual hit shape toward the target")
	_dummy.position = original_target
	print("PASS: aimed hit geometry above and below the actor")


## 免疫、格挡等接收者返回 false 时，不应被登记为命中或触发命中反馈。
func _test_rejected_hit_has_no_feedback() -> void:
	_reset(0.0)
	var target: RejectingHitTarget = RejectingHitTarget.new()
	target.collision_layer = 4
	target.collision_mask = 0
	var collision: CollisionShape2D = CollisionShape2D.new()
	var shape: RectangleShape2D = RectangleShape2D.new()
	shape.size = Vector2(48.0, 80.0)
	collision.position = Vector2(0.0, -40.0)
	collision.shape = shape
	target.add_child(collision)
	_scene.add_child(target)
	# 放在空中隔离专用拒绝目标，避免同位置的远程敌人被剑查询同时命中。
	_group.body.global_position = Vector2(1000.0, 300.0)
	target.global_position = Vector2(1060.0, 300.0)
	await physics_frame

	var sword: SwordWeapon = _group.body.weapon
	sword.restore_state(_idle)
	for frame: int in range(24):
		sword.tick(frame == 0, 1, true, true, 0.0)
		if target.attempts > 0:
			break
	_check(target.attempts > 0, "Regression target must be reached by the sword query")
	_check(not bool(sword.get("_feedback_sent"))
		and (sword.get("_hit_targets") as Dictionary).is_empty(),
		"Rejected damage must not count as a hit or schedule hit feedback")
	_scene.remove_child(target)
	target.queue_free()
	sword.restore_state(_idle)
	print("PASS: rejected damage produces no hit registration or feedback")
