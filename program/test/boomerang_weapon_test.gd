extends SceneTree

## 玩家选择回旋镖后的左键攻击与独立延迟对象纵切：
## --headless --path program --script res://test/boomerang_weapon_test.gd
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

	_test_player_attachment_contract()
	var boomerang: DelayableBoomerang = await _test_delayed_right_click_launch()
	if boomerang != null:
		await _test_boomerang_delay_contract(boomerang)
		_test_return_prediction(boomerang)
		await _test_pinned_damage(boomerang)
		await _test_round_cleanup()
		await _test_tier_three_boomerang_launch()

	if _failures.is_empty():
		print("BOOMERANG_WEAPON_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("BOOMERANG_WEAPON_TEST_FAIL: " + failure)
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


func _test_player_attachment_contract() -> void:
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		var launcher: BoomerangLauncher = actor.get_node_or_null("BoomerangLauncher") as BoomerangLauncher
		_check(launcher != null, "Every player replica must own the same boomerang launcher attachment")
	var body_state: Dictionary = _player.capture_delay_attachment_state()
	_check(body_state.has("weapon") and body_state.has("boomerang_launcher"),
		"Player attachment snapshot must include both sword and boomerang launcher state")
	var held_launcher: BoomerangLauncher = _player.get_node("BoomerangLauncher") as BoomerangLauncher
	held_launcher.set_weapon_pose(true, false, Vector2.UP)
	_check(held_launcher.pose_aim_direction.is_equal_approx(Vector2.UP),
		"An equipped non-charging boomerang visual must accept continuous mouse aim")
	var original_attack_speed: float = held_launcher.attack_speed_multiplier
	held_launcher.attack_speed_multiplier = 2.0
	_check(is_equal_approx(held_launcher.get_attack_cooldown(false), 0.175)
		and is_equal_approx(held_launcher.get_attack_cooldown(true), 0.28),
		"Attack speed must shorten normal and charged boomerang cooldowns")
	held_launcher.attack_speed_multiplier = original_attack_speed
	print("PASS: boomerang launcher participates in the generic player attachment snapshot")


func _test_delayed_right_click_launch() -> DelayableBoomerang:
	_reset_player_delay(0.1)
	var switch_weapon: InputEventKey = InputEventKey.new()
	switch_weapon.keycode = KEY_2
	switch_weapon.pressed = true
	root.push_input(switch_weapon, true)
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = Vector2(1100.0, 560.0)
	click.pressed = true
	root.push_input(click, true)

	_tick_player_pair()
	_check(get_nodes_in_group("player_boomerangs").is_empty(),
		"A delayed player's boomerang attack must not let the preview replica spawn a real boomerang")
	var first_record: Recording = _group.preview_system.slots[_group.preview_system.write_head]
	_check(first_record != null and first_record.weapon_slot == 2
		and first_record.secondary_attack_pressed
		and first_record.secondary_aim_direction.x > 0.0,
		"Selected boomerang, left-click and resolved aim must be recorded in the delay frame")

	for frame: int in range(14):
		_tick_player_pair()
		if not get_nodes_in_group("player_boomerangs").is_empty():
			break
	var nodes: Array[Node] = get_nodes_in_group("player_boomerangs")
	_check(nodes.size() == 1,
		"The recorded boomerang attack must spawn exactly one authority boomerang after player delay")
	if nodes.is_empty():
		return null
	var boomerang: DelayableBoomerang = nodes[0] as DelayableBoomerang
	await process_frame # 让回旋镖控制器完成三体延迟初始化。
	var controller: Node = boomerang.get_node_or_null("BoomerangDelayController")
	if controller != null:
		controller.set_physics_process(false)
	return boomerang


func _test_boomerang_delay_contract(boomerang: DelayableBoomerang) -> void:
	var controller: DelayControllerBase = boomerang.get_node("BoomerangDelayController") as DelayControllerBase
	var preview: BaseActor = controller.call("get_preview_body") as BaseActor
	var predictor: BaseActor = controller.get("predictor_body") as BaseActor
	_check(boomerang is BaseActor and controller is CommandReplayDelayController,
		"Boomerang must reuse BaseActor and the generic command-replay delay adapter")
	_check(boomerang.delay_replica_role == BaseActor.DelayReplicaRole.AUTHORITY
		and preview.delay_replica_role == BaseActor.DelayReplicaRole.PREVIEW
		and predictor.delay_replica_role == BaseActor.DelayReplicaRole.PREDICTOR,
		"Boomerang controller must create authority, preview and predictor replicas")
	_check(bool(boomerang.damage_enabled) and not bool(preview.get("damage_enabled"))
		and not bool(predictor.get("damage_enabled")),
		"Only the authority boomerang may query and apply enemy damage")
	_check(controller.get_delay_buffer_capacity() == 301
		and int(_budget.call("get_registered_controller_count")) == _baseline_controller_count + 1,
		"A live boomerang must own the shared 301-slot history and one delay-budget registration")
	_check(boomerang.is_in_group("round_projectiles")
		and not preview.is_in_group("round_projectiles")
		and not predictor.is_in_group("round_projectiles"),
		"Only the authority boomerang may participate in round lifecycle cleanup")
	print("PASS: boomerang is a complete reusable BaseActor delay object")


func _test_return_prediction(boomerang: DelayableBoomerang) -> void:
	var controller: DelayControllerBase = boomerang.get_node("BoomerangDelayController") as DelayControllerBase
	var predictor: DelayableBoomerang = controller.get("predictor_body") as DelayableBoomerang
	predictor.max_distance = 20.0
	predictor.global_position = _player.global_position + Vector2(100.0, -40.0)
	predictor.launch(Vector2.RIGHT)
	predictor.simulate_delay_command({
		"advance": true,
		"move_direction": Vector2.RIGHT,
		"should_catch": false,
	}, 0.1)
	_check(predictor.travel_phase == DelayableBoomerang.TravelPhase.RETURNING,
		"Crossing the outbound distance must switch the boomerang to its return phase")
	var return_command: Dictionary = predictor.capture_delay_command()
	_check((return_command.get("move_direction", Vector2.ZERO) as Vector2).x < 0.0,
		"The return command must store a resolved direction toward the real player")
	_check(not predictor.is_in_group("player_boomerangs") and not predictor.damage_enabled,
		"Predicting the return path must not create a live projectile or damage authority")
	print("PASS: outbound and return flight can be predicted without world side effects")


func _test_pinned_damage(boomerang: DelayableBoomerang) -> void:
	var controller: DelayControllerBase = boomerang.get_node("BoomerangDelayController") as DelayControllerBase
	var preview: BaseActor = controller.call("get_preview_body") as BaseActor
	# 上一用例为验证玩家回放临时设成 0.1 秒；恢复自然延迟后才有完整负载分配给弹体。
	_reset_player_delay(_group.natural_delay_time)
	_dummy.call("reset_combat", true)
	_dummy.set_physics_process(false)
	boomerang.global_position = _dummy.global_position + Vector2(0.0, -24.0)
	boomerang.velocity = Vector2.RIGHT * boomerang.flight_speed
	boomerang.damage_tick_left = 0.0
	controller.call("_sync_preview_to_body", true)
	await physics_frame # 把直接设置的位置同步给物理查询空间。

	_authority.enter_thinking_time()
	_check(controller.request_delay_change(0.8),
		"A flying boomerang must accept its own delay request during thinking time")
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	while _authority.is_in_thinking_time():
		await process_frame
	controller.set_physics_process(false)
	var pinned_position: Vector2 = boomerang.global_position
	var preview_start: Vector2 = preview.global_position
	for frame: int in range(30):
		controller.call("_physics_process", 0.01)
	_check(preview.global_position.distance_to(preview_start) > 100.0 and preview.visible,
		"Boomerang preview must show the future flight during authority wait "
		+ "(delay=%.2f start=%s end=%s active=%s visible=%s)" % [
			controller.delay_time, str(preview_start), str(preview.global_position),
			str(preview.get("active")), str(preview.visible),
		])
	for frame: int in range(40):
		controller.call("_physics_process", 0.01)

	_check(boomerang.global_position.is_equal_approx(pinned_position),
		"Authority boomerang must remain pinned while its 0.8-second history is filling")
	# 最后 0.1 秒仍属于 0.8 秒等待窗，并足以覆盖当前 0.08 秒伤害脉冲间隔。
	for frame: int in range(10):
		controller.call("_physics_process", 0.01)
	_check(bool(_dummy.call("is_defeated"))
		and float(_dummy.get("total_damage")) >= float(_dummy.get("max_health")),
		"Repeated authority pulses at the delayed position must defeat the target "
		+ "(damage=%.1f hp=%.1f/%.1f interval=%.2f)" % [
			float(_dummy.get("total_damage")), float(_dummy.get("current_health")),
			float(_dummy.get("max_health")), boomerang.damage_interval_seconds,
		])
	_check(controller.call("is_mouse_over_delay_visual", pinned_position)
		and controller.call("is_mouse_over_delay_visual", preview.global_position),
		"Delay selection must recognize both the pinned boomerang and its future preview")
	print("PASS: delaying a boomerang creates a stationary repeated-damage point")


func _test_round_cleanup() -> void:
	_scene.get_node("CombatRoomController").call("_clear_round_projectiles")
	await process_frame
	_check(get_nodes_in_group("player_boomerangs").is_empty(),
		"Round cleanup must remove the live player boomerang")
	_check(int(_budget.call("get_registered_controller_count")) == _baseline_controller_count,
		"Freeing the boomerang must release its shared delay-budget registration")
	var participants: Array = _authority.get("_thinking_prediction_participants") as Array
	_check(participants.size() == _baseline_participant_count,
		"Freeing the boomerang must unregister its thinking-time prediction callbacks")
	print("PASS: boomerang lifecycle cleanup leaves no freed delay participant")


func _test_tier_three_boomerang_launch() -> void:
	var baseline: DelayableBoomerang = load(
		"res://scenes/combat/boomerang/delayable_boomerang.tscn").instantiate() as DelayableBoomerang
	var base_damage: float = baseline.damage
	var base_speed: float = baseline.flight_speed
	var base_range: float = baseline.max_distance
	var base_interval: float = baseline.damage_interval_seconds
	baseline.free()
	_reset_player_delay(0.0)
	_player.call("_cancel_action_input")
	_player.call("select_weapon", 2)
	var screen_aim: Vector2 = _player.get_global_transform_with_canvas() * Vector2(160.0, 0.0)
	_player.call("toggle_charge_mode", screen_aim)
	for frame: int in range(300):
		_tick_player_pair()
	_check(int(_player.call("get_charge_tier")) == 3,
		"Three seconds must reach boomerang charge tier three")
	_player.call("begin_attack_input", screen_aim)
	_tick_player_pair()
	await process_frame
	var nodes: Array[Node] = get_nodes_in_group("player_boomerangs")
	_check(nodes.size() == 1, "Tier-three boomerang release must spawn one authority projectile")
	if not nodes.is_empty():
		var charged_boomerang: DelayableBoomerang = nodes[0] as DelayableBoomerang
		_check(charged_boomerang.damage > base_damage
			and charged_boomerang.flight_speed > base_speed
			and charged_boomerang.max_distance > base_range
			and charged_boomerang.attack_size_multiplier > 1.0
			and charged_boomerang.damage_interval_seconds < base_interval,
			"Tier-three boomerang must gain continuous damage, speed, range, size and pulse rate "
			+ "(damage=%.1f speed=%.1f range=%.1f size=%.2f interval=%.3f)" % [
				charged_boomerang.damage, charged_boomerang.flight_speed,
				charged_boomerang.max_distance, charged_boomerang.attack_size_multiplier,
				charged_boomerang.damage_interval_seconds,
			])
	_scene.get_node("CombatRoomController").call("_clear_round_projectiles")
	await process_frame
	print("PASS: boomerang charge tiers culminate in the configured tier-three abilities")


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
	_group.configure()


func _tick_player_pair() -> void:
	_group.body.tick_physics(0, 0.01)
	_group.preview_body.tick_physics(0, 0.01)
