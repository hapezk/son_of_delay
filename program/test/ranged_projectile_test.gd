extends SceneTree

## 远程单位与可延迟弹幕纵切：
## --headless --path program --script res://test/ranged_projectile_test.gd
const COMMAND_REPLAY_CONTROLLER_PATH: String = \
	"res://scenes/components/command_replay_delay_controller.gd"
var _scene: Node
var _group: DelayedActorGroup
var _player: BaseActor
var _ranged: BaseActor
var _ranged_delay: DelayControllerBase
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
	_ranged = _scene.get_node("Enemies/RangedEnemyA") as BaseActor
	_ranged_delay = _ranged.get_node("EnemyDelayController") as DelayControllerBase
	_authority = _scene.get_node("WorldTimeAuthority") as WorldTimeAuthority
	_budget = _scene.get_node("DelayBudgetManager")
	_projectile_root = _scene.get_node("Projectiles") as Node2D
	_authority.thinking_entry_duration = 0.0
	_authority.combat_tuning = _authority.get_combat_tuning().duplicate() as CombatTuning
	_authority.combat_tuning.hit_stop_enabled = false
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	for enemy: Node in _scene.get_node("Enemies").get_children():
		enemy.set_physics_process(false)
	await process_frame
	for delay_controller: Node in get_nodes_in_group("enemy_delay_controller"):
		delay_controller.set_physics_process(false)
	for delay_controller: Node in get_nodes_in_group("moving_platform_delay_controllers"):
		delay_controller.set_physics_process(false)
	# 远程敌人的固定测试坐标与主场景尖刺重合；本测试只验证射击与延迟，不让机关改写攻击状态。
	for trap: Node in get_nodes_in_group("traps"):
		trap.set_physics_process(false)
	_baseline_controller_count = int(_budget.call("get_registered_controller_count"))
	var baseline_participants: Array = _authority.get("_thinking_prediction_participants") as Array
	_baseline_participant_count = baseline_participants.size()

	_test_common_actor_and_controller_contract()
	var projectile: BaseActor = await _test_ranged_enemy_fires()
	if projectile != null:
		await _test_projectile_delay_and_permissions(projectile)
		await _test_projectile_bounce(projectile)
		await _test_authority_projectile_damage()
		await _test_round_cleanup_releases_budget()

	if _failures.is_empty():
		print("RANGED_PROJECTILE_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("RANGED_PROJECTILE_TEST_FAIL: " + failure)
	Engine.time_scale = 1.0
	paused = false
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)


func _test_common_actor_and_controller_contract() -> void:
	var melee_delay: Node = _scene.get_node("Enemies/MeleeEnemyA/EnemyDelayController")
	_check(_ranged is BaseActor,
		"Ranged enemy must derive from BaseActor")
	_check(_group.body.collision_layer == 1
		and _group.preview_body.collision_layer == 0
		and _group.predictor.collision_layer == 0
		and _group.body.collision_mask == 2
		and _group.preview_body.collision_mask == 2
		and _group.predictor.collision_mask == 2,
		"Only the authority player may expose collision layer 1; replicas must remain terrain-only")
	var melee_base: Script = melee_delay.get_script().get_base_script() as Script
	var ranged_base: Script = _ranged_delay.get_script().get_base_script() as Script
	_check(melee_base != null and melee_base.resource_path == COMMAND_REPLAY_CONTROLLER_PATH
		and ranged_base != null and ranged_base.resource_path == COMMAND_REPLAY_CONTROLLER_PATH,
		"Melee and ranged enemy adapters must share CommandReplayDelayController")
	_check(_ranged.is_delay_selection_point(_ranged.global_position + Vector2(0.0, -24.0)),
		"Ranged enemy must expose the shared BaseActor selection contract")
	_check(_ranged_delay.get_delay_buffer_capacity() == 301,
		"Ranged enemy must allocate the same 3s * 100fps + 1 ring buffer")
	print("PASS: ranged enemy uses the shared actor and command-replay contracts")


func _test_ranged_enemy_fires() -> BaseActor:
	_player.call("reset_for_respawn", Vector2(700.0, 625.0))
	_ranged.call("reset_combat", true)
	_ranged.global_position = Vector2(1060.0, 649.0)
	var command: Dictionary = _ranged.capture_delay_command()
	var aim_direction: Vector2 = command.get("aim_direction", Vector2.ZERO) as Vector2
	_check(bool(command.get("has_target", false))
		and int(command.get("intent", -1)) == 3
		and aim_direction.x < 0.0,
		"Ranged command frame must record a resolved shoot intent and aim direction")

	_authority.enter_thinking_time()
	_check(_ranged_delay.request_delay_change(0.1),
		"Ranged enemy must accept delay through the shared controller during thinking time")
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	while _authority.is_in_thinking_time():
		await process_frame
	_ranged_delay.set_physics_process(false)
	var preview: BaseActor = _ranged_delay.call("get_preview_body") as BaseActor
	for frame: int in range(5):
		_ranged_delay.call("_physics_process", 0.01)
	_check(int(_ranged.get("attack_phase")) == 0 and int(preview.get("attack_phase")) == 1,
		"Ranged preview must begin aiming while the delayed authority still waits")
	for frame: int in range(8):
		_ranged_delay.call("_physics_process", 0.01)
	_check(int(_ranged.get("attack_phase")) == 1,
		"Ranged authority must replay the recorded shoot command after 0.1 seconds")
	for frame: int in range(70):
		if _projectile_root.get_child_count() > 0:
			break
		_ranged_delay.call("_physics_process", 0.01)
	var projectile: BaseActor = _projectile_root.get_child(0) as BaseActor \
		if _projectile_root.get_child_count() > 0 else null
	_check(projectile != null and projectile.is_in_group("hostile_projectiles"),
		"Delayed ranged windup must eventually spawn one authority projectile in the room container")
	if projectile == null:
		return null
	await process_frame
	var projectile_delay: Node = projectile.get_node_or_null("ProjectileDelayController")
	if projectile_delay != null:
		projectile_delay.set_physics_process(false)
	return projectile


func _test_projectile_delay_and_permissions(projectile: BaseActor) -> void:
	var controller: DelayControllerBase = projectile.get_node("ProjectileDelayController") as DelayControllerBase
	var preview: BaseActor = controller.call("get_preview_body") as BaseActor
	var predictor: BaseActor = controller.get("predictor_body") as BaseActor
	var controller_base: Script = controller.get_script().get_base_script() as Script
	_check(controller_base != null and controller_base.resource_path == COMMAND_REPLAY_CONTROLLER_PATH
		and projectile.delay_controller == controller,
		"Projectile must bind to the same generic command-replay controller")
	_check(projectile.delay_replica_role == BaseActor.DelayReplicaRole.AUTHORITY
		and preview.delay_replica_role == BaseActor.DelayReplicaRole.PREVIEW
		and predictor.delay_replica_role == BaseActor.DelayReplicaRole.PREDICTOR,
		"Projectile controller must configure authority, preview and predictor roles")
	_check(projectile.collision_mask == 3 and bool(projectile.get("damage_enabled"))
		and preview.collision_mask == 2 and not bool(preview.get("damage_enabled"))
		and predictor.collision_mask in [0, 2] and not bool(predictor.get("damage_enabled")),
		"Only the authority projectile may collide with and damage the player "
		+ "(body mask=%d damage=%s, preview mask=%d damage=%s, predictor mask=%d damage=%s)" % [
			projectile.collision_mask, projectile.get("damage_enabled"),
			preview.collision_mask, preview.get("damage_enabled"),
			predictor.collision_mask, predictor.get("damage_enabled"),
		])
	_check(not preview.is_physics_processing() and not predictor.is_physics_processing(),
		"Controller must be the only physics clock for projectile replicas")
	_check(controller.get_delay_buffer_capacity() == 301
		and int(_budget.call("get_registered_controller_count")) == _baseline_controller_count + 1,
		"Live projectile must own a 301-slot buffer and register with shared delay budget")

	_authority.enter_thinking_time()
	_check(controller.request_delay_change(0.2),
		"Projectile delay request must be accepted during thinking time")
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	while _authority.is_in_thinking_time():
		await process_frame
	controller.set_physics_process(false)
	_check(predictor.collision_mask == 2 and not bool(predictor.get("damage_enabled")),
		"Activating projectile delay must prepare a terrain-only hidden predictor")
	var body_start: Vector2 = projectile.global_position
	var preview_start: Vector2 = preview.global_position
	for frame: int in range(5):
		controller.call("_physics_process", 0.01)
	_check(projectile.global_position.is_equal_approx(body_start),
		"Authority projectile must freeze while its delay history is filling")
	_check(preview.global_position.distance_to(preview_start) > 1.0 and preview.visible,
		"Projectile preview must continue along the future trajectory during authority wait")
	var timeline: DelayTimelineBuffer = controller.get("_timeline") as DelayTimelineBuffer
	var slots: Array = controller.get("_slots") as Array
	var latest_frame: Variant = slots[timeline.write_head] if timeline.write_head >= 0 else null
	_check(latest_frame is DelayFrame,
		"Projectile history must store the shared DelayFrame representation")
	for frame: int in range(22):
		controller.call("_physics_process", 0.01)
	_check(projectile.global_position.distance_to(body_start) > 1.0,
		"Authority projectile must replay recorded advance commands after 0.2 seconds")
	_check(controller.call("is_mouse_over_delay_visual", projectile.global_position)
		and controller.call("is_mouse_over_delay_visual", preview.global_position),
		"Shared delay selection must recognize both projectile authority and preview")
	print("PASS: projectile freezes, previews, records and replays through the shared delay layer")


func _test_projectile_bounce(projectile: BaseActor) -> void:
	var controller: DelayControllerBase = projectile.get_node("ProjectileDelayController") as DelayControllerBase
	var predictor: BaseActor = controller.get("predictor_body") as BaseActor
	# 主关卡延长后，右墙位于 x=6380；仍从墙前同样距离验证碰撞。
	predictor.global_position = Vector2(6345.0, 300.0)
	predictor.call("launch", Vector2.RIGHT)
	await physics_frame
	predictor.simulate_delay_command({"advance": true}, 0.05)
	_check(int(predictor.get("bounce_count")) == 0 and not bool(predictor.get("active")),
		"Projectile must expire on terrain because enemy-shot bounce is disabled by default")
	predictor.set("bounce_enabled", true)
	predictor.set("max_bounces", 1)
	predictor.global_position = Vector2(6345.0, 300.0)
	predictor.call("launch", Vector2.RIGHT)
	predictor.simulate_delay_command({"advance": true}, 0.05)
	_check(int(predictor.get("bounce_count")) == 1
		and predictor.velocity.x < 0.0 and bool(predictor.get("active")),
		"The common exported switch must still support an explicitly enabled terrain bounce")
	print("PASS: projectile expires by default and retains an optional terrain-bounce switch")


func _test_authority_projectile_damage() -> void:
	_player.call("reset_health")
	_player.global_position = Vector2(520.0, 625.0)
	var health_before: float = float(_player.get("current_health"))
	var projectile_scene: PackedScene = load("res://scenes/combat/projectiles/delayable_projectile.tscn") as PackedScene
	var projectile: BaseActor = projectile_scene.instantiate() as BaseActor
	_projectile_root.add_child(projectile)
	projectile.global_position = Vector2(440.0, 625.0)
	projectile.call("launch", Vector2.RIGHT)
	await process_frame
	var controller: Node = projectile.get_node("ProjectileDelayController")
	controller.set_physics_process(false)
	for frame: int in range(20):
		if not is_instance_valid(projectile) or not bool(projectile.get("active")):
			break
		projectile.simulate_delay_command({"advance": true}, 0.01)
	_check(float(_player.get("current_health")) == health_before - 12.0,
		"Authority projectile must apply its configured damage exactly once")
	await process_frame
	_check(not is_instance_valid(projectile),
		"Authority projectile must leave the scene after a player hit")
	print("PASS: only the authority projectile can damage the player")


func _test_round_cleanup_releases_budget() -> void:
	_scene.get_node("CombatRoomController").call("_clear_hostile_projectiles")
	await process_frame
	_check(get_nodes_in_group("hostile_projectiles").is_empty(),
		"Round cleanup must remove every authority projectile")
	_check(int(_budget.call("get_registered_controller_count")) == _baseline_controller_count,
		"Removing projectiles must release their delay-budget registrations")
	var participants: Array = _authority.get("_thinking_prediction_participants") as Array
	_check(participants.size() == _baseline_participant_count,
		"Removing projectiles must unregister their thinking-time callbacks")
	# 回归截图中的路径：弹幕释放后再次进入思考时间不得尝试转换 Freed Object。
	_authority.enter_thinking_time()
	_authority.call("_physics_process", 0.01)
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	while _authority.is_in_thinking_time():
		await process_frame
	_check(not _authority.is_in_thinking_time() and not paused,
		"Thinking time must still enter and exit after temporary projectiles are freed")
	print("PASS: projectile lifecycle cleanup releases shared budget state")
