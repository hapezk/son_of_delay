extends SceneTree

## 法杖直线弹、公共发射器与双阵营弹幕纵切：
## --headless --path program --script res://test/straight_shot_weapon_test.gd
const LAUNCHER_BASE_PATH: String = "res://scenes/combat/delay_weapon_launcher_base.gd"

var _scene: Node
var _group: DelayedActorGroup
var _player: BaseActor
var _dummy: BaseActor
var _authority: WorldTimeAuthority
var _budget: Node
var _projectile_root: Node2D
var _baseline_controller_count: int = 0
var _baseline_participant_count: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _captured_projectile_diagnostics: Array[Dictionary] = []


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
	_player = _group.body
	_group.unlock_weapon_for_all(2)
	_group.unlock_weapon_for_all(3)
	_dummy = _scene.get_node("Enemies/MeleeEnemyA") as BaseActor
	_authority = _scene.get_node("WorldTimeAuthority") as WorldTimeAuthority
	_budget = _scene.get_node("DelayBudgetManager")
	_projectile_root = _scene.get_node("Projectiles") as Node2D
	_authority.thinking_entry_duration = 0.0
	_authority.combat_tuning = _authority.get_combat_tuning().duplicate() as CombatTuning
	_authority.combat_tuning.hit_stop_enabled = false
	_disable_automatic_combat_ticks()
	await process_frame
	_baseline_controller_count = int(_budget.call("get_registered_controller_count"))
	var baseline_participants: Array = _authority.get("_thinking_prediction_participants") as Array
	_baseline_participant_count = baseline_participants.size()

	_test_shared_launcher_contract()
	_test_editable_launch_speed_and_charge_range()
	_test_held_ranged_weapon_repetition()
	await _test_staff_contact_attack()
	var bolt: DelayableProjectile = await _test_delayed_e_key_launch()
	if bolt != null:
		_test_projectile_faction_contract(bolt)
		await _test_independent_bolt_delay(bolt)
		await _test_authority_bolt_damage()
		await _test_round_cleanup()
		await _test_tier_three_staff_launch()

	if _failures.is_empty():
		print("STRAIGHT_SHOT_WEAPON_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("STRAIGHT_SHOT_WEAPON_TEST_FAIL: " + failure)
	Engine.time_scale = 1.0
	paused = false
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)


func _disable_automatic_combat_ticks() -> void:
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	for enemy: Node in _scene.get_node("Enemies").get_children():
		enemy.set_physics_process(false)
	for delay_controller: Node in get_nodes_in_group("enemy_delay_controller"):
		delay_controller.set_physics_process(false)
	for delay_controller: Node in get_nodes_in_group("moving_platform_delay_controllers"):
		delay_controller.set_physics_process(false)


func _test_shared_launcher_contract() -> void:
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		var boomerang_launcher: Node = actor.get_node_or_null("BoomerangLauncher")
		var straight_launcher: Node = actor.get_node_or_null("StraightShotLauncher")
		_check(boomerang_launcher != null and straight_launcher != null,
			"Every player replica must own both ranged launcher attachments")
		if boomerang_launcher == null or straight_launcher == null:
			continue
		var boomerang_base: Script = boomerang_launcher.get_script().get_base_script() as Script
		var straight_base: Script = straight_launcher.get_script().get_base_script() as Script
		_check(boomerang_base != null and straight_base != null
			and boomerang_base.resource_path == LAUNCHER_BASE_PATH
			and straight_base.resource_path == LAUNCHER_BASE_PATH,
			"Boomerang and straight shot must reuse the same minimal launcher base")
	var state: Dictionary = _player.capture_delay_attachment_state()
	_check(state.has("boomerang_launcher") and state.has("straight_shot_launcher"),
		"Player delay attachment snapshot must include both independent launcher cooldowns")
	_check(get_nodes_in_group("enemy_damage_body").size() == 7,
		"Only the three authority enemies may be registered as player-projectile targets")
	var held_staff: StraightShotLauncher = _player.get_node("StraightShotLauncher") as StraightShotLauncher
	held_staff.set_weapon_pose(true, false, Vector2.UP)
	_check(held_staff.pose_aim_direction.is_equal_approx(Vector2.UP),
		"An equipped non-charging staff visual must accept continuous mouse aim")
	var original_attack_speed: float = held_staff.attack_speed_multiplier
	var base_cooldown: float = held_staff.cooldown_seconds
	var charged_multiplier: float = held_staff.charged_cooldown_multiplier
	var base_swing_seconds: float = held_staff.swing_seconds
	held_staff.attack_speed_multiplier = 2.0
	_check(is_equal_approx(held_staff.get_attack_cooldown(false), base_cooldown / 2.0)
		and is_equal_approx(
			held_staff.get_attack_cooldown(true), base_cooldown * charged_multiplier / 2.0)
		and is_equal_approx(held_staff.get_scaled_swing_seconds(), base_swing_seconds / 2.0),
		"Attack speed must shorten staff cooldown, charged cooldown and swing visual together")
	held_staff.attack_speed_multiplier = original_attack_speed
	print("PASS: both player ranged weapons share one delay-aware launcher base")


## Launch Speed 必须直接决定初速；三档射程倍率也要进入可复制的弹体状态。
func _test_editable_launch_speed_and_charge_range() -> void:
	var bolt_scene: PackedScene = load("res://scenes/combat/staff/straight_magic_bolt_actor.tscn") as PackedScene
	var expected_ranges: Dictionary[int, float] = {1: 720.0, 2: 900.0, 3: 1200.0}
	var expected_penetrations: Dictionary[int, int] = {1: 0, 2: 1, 3: 2}
	for tier: int in expected_ranges:
		var bolt: DelayableProjectile = bolt_scene.instantiate() as DelayableProjectile
		_projectile_root.add_child(bolt)
		bolt.launch_speed = 777.0
		bolt.move_speed = 100.0
		bolt.configure_charge_tier(tier)
		bolt.launch(Vector2.RIGHT)
		var state: Dictionary = bolt.capture_simulation_state()
		_check(is_equal_approx(bolt.velocity.length(), 777.0),
			"Inspector Launch Speed must not be capped by Move Speed")
		_check(is_equal_approx(bolt.max_travel_distance, expected_ranges[tier])
			and is_equal_approx(float(state.get("max_travel_distance", 0.0)), expected_ranges[tier]),
			"Staff tier %d range must scale and survive delay-state capture" % tier)
		_check(bolt.max_penetrations == expected_penetrations[tier]
			and int(state.get("max_penetrations", -1)) == expected_penetrations[tier],
			"Staff tier %d penetration must scale and survive delay-state capture" % tier)
		var state_penetration_groups: Array = state.get("penetration_target_groups", []) as Array
		var should_target_enemies: bool = expected_penetrations[tier] > 0
		_check(state_penetration_groups.has(&"enemy_damage_body") == should_target_enemies,
			"Staff tier %d delay state must keep the correct penetration target group" % tier)
		bolt.free()
	print("PASS: editable launch speed, charged ranges and 0/1/2 penetration tiers")


## 回旋镖与法杖都消费玩家的通用主攻击长按；冷却结束后应再次收到发射请求。
func _test_held_ranged_weapon_repetition() -> void:
	_reset_player_delay(0.0)
	var launchers: Dictionary[int, DelayWeaponLauncherBase] = {
		2: _player.get_node("BoomerangLauncher") as DelayWeaponLauncherBase,
		3: _player.get_node("StraightShotLauncher") as DelayWeaponLauncherBase,
	}
	var screen_aim: Vector2 = _player.get_global_transform_with_canvas() * Vector2(160.0, 0.0)
	for weapon_slot: int in launchers:
		var launcher: DelayWeaponLauncherBase = launchers[weapon_slot]
		_player.call("_cancel_action_input")
		_player.call("select_weapon", weapon_slot)
		launcher.reset_state()
		# 只演算冷却而不生成实体，让测试专注验证 Player 是否持续发送主攻击。
		launcher.configure_delay_replica(BaseActor.DelayReplicaRole.PREVIEW)
		Input.action_press("attack")
		_player.call("begin_attack_input", screen_aim)
		var availability_blocker: Node = null
		if weapon_slot == 2:
			# 模拟上一枚回旋镖仍在飞行：按住期间不可用，回收后无需重新点击。
			availability_blocker = Node.new()
			_scene.add_child(availability_blocker)
			availability_blocker.add_to_group(&"player_boomerangs")
		_player.tick_physics(0, 0.01)
		if availability_blocker != null:
			_check(is_zero_approx(launcher.cooldown_left),
				"An unavailable boomerang must wait without consuming its held request")
			availability_blocker.remove_from_group(&"player_boomerangs")
			availability_blocker.queue_free()
			_player.tick_physics(0, 0.01)
			_check(launcher.cooldown_left > 0.0,
				"A held boomerang must launch as soon as it becomes available")
		var cooldown: float = launcher.get_attack_cooldown(false)
		var repeat_ticks: int = ceili(cooldown / 0.01) + 1
		for frame: int in range(repeat_ticks):
			_player.tick_physics(0, 0.01)
		_check(launcher.cooldown_left > cooldown * 0.5,
			"Holding left click must request another launch after weapon %d cooldown" % weapon_slot)
		_player.call("release_attack_input")
		Input.action_release("attack")
		for frame: int in range(repeat_ticks + 1):
			_player.tick_physics(0, 0.01)
		_check(is_zero_approx(launcher.cooldown_left),
			"Releasing left click must stop repeated requests for weapon %d" % weapon_slot)
		launcher.configure_delay_replica(BaseActor.DelayReplicaRole.AUTHORITY)
	print("PASS: held left click repeats every ranged weapon after its own cooldown")


func _test_staff_contact_attack() -> void:
	_reset_player_delay(0.0)
	_dummy.call("reset_combat", true)
	_player.global_position = _dummy.global_position + Vector2(-40.0, -24.0)
	_player.call("select_weapon", 3)
	await physics_frame
	var health_before: float = float(_dummy.get("current_health"))
	var projectiles_before: int = get_nodes_in_group("player_magic_bolts").size()
	var screen_aim: Vector2 = _player.get_global_transform_with_canvas() * Vector2(120.0, 0.0)
	_player.call("begin_attack_input", screen_aim)
	_player.tick_physics(0, 0.01)
	_check(float(_dummy.get("current_health")) == health_before - 14.0,
		"A staff body contact must apply the same configured damage as its normal bolt")
	_check(get_nodes_in_group("player_magic_bolts").size() == projectiles_before,
		"A successful staff body hit must suppress projectile creation")
	print("PASS: staff swing uses its visible body as contact damage and suppresses the bolt")


func _test_delayed_e_key_launch() -> DelayableProjectile:
	_reset_player_delay(0.1)
	var switch_weapon: InputEventKey = InputEventKey.new()
	switch_weapon.keycode = KEY_3
	switch_weapon.pressed = true
	root.push_input(switch_weapon, true)
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = Vector2(1100.0, 560.0)
	press.pressed = true
	root.push_input(press, true)

	_tick_player_pair()
	_check(get_nodes_in_group("player_magic_bolts").is_empty(),
		"The delayed player's preview replica must not create a real magic bolt")
	var first_record: Recording = _group.preview_system.slots[_group.preview_system.write_head]
	_check(first_record != null and first_record.weapon_slot == 3
		and first_record.straight_shot_pressed
		and not first_record.straight_shot_aim_direction.is_zero_approx(),
		"Selected staff, left-click and mouse direction must be stored in the player delay frame")

	for frame: int in range(14):
		_tick_player_pair()
		if not get_nodes_in_group("player_magic_bolts").is_empty():
			break
	var nodes: Array[Node] = get_nodes_in_group("player_magic_bolts")
	_check(nodes.size() == 1,
		"The recorded staff attack must create exactly one authority magic bolt after player delay")
	if nodes.is_empty():
		return null
	var bolt: DelayableProjectile = nodes[0] as DelayableProjectile
	await process_frame
	var controller: Node = bolt.get_node_or_null("ProjectileDelayController")
	if controller != null:
		controller.set_physics_process(false)
	return bolt


func _test_projectile_faction_contract(bolt: DelayableProjectile) -> void:
	var controller: DelayControllerBase = bolt.get_node("ProjectileDelayController") as DelayControllerBase
	var preview: DelayableProjectile = controller.call("get_preview_body") as DelayableProjectile
	var predictor: DelayableProjectile = controller.get("predictor_body") as DelayableProjectile
	_check(bolt.damage_target_group == &"enemy_damage_body"
		and bolt.collision_mask == 6 and preview.collision_mask == 2,
		"Player bolt must collide with enemies plus terrain while preview remains terrain-only")
	_check(bolt.damage_enabled and not preview.damage_enabled and not predictor.damage_enabled,
		"Only the authority magic bolt may damage an enemy")
	_check(controller.get_delay_buffer_capacity() == 301
		and int(_budget.call("get_registered_controller_count")) == _baseline_controller_count + 1,
		"Magic bolt must reuse the shared 301-slot projectile controller and budget registration")
	_check(bolt.is_in_group("round_projectiles")
		and not preview.is_in_group("player_magic_bolts")
		and not predictor.is_in_group("player_magic_bolts"),
		"Only the authority bolt may enter gameplay and round-cleanup groups")
	print("PASS: one generic projectile implementation supports the player faction")


func _test_independent_bolt_delay(bolt: DelayableProjectile) -> void:
	var controller: DelayControllerBase = bolt.get_node("ProjectileDelayController") as DelayControllerBase
	var preview: BaseActor = controller.call("get_preview_body") as BaseActor
	# 玩家回到自然延迟时不占负载，独立弹体才能获得本用例申请的完整额度。
	_reset_player_delay(_group.natural_delay_time)
	bolt.global_position = Vector2(900.0, 420.0)
	bolt.call("launch", Vector2.RIGHT)
	controller.call("_sync_preview_to_body", true)

	_authority.enter_thinking_time()
	_check(controller.request_delay_change(0.2),
		"A player magic bolt must accept an independent delay during thinking time")
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	while _authority.is_in_thinking_time():
		await process_frame
	controller.set_physics_process(false)
	var body_start: Vector2 = bolt.global_position
	var preview_start: Vector2 = preview.global_position
	for frame: int in range(10):
		controller.call("_physics_process", 0.01)
	_check(bolt.global_position.is_equal_approx(body_start),
		"Magic-bolt authority must freeze while its delay history is filling")
	_check(preview.global_position.distance_to(preview_start) > 50.0,
		"Magic-bolt preview must continue in a straight line during authority wait")
	for frame: int in range(13):
		controller.call("_physics_process", 0.01)
	_check(bolt.global_position.distance_to(body_start) > 1.0,
		"Magic-bolt authority must replay the straight-flight commands after its delay")
	print("PASS: straight magic bolt freezes, previews and replays independently")


func _test_authority_bolt_damage() -> void:
	_dummy.call("reset_combat", true)
	_dummy.set_physics_process(false)
	var health_before: float = float(_dummy.get("current_health"))
	var bolt_scene: PackedScene = load("res://scenes/combat/staff/straight_magic_bolt.tscn") as PackedScene
	var bolt: DelayableProjectile = bolt_scene.instantiate() as DelayableProjectile
	var expected_damage: float = bolt.damage
	_captured_projectile_diagnostics.clear()
	bolt.diagnostic_event.connect(_on_projectile_diagnostic)
	_projectile_root.add_child(bolt)
	bolt.global_position = _dummy.global_position + Vector2(-100.0, -24.0)
	bolt.call("launch", Vector2.RIGHT)
	await process_frame
	var controller: Node = bolt.get_node("ProjectileDelayController")
	controller.set_physics_process(false)
	await physics_frame
	for frame: int in range(24):
		if not is_instance_valid(bolt) or not bolt.active:
			break
		bolt.simulate_delay_command({"advance": true}, 0.01)
	_check(float(_dummy.get("current_health")) == health_before - expected_damage
		and int(_dummy.get("hit_count")) == 1,
		"Authority magic bolt must deal 14 damage exactly once to an enemy")
	var captured_accepted_hit: bool = false
	for event: Dictionary in _captured_projectile_diagnostics:
		if event.get("event_type", &"") == &"collision" \
				and bool(event.get("damage_accepted", false)):
			captured_accepted_hit = true
			break
	_check(captured_accepted_hit,
		"Generic projectile diagnostics must support enemy targets without player-only fields")
	await process_frame
	_check(not is_instance_valid(bolt),
		"Straight magic bolt must leave the scene immediately after a valid enemy hit")
	print("PASS: straight magic bolt damages enemy authority once and expires")


func _on_projectile_diagnostic(_projectile: BaseActor, event: Dictionary) -> void:
	_captured_projectile_diagnostics.append(event.duplicate())


func _test_round_cleanup() -> void:
	_scene.get_node("CombatRoomController").call("_clear_round_projectiles")
	await process_frame
	_check(get_nodes_in_group("player_magic_bolts").is_empty(),
		"Round cleanup must remove remaining player magic bolts")
	_check(int(_budget.call("get_registered_controller_count")) == _baseline_controller_count,
		"Removing magic bolts must release their delay-budget registrations")
	var participants: Array = _authority.get("_thinking_prediction_participants") as Array
	_check(participants.size() == _baseline_participant_count,
		"Removing magic bolts must unregister their thinking-time callbacks")
	print("PASS: player bolt cleanup leaves no freed delay participant")


func _test_tier_three_staff_launch() -> void:
	var baseline: DelayableProjectile = load(
		"res://scenes/combat/staff/straight_magic_bolt_actor.tscn").instantiate() as DelayableProjectile
	var base_damage: float = baseline.damage
	var base_speed: float = baseline.launch_speed
	baseline.free()
	_reset_player_delay(0.0)
	_player.call("_cancel_action_input")
	_player.call("select_weapon", 3)
	# 远离近战木桩，确保这一用例验证的是三档弹体而不是杖身接触攻击。
	_player.global_position = Vector2(120.0, 624.9)
	var screen_aim: Vector2 = _player.get_global_transform_with_canvas() * Vector2(160.0, 0.0)
	_player.call("toggle_charge_mode", screen_aim)
	for frame: int in range(300):
		_tick_player_pair()
	_check(int(_player.call("get_charge_tier")) == 3,
		"Three seconds must reach staff charge tier three")
	_player.call("begin_attack_input", screen_aim)
	_tick_player_pair()
	await process_frame
	var nodes: Array[Node] = get_nodes_in_group("player_magic_bolts")
	_check(nodes.size() == 1, "Tier-three staff release must spawn one authority bolt")
	if not nodes.is_empty():
		var charged_bolt: DelayableProjectile = nodes[0] as DelayableProjectile
		_check(charged_bolt.damage > base_damage
			and charged_bolt.launch_speed > base_speed
			and charged_bolt.attack_size_multiplier > 1.0
			and charged_bolt.max_penetrations == 2
			and charged_bolt.penetration_target_groups.has(&"enemy_damage_body"),
			"Tier-three staff must gain continuous damage, speed, size and two-target penetration")
	_scene.get_node("CombatRoomController").call("_clear_round_projectiles")
	await process_frame
	print("PASS: staff charge tiers culminate in a large piercing tier-three bolt")


func _reset_player_delay(delay: float) -> void:
	_group._setting_delay_internally = true
	_group.delay_time = delay
	_group._setting_delay_internally = false
	_group._pending_delay = -1.0
	_group.preview_system.reset_to_initial_state()
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.global_position = Vector2(350.0, 624.9)
		actor.velocity = Vector2.ZERO
		actor.graphics.scale = Vector2.ONE
		actor.get_node("BoomerangLauncher").call("reset_state")
		actor.get_node("StraightShotLauncher").call("reset_state")
	_group.configure()


func _tick_player_pair() -> void:
	_group.body.tick_physics(0, 0.01)
	_group.preview_body.tick_physics(0, 0.01)
