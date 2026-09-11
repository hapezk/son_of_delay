extends SceneTree

## 一次真实伤害在恢复自然延迟后，不得被同一份失效历史再次判定为新闪回。
## --headless --path program --script res://test/damage_flashback_regression_test.gd
var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await physics_frame
	await physics_frame

	var group: DelayedActorGroup = scene.get_node("Actors/BodyGroup") as DelayedActorGroup
	var player: BaseActor = group.body
	var damage_source: Node = scene.get_node("Enemies/MeleeEnemyA")
	# 隔离后续敌人攻击，只观察首次受伤引起的恢复流程。
	for enemy: Node in scene.get_node("Enemies").get_children():
		enemy.set("attack_enabled", false)
		enemy.set("damage_enabled", false)

	var health_before: float = float(player.get("current_health"))
	var accepted: bool = bool(player.call(
		"receive_hit", 20.0, damage_source, 1, Vector2.LEFT))
	var divergence_after_hit: int = group.divergence_count
	_check(accepted, "The initial damage must be accepted")
	_check(divergence_after_hit == 1,
		"One accepted hit must start exactly one flashback")

	# 覆盖 10 帧闪回、自然延迟重建和随后完整的一秒回放窗口。
	var retrigger_frame: int = -1
	for frame_index: int in range(240):
		await physics_frame
		if group.divergence_count > divergence_after_hit:
			retrigger_frame = frame_index
			break
	_check(is_equal_approx(float(player.get("current_health")), health_before - 20.0),
		"The isolated hit must remove health exactly once")
	_check(group.divergence_count == divergence_after_hit,
		"Restoring natural delay must not retrigger flashback from stale history; frame=%d count=%d reason=%s body=%s expected=%s position_error=%.3f velocity_error=%.3f" % [
			retrigger_frame,
			group.divergence_count,
			group.last_divergence_reason,
			group.last_divergence_body_position,
			group.last_divergence_expected_position,
			group.last_divergence_position_error,
			group.last_divergence_velocity_error,
		])

	if _failures.is_empty():
		print("DAMAGE_FLASHBACK_REGRESSION_TEST_PASS")
	else:
		for failure: String in _failures:
			push_error("DAMAGE_FLASHBACK_REGRESSION_TEST_FAIL: " + failure)
	root.remove_child(scene)
	scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)
