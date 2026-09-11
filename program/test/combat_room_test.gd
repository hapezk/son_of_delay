extends SceneTree

## 基础敌人 AI 与战斗房间闭环：
## --headless --path program --script res://test/combat_room_test.gd
var _scene: Node
var _controller: Node
var _group: DelayedActorGroup
var _player: BaseActor
var _enemy_left: CharacterBody2D
var _enemy_right: CharacterBody2D
var _enemy_ranged: CharacterBody2D
var _authority: WorldTimeAuthority
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
	_controller = _scene.get_node("CombatRoomController")
	_group = _scene.get_node("Actors/BodyGroup") as DelayedActorGroup
	_player = _group.body
	_enemy_left = _scene.get_node("Enemies/MeleeEnemyA") as CharacterBody2D
	_enemy_right = _scene.get_node("Enemies/MeleeEnemyB") as CharacterBody2D
	_enemy_ranged = _scene.get_node("Enemies/RangedEnemyA") as CharacterBody2D
	_authority = _scene.get_node("WorldTimeAuthority") as WorldTimeAuthority
	_authority.combat_tuning = _authority.get_combat_tuning().duplicate() as CombatTuning
	_authority.combat_tuning.hit_stop_enabled = false
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	for enemy: Node in [_enemy_left, _enemy_right, _enemy_ranged]:
		enemy.set_physics_process(false)
	for delay_controller: Node in get_nodes_in_group("enemy_delay_controller"):
		delay_controller.set_physics_process(false)
	await physics_frame
	_test_player_stats_panel_layout()
	await _test_thinking_time_input()
	_test_enemy_state_flow()
	await _test_room_victory_and_restart()
	_test_room_defeat_and_auto_restart()
	if _failures.is_empty():
		print("COMBAT_ROOM_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("COMBAT_ROOM_TEST_FAIL: " + failure)
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)


func _test_player_stats_panel_layout() -> void:
	var panel: Control = _scene.get_node("CombatHelp/PlayerStatsPanel") as Control
	var controls: Label = _scene.get_node("CombatHelp/Controls") as Label
	var wave_status: Label = _scene.get_node("CombatHelp/WaveStatus") as Label
	var health_label: Label = panel.get_node("Margin/VBox/HealthLabel") as Label
	var player_delay_label: Label = panel.get_node(
		"Margin/VBox/PlayerDelayLabel") as Label
	var budget_label: Label = panel.get_node("Margin/VBox/DelayBudgetLabel") as Label
	var energy_label: Label = panel.get_node("Margin/VBox/DelayEnergyLabel") as Label
	_check(health_label.text == "生命  100 / 100"
		and player_delay_label.text == "玩家延迟  1.00s / 自然延迟 1.00s"
		and budget_label.text == "延迟负载  0.00 / 1.00s"
		and energy_label.text == "时滞能量  1.00 / 1.00",
		"Compact player panel must show health and the three delay resources")
	_check(panel.get_node_or_null("Margin/VBox/StatsLabel") == null
		and panel.position.is_equal_approx(Vector2(20.0, 16.0)),
		"Removed combat-stat text must stay absent and the panel must remain top-left")
	_check(not panel.get_global_rect().intersects(controls.get_global_rect())
		and not panel.get_global_rect().intersects(wave_status.get_global_rect())
		and not controls.get_global_rect().intersects(wave_status.get_global_rect()),
		"Player panel, control hints and wave status must occupy separate HUD regions")
	_check(panel.size.x >= panel.get_combined_minimum_size().x
		and panel.size.y >= panel.get_combined_minimum_size().y
		and controls.size.x >= controls.get_combined_minimum_size().x
		and controls.size.y >= controls.get_combined_minimum_size().y,
		"HUD rectangles must be large enough to avoid clipping their text")
	_player.set("current_health", 75.0)
	panel.call("_process", 0.0)
	_check(health_label.text == "生命  75 / 100"
		and is_equal_approx((panel.get_node("Margin/VBox/HealthBar") as ProgressBar).value, 75.0),
		"Player panel must refresh its health text and bar from the authority body")
	_player.set("current_health", float(_player.get("max_health")))
	panel.call("_process", 0.0)
	print("PASS: player attributes and main HUD text use non-overlapping regions")


func _test_thinking_time_input() -> void:
	var press: InputEventKey = InputEventKey.new()
	press.keycode = KEY_SPACE
	press.physical_keycode = KEY_SPACE
	press.pressed = true
	root.push_input(press, true)
	_check(_authority.is_entering_thinking_time() and not paused,
		"Space input must begin the slowdown before the SceneTree is paused")
	await _wait_for_thinking_pause()
	_check(_authority.is_in_thinking_time() and paused,
		"Thinking entry must pause only after the slowdown finishes")
	_check(is_equal_approx(Engine.time_scale, 1.0)
		and Engine.physics_ticks_per_second == WorldTimeAuthority.BASE_PHYSICS_TPS,
		"Paused prediction must restore the fixed 1x / 100 TPS simulation baseline")
	_check(not _player.can_process(),
		"Player must inherit pausable mode instead of continuing below an always-processing Main root")
	var release: InputEventKey = press.duplicate() as InputEventKey
	release.pressed = false
	root.push_input(release, true)
	root.push_input(press, true)
	var exit_started_usec: int = Time.get_ticks_usec()
	while _authority.is_in_thinking_time() \
			and Time.get_ticks_usec() - exit_started_usec < 1_000_000:
		await process_frame
	_check(not _authority.is_in_thinking_time() and not paused,
		"A second Space input must leave thinking time and resume gameplay")
	print("PASS: real Space input enters and exits thinking time")


func _wait_for_thinking_pause() -> void:
	var started_usec: int = Time.get_ticks_usec()
	while not _authority.is_in_thinking_time() \
			and Time.get_ticks_usec() - started_usec < 1_000_000:
		await process_frame


func _test_enemy_state_flow() -> void:
	_group.respawn_player()
	_player.call("reset_for_respawn", Vector2(100.0, 625.0))
	_enemy_left.call("reset_combat", true)
	_enemy_left.global_position = Vector2(360.0, 649.0)
	_enemy_left.set("attack_enabled", true)
	_enemy_left.call("_physics_process", 0.01)
	_check(int(_enemy_left.get("attack_phase")) == 5,
		"Enemy inside detection range but outside attack range must enter chase")
	var start_x: float = _enemy_left.global_position.x
	_enemy_left.call("_physics_process", 0.10)
	_check(_enemy_left.global_position.x < start_x and _enemy_left.velocity.x < 0.0,
		"Chasing enemy must accelerate horizontally toward the real player")

	_player.global_position = Vector2(_enemy_left.global_position.x - 70.0, 625.0)
	_enemy_left.call("_physics_process", 0.01)
	_check(int(_enemy_left.get("attack_phase")) == 1
		and _enemy_left.get_node("AttackVisual").visible,
		"Enemy reaching stop distance must lock facing and begin telegraphed windup")
	_enemy_left.call("receive_hit", 10.0, _player, 1, Vector2.RIGHT)
	_check(int(_enemy_left.get("attack_phase")) == 6
		and _enemy_left.velocity.x > 0.0 and _enemy_left.velocity.y < 0.0,
		"Taking nonlethal damage must interrupt attack and enter directional hurt knockback")
	_check(not _enemy_left.get_node("AttackVisual").visible,
		"Hurt interruption must immediately hide the old attack hitbox warning")
	for frame: int in range(20):
		_enemy_left.call("_physics_process", 0.01)
	_check(int(_enemy_left.get("attack_phase")) in [0, 1, 5],
		"Enemy must leave hurt and resume idle, chase or a new valid windup after the timer")
	print("PASS: enemy idle, chase, attack windup and hurt interruption")


func _test_room_victory_and_restart() -> void:
	_group.respawn_player()
	var enemy_root: Node = _scene.get_node("Enemies")
	var enemies: Array[Node] = []
	var spawn_positions: Array[Vector2] = []
	for child: Node in enemy_root.get_children():
		if child.has_method("is_defeated"):
			enemies.append(child)
			spawn_positions.append((child as Node2D).global_position)
	for enemy: Node in enemies:
		enemy.call("receive_hit", 1000.0, _player, 3, Vector2.RIGHT)
	_check(enemies.size() == 7 and int(_controller.get("room_state")) == 0,
		"Clearing all seven enemies must unlock the finish without ending the game early")
	_check((_scene.get_node("FinishGoal/Status") as Label).text.contains("终点已开放"),
		"Clearing the room must visibly unlock the finish gate")
	_controller.call("_on_finish_body_entered", _player)
	var result_layer: CanvasLayer = _scene.get_node("CombatResult") as CanvasLayer
	var restart_button: Button = _scene.get_node("CombatResult/Backdrop/RestartButton") as Button
	_check(int(_controller.get("room_state")) == 1 and result_layer.visible and restart_button.visible,
		"Entering the unlocked finish must show completion with a restart control")
	_check((result_layer.get_node("Backdrop/ResultTitle") as Label).text == "游戏完成",
		"Finish overlay must clearly identify full game completion")
	await process_frame
	_check(paused and _authority.is_externally_paused(&"combat_victory"),
		"Victory must pause gameplay through the shared pause authority")
	_controller.call("restart_round")
	_check(int(_controller.get("room_state")) == 0 and not result_layer.visible and not paused,
		"Victory restart must return the room to playing state")
	var all_revived: bool = true
	var all_at_spawn: bool = true
	for enemy_index: int in range(enemies.size()):
		var enemy: Node = enemies[enemy_index]
		all_revived = all_revived and not bool(enemy.call("is_defeated")) \
			and is_equal_approx(float(enemy.get("current_health")), float(enemy.get("max_health")))
		all_at_spawn = all_at_spawn and (enemy as Node2D).global_position.is_equal_approx(
			spawn_positions[enemy_index])
	_check(all_revived, "Restart must revive every enemy at full health")
	_check(all_at_spawn, "Restart must return every enemy to its authored spawn position")
	print("PASS: finish-gated completion, result overlay and manual restart")


func _test_room_defeat_and_auto_restart() -> void:
	_player.set("current_health", 20.0)
	_player.call("_update_health_visual")
	_player.call("receive_hit", 20.0, _enemy_left, 1, Vector2.LEFT)
	var result_layer: CanvasLayer = _scene.get_node("CombatResult") as CanvasLayer
	var restart_button: Button = _scene.get_node("CombatResult/Backdrop/RestartButton") as Button
	_check(int(_controller.get("room_state")) == 2 and result_layer.visible and not restart_button.visible,
		"Player death must show defeat while the death system prepares automatic restart")
	_check((result_layer.get_node("Backdrop/ResultTitle") as Label).text == "战败",
		"Defeat overlay must clearly identify the result")
	# 死亡倒计时的逐帧行为已由 jump_health_dummy_test 覆盖，这里直接调用其最终入口。
	_group.respawn_player()
	_check(int(_controller.get("room_state")) == 0 and not result_layer.visible
		and bool(_player.call("is_alive")),
		"Player respawn signal must reopen a clean playable round")
	print("PASS: room defeat and automatic-respawn handoff")
