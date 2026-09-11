extends SceneTree

## 可复用移动平台、固定尖刺与可延迟坠落陷阱纵切：
## --headless --path program --script res://test/platform_trap_test.gd
var _scene: Node
var _group: DelayedActorGroup
var _player: BaseActor
var _authority: WorldTimeAuthority
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
## 与 FallingTrap.TrapState 顺序一致；测试刻意只依赖 BaseActor 公共契约，不依赖编辑器全局类缓存。
const FALLING_TRAP_ARMED: int = 0
const FALLING_TRAP_FALLING: int = 1
const FALLING_TRAP_LANDED: int = 2
const FALLING_TRAP_RETURNING: int = 3

class PlatformPassenger:
	extends CharacterBody2D
	var gravity: float = 1600.0

	func _physics_process(delta: float) -> void:
		velocity.y += gravity * delta
		move_and_slide()


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
	_authority = _scene.get_node("WorldTimeAuthority") as WorldTimeAuthority
	_authority.thinking_entry_duration = 0.0
	_disable_automatic_combat_ticks()
	await process_frame

	var platform: AnimatableBody2D = await _test_moving_platform_route()
	await _test_platform_carries_passenger(platform)
	await _test_player_drops_through_one_way_platform(platform)
	await _test_spike_damage_authority()
	await _test_falling_trap_cycle_and_delay()
	await _test_delayable_platform_adapter()
	_test_pause_contract(platform)

	if _failures.is_empty():
		print("PLATFORM_TRAP_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("PLATFORM_TRAP_TEST_FAIL: " + failure)
	Engine.time_scale = 1.0
	paused = false
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	# AnimatableBody2D 的同步变换在物理服务器帧末发布；退出前额外留一帧完成 RID 清理。
	await physics_frame
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
	for delay_controller: Node in get_nodes_in_group("falling_trap_delay_controllers"):
		delay_controller.set_physics_process(false)


func _test_moving_platform_route() -> AnimatableBody2D:
	var platform_scene: PackedScene = load("res://scenes/environment/moving_platform.tscn") as PackedScene
	var platform: AnimatableBody2D = platform_scene.instantiate() as AnimatableBody2D
	platform.position = Vector2(800.0, 500.0)
	platform.set("travel_offset", Vector2(100.0, 0.0))
	platform.set("travel_speed", 100.0)
	platform.set("endpoint_wait_seconds", 0.25)
	_scene.add_child(platform)
	var endpoint_hits: Array[int] = [0]
	platform.connect("endpoint_reached", func(_at_end: bool) -> void: endpoint_hits[0] += 1)

	var route_start: Vector2 = platform.call("get_route_start") as Vector2
	var route_end: Vector2 = platform.call("get_route_end") as Vector2
	_check(route_start.is_equal_approx(Vector2(800.0, 500.0))
		and route_end.is_equal_approx(Vector2(900.0, 500.0)),
		"Moving platform route must use the authored local position plus travel_offset")
	for frame: int in range(25):
		await physics_frame
	_check(platform.position.distance_to(route_start) >= 23.0
		and platform.position.distance_to(route_start) <= 27.0,
		"Moving platform must advance by travel_speed multiplied by physics delta")
	# sync_to_physics 会晚一个同步点公开变换；多留四帧仍处在端点等待窗口内。
	for frame: int in range(80):
		await physics_frame
	_check(platform.position.is_equal_approx(route_end) and endpoint_hits[0] == 1,
		"Moving platform must clamp exactly to its endpoint and emit one endpoint signal")
	for frame: int in range(10):
		await physics_frame
	_check(platform.position.is_equal_approx(route_end),
		"Moving platform must remain still during its configured endpoint wait")
	for frame: int in range(20):
		await physics_frame
	_check(platform.position.distance_to(route_end) >= 7.0
		and platform.position.distance_to(route_end) <= 13.0,
		"After waiting, moving platform must reverse along the same route")

	platform.set_physics_process(false)
	platform.set("start_at_end", true)
	platform.call("reset_motion")
	await physics_frame
	_check(platform.position.distance_to(route_end) <= 0.1,
		"Reset must honor start_at_end without changing the authored route")
	var collision: CollisionShape2D = platform.get_node("CollisionShape2D") as CollisionShape2D
	_check(platform.collision_layer == 2 and platform.sync_to_physics
		and collision.one_way_collision and is_equal_approx(collision.one_way_collision_margin, 4.0),
		"Reusable platform must use terrain collision, physics synchronization and one-way defaults")
	_check(platform.z_index < _player.z_index,
		"One-way moving-platform visuals must render below the player standing on them")
	_check(platform.is_in_group("moving_platforms"),
		"Moving platforms must expose a group for future switches and room resets")
	_check(platform.is_in_group("player_respawn_reset") and platform.has_method("reset_combat"),
		"Moving platform must participate in the existing optional round-reset contract")
	_check(platform.has_method("is_drop_through_platform")
		and bool(platform.call("is_drop_through_platform")),
		"One-way moving platforms must explicitly expose the player drop-through contract")
	print("PASS: moving platform supports reusable routes, waits, reversal and reset")
	return platform


func _test_platform_carries_passenger(platform: AnimatableBody2D) -> void:
	platform.set("start_at_end", false)
	platform.set("movement_enabled", false)
	platform.call("reset_motion")
	platform.set_physics_process(true)
	await physics_frame
	await physics_frame

	var passenger: PlatformPassenger = PlatformPassenger.new()
	passenger.collision_layer = 1
	passenger.collision_mask = 2
	var passenger_shape: CollisionShape2D = CollisionShape2D.new()
	var rectangle: RectangleShape2D = RectangleShape2D.new()
	rectangle.size = Vector2(32.0, 32.0)
	passenger_shape.shape = rectangle
	passenger.add_child(passenger_shape)
	_scene.add_child(passenger)
	passenger.global_position = platform.global_position + Vector2(0.0, -28.1)
	for frame: int in range(12):
		await physics_frame

	var platform_start_x: float = platform.global_position.x
	var passenger_start_x: float = passenger.global_position.x
	platform.set("movement_enabled", true)
	for frame: int in range(40):
		await physics_frame
	var platform_delta_x: float = platform.global_position.x - platform_start_x
	var passenger_delta_x: float = passenger.global_position.x - passenger_start_x
	_check(platform_delta_x > 35.0 and passenger_delta_x > 35.0
		and absf(platform_delta_x - passenger_delta_x) <= 3.0
		and passenger.is_on_floor(),
		"Animatable moving platform must carry a grounded CharacterBody2D passenger")
	passenger.queue_free()
	platform.set_physics_process(false)
	print("PASS: moving platform carries a grounded physics passenger")


## S 只排除玩家当前脚下的单向平台；落地后普通地面仍保持实体碰撞。
func _test_player_drops_through_one_way_platform(platform: AnimatableBody2D) -> void:
	platform.set("start_at_end", false)
	platform.set("movement_enabled", false)
	platform.call("reset_motion")
	platform.set_physics_process(false)
	await physics_frame
	await physics_frame

	# x=850 位于本测试平台上，同时避开主场景中稍低的另一座移动平台。
	var platform_top_position: Vector2 = platform.global_position + Vector2(50.0, -36.1)
	_set_player_delay_for_test(0.0, platform_top_position)
	for frame: int in range(5):
		_player.tick_physics(0, 0.01)
	_check(_player.is_grounded_for_simulation(),
		"Player must settle on the one-way platform before testing drop-through")

	_player.call("buffer_hit_stop_input", &"ui_down")
	_player.tick_physics(0, 0.01)
	var ignored_current_platform: bool = _player.get_collision_exceptions().has(platform)
	var drop_start_y: float = _player.global_position.y
	for frame: int in range(45):
		_player.tick_physics(0, 0.01)
	_check(ignored_current_platform and _player.global_position.y > drop_start_y + 60.0,
		"Pressing S on a one-way moving platform must immediately let the player fall through")
	_check(not _player.get_collision_exceptions().has(platform),
		"The platform collision exception must expire after the player has cleared the thin platform")

	# Recording 的末尾参数保持向后兼容，同时验证下穿会进入延迟命令字典。
	var drop_recording: Recording = Recording.new(
		0.0, false, Vector2.ZERO, Vector2.ZERO,
		false, 1, 0.0, false, Vector2.RIGHT, false, Vector2.RIGHT, true
	)
	_check(drop_recording.drop_pressed and bool(drop_recording.command.get("drop_pressed", false)),
		"Platform drop input must be serialized into the existing delayed player command")

	var static_platform: PhysicsBody2D = _scene.get_node("SideScrollLevel/PlatformA") as PhysicsBody2D
	var static_shape: CollisionShape2D = static_platform.get_node("CollisionShape2D") as CollisionShape2D
	_check(static_shape.one_way_collision,
		"Fixed level platforms must use the shared one-way platform rule")
	_set_player_delay_for_test(0.0, static_platform.global_position + Vector2(0.0, -36.1))
	for frame: int in range(5):
		_player.tick_physics(0, 0.01)
	_player.call("buffer_hit_stop_input", &"ui_down")
	_player.tick_physics(0, 0.01)
	var ignored_static_platform: bool = _player.get_collision_exceptions().has(static_platform)
	var static_drop_start_y: float = _player.global_position.y
	for frame: int in range(45):
		_player.tick_physics(0, 0.01)
	_check(ignored_static_platform and _player.global_position.y > static_drop_start_y + 60.0,
		"The same S input must also drop through fixed instances of the shared platform class")

	# 玩家可以在空中提前按住 S；落到薄平台后的首个可控帧应自动继续下穿。
	_set_player_delay_for_test(0.0, static_platform.global_position + Vector2(0.0, -120.0))
	_player.velocity = Vector2.ZERO
	Input.action_press("ui_down")
	var held_drop_started: bool = false
	for frame: int in range(90):
		_player.tick_physics(0, 0.01)
		held_drop_started = held_drop_started or bool(
			_player.call("is_dropping_through_platform"))
	Input.action_release("ui_down")
	_check(held_drop_started and _player.global_position.y > static_platform.global_position.y + 30.0,
		"Holding S before landing must repeatedly request drop-through until a platform is reached")

	_set_player_delay_for_test(0.0, Vector2(850.0, 625.0))
	for frame: int in range(3):
		_player.tick_physics(0, 0.01)
	var ground_y: float = _player.global_position.y
	_player.call("buffer_hit_stop_input", &"ui_down")
	_player.tick_physics(0, 0.01)
	for frame: int in range(10):
		_player.tick_physics(0, 0.01)
	_check(_player.get_collision_exceptions().is_empty()
		and absf(_player.global_position.y - ground_y) <= 0.5,
		"Pressing S on ordinary ground must not disable terrain collision")
	print("PASS: player drops through only the current one-way platform and records the delayed command")


func _test_spike_damage_authority() -> void:
	_set_player_delay_for_test(0.5, Vector2(600.0, 625.0))
	var trap_scene: PackedScene = load("res://scenes/environment/spike_trap.tscn") as PackedScene
	var trap: SpikeTrap = trap_scene.instantiate() as SpikeTrap
	trap.position = Vector2(600.0, 649.0)
	trap.set("damage", 20.0)
	trap.set("cycle_enabled", false)
	trap.set("starts_active", true)
	_scene.add_child(trap)
	trap.set_physics_process(false)
	var enemy: MeleeEnemy = _scene.get_node("Enemies/MeleeEnemyA") as MeleeEnemy
	enemy.call("reset_combat", true)
	enemy.global_position = Vector2(620.0, 649.0)
	enemy.set_physics_process(false)
	await physics_frame
	await physics_frame
	await physics_frame
	var body_health_before: float = float(_player.get("current_health"))
	var preview_health_before: float = float(_group.preview_body.get("current_health"))
	var enemy_health_before: float = float(enemy.get("current_health"))
	trap.call("_physics_process", 0.01)
	_check(float(_player.get("current_health")) == body_health_before - 20.0,
		"Active spike trap must damage the overlapping authority player")
	_check(float(enemy.get("current_health")) == enemy_health_before - 20.0,
		"Faction-neutral spikes must damage an overlapping authority enemy")
	_check(float(_group.preview_body.get("current_health")) == preview_health_before,
		"Spike trap must ignore the player's overlapping preview and predictor replicas")
	_check(trap.collision_mask == 5
		and trap.damage_target_groups.has(&"player_damage_body")
		and trap.damage_target_groups.has(&"enemy_damage_body"),
		"Faction-neutral spikes must query both player and enemy damage layers")
	_check(is_zero_approx(_group.delay_time) and _group.divergence_count == 1,
		"Trap damage must enter the existing external-divergence path and clear stale player future")
	trap.call("_physics_process", 0.01)
	_check(float(_player.get("current_health")) == body_health_before - 20.0,
		"Trap repeat cooldown must prevent damage on every physics tick")
	_player.set("_hurt_invulnerability_left", 0.0)
	trap.call("_physics_process", 0.50)
	_check(float(_player.get("current_health")) == body_health_before - 40.0,
		"A target remaining on spikes may be hit again after both cooldown gates allow it")

	# 把角色移出检测区，再单独验证可用于关卡错峰布置的机关循环。
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.global_position = Vector2(300.0, 625.0)
	await physics_frame
	trap.set("cycle_enabled", true)
	trap.set("starts_active", false)
	trap.set("inactive_seconds", 0.20)
	trap.set("warning_seconds", 0.10)
	trap.set("active_seconds", 0.15)
	trap.call("reset_cycle")
	_check(int(trap.get("current_state")) == 0 and not bool(trap.call("is_damage_active")),
		"Cycling spike trap may start safely retracted")
	trap.call("_physics_process", 0.20)
	_check(int(trap.get("current_state")) == 1,
		"Retracted spikes must enter a visible warning state before becoming dangerous")
	trap.call("_physics_process", 0.10)
	_check(int(trap.get("current_state")) == 2 and bool(trap.call("is_damage_active")),
		"Warning completion must activate spike damage")
	trap.call("_physics_process", 0.15)
	_check(int(trap.get("current_state")) == 0,
		"Active spikes must retract and continue their configured cycle")
	trap.call("set_active", true)
	_check(bool(trap.call("is_damage_active")) and trap.is_in_group("traps"),
		"Level scripts must be able to activate a grouped trap directly")
	trap.call("reset_combat", false)
	_check(not bool(trap.call("is_damage_active")) and trap.is_in_group("player_respawn_reset"),
		"Trap round reset must restore its authored inactive start state")
	print("PASS: spike trap supports authority-only damage, repeat hits and timed cycles")


func _test_falling_trap_cycle_and_delay() -> void:
	var trap: BaseActor = _scene.get_node("EnvironmentGameplay/TimedSpikes") as BaseActor
	var controller: Node = trap.get_node("FallingTrapDelayController")
	controller.set_physics_process(false)
	var preview: BaseActor = controller.call("get_preview_body") as BaseActor
	var predictor: BaseActor = controller.get("predictor_body") as BaseActor
	var home_position: Vector2 = trap.global_position
	_check(trap != null and controller is CommandReplayDelayController
		and preview != null and predictor != null,
		"TimedSpikes must use a BaseActor plus the shared command-replay delay adapter")
	var authority_damage_area: Area2D = trap.get_node("DamageArea") as Area2D
	var preview_damage_area: Area2D = preview.get_node("DamageArea") as Area2D
	var preview_trigger_area: Area2D = preview.get_node("TriggerArea") as Area2D
	_check(trap.collision_layer == 2 and trap.collision_mask == 2
		and not trap.base_collision.one_way_collision and preview.collision_layer == 0
		and authority_damage_area.monitoring and not preview_damage_area.monitoring
		and preview_trigger_area.monitoring,
		"The authority falling trap must be solid and dangerous while replicas remain non-interactive")

	_set_player_delay_for_test(0.0, Vector2(home_position.x, 625.0))
	var enemy: MeleeEnemy = _scene.get_node("Enemies/MeleeEnemyA") as MeleeEnemy
	enemy.call("reset_combat", true)
	enemy.global_position = Vector2(home_position.x + 30.0, 649.0)
	await physics_frame
	await physics_frame
	var trigger_command: Dictionary = trap.capture_delay_command()
	_check(bool(trigger_command.get("trigger_fall", false)),
		"A real player entering the authored area below TimedSpikes must trigger its fall")
	var maximum_fall_speed: float = 0.0
	trap.simulate_delay_command(trigger_command, 0.01)
	for frame: int in range(160):
		trap.simulate_delay_command({"trigger_fall": false}, 0.01)
		maximum_fall_speed = maxf(maximum_fall_speed, trap.velocity.y)
		if int(trap.get("current_state")) == FALLING_TRAP_LANDED:
			break
	_check(int(trap.get("current_state")) == FALLING_TRAP_LANDED
		and trap.global_position.y > home_position.y + 300.0 and maximum_fall_speed > 300.0,
		"Triggered TimedSpikes must accelerate under gravity and stop on terrain")

	var player_health_before: float = float(_player.get("current_health"))
	var enemy_health_before: float = float(enemy.get("current_health"))
	await physics_frame
	await physics_frame
	trap.simulate_delay_command({"trigger_fall": false}, 0.01)
	_check(float(_player.get("current_health")) < player_health_before
		and float(enemy.get("current_health")) < enemy_health_before,
		"The landed authority trap must damage overlapping player and enemy bodies alike")

	# 先进入回升阶段，再让玩家从下方跳向尖刺：实体碰撞应阻挡玩家，伤害区仍应生效。
	enemy.global_position = Vector2(420.0, 649.0)
	while int(trap.get("current_state")) == FALLING_TRAP_LANDED:
		trap.simulate_delay_command({"trigger_fall": false}, 0.01)
	for frame: int in range(80):
		trap.simulate_delay_command({"trigger_fall": false}, 0.01)
	_set_player_delay_for_test(0.0, trap.global_position + Vector2(0.0, 58.0))
	_player.set("_hurt_invulnerability_left", 0.0)
	_player.velocity = Vector2(0.0, -300.0)
	await physics_frame
	await physics_frame
	var upward_blocked: bool = _player.test_move(
		_player.global_transform,
		Vector2(0.0, -20.0)
	)
	var returning_health_before: float = float(_player.get("current_health"))
	trap.simulate_delay_command({"trigger_fall": false}, 0.01)
	_check(upward_blocked and float(_player.get("current_health")) < returning_health_before,
		"A player jumping into the rising spikes must be blocked and damaged, not pass through them")

	_set_player_delay_for_test(0.0, Vector2(300.0, 625.0))
	var saw_returning: bool = false
	for frame: int in range(700):
		trap.simulate_delay_command({"trigger_fall": true}, 0.01)
		saw_returning = saw_returning or int(trap.get("current_state")) == FALLING_TRAP_RETURNING
		if int(trap.get("current_state")) == FALLING_TRAP_ARMED:
			break
	_check(saw_returning and int(trap.get("current_state")) == FALLING_TRAP_ARMED
		and trap.global_position.distance_to(home_position) <= 0.1,
		"After landing, TimedSpikes must return slowly and cannot re-arm before reaching home")

	# 精确覆盖玩法目标：先让机关开始坠落，再设置延迟，确认权威体原地冻结而蓝色体继续预测。
	_set_player_delay_for_test(0.0, Vector2(home_position.x, 625.0))
	trap.call("reset_combat", false)
	await physics_frame
	await physics_frame
	trap.simulate_delay_command(trap.capture_delay_command(), 0.01)
	for frame: int in range(10):
		trap.simulate_delay_command({"trigger_fall": false}, 0.01)
	var falling_position: Vector2 = trap.global_position
	_check(int(trap.get("current_state")) == FALLING_TRAP_FALLING
		and falling_position.y > home_position.y,
		"Delay regression setup must begin while TimedSpikes is already falling")
	_authority.enter_thinking_time()
	var request_accepted: bool = bool(controller.call("request_delay_change", 0.20))
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	while _authority.is_in_thinking_time():
		await process_frame
	for frame: int in range(12):
		controller.call("_physics_process", 0.01)
	_check(request_accepted and trap.global_position.distance_to(falling_position) <= 0.1
		and preview.global_position.y > falling_position.y,
		"Adding delay during a fall must freeze the authority trap while its blue preview keeps falling")
	for frame: int in range(12):
		controller.call("_physics_process", 0.01)
	_check(trap.global_position.y > falling_position.y
		and is_equal_approx(float(controller.get("delay_time")), 0.20),
		"After the delayed window, TimedSpikes must replay and continue the same physical fall")
	trap.call("reset_combat", false)
	_set_player_delay_for_test(0.0, Vector2(300.0, 625.0))
	print("PASS: falling trap triggers below the player, returns, and freezes through shared delay")


func _test_delayable_platform_adapter() -> void:
	var delayable_scene: PackedScene = load(
		"res://scenes/environment/delayable_moving_platform.tscn"
	) as PackedScene
	var actor: DelayableMovingPlatform = delayable_scene.instantiate() as DelayableMovingPlatform
	actor.position = Vector2(3500.0, 420.0)
	actor.travel_offset = Vector2(100.0, 0.0)
	actor.travel_speed = 100.0
	actor.endpoint_wait_seconds = 0.0
	_scene.add_child(actor)
	await process_frame
	await process_frame
	var controller: Node = actor.get_node("MovingPlatformDelayController")
	controller.set_physics_process(false)
	var preview: DelayableMovingPlatform = controller.call("get_preview_body") \
		as DelayableMovingPlatform
	var predictor: DelayableMovingPlatform = controller.get("predictor_body") \
		as DelayableMovingPlatform
	_check(controller.is_in_group("moving_platform_delay_controllers")
		and controller is CommandReplayDelayController,
		"Moving platform must use its thin adapter over the shared command-replay controller")
	_check(preview != null and predictor != null
		and preview.travel_offset == Vector2(100.0, 0.0)
		and predictor.travel_speed == 100.0,
		"Platform delay replicas must inherit per-instance route configuration")
	var authority_shape: CollisionShape2D = actor.platform.platform_collision
	var preview_shape: CollisionShape2D = preview.platform.platform_collision
	_check(actor.platform.collision_layer == 2 and actor.platform.sync_to_physics
		and not authority_shape.disabled
		and preview.platform.collision_layer == 0 and preview_shape.disabled,
		"Only the authority moving platform may carry or collide with actors")
	_check(actor.has_node("DelayControlUi") and preview.platform.modulate.a < 1.0,
		"Delayable platform must reuse the common delay UI and blue preview presentation")
	# 载人能力已在上一项以 sync_to_physics 验证；关闭同步后可按精确的 0.01 秒手动验证时间轴。
	actor.platform.sync_to_physics = false
	# 初始化发生在 deferred 阶段；先复位并等一次物理发布，排除挂接控制器前排队的首帧位移。
	actor.call("reset_combat", false)
	await physics_frame
	_check(not bool(controller.call("request_delay_change", 0.20)),
		"Moving-platform delay requests outside thinking time must be rejected")
	_authority.enter_thinking_time()
	var request_accepted: bool = bool(controller.call("request_delay_change", 0.20))
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	while _authority.is_in_thinking_time():
		await process_frame
	_check(request_accepted and is_equal_approx(float(controller.get("delay_time")), 0.20),
		"Moving-platform delay must commit through the shared thinking-time authority")
	var body_start: Vector2 = actor.platform.position
	var preview_start: Vector2 = preview.platform.position
	# 公共时间轴按固定 0.01 秒手动推进，避免无头环境一帧内补跑多个物理 tick 造成计数漂移。
	for frame: int in range(16):
		controller.call("_physics_process", 0.01)
	var body_wait_distance: float = actor.platform.position.distance_to(body_start)
	var preview_lead_distance: float = preview.platform.position.distance_to(preview_start)
	_check(body_wait_distance <= 0.1,
		"Authority platform must wait while filling delay history (distance=%.2f)" % body_wait_distance)
	_check(preview_lead_distance >= 10.0,
		"Blue platform preview must move ahead during the wait (distance=%.2f)" % preview_lead_distance)
	for frame: int in range(16):
		controller.call("_physics_process", 0.01)
	var replay_distance: float = actor.platform.position.distance_to(body_start)
	_check(replay_distance >= 10.0,
		"The authority platform must later replay the same route movement (distance=%.2f)" \
		% replay_distance)
	var authority_point: Vector2 = actor.to_global(actor.platform.position)
	var preview_point: Vector2 = preview.to_global(preview.platform.position)
	_check(bool(controller.call("is_mouse_over_delay_visual", authority_point))
		and bool(controller.call("is_mouse_over_delay_visual", preview_point)),
		"Delay selection must recognize both real and blue moving-platform positions")
	actor.call("reset_combat", false)
	_check(is_zero_approx(float(controller.get("delay_time"))) and not preview.visible,
		"Platform lifecycle reset must clear its command history and hide the preview")
	actor.queue_free()
	await process_frame
	await physics_frame
	print("PASS: moving platform reuses the shared three-replica delay timeline")


func _test_pause_contract(platform: AnimatableBody2D) -> void:
	var trap: Node = get_first_node_in_group("traps")
	paused = true
	_check(not platform.can_process() and trap != null and not trap.can_process(),
		"Platforms and traps must inherit the unified SceneTree pause instead of running in thinking time")
	paused = false
	print("PASS: environment mechanics obey the shared pause authority")


func _set_player_delay_for_test(delay: float, player_position: Vector2) -> void:
	_group._setting_delay_internally = true
	_group.delay_time = delay
	_group._setting_delay_internally = false
	_group._pending_delay = -1.0
	_group.preview_system.reset_to_initial_state()
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.global_position = player_position
		actor.velocity = Vector2.ZERO
		actor.call("reset_health")
	_group.configure()
