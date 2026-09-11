extends SceneTree

## 初始武器锁定、F 范围拾取与玩家三体同步纵切：
## --headless --path program --script res://test/weapon_unlock_test.gd
var _scene: Node
var _group: DelayedActorGroup
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
	_disable_automatic_ticks()
	await process_frame

	_check(InputMap.has_action("interact"), "Project input map must expose the F interact action")
	_check(bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d")),
		"The project must enable HDR 2D for selective pickup glow")
	var world_environment: WorldEnvironment = _scene.get_node(
		"WorldEnvironment") as WorldEnvironment
	_check(world_environment.environment != null
		and world_environment.environment.glow_enabled,
		"The main scene environment must enable glow post-processing")
	_check(world_environment.environment.background_mode == Environment.BG_CANVAS,
		"The main environment must process the 2D canvas")
	_check(get_nodes_in_group(&"weapon_pickups").size() == 2,
		"The test scene must contain boomerang and staff pickups")
	_check(_all_replicas_match_unlocks(true, false, false),
		"Every player replica must start with only the sword unlocked")

	_push_key(KEY_2)
	_check(int(_group.preview_body.get("equipped_weapon")) == 1,
		"Pressing 2 before pickup must leave the sword equipped")
	_push_interact()
	await process_frame
	_check(get_nodes_in_group(&"weapon_pickups").size() == 2,
		"Pressing F outside pickup range must not consume a weapon")

	var boomerang_pickup: Node2D = _find_pickup(2)
	var staff_pickup: Node2D = _find_pickup(3)
	_check(boomerang_pickup != null and staff_pickup != null,
		"Both weapon pickups must be identifiable by slot")
	if boomerang_pickup != null and staff_pickup != null:
		_check(boomerang_pickup.is_in_group(&"pickups")
			and staff_pickup.is_in_group(&"pickups"),
			"Weapon pickups must also register as generic pickups")
		var boomerang_prompt: Label = boomerang_pickup.get_node("Prompt") as Label
		var staff_prompt: Label = staff_pickup.get_node("Prompt") as Label
		var staff_particles: CPUParticles2D = staff_pickup.get_node(
			"VisualRoot/Particles") as CPUParticles2D
		var staff_glow: Polygon2D = staff_pickup.get_node(
			"VisualRoot/Glow") as Polygon2D
		_check(not boomerang_prompt.visible and not staff_prompt.visible,
			"Pickup prompts must stay hidden while the live player is far away")
		_check(staff_particles.emitting,
			"Pickup particles must emit continuously")
		_check(maxf(staff_glow.color.r, maxf(
			staff_glow.color.g, staff_glow.color.b)) > 1.0,
			"Pickup glow color must be overbright in HDR 2D")
		# 复现实际问题：本体在回旋镖旁，预览体在法杖旁按 F。
		_group.body.global_position = boomerang_pickup.global_position
		_group.preview_body.global_position = staff_pickup.global_position
		await process_frame
		_check(not boomerang_prompt.visible and staff_prompt.visible,
			"Only the pickup near the live preview player may show F(拾取)")
		_check(staff_prompt.text == "F(拾取)",
			"The nearby pickup prompt must use the generic F(拾取) text")
		_push_interact()
		_group.preview_body.tick_physics(0, 0.01)
	var recorded_interaction: Recording = _group.preview_system.slots[
		_group.preview_system.write_head]
	_check(recorded_interaction != null and recorded_interaction.interact_pressed,
		"The preview replica must record F in its delay frame")
	_check(_all_replicas_match_unlocks(true, false, false)
		and get_nodes_in_group(&"weapon_pickups").size() == 2,
		"Recording F at the staff must not instantly collect the boomerang beside the body")
	if recorded_interaction != null and staff_pickup != null:
		# 直接让本体消费刚才的历史帧，验证副作用发生在回放时及本体当时的位置。
		_group.body.global_position = recorded_interaction.pos
		_group.preview_system.read_head = _group.preview_system.write_head
		_group.body.tick_physics(0, 0.01)
		await process_frame
	_check(_all_replicas_match_unlocks(true, false, true),
		"Replaying F at the staff must unlock the staff on all player replicas")
	_check(_find_pickup(2) != null and _find_pickup(3) == null,
		"The replayed interaction must collect the staff and leave the boomerang untouched")

	_group.set_delay_time_immediate(0.0)
	_group.configure()
	if boomerang_pickup != null:
		_group.body.global_position = boomerang_pickup.global_position
		_push_interact()
		_check(_find_pickup(2) != null,
			"Even at zero delay, F must wait for the authority physics frame")
		_group.body.tick_physics(0, 0.01)
		await process_frame
	_check(_all_replicas_match_unlocks(true, true, true),
		"The zero-delay authority frame must unlock the remaining boomerang")
	_check(get_nodes_in_group(&"weapon_pickups").is_empty(),
		"Both pickups must disappear only after authority execution")
	_push_key(KEY_2)
	_check(int(_group.body.get("equipped_weapon")) == 2,
		"Pressing 2 after pickup must equip the boomerang")
	_push_key(KEY_3)
	_check(int(_group.body.get("equipped_weapon")) == 3,
		"Pressing 3 after pickup must equip the staff")

	if _failures.is_empty():
		print("WEAPON_UNLOCK_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("WEAPON_UNLOCK_TEST_FAIL: " + failure)
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)


func _disable_automatic_ticks() -> void:
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	for enemy: Node in _scene.get_node("Enemies").get_children():
		enemy.set_physics_process(false)
	for controller: Node in get_nodes_in_group(&"enemy_delay_controller"):
		controller.set_physics_process(false)
	for controller: Node in get_nodes_in_group(&"moving_platform_delay_controllers"):
		controller.set_physics_process(false)


func _all_replicas_match_unlocks(sword: bool, boomerang: bool, staff: bool) -> bool:
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		if bool(actor.call("is_weapon_unlocked", 1)) != sword \
				or bool(actor.call("is_weapon_unlocked", 2)) != boomerang \
				or bool(actor.call("is_weapon_unlocked", 3)) != staff:
			return false
	return true


func _find_pickup(slot: int) -> Node2D:
	for pickup_node: Node in get_nodes_in_group(&"weapon_pickups"):
		if int(pickup_node.get("weapon_slot")) == slot:
			return pickup_node as Node2D
	return null


func _push_key(keycode: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	root.push_input(event, true)


func _push_interact() -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_F
	event.pressed = true
	root.push_input(event, true)
