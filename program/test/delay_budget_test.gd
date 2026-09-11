extends SceneTree

## 延迟资源纵切：自然延迟、负载、一次性能量、顺序部分结算和动作取消退款。
## --headless --path program --script res://test/delay_budget_test.gd
var _scene: Node
var _group: DelayedActorGroup
var _enemy_a: EnemyDelayController
var _enemy_b: EnemyDelayController
var _authority: WorldTimeAuthority
var _budget: DelayBudgetManager
var _panel: PlayerStatsPanel
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _run() -> void:
	var progression: Node = root.get_node_or_null("DelayProgression")
	if progression != null:
		progression.call("reset_progression")
	_scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(_scene)
	_group = _scene.get_node("Actors/BodyGroup") as DelayedActorGroup
	_enemy_a = _scene.get_node(
		"Enemies/MeleeEnemyA/EnemyDelayController") as EnemyDelayController
	_enemy_b = _scene.get_node(
		"Enemies/MeleeEnemyB/EnemyDelayController") as EnemyDelayController
	_authority = _scene.get_node("WorldTimeAuthority") as WorldTimeAuthority
	_budget = _scene.get_node("DelayBudgetManager") as DelayBudgetManager
	_panel = _scene.get_node("CombatHelp/PlayerStatsPanel") as PlayerStatsPanel
	_authority.thinking_entry_duration = 0.0
	_disable_automatic_physics()
	await process_frame

	_check(int(_budget.get_registered_controller_count()) == 13,
		"Budget manager must discover the player, seven enemies and five environment controllers")
	_check(is_equal_approx(_group.natural_delay_time, 1.0)
		and is_equal_approx(_group.delay_time, 1.0)
		and is_zero_approx(_budget.get_used_delay()),
		"The player's built-in one-second natural delay must consume no load")
	_check(is_equal_approx(_budget.total_capacity, 1.0)
		and is_equal_approx(_budget.current_energy, 1.0),
		"A new run must start with one second of load capacity and one full energy")
	_check(not _enemy_a.request_delay_change(0.5),
		"World targets must still reject adjustments outside thinking time")

	await _test_player_shortcut_scope()
	await _test_self_delay_tradeoff()
	await _test_ordered_partial_settlement()
	await _test_player_negative_delay_refunds()
	await _test_enemy_action_acceleration()
	_test_hud()

	if _failures.is_empty():
		print("DELAY_BUDGET_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("DELAY_BUDGET_TEST_FAIL: " + failure)
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)


func _test_player_shortcut_scope() -> void:
	# 非思考时间 Q/E 直接作用于玩家，并由当前容量把极值请求裁成可支付结果。
	_check(_group.request_self_delay_shortcut(KEY_Q)
		and is_zero_approx(_group.get_requested_delay()),
		"Outside thinking time Q must request the player's maximum negative-direction load")
	_group.clear_pending_delay_request()
	_budget.set_current_energy_for_test(1.0)
	_check(_group.request_self_delay_shortcut(KEY_E)
		and is_equal_approx(_group.get_requested_delay(), 2.0),
		"Outside thinking time E must request the player's maximum positive-direction load")
	_group.clear_pending_delay_request()
	_budget.set_current_energy_for_test(1.0)

	# 思考时间里 AttackInputBuffer 不得抢走 Q/E；它们应继续传给鼠标悬停目标。
	_authority.enter_thinking_time()
	_check(not _group.request_self_delay_shortcut(KEY_Q)
		and not _group.request_self_delay_shortcut(KEY_E)
		and is_equal_approx(_group.get_requested_delay(), _group.natural_delay_time),
		"Thinking-time Q/E must not bypass mouse-target selection to modify the player")
	var player_input: Node = _group.get_adjustment_input()
	_check(is_zero_approx(float(player_input.call("shortcut_delay_for_key", KEY_Q)))
		and is_equal_approx(float(player_input.call("shortcut_delay_for_key", KEY_E)), 3.0),
		"Hovered player Q/E must expose its allowed negative and positive directional limits")
	_finish_thinking_time()


func _test_self_delay_tradeoff() -> void:
	_authority.enter_thinking_time()
	_check(_group.request_delay_change(0.0)
		and is_equal_approx(_group.get_requested_delay(), 0.0)
		and is_equal_approx(_budget.get_projected_used_delay(), 1.0)
		and is_equal_approx(_budget.current_energy, 1.0),
		"Thinking time must preview self-delay load without spending energy early")
	_finish_thinking_time()
	_group.call("_physics_process", 0.01)
	_check(is_zero_approx(_group.delay_time)
		and is_equal_approx(_budget.get_used_delay(), 1.0)
		and is_zero_approx(_budget.current_energy),
		"Canceling natural delay must spend one energy and occupy the initial load slot")

	_budget.call("_process", 0.25)
	_check(is_equal_approx(_budget.current_energy, 0.25),
		"Exported regeneration must restore energy from logical delta")
	_authority.enter_thinking_time()
	_budget.call("_process", 1.0)
	_check(is_equal_approx(_budget.current_energy, 0.25),
		"Energy must not regenerate while thinking time pauses the world")
	_check(_group.request_delay_change(_group.natural_delay_time),
		"Returning to natural delay must remain available with an empty energy bar")
	_finish_thinking_time()
	_group.call("_physics_process", 0.01)
	_check(is_equal_approx(_group.delay_time, 1.0)
		and is_zero_approx(_budget.get_used_delay())
		and is_equal_approx(_budget.current_energy, 0.25),
		"Returning to the natural state must release load for free without refunding energy")


func _test_ordered_partial_settlement() -> void:
	_budget.set_current_energy_for_test(0.6)
	_authority.enter_thinking_time()
	_check(_enemy_a.request_delay_change(1.0) and _enemy_b.request_delay_change(1.0),
		"Thinking time must accept provisional requests even when their total is too large")
	_finish_thinking_time()
	_check(is_equal_approx(_enemy_a.delay_time, 0.6)
		and is_zero_approx(_enemy_b.delay_time)
		and is_zero_approx(_budget.current_energy)
		and is_equal_approx(_budget.get_used_delay(), 0.6),
		"The first selected target must receive the available partial allocation")

	# 免费释放统一先结算，所以后选目标可以立即使用腾出的完整容量。
	_budget.set_current_energy_for_test(1.0)
	_authority.enter_thinking_time()
	_check(_enemy_b.request_delay_change(1.0) and _enemy_a.request_delay_change(0.0),
		"A release and a new allocation may be queued in either visual order")
	_finish_thinking_time()
	_check(is_zero_approx(_enemy_a.delay_time)
		and is_equal_approx(_enemy_b.delay_time, 1.0)
		and is_equal_approx(_budget.get_used_delay(), 1.0)
		and is_zero_approx(_budget.current_energy),
		"Free releases must settle before paid allocations while paid targets keep selection order")

	# 恢复所有普通目标，为动作负延迟腾出负载。
	_authority.enter_thinking_time()
	_enemy_b.request_delay_change(0.0)
	_finish_thinking_time()


func _test_player_negative_delay_refunds() -> void:
	_budget.set_current_energy_for_test(1.0)
	var charging_player: BaseActor = _group.preview_body
	var aim: Vector2 = charging_player.get_global_transform_with_canvas() * Vector2(120.0, 0.0)
	charging_player.call("toggle_charge_mode", aim)
	var charge_before: float = float(charging_player.call("get_charge_elapsed_seconds"))
	var player_input: Node = _group.get_adjustment_input()
	_check(is_equal_approx(float(player_input.call("shortcut_delay_for_key", KEY_1)), 1.0)
		and is_zero_approx(float(player_input.call("shortcut_delay_for_key", KEY_Q))),
		"Charging must not turn numeric presets negative while committed delay is positive")
	_authority.enter_thinking_time()
	_check(not _group.request_delay_change(-1.0),
		"A charging player with committed positive delay must reject action acceleration")
	_finish_thinking_time()
	_check(is_equal_approx(_group.delay_time, _group.natural_delay_time)
		and is_zero_approx(_budget.get_used_delay())
		and is_equal_approx(_budget.current_energy, 1.0)
		and is_equal_approx(
			float(charging_player.call("get_charge_elapsed_seconds")), charge_before),
		"Reducing positive delay must never be converted into free charge acceleration")
	charging_player.call("toggle_charge_mode", aim)

	# 初始 1 秒负载只能抵消 1 秒自然延迟；归零后没有剩余容量实现负延迟。
	_authority.enter_thinking_time()
	_group.request_delay_change(0.0)
	_finish_thinking_time()
	_group.call("_physics_process", 0.01)
	_budget.set_current_energy_for_test(1.0)
	var zero_delay_player: BaseActor = _group.body
	zero_delay_player.call("toggle_charge_mode", aim)
	charge_before = float(zero_delay_player.call("get_charge_elapsed_seconds"))
	_authority.enter_thinking_time()
	_check(not _group.request_delay_change(-1.0)
		and is_zero_approx(float(
			_group.get_adjustment_input().call("shortcut_delay_for_key", KEY_Q))),
		"No-spare-load state must reject negative requests and keep Q at zero")
	_finish_thinking_time()
	_check(is_zero_approx(_group.delay_time)
		and is_equal_approx(_budget.get_used_delay(), 1.0)
		and is_equal_approx(_budget.current_energy, 1.0)
		and is_equal_approx(
			float(zero_delay_player.call("get_charge_elapsed_seconds")), charge_before),
		"Initial load capacity must be fully consumed by natural-delay cancellation")
	zero_delay_player.call("toggle_charge_mode", aim)

	# 升级到 2 秒负载后，归零占 1 秒，剩余 1 秒才可以用于动作负延迟。
	_budget.total_capacity = 2.0
	_budget.set_current_energy_for_test(1.0)
	zero_delay_player.call("toggle_charge_mode", aim)
	charge_before = float(zero_delay_player.call("get_charge_elapsed_seconds"))
	_authority.enter_thinking_time()
	_check(_group.request_delay_change(-1.0),
		"A zero-delay charging player with spare load may request action acceleration")
	_finish_thinking_time()
	_check(is_equal_approx(_group.get_committed_delay_setting(), -1.0)
		and is_equal_approx(_budget.get_used_delay(), 2.0)
		and is_zero_approx(_budget.current_energy)
		and float(_group.body.call("get_charge_elapsed_seconds")) >= charge_before + 0.99,
		"Negative delay must spend only spare load and fast-forward an active charge")
	_group.body.call("toggle_charge_mode", aim)
	_group.call("_physics_process", 0.01)
	_check(is_equal_approx(_budget.current_energy, 0.5)
		and is_equal_approx(_budget.get_used_delay(), 1.0)
		and is_zero_approx(_group.delay_time),
		"Manual cancellation must return action load, refund half energy and preserve zero delay")

	_budget.set_current_energy_for_test(1.0)
	_group.body.call("toggle_charge_mode", aim)
	_authority.enter_thinking_time()
	_group.request_delay_change(-1.0)
	_finish_thinking_time()
	_group.body.call("begin_attack_input", aim)
	_group.body.tick_physics(0, 0.01)
	_group.call("_physics_process", 0.01)
	_check(is_zero_approx(_budget.current_energy)
		and is_equal_approx(_budget.get_used_delay(), 1.0),
		"Successful charged release must return only action load without refunding energy")

	_budget.set_current_energy_for_test(1.0)
	_group.body.call("toggle_charge_mode", aim)
	_authority.enter_thinking_time()
	_group.request_delay_change(-1.0)
	_finish_thinking_time()
	_group.body.call("receive_hit", 1.0, null, 1, Vector2.LEFT)
	_group.call("_physics_process", 0.01)
	_check(is_equal_approx(_budget.current_energy, 0.5)
		and is_equal_approx(_budget.get_used_delay(), 1.0),
		"Damage interruption must refund half action energy while preserving regular load")

	# 后续敌人用例仍以默认资源和玩家自然延迟为起点。
	_group.set_delay_time_immediate(_group.natural_delay_time)
	_group.clear_pending_delay_request()
	_budget.total_capacity = 1.0


func _test_enemy_action_acceleration() -> void:
	var enemy: MeleeEnemy = _enemy_a.body as MeleeEnemy
	_budget.set_current_energy_for_test(1.0)
	_enemy_a.set_delay_time_immediate(0.5)
	enemy.call("_begin_attack_facing", -1, 1)
	_authority.enter_thinking_time()
	_check(not _enemy_a.request_delay_change(-0.25),
		"An active enemy windup must still reject acceleration while positive delay remains")
	_finish_thinking_time()
	_check(is_equal_approx(_enemy_a.delay_time, 0.5)
		and is_equal_approx(_budget.current_energy, 1.0),
		"Rejected acceleration must not erase positive delay or consume energy")
	_enemy_a.set_delay_time_immediate(0.0)
	enemy.call("_begin_attack_facing", -1, 1)
	_authority.enter_thinking_time()
	_check(_enemy_a.request_delay_change(-0.25),
		"An enemy windup must expose the shared one-shot negative-delay rule")
	_finish_thinking_time()
	_check(is_equal_approx(_enemy_a.get_committed_delay_setting(), -0.25)
		and is_equal_approx(_budget.get_used_delay(), 0.25)
		and is_equal_approx(_budget.current_energy, 0.75),
		"Enemy acceleration must spend energy once and hold load until the windup resolves")
	enemy.simulate_delay_command({}, 0.4)
	_check(is_zero_approx(_enemy_a.delay_time)
		and is_zero_approx(_budget.get_used_delay())
		and is_equal_approx(_budget.current_energy, 0.75),
		"A successful enemy action must return load without energy refund")

	_budget.set_current_energy_for_test(1.0)
	enemy.call("_begin_attack_facing", -1, 2)
	_authority.enter_thinking_time()
	_enemy_a.request_delay_change(-0.2)
	_finish_thinking_time()
	enemy.call("receive_hit", 1.0, _group.body, 1, Vector2.RIGHT)
	_check(is_zero_approx(_budget.get_used_delay())
		and is_equal_approx(_budget.current_energy, 0.9),
		"Interrupting an accelerated enemy windup must refund half its actual energy cost")

	_group.respawn_player()
	_check(is_equal_approx(_budget.current_energy, _budget.maximum_energy)
		and is_zero_approx(_budget.get_used_delay())
		and is_equal_approx(_group.delay_time, _group.natural_delay_time),
		"Player death restart must refill energy, clear world load and restore natural delay")


func _test_hud() -> void:
	_panel.call("_process", 0.0)
	var load_label: Label = _panel.get_node("Margin/VBox/DelayBudgetLabel") as Label
	var energy_label: Label = _panel.get_node("Margin/VBox/DelayEnergyLabel") as Label
	_check(load_label.text.begins_with("延迟负载")
		and energy_label.text.begins_with("时滞能量"),
		"HUD must show independent delay-load and delay-energy readouts")


func _finish_thinking_time() -> void:
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	_authority.call("_finish_pending_resume")


func _disable_automatic_physics() -> void:
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	for enemy: Node in _scene.get_node("Enemies").get_children():
		enemy.set_physics_process(false)
	for controller: Node in get_nodes_in_group("command_replay_delay_controllers"):
		controller.set_physics_process(false)
