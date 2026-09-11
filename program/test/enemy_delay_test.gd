extends SceneTree

## 敌人延迟纵切：共享时间线、输入回放、可穿身碰撞、软重预测与可靠攻击事件。
## --headless --path program --script res://test/enemy_delay_test.gd
var _scene: Node
var _group: DelayedActorGroup
var _player: BaseActor
var _enemy: CharacterBody2D
var _other_enemy: CharacterBody2D
var _enemy_delay: Node
var _authority: WorldTimeAuthority
var _budget: DelayBudgetManager
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
	_enemy = _scene.get_node("Enemies/MeleeEnemyA") as CharacterBody2D
	_other_enemy = _scene.get_node("Enemies/MeleeEnemyB") as CharacterBody2D
	_enemy_delay = _enemy.get_node("EnemyDelayController")
	_authority = _scene.get_node("WorldTimeAuthority") as WorldTimeAuthority
	_budget = _scene.get_node("DelayBudgetManager") as DelayBudgetManager
	# 本文件验证回放稳定性而非资源额度；提供充足额度，资源规则由 delay_budget_test 覆盖。
	_budget.total_capacity = 3.0
	_budget.maximum_energy = 3.0
	_budget.set_current_energy_for_test(3.0)
	# 本测试聚焦延迟回放；思考时间的 0.2 秒入场由 combat_room_test 独立覆盖。
	_authority.thinking_entry_duration = 0.0
	_authority.combat_tuning = _authority.get_combat_tuning().duplicate() as CombatTuning
	_authority.combat_tuning.hit_stop_enabled = false
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	_other_enemy.set_physics_process(false)
	# 等待子控制器的 deferred 初始化完成，再改为测试脚本逐帧驱动。
	await process_frame
	for delay_controller: Node in get_nodes_in_group("enemy_delay_controller"):
		delay_controller.set_physics_process(false)

	_test_actor_bodies_only_collide_with_terrain()
	_test_shared_adjustment_logic()
	await _test_thinking_time_gate_and_multi_registration()
	await _test_moving_delay_entry_uses_shared_waiting()
	await _test_delayed_chase_replay()
	_test_player_and_enemy_share_command_buffer()
	_test_shared_delay_base_and_ui()
	await _test_positive_delay_transition_preserves_history()
	_test_ai_frame_records_resolved_intent()
	await _test_preview_body_overlap_keeps_delay()
	await _test_replay_mismatch_reforecasts_without_reset()
	await _test_preview_cannot_damage()
	await _test_damage_preserves_delay_and_reforecasts()
	_test_hurt_buffers_attack_action()
	await _test_delayed_attack_reexecutes_command()

	if _failures.is_empty():
		print("ENEMY_DELAY_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("ENEMY_DELAY_TEST_FAIL: " + failure)
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)


func _test_actor_bodies_only_collide_with_terrain() -> void:
	var preview: CharacterBody2D = _enemy_delay.call("get_preview_body") as CharacterBody2D
	var predictor: CharacterBody2D = _enemy_delay.get("predictor_body") as CharacterBody2D
	_check(_player.collision_mask == 2 and _enemy.collision_mask == 2
		and _other_enemy.collision_mask == 2,
		"Player and real enemies must only collide with terrain, never block one another "
		+ "(player=%d delayed_enemy=%d other_enemy=%d)" % [
			_player.collision_mask, _enemy.collision_mask, _other_enemy.collision_mask,
		])
	_check(preview != null and predictor != null
		and preview.collision_mask == 2 and predictor.collision_mask == 2,
		"Enemy preview and predictor must use the same terrain-only collision mask")
	print("PASS: actor bodies can pass through one another while terrain stays solid")


func _test_shared_adjustment_logic() -> void:
	var player_ui: Node = _player.get_node_or_null("DelayControlUi")
	var player_input: Node
	if player_ui != null:
		player_input = player_ui.call("get_adjustment_input") as Node
	var enemy_input: Node = _enemy_delay.call("get_adjustment_input") as Node
	_check(player_input != null and enemy_input != null,
		"Player and enemy must both own a configured shared delay input component")
	if player_input == null or enemy_input == null:
		return
	_check(player_input.get_script() == enemy_input.get_script(),
		"Player and enemy delay input must execute the same implementation")
	_check(player_input.call("get_tuning") == enemy_input.call("get_tuning"),
		"Player and enemy delay input must read the same tuning resource")
	_check(bool(player_input.get("shortcuts_require_thinking_time"))
		and bool(enemy_input.get("shortcuts_require_thinking_time")),
		"Player and enemy preset shortcuts must both require thinking time")

	player_input.call("reset_scroll_state")
	enemy_input.call("reset_scroll_state")
	var player_value: float = 1.0
	var enemy_value: float = 1.0
	for now_msec: int in [1000, 1050, 1100, 1150, 1200, 1250, 1300]:
		player_value = float(player_input.call("calculate_scroll_target", player_value, 1, now_msec))
		enemy_value = float(enemy_input.call("calculate_scroll_target", enemy_value, 1, now_msec))
		_check(is_equal_approx(player_value, enemy_value),
			"Shared rapid-scroll sequence must produce the same player and enemy value")
	_check(is_equal_approx(player_value, 1.2)
		and is_equal_approx(float(player_input.call("get_active_step_seconds")), 0.1)
		and is_equal_approx(float(enemy_input.call("get_active_step_seconds")), 0.1),
		"Both targets must accelerate 0.01 -> 0.1 and snap to the same tenth-second step")
	player_input.call("reset_scroll_step_if_idle", 1600)
	enemy_input.call("reset_scroll_step_if_idle", 1600)
	_check(is_equal_approx(float(player_input.call("get_active_step_seconds")), 0.01)
		and is_equal_approx(float(enemy_input.call("get_active_step_seconds")), 0.01),
		"Both targets must restore 0.01-second precision after the same idle timeout")
	_check(is_equal_approx(float(player_input.call("quick_delay_for_key", KEY_3)), 3.0)
		and is_equal_approx(float(enemy_input.call("quick_delay_for_key", KEY_R)), 0.0)
		and is_zero_approx(float(player_input.call("shortcut_delay_for_key", KEY_Q)))
		and is_equal_approx(float(enemy_input.call("shortcut_delay_for_key", KEY_E)), 3.0),
		"Preset, reset and target-aware Q/E keys must come from the common mapping")
	print("PASS: player and enemy share scroll acceleration, snapping and shortcut mapping")


func _test_thinking_time_gate_and_multi_registration() -> void:
	_check(not bool(_enemy_delay.call("request_delay_change", 1.0)),
		"Enemy delay requests outside thinking time must be rejected")
	var participants: Array = _authority.get("_thinking_prediction_participants") as Array
	_check(participants.size() >= 2,
		"World time authority must retain both player and enemy delay participants")
	_authority.enter_thinking_time()
	_check(bool(_enemy_delay.call("request_delay_change", 1.0)),
		"Enemy delay request must be accepted during thinking time")
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	while _authority.is_in_thinking_time():
		await process_frame
	_check(not _authority.is_in_thinking_time() and not paused,
		"Committing enemy delay must still resume the shared world")
	_check(is_equal_approx(float(_enemy_delay.get("delay_time")), 1.0),
		"The queued enemy delay must commit exactly when thinking time exits")
	_check(not bool(_enemy_delay.call("request_delay_change", 2.0)),
		"The same public API must reject a post-exit request")
	_check(_other_enemy.has_node("EnemyDelayController")
		and get_nodes_in_group("enemy_delay_controller").size() == 7,
		"Every authority enemy in the main combat room must own the shared delay adapter")
	print("PASS: enemy delay is thinking-time-only and coexists with player prediction")


func _test_delayed_chase_replay() -> void:
	_enemy.call("reset_combat", true)
	_player.call("reset_for_respawn", Vector2(100.0, 625.0))
	_enemy.global_position = Vector2(420.0, 649.0)
	await _commit_enemy_delay(1.0)
	var body_start_x: float = _enemy.global_position.x
	for frame: int in range(40):
		_enemy_delay.call("_physics_process", 0.01)
	var preview: CharacterBody2D = _enemy_delay.call("get_preview_body") as CharacterBody2D
	_check(is_equal_approx(_enemy.global_position.x, body_start_x),
		"Real enemy must wait while its one-second history is still filling")
	_check(preview.global_position.x < body_start_x,
		"Blue preview must run current AI and show the enemy chasing ahead")
	for frame: int in range(63):
		_enemy_delay.call("_physics_process", 0.01)
	_check(_enemy.global_position.x < body_start_x,
		"Real enemy must begin consuming the recorded chase after the configured delay")
	_check(is_equal_approx(float(_enemy_delay.get("delay_time")), 1.0),
		"Deterministic command replay must not invalidate itself as a snapshot mismatch")
	print("PASS: enemy preview runs ahead and real enemy replays later")


func _test_moving_delay_entry_uses_shared_waiting() -> void:
	_enemy.call("reset_combat", true)
	_player.call("reset_for_respawn", Vector2(100.0, 625.0))
	_enemy.global_position = Vector2(420.0, 649.0)
	await physics_frame
	_enemy_delay.set_physics_process(true)
	for frame: int in range(12):
		await physics_frame
	_enemy_delay.set_physics_process(false)
	var moving_speed: float = absf(_enemy.velocity.x)
	var position_after_warmup: Vector2 = _enemy.global_position
	_check(moving_speed > 0.0, "Moving-delay regression setup must give the enemy horizontal velocity")
	await _commit_enemy_delay(0.3)
	var preview: CharacterBody2D = _enemy_delay.call("get_preview_body") as CharacterBody2D
	var preview_after_commit: Vector2 = preview.global_position
	_check(preview.global_position.x < _enemy.global_position.x and is_zero_approx(preview.velocity.x),
		"Entering delay while moving must place the preview at the shared waiting-stop endpoint")
	_enemy_delay.set_physics_process(true)
	for frame: int in range(15):
		await physics_frame
	_check(is_zero_approx(_enemy.velocity.x),
		"The real enemy must use the same horizontal braking wait as the delayed player")
	var divergence_frame: int = -1
	for frame: int in range(25):
		await physics_frame
		if is_zero_approx(float(_enemy_delay.get("delay_time"))):
			divergence_frame = frame + 15
			break
	_enemy_delay.set_physics_process(false)
	_check(is_equal_approx(float(_enemy_delay.get("delay_time")), 0.3),
		"Moving delay entry must replay cleanly without a false divergence reset "
		+ "(reason=%s frame=%d warmup=%s preview_start=%s pos_error=%.3f vel_error=%.3f body=%s expected=%s)" % [
			str(_enemy_delay.get("last_divergence_reason")),
			divergence_frame, str(position_after_warmup), str(preview_after_commit),
			float(_enemy_delay.get("last_divergence_position_error")),
			float(_enemy_delay.get("last_divergence_velocity_error")),
			str(_enemy_delay.get("last_divergence_body_position")),
			str(_enemy_delay.get("last_divergence_expected_position")),
		])
	print("PASS: moving player and enemy delay entry share the same waiting semantics")


func _test_player_and_enemy_share_command_buffer() -> void:
	var player_buffer: RefCounted = _group.preview_system.get("_command_buffer") as RefCounted
	var enemy_buffer: RefCounted = _enemy_delay.get("_command_buffer") as RefCounted
	_check(player_buffer != null and enemy_buffer != null
		and player_buffer.get_script() == enemy_buffer.get_script(),
		"Player and enemy must use the same command record/consume implementation")
	var enemy_slots: Array[DelayFrame] = _enemy_delay.get("_slots") as Array[DelayFrame]
	var enemy_timeline: RefCounted = _enemy_delay.get("_timeline") as RefCounted
	var latest_index: int = int(enemy_timeline.get("write_head")) if enemy_timeline != null else -1
	var latest_frame: DelayFrame = enemy_slots[latest_index] if latest_index >= 0 else null
	_check(latest_frame != null and not latest_frame.command.is_empty(),
		"Enemy history must contain an AI command plus expected replay result")
	_check(latest_frame != null and not latest_frame.command.has("global_position")
		and not latest_frame.command.has("attack_phase"),
		"Enemy history must no longer be a state snapshot restored directly onto the body")
	print("PASS: player and enemy share command-frame buffering instead of snapshot playback")


## 玩家与敌人只保留适配策略差异；最小三体模型、帧信封和 UI 都来自公共基类。
func _test_shared_delay_base_and_ui() -> void:
	var player_ui: DelayControlUi = _player.get_node_or_null("DelayControlUi") as DelayControlUi
	var enemy_ui: DelayControlUi = _enemy.get_node_or_null("DelayControlUi") as DelayControlUi
	_check(_enemy is BaseActor and _enemy_delay is DelayControllerBase,
		"Delayable enemies must join the BaseActor and DelayControllerBase hierarchy")
	_check(player_ui != null and enemy_ui != null and player_ui.get_script() == enemy_ui.get_script(),
		"Player and enemy must reuse the same delay UI implementation")
	_check(_group.get_delay_ui_text() == "延迟\n%.2fs" % _group.get_requested_delay()
		and str(_enemy_delay.call("get_delay_ui_text"))
			== "延迟\n%.2fs" % float(_enemy_delay.call("get_requested_delay")),
		"Every delayable actor must use the same two-line Chinese delay label")
	_check(player_ui.position == _player.get_delay_ui_anchor_offset()
		and enemy_ui.position == (_enemy as BaseActor).get_delay_ui_anchor_offset()
		and enemy_ui.position == Vector2(0.0, -24.0),
		"Shared delay UI must ask each BaseActor for its visual center anchor")
	var player_frame: Recording = Recording.new(1.0, false, Vector2.ZERO, Vector2.ZERO)
	_check(player_frame is DelayFrame,
		"Player Recording and enemy frames must share the same minimal DelayFrame envelope")
	var enemy_timeline: DelayTimelineBuffer = _enemy_delay.get("_timeline") as DelayTimelineBuffer
	_check(_group.get_delay_buffer_capacity() == 301 and enemy_timeline.capacity == 301,
		"Three seconds at 100 TPS must allocate the same fixed 301-slot ring for every adapter")
	var original_max_delay: float = float(_enemy_delay.get("max_delay_time"))
	_enemy_delay.set("max_delay_time", 9.0)
	_check(is_equal_approx(float(_enemy_delay.call("get_effective_max_delay_time")), 3.0),
		"Changing a runtime limit must not read beyond the already allocated ring")
	_enemy_delay.set("max_delay_time", original_max_delay)
	var standalone_buffer: DelayCommandBuffer = DelayCommandBuffer.new()
	var standalone_slots: Array[DelayFrame] = []
	standalone_buffer.configure(3.0)
	standalone_buffer.prepare_storage(standalone_slots)
	for frame_index: int in range(standalone_buffer.timeline.capacity * 3 + 7):
		standalone_buffer.record(standalone_slots, DelayFrame.new({"index": frame_index}))
	_check(standalone_slots.size() == 301 and standalone_buffer.timeline.write_head == 6,
		"Long sessions must wrap and overwrite the same fixed storage instead of growing history")
	print("PASS: actors, controllers, frames and delay UI share the extracted base model")


## 预览与本体允许存在微小位置残差；越过攻击距离边界时也必须执行同一条已解析命令。
func _test_ai_frame_records_resolved_intent() -> void:
	_enemy.call("reset_combat", true)
	_player.call("reset_for_respawn", Vector2(100.0, 625.0))
	_enemy.global_position = Vector2(188.0, 649.0)
	_enemy.set("attack_phase", 5)
	var command: Dictionary = _enemy.call("capture_delay_command") as Dictionary
	_check(command.has("intent"),
		"Enemy delay frames must store a resolved AI intent instead of only the target position")
	# 1.5 像素仍在允许误差内，但足以从 88 像素攻击边界的一侧跨到另一侧。
	_enemy.global_position.x += 1.5
	_enemy.call("simulate_delay_command", command, 0.01)
	_check(int(_enemy.get("attack_phase")) == 1,
		"Replayed body must obey the preview's attack intent without re-evaluating its own distance")
	print("PASS: enemy replay uses resolved AI intent across a tolerated convergence offset")


func _test_preview_body_overlap_keeps_delay() -> void:
	_enemy.call("reset_combat", true)
	_player.call("reset_for_respawn", Vector2(100.0, 625.0))
	_enemy.global_position = Vector2(260.0, 649.0)
	# 此项只验证追赶与重合；关闭真实伤害，避免玩家击退改变目标位置。
	_enemy.set("damage_enabled", false)
	await physics_frame
	await _commit_enemy_delay(0.2)
	var preview: CharacterBody2D = _enemy_delay.call("get_preview_body") as CharacterBody2D
	var minimum_gap: float = INF
	_enemy_delay.set_physics_process(true)
	for frame: int in range(180):
		await physics_frame
		minimum_gap = minf(minimum_gap, _enemy.global_position.distance_to(preview.global_position))
		if is_zero_approx(float(_enemy_delay.get("delay_time"))):
			break
	_enemy_delay.set_physics_process(false)
	_enemy.set("damage_enabled", true)
	_check(minimum_gap <= 2.0,
		"Overlap regression must actually let the delayed body catch the moving preview")
	_check(is_equal_approx(float(_enemy_delay.get("delay_time")), 0.2),
		"Preview/body convergence must not be treated as replay divergence "
		+ "(gap=%.3f reason=%s pos_error=%.3f vel_error=%.3f)" % [
			minimum_gap, str(_enemy_delay.get("last_divergence_reason")),
			float(_enemy_delay.get("last_divergence_position_error")),
			float(_enemy_delay.get("last_divergence_velocity_error")),
		])
	print("PASS: moving preview can overlap the delayed body without clearing delay")


func _test_replay_mismatch_reforecasts_without_reset() -> void:
	_enemy.call("reset_combat", true)
	_player.call("reset_for_respawn", Vector2(100.0, 625.0))
	_enemy.global_position = Vector2(420.0, 649.0)
	await _commit_enemy_delay(0.2)
	for frame: int in range(25):
		_enemy_delay.call("_physics_process", 0.01)
	var timeline: RefCounted = _enemy_delay.get("_timeline") as RefCounted
	var read_head_before: int = int(timeline.get("read_head"))
	var write_head_before: int = int(timeline.get("write_head"))
	var reforecast_count_before: int = int(_enemy_delay.get("reforecast_count"))
	var mismatched_frame: DelayFrame = DelayFrame.new(
		{},
		_enemy.global_position + Vector2(32.0, 0.0),
		_enemy.velocity
	)
	var detected: bool = bool(_enemy_delay.call("_check_replay_divergence", mismatched_frame))
	_check(detected and StringName(_enemy_delay.get("last_divergence_reason")) == &"replay_mismatch",
		"Enemy replay mismatch must remain visible in diagnostics")
	_check(is_equal_approx(float(_enemy_delay.get("delay_time")), 0.2),
		"Enemy replay mismatch must never clear the player-assigned delay")
	_check(int(timeline.get("read_head")) == read_head_before
		and int(timeline.get("write_head")) == write_head_before,
		"Soft reforecast must preserve the command timeline cursors")
	_check(int(_enemy_delay.get("reforecast_count")) == reforecast_count_before + 1,
		"A replay mismatch must reforecast the remaining input window exactly once")
	print("PASS: enemy replay mismatch refreshes its estimate without resetting delay")


func _test_positive_delay_transition_preserves_history() -> void:
	var player_timeline: RefCounted = _group.preview_system.get("_timeline") as RefCounted
	var enemy_timeline: RefCounted = _enemy_delay.get("_timeline") as RefCounted
	_check(player_timeline != null and enemy_timeline != null
		and player_timeline.get_script() == enemy_timeline.get_script(),
		"Player and enemy must share the same delay timeline implementation")

	var preview: CharacterBody2D = _enemy_delay.call("get_preview_body") as CharacterBody2D
	var body_before_reduction: Vector2 = _enemy.global_position
	var preview_before_reduction: Vector2 = preview.global_position
	await _commit_enemy_delay(0.29)
	var predictor: CharacterBody2D = _enemy_delay.get("predictor_body") as CharacterBody2D
	_check(predictor != null and preview.global_position.is_equal_approx(predictor.global_position),
		"Reducing positive enemy delay must adopt the shared predictor's re-simulated endpoint")
	_enemy_delay.call("_physics_process", 0.01)
	_check(_enemy.global_position.distance_to(preview.global_position)
		< body_before_reduction.distance_to(preview_before_reduction),
		"Reducing enemy delay must consume nearer retained history immediately instead of refilling")

	var preview_before_increase: Vector2 = preview.global_position
	var read_head_before_increase: int = int(enemy_timeline.get("read_head"))
	var speed_before_increase: float = absf(_enemy.velocity.x)
	await _commit_enemy_delay(1.0)
	_check(preview.global_position.is_equal_approx(preview_before_increase),
		"Increasing positive enemy delay must also preserve the running preview")
	_enemy_delay.call("_physics_process", 0.01)
	_check(int(enemy_timeline.get("read_head")) == read_head_before_increase,
		"Increasing enemy delay must wait without consuming another command frame")
	_check(absf(_enemy.velocity.x) <= speed_before_increase,
		"Enemy waiting must decelerate horizontally without consuming an AI command")
	print("PASS: positive enemy delay changes preserve and reposition the shared timeline")


func _test_preview_cannot_damage() -> void:
	_enemy.call("reset_combat", true)
	_player.call("reset_for_respawn", Vector2(350.0, 625.0))
	_player.call("reset_health")
	# 玩家仍占用少量共享容量；2 秒足以覆盖本段 0.9 秒的纯预览窗口。
	await _commit_enemy_delay(2.0)
	var health_before: float = float(_player.get("current_health"))
	for frame: int in range(90):
		_enemy_delay.call("_physics_process", 0.01)
	var preview: CharacterBody2D = _enemy_delay.call("get_preview_body") as CharacterBody2D
	_check(is_equal_approx(float(_player.get("current_health")), health_before),
		"Preview attack during the initial delay window must not damage the player")
	_check(preview.collision_layer == 0 and not bool(preview.get("damage_enabled"))
		and not preview.is_in_group("player_respawn_reset"),
		"Enemy preview must stay outside damage, collision and round-reset authority")
	print("PASS: enemy preview is visual-only and cannot affect combat authority")


func _test_damage_preserves_delay_and_reforecasts() -> void:
	_enemy.call("reset_combat", true)
	_player.call("reset_for_respawn", Vector2(100.0, 625.0))
	_enemy.global_position = Vector2(420.0, 649.0)
	await _commit_enemy_delay(0.3)
	for frame: int in range(12):
		_enemy_delay.call("_physics_process", 0.01)
	var timeline: RefCounted = _enemy_delay.get("_timeline") as RefCounted
	var read_head_before: int = int(timeline.get("read_head"))
	var write_head_before: int = int(timeline.get("write_head"))
	var accepted: bool = bool(_enemy.call("receive_hit", 10.0, _player, 1, Vector2.RIGHT))
	_check(accepted and is_equal_approx(float(_enemy_delay.get("delay_time")), 0.3),
		"Immediate enemy damage and knockback must preserve its configured delay")
	_check(StringName(_enemy_delay.get("last_divergence_reason")) == &"body_damaged",
		"Damage-triggered reforecast must retain an explicit diagnostic reason")
	_check(int(timeline.get("read_head")) == read_head_before
		and int(timeline.get("write_head")) == write_head_before,
		"Damage reforecast must not discard or skip queued AI inputs")
	var preview: CharacterBody2D = _enemy_delay.call("get_preview_body") as CharacterBody2D
	_check(preview.visible and _enemy.velocity.x > 0.0,
		"Knockback must apply immediately while the refreshed enemy preview remains visible")
	for frame: int in range(20):
		_enemy_delay.call("_physics_process", 0.01)
	_check(int(_enemy.get("attack_phase")) != 6,
		"Enemy hurt time must keep advancing while delayed history is still filling")
	_check(is_equal_approx(float(_enemy_delay.get("delay_time")), 0.3),
		"Completing immediate hurt recovery must still preserve enemy delay")

	_enemy.call("receive_hit", 1000.0, _player, 3, Vector2.RIGHT)
	_check(is_zero_approx(float(_enemy_delay.get("delay_time")))
		and StringName(_enemy_delay.get("last_divergence_reason")) == &"body_defeated"
		and not preview.visible,
		"Defeat must clear the finished enemy lifecycle and hide its obsolete preview")
	print("PASS: damage reforecasts in place; only defeat clears enemy delay")


func _test_hurt_buffers_attack_action() -> void:
	_other_enemy.call("reset_combat", true)
	_other_enemy.global_position = Vector2(800.0, 649.0)
	_other_enemy.call("receive_hit", 1.0, _player, 1, Vector2.RIGHT)
	var attack_command: Dictionary = {
		"has_target": true,
		"intent": 3,
		"facing": -1,
		"attack_action_id": 7,
	}
	_other_enemy.call("simulate_delay_command", attack_command, 0.01)
	_check(int(_other_enemy.get("_pending_attack_action_id")) == 7
		and int(_other_enemy.get("attack_phase")) == 6,
		"An attack input arriving during hurt must be retained instead of consumed and lost")
	var hold_command: Dictionary = {"has_target": true, "intent": 0, "facing": -1}
	for frame: int in range(20):
		_other_enemy.call("simulate_delay_command", hold_command, 0.01)
	_check(int(_other_enemy.get("attack_phase")) == 1
		and int(_other_enemy.get("_attack_sequence_id")) == 7
		and int(_other_enemy.get("_pending_attack_action_id")) == 0,
		"The retained attack must begin exactly once as soon as hurt recovery ends")
	print("PASS: one-shot enemy attack input survives immediate hurt and knockback")


func _test_delayed_attack_reexecutes_command() -> void:
	_enemy.call("reset_combat", true)
	_player.call("reset_for_respawn", Vector2(350.0, 625.0))
	_player.call("reset_health")
	_enemy.global_position = Vector2(420.0, 649.0)
	# 让直接空间查询先同步测试脚本刚设置的碰撞体位置。
	await physics_frame
	await _commit_enemy_delay(0.2)
	var health_before: float = float(_player.get("current_health"))
	_enemy_delay.set_physics_process(true)
	for frame: int in range(100):
		await physics_frame
	_enemy_delay.set_physics_process(false)
	_check(float(_player.get("current_health")) < health_before,
		"The real enemy must execute the buffered attack command after its delay "
		+ "(health=%.1f phase=%d enemy=%s player=%s mask=%d layer=%d)" % [
			float(_player.get("current_health")), int(_enemy.get("attack_phase")),
			str(_enemy.global_position), str(_player.global_position),
			_enemy.collision_mask, _enemy.collision_layer,
		])
	_check(is_equal_approx(float(_enemy_delay.get("delay_time")), 0.2),
		"A deterministic delayed attack must not be mistaken for an enemy replay divergence")
	print("PASS: delayed enemy attack is re-simulated from the same buffered AI command")


func _commit_enemy_delay(value: float) -> void:
	_budget.set_current_energy_for_test(_budget.maximum_energy)
	_authority.enter_thinking_time()
	_enemy_delay.call("request_delay_change", value)
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	while _authority.is_in_thinking_time():
		await process_frame
