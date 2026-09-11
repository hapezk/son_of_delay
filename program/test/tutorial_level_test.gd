extends SceneTree

## 教学关卡结构与十七步流程纵切：
## --headless --path program --script res://test/tutorial_level_test.gd
var _scene: Node
var _group: DelayedActorGroup
var _controller: Node
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _run() -> void:
	_scene = load("res://scenes/tutorial/tutorial_level.tscn").instantiate()
	root.add_child(_scene)
	# 让同步到物理服务器的 AnimatableBody2D 先应用场景初始变换，再冻结自动流程。
	await physics_frame
	_group = _scene.get_node("Actors/BodyGroup") as DelayedActorGroup
	_controller = _scene.get_node("TutorialController")
	_disable_automatic_ticks()

	_check(is_equal_approx(_group.delay_time, 1.0),
		"Tutorial must start with the player's one-second natural delay")
	_check(is_equal_approx(_group.natural_delay_time, 1.0),
		"Tutorial must explain the same natural delay used by regular levels")
	_check(int(_controller.call("get_lesson_index")) == 0,
		"Tutorial must begin with the movement lesson")
	_check(get_nodes_in_group(&"weapon_pickups").size() == 2,
		"Tutorial must contain boomerang and staff pickups")
	_check(get_nodes_in_group(&"delayable_lift_gates").size() == 1,
		"Tutorial must contain one delayable lift-gate target")
	_check(get_nodes_in_group(&"pressure_switches").size() == 1,
		"Tutorial must contain one floor pressure switch")
	var stats_panel: Control = _scene.get_node(
		"TutorialUI/PlayerStatsPanel") as Control
	var lesson_panel: Control = _scene.get_node(
		"TutorialUI/LessonPanel") as Control
	var lesson_title: Label = _scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonTitle") as Label
	var lesson_hint: Label = _scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonHint") as Label
	var viewport_center_x: float = root.get_visible_rect().size.x * 0.5
	_check(stats_panel.position.is_equal_approx(Vector2(16.0, 16.0))
		and not stats_panel.get_global_rect().intersects(lesson_panel.get_global_rect()),
		"Compact player attributes must stay in the top-left without covering the lesson")
	_check(is_equal_approx(lesson_panel.get_global_rect().get_center().x, viewport_center_x)
		and lesson_title.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER
		and lesson_hint.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER
		and lesson_panel.get_node_or_null("Margin/VBox/LessonProgress") == null,
		"Tutorial card and all of its text rows must be centered on the viewport")
	_check(stats_panel.get_node_or_null("Margin/VBox/StatsLabel") == null,
		"Tutorial HUD must omit redundant weapon, movement and combat-stat text")

	var body: BaseActor = _group.body
	var player: BaseActor = _group.preview_body
	_check(body.z_index >= 20,
		"Player must render above ordinary world objects")
	var left_wall_visual: CanvasItem = _scene.get_node(
		"Background/LeftWall/Visual") as CanvasItem
	var ground_trim: CanvasItem = _scene.get_node(
		"Background/Ground/GroundTrim") as CanvasItem
	_check(left_wall_visual.z_index > ground_trim.z_index,
		"Left boundary pillar must render above the ground trim")
	_check(left_wall_visual.z_index < body.z_index,
		"Left boundary pillar must remain below the player")
	var lesson_gates: CanvasItem = _scene.get_node(
		"TutorialCourse/Gates") as CanvasItem
	_check(lesson_gates.z_index > ground_trim.z_index,
		"Thin lesson gates must render above the ground trim")
	_check(lesson_gates.z_index < body.z_index,
		"Thin lesson gates must remain below the player")
	var theoretical_jump_height: float = body.jump_velocity * body.jump_velocity \
		/ (2.0 * body.gravity)
	var drop_platform: MovingPlatform = _scene.get_node(
		"TutorialCourse/DropPlatform") as MovingPlatform
	var drop_platform_rise: float = 649.0 - (drop_platform.position.y - 12.0)
	_check(drop_platform_rise < theoretical_jump_height,
		"Drop platform rise %.1f must stay below runtime jump height %.1f (v=%.1f, g=%.1f)" % [
			drop_platform_rise, theoretical_jump_height, body.jump_velocity, body.gravity,
		])
	var pressure_switch: Node2D = _scene.get_node(
		"TutorialCourse/PressureSwitch") as Node2D
	var lift_gate: Node2D = _scene.get_node("TutorialCourse/LiftGate") as Node2D
	var lift_gate_delay_ui: Node2D = lift_gate.get_node("DelayControlUi") as Node2D
	var fixed_delay_ui_position: Vector2 = lift_gate_delay_ui.global_position
	_check(int(lift_gate.get("obstruction_escape_direction")) == -1,
		"Tutorial lift gate safety must always return the player to the switch side")
	_check(lift_gate_delay_ui.top_level,
		"Lift gate delay UI must not inherit the moving gate transform")
	_check(fixed_delay_ui_position.is_equal_approx(
		lift_gate.call("get_fixed_delay_ui_global_position") as Vector2),
		"Lift gate delay UI must start at the closed doorway center")
	_check(float(lift_gate.get("gate_height")) > theoretical_jump_height + 48.0,
		"Closed lift gate must be too tall to jump over")
	# 玩家从完全离开开关到身体完全越过门的最短奔跑时间。
	var switch_release_x: float = pressure_switch.global_position.x \
		+ float(pressure_switch.call("get_trigger_half_width")) + 24.0
	var gate_clear_x: float = lift_gate.global_position.x \
		+ float(lift_gate.get("gate_width")) * 0.5 + 24.0 + 8.0
	var minimum_run_seconds: float = (gate_clear_x - switch_release_x) / body.move_speed
	var no_delay_block_seconds: float = float(lift_gate.call(
		"get_grounded_block_time", 48.0))
	_check(no_delay_block_seconds < minimum_run_seconds,
		"Gate must block in %.2fs before the player can run across in %.2fs" % [
			no_delay_block_seconds, minimum_run_seconds,
		])
	_check(no_delay_block_seconds + 1.0 > minimum_run_seconds,
		"One second of delay must leave enough time to clear the gate")
	player.global_position.x = 400.0
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 1,
		"Moving right must advance to the jump lesson")

	player.global_position.x = 700.0
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 2,
		"Clearing the obstacle must advance to the drop-through lesson")

	player.set("_drop_through_time_left", 0.2)
	_controller.call("_process", 0.0)
	await process_frame
	_check(int(_controller.call("get_lesson_index")) == 3,
		"A real platform drop must advance to the sword lesson")
	_check(_is_gate_open("GateAfterDrop"),
		"Completing platform drop must open its lesson gate")
	_check(_scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonTitle").text.ends_with("普通攻击"),
		"Normal attack lesson must use the requested title")
	_check(_scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonHint").text \
		.contains("鼠标瞄准假人左键使用普通攻击，按住可自动普攻"),
		"Normal attack lesson must use the requested instruction")

	var sword_dummy: MeleeEnemy = _scene.get_node(
		"TutorialCourse/SwordDummy") as MeleeEnemy
	_check(sword_dummy.max_health >= 200.0,
		"Sword tutorial dummy needs enough health for repeat and charged attacks")
	sword_dummy.hit_count = 3
	sword_dummy.last_combo = 3
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 4,
		"A full repeated sword combo must advance to charged attack training")
	_check(_scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonHint").text \
		.contains("鼠标右键进入蓄力模式，蓄力时间越久效果越强"),
		"Charged attack lesson must use the requested instruction")

	sword_dummy.hit_count = 4
	sword_dummy.last_combo = 4
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 5,
		"A charged sword hit must advance to boomerang pickup")
	await process_frame
	_check(_is_gate_open("GateAfterSword"),
		"Both sword lessons must be complete before opening the combat gate")

	_check(_group.unlock_weapon_for_all(2),
		"Tutorial setup must be able to unlock the boomerang")
	_check(bool(player.call("select_weapon", 2)),
		"Tutorial setup must be able to equip the boomerang")
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 6,
		"Unlocking and equipping slot 2 must advance to boomerang use")

	var boomerang_target: MeleeEnemy = _scene.get_node(
		"TutorialCourse/BoomerangTarget") as MeleeEnemy
	boomerang_target.hit_count = 1
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 7,
		"Hitting the ranged target must advance to staff pickup")

	_check(_group.unlock_weapon_for_all(3),
		"Tutorial setup must be able to unlock the staff")
	_check(bool(player.call("select_weapon", 3)),
		"Tutorial setup must be able to equip the staff")
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 8,
		"Unlocking and equipping slot 3 must advance to staff use")

	var staff_target: MeleeEnemy = _scene.get_node(
		"TutorialCourse/StaffTarget") as MeleeEnemy
	staff_target.hit_count = 1
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 9,
		"Hitting the staff target must advance to thinking-time introduction")
	_check(_scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonHint").text.contains("世界会暂停"),
		"Thinking-time lesson must explain pausing and target inspection")
	var authority: WorldTimeAuthority = _scene.get_node(
		"WorldTimeAuthority") as WorldTimeAuthority
	authority.thinking_entry_duration = 0.0
	authority.enter_thinking_time()
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 10,
		"Entering thinking time must advance to mouse fine-tuning")
	_check(_scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonHint").text.contains("0.01 秒"),
		"Fine-tuning lesson must explain scroll direction and the smallest step")
	_check(_group.request_delay_change(0.99),
		"Tutorial setup must accept a one-tick pending delay adjustment")
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 11,
		"A pending 0.01-second reduction must advance to self-delay control")
	authority.request_exit_thinking_time()
	authority.call("_physics_process", 0.01)
	authority.call("_finish_pending_resume")
	_check(_scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonHint").text.contains("按 R") \
		and _scene.get_node(
			"TutorialUI/LessonPanel/Margin/VBox/LessonHint").text.contains("直接归零"),
		"Self-delay lesson must explain how natural delay consumes load when canceled")

	_group.set_delay_time_immediate(0.0)
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 12,
		"Removing natural delay must advance to the load-release lesson")
	_check(_scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonHint").text.contains("全部延迟负载"),
		"Restore lesson must explain that returning to natural delay frees load")

	_group.set_delay_time_immediate(_group.natural_delay_time)
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 13,
		"Restoring natural delay must advance directly to gate-delay training")
	_check(not _scene.get_node(
		"TutorialUI/LessonPanel/Margin/VBox/LessonHint").text.contains("负延迟"),
		"Tutorial must not teach unavailable negative delay with the initial capacity")

	var gate_controller: Node = _scene.get_node(
		"TutorialCourse/LiftGate/LiftGateDelayController")
	gate_controller.call("set_delay_time_immediate", 1.0)
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 14,
		"Committed gate delay must advance to the pressure-switch lesson")

	body.global_position = pressure_switch.global_position - Vector2(0.0, 24.0)
	await physics_frame
	await physics_frame
	await process_frame
	var switch_pressed: bool = bool(pressure_switch.call("is_pressed"))
	var switch_area: Area2D = pressure_switch as Area2D
	_check(switch_pressed,
		"Player on switch must activate it: player=%s layer=%d switch=%s mask=%d overlaps=%d" % [
			body.global_position,
			body.collision_layer,
			pressure_switch.global_position,
			switch_area.collision_mask,
			switch_area.get_overlapping_bodies().size(),
		])
	var open_command: Dictionary = lift_gate.call("capture_delay_command") as Dictionary
	_check(bool(open_command.get("switch_pressed", false)),
		"Lift gate command capture must read the linked pressure switch")
	for _frame_index: int in range(110):
		lift_gate.call("simulate_delay_command", open_command, 0.01)
	_check(bool(lift_gate.call("is_fully_open")),
		"Holding the floor switch must fully raise the lift gate")
	_check(lift_gate_delay_ui.global_position.is_equal_approx(fixed_delay_ui_position),
		"Lift gate delay UI must remain at the doorway center while the gate rises")
	_check(bool(gate_controller.call(
		"is_mouse_over_delay_visual", fixed_delay_ui_position)),
		"Raised lift gate must remain selectable across its closed doorway position")
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 15,
		"A fully raised delayed gate must advance to the passage lesson")

	# 玩家站在门下时，门要先停在接触面，再把玩家送回最近的安全侧。
	var gate_closed_bottom_y: float = fixed_delay_ui_position.y \
		+ float(lift_gate.get("gate_height")) * 0.5
	# 故意站到门洞右半边；教学门仍应送回左侧，不能借防卡机制越门。
	body.global_position = Vector2(
		lift_gate.global_position.x + 12.0, gate_closed_bottom_y - 24.0)
	body.velocity = Vector2.ZERO
	body.reset_physics_interpolation()
	await physics_frame
	await physics_frame
	await process_frame
	# 这里直接注入已记录的“开关释放”命令，隔离 Area2D 传送缓存对夹门测试的影响。
	var close_command: Dictionary = {"switch_pressed": false}
	var obstruction_detected: bool = false
	for _frame_index: int in range(110):
		lift_gate.call("simulate_delay_command", close_command, 0.01)
		if bool(lift_gate.call("was_solid_obstacle_motion_blocked")):
			obstruction_detected = true
			break
	# 脱困会更新玩家变换；等待物理服务器同步后，门应自行完成余下关闭行程。
	await physics_frame
	await physics_frame
	for _frame_index: int in range(110):
		lift_gate.call("simulate_delay_command", close_command, 0.01)
	var gate_left_x: float = lift_gate.global_position.x \
		- float(lift_gate.get("gate_width")) * 0.5
	var gate_right_x: float = lift_gate.global_position.x \
		+ float(lift_gate.get("gate_width")) * 0.5
	var player_outside_gate: bool = body.global_position.x + 24.0 < gate_left_x \
		or body.global_position.x - 24.0 > gate_right_x
	_check(obstruction_detected,
		"Closing lift gate must detect the player obstruction")
	_check(player_outside_gate,
		"Lift gate safety must move the player completely outside the gate")
	_check(body.global_position.x < gate_left_x,
		"Player on either half must be returned to the tutorial gate approach side")
	_check(bool(lift_gate.call("is_fully_closed")),
		"Lift gate must continue closing after automatically releasing the player")

	# 防卡已独立验证；这里再把玩家放到门右侧，只用于推进后续教学步骤。
	# 防卡路径可能把当前输入权威切回本体；两份角色都放到门外，专测课程追赶。
	body.global_position.x = gate_clear_x
	player.global_position.x = gate_clear_x
	_controller.call("_process", 0.0)
	_check(int(_controller.call("get_lesson_index")) == 16,
		"Crossing the delayed lift gate must open the route to the exit")

	body.global_position.x = 3520.0
	player.global_position.x = 3520.0
	_controller.call("_process", 0.0)
	_check(bool(_controller.call("is_complete")),
		"Reaching the exit must complete the tutorial")
	_check(_scene.get_node("TutorialUI/CompletionBackdrop").visible,
		"Tutorial completion must display its result overlay")

	# 将测试实例登记为当前场景，真实覆盖完成界面按 Enter 进入正式关卡的路径。
	current_scene = _scene
	var continue_event: InputEventKey = InputEventKey.new()
	continue_event.keycode = KEY_ENTER
	continue_event.pressed = true
	_controller.call("_unhandled_input", continue_event)
	await process_frame
	await process_frame
	_check(current_scene != null and is_instance_valid(current_scene),
		"Pressing Enter after completion must open a valid scene")
	_check(current_scene != null and current_scene.scene_file_path == "res://scenes/main.tscn",
		"Pressing Enter after completion must enter the main level")

	if _failures.is_empty():
		print("TUTORIAL_LEVEL_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("TUTORIAL_LEVEL_TEST_FAIL: " + failure)
	if current_scene != null and is_instance_valid(current_scene):
		var scene_to_free: Node = current_scene
		current_scene = null
		root.remove_child(scene_to_free)
		scene_to_free.queue_free()
	elif is_instance_valid(_scene):
		root.remove_child(_scene)
		_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)


func _disable_automatic_ticks() -> void:
	_controller.set_process(false)
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	for dummy_name: String in ["SwordDummy", "BoomerangTarget", "StaffTarget"]:
		var dummy: MeleeEnemy = _scene.get_node(
			"TutorialCourse/" + dummy_name) as MeleeEnemy
		dummy.set_physics_process(false)
	var gate_controller: Node = _scene.get_node(
		"TutorialCourse/LiftGate/LiftGateDelayController")
	gate_controller.set_physics_process(false)


func _is_gate_open(gate_name: String) -> bool:
	var gate: StaticBody2D = _scene.get_node(
		"TutorialCourse/Gates/" + gate_name) as StaticBody2D
	var collision: CollisionShape2D = gate.get_node(
		"CollisionShape2D") as CollisionShape2D
	return collision.disabled and not gate.get_node("GateLabel").visible
