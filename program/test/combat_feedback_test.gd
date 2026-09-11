extends SceneTree

## 真实时间反馈回归：--headless --path program --script res://test/combat_feedback_test.gd
class PauseProbe:
	extends Node
	var frames: int = 0
	func _physics_process(_delta: float) -> void:
		frames += 1

var _scene: Node
var _group: DelayedActorGroup
var _authority: WorldTimeAuthority
var _tuning: CombatTuning
var _dummy: CharacterBody2D
var _probe: PauseProbe
var _idle: Dictionary
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _baseline_time_scale: float = 1.0
var _baseline_physics_tps: int = 60
var _baseline_max_physics_steps: int = 8
var _baseline_tree_paused: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _run() -> void:
	_baseline_time_scale = Engine.time_scale
	_baseline_physics_tps = Engine.physics_ticks_per_second
	_baseline_max_physics_steps = Engine.max_physics_steps_per_frame
	_baseline_tree_paused = paused
	_scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(_scene)
	_group = _scene.get_node("Actors/BodyGroup") as DelayedActorGroup
	_authority = _scene.get_node("WorldTimeAuthority") as WorldTimeAuthority
	_dummy = _scene.get_node("Enemies/MeleeEnemyA") as CharacterBody2D
	# 此文件验证玩家武器反馈，木桩主动攻击由 jump_health_dummy_test 单独覆盖。
	for target: Node in _scene.get_node("Enemies").get_children():
		target.set("attack_enabled", false)
		target.set("max_health", 100000.0)
		target.call("reset_combat", true)
		target.set_physics_process(false)
	for delay_controller: Node in get_nodes_in_group("enemy_delay_controller"):
		delay_controller.set_physics_process(false)
	_tuning = _authority.get_combat_tuning().duplicate() as CombatTuning
	_authority.combat_tuning = _tuning
	# 测试副本使用固定数值，不改动用户在资源中保存的手感参数。
	_tuning.attack_move_multiplier = 0.2
	_tuning.air_acceleration_multiplier = 0.25
	# 留出足够真实时间，避免无头帧率影响对暂停中间状态的观察。
	_tuning.hit_stop_seconds = 0.12
	_tuning.heavy_hit_stop_seconds = 0.16
	_tuning.hurt_character_flash_seconds = 0.12
	_tuning.hurt_screen_flash_seconds = 0.16
	_tuning.hurt_screen_flash_opacity = 0.30
	_tuning.hurt_screen_vignette_inner_radius = 0.62
	_tuning.hurt_screen_vignette_softness = 0.40
	_tuning.hurt_shake_seconds = 0.12
	_tuning.hurt_shake_strength = 2.0
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	_probe = PauseProbe.new()
	_scene.add_child(_probe)
	_idle = _group.body.weapon.capture_state()
	await physics_frame
	_test_movement()
	_test_air_movement()
	_test_release_during_pause()
	await _test_player_hurt_feedback()
	await _test_hit_stop_and_shake()
	await _test_heavy_hit_and_thinking_time()
	await _test_reset_slow_motion()
	await _test_external_pause_ownership()
	await _test_real_timer_api()
	_test_ground_contact_reuse()
	_test_authority_exit_restoration()
	await process_frame
	if _failures.is_empty():
		print("COMBAT_FEEDBACK_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("COMBAT_FEEDBACK_TEST_FAIL: " + failure)
	quit(0 if _failures.is_empty() else 1)


## 测试设置也走正式玩法入口，确保不会绕过“只能在思考时间修改”的规则。
func _set_player_delay_during_thinking_time(target_delay: float) -> void:
	var saved_entry_duration: float = _authority.thinking_entry_duration
	_authority.thinking_entry_duration = 0.0
	_authority.enter_thinking_time()
	_check(_group.request_delay_change(target_delay),
		"Player delay setup must be accepted during thinking time")
	_authority.request_exit_thinking_time()
	_authority.call("_physics_process", 0.01)
	_authority.call("_finish_pending_resume")
	_group.call("_physics_process", 0.01)
	_authority.thinking_entry_duration = saved_entry_duration


func _test_movement() -> void:
	_set_player_delay_during_thinking_time(0.0)
	_group.body.position = Vector2(100, 625)
	_group.body.velocity = Vector2(320, 0)
	Input.action_press("ui_right")
	_group.body.set("_attack_requested", true)
	_group.body.tick_physics(0, 0.01)
	_check(is_equal_approx(_group.body.velocity.x, 64.0), "Attack must clamp running speed to 20%% on first frame; actual=%s" % _group.body.velocity)
	_tuning.attack_move_multiplier = 0.0
	_group.body.tick_physics(0, 0.01)
	_check(is_zero_approx(_group.body.velocity.x), "Changing shared multiplier must affect active attack immediately")
	_tuning.attack_move_multiplier = 0.2
	_group.body.weapon.restore_state(_idle)
	for frame: int in range(25):
		_group.body.tick_physics(0, 0.01)
	_check(is_equal_approx(_group.body.velocity.x, 320.0), "Normal movement must recover after attack")
	Input.action_release("ui_right")
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		_check(actor.weapon.get_combat_tuning() == _tuning, "All three actors must read WorldTimeAuthority tuning")
	print("PASS: first-frame slowdown, live tuning and recovery")


## 空中转向受较小加速度约束，但挥剑不截断原来的水平惯性。
func _test_air_movement() -> void:
	var actor: BaseActor = _group.body
	actor.position = Vector2(100, 300)
	actor.velocity = Vector2(320, 0)
	actor.weapon.restore_state(_idle)
	Input.action_press("ui_left")
	actor.tick_physics(0, 0.01)
	_check(is_equal_approx(actor.velocity.x, 316.0), "Air reversal must use 25% acceleration")
	actor.velocity.x = 320.0
	actor.set("_attack_requested", true)
	actor.tick_physics(0, 0.01)
	_check(is_equal_approx(actor.velocity.x, 316.0), "Air attack must preserve the same horizontal inertia as normal air movement")
	Input.action_release("ui_left")
	actor.position = Vector2(100, 625)
	actor.velocity = Vector2(320, 0)
	actor.weapon.restore_state(_idle)
	# 用一条明确的逻辑输入测试同时起跳和攻击，避免人工快进中的 just_pressed 帧语义。
	var history: PreviewSystem = _group.preview_system
	history.record(Recording.new(1.0, true, actor.position, actor.velocity, true, 1))
	history.read_head = history.write_head
	history.stall_frames = 0
	actor.inputed = false
	actor.tick_physics(0, 0.01)
	_check(actor.velocity.y < 0.0 and is_equal_approx(actor.velocity.x, 320.0), "Jump and attack on the same frame must not apply grounded slowdown; actual=%s" % actor.velocity)
	actor.inputed = true
	history.reset_to_initial_state()
	print("PASS: reduced air acceleration, air attack inertia and jump-frame rules")


## 角色暂停时不会接收普通输入回调；恢复后必须以真实输入状态清除遗留的长按。
func _test_release_during_pause() -> void:
	_set_player_delay_during_thinking_time(0.0)
	var actor: BaseActor = _group.body
	actor.weapon.restore_state(_idle)
	actor.set("_attack_held", true)
	actor.set("_attack_hold_elapsed", 1.0)
	actor.set("_attack_requested", false)
	Input.action_press("attack")
	paused = true
	# 模拟顿帧中用户松开：不向 Player 投递 InputEvent，因此它错过 release 回调。
	Input.action_release("attack")
	paused = false
	actor.tick_physics(0, 0.01)
	_check(not bool(actor.get("_attack_held")), "First frame after pause must clear a missed attack release")
	_check(actor.weapon.phase == SwordWeapon.Phase.IDLE, "Missed release must not restart an automatic attack")
	print("PASS: release during hit stop cannot leave attack held forever")


## 玩家受伤反馈必须使用真实时间，在慢动作或暂停体系旁边仍能按预期结束。
func _test_player_hurt_feedback() -> void:
	_set_player_delay_during_thinking_time(0.0)
	var actor: BaseActor = _group.body
	actor.call("reset_health")
	var base: Transform2D = Transform2D(0.03, Vector2(4.0, 7.0))
	root.global_canvas_transform = base
	var accepted: bool = bool(actor.call("receive_hit", 20.0, _dummy, 1, Vector2.RIGHT))
	var flash: CanvasLayer = _authority.get_node("DamageScreenFlash") as CanvasLayer
	var overlay: ColorRect = flash.get_node("Overlay") as ColorRect
	var sprite: Sprite2D = actor.get_node("VisualRoot/Graphics/Sprite2D") as Sprite2D
	var material: ShaderMaterial = sprite.material as ShaderMaterial
	var initial_opacity: float = float(flash.call("get_opacity"))
	_check(accepted and bool(flash.call("is_playing")) and initial_opacity > 0.0,
		"Accepted player damage must start a visible full-screen red flash")
	var visible_size: Vector2 = root.get_visible_rect().size
	_check(overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE and overlay.size.is_equal_approx(visible_size),
		"Damage overlay must cover the viewport without blocking input; actual=%s expected=%s mouse=%s" % [
			overlay.size, visible_size, overlay.mouse_filter
		])
	var vignette_material: ShaderMaterial = overlay.material as ShaderMaterial
	_check(vignette_material != null
		and is_equal_approx(float(vignette_material.get_shader_parameter("inner_radius")), 0.62)
		and is_equal_approx(float(vignette_material.get_shader_parameter("edge_softness")), 0.40),
		"Damage overlay must use the configured radial edge-mask material")
	_check(is_equal_approx(float(material.get_shader_parameter("white_amount")), 1.0),
		"Accepted player damage must immediately whiten the body sprite")
	_check(not root.global_canvas_transform.is_equal_approx(base),
		"Accepted player damage must start a light screen shake")
	await _wait_real(0.05)
	_check(float(flash.call("get_opacity")) < initial_opacity and float(flash.call("get_opacity")) > 0.0,
		"Red overlay must fade over real time")
	var mid_white: float = float(material.get_shader_parameter("white_amount"))
	_check(mid_white > 0.0 and mid_white < 1.0, "Body sprite must fade from white back to its original color")
	await _wait_real(0.15)
	_check(not bool(flash.call("is_playing")) and is_zero_approx(float(flash.call("get_opacity"))),
		"Red overlay must hide completely after its duration")
	_check(is_zero_approx(float(material.get_shader_parameter("white_amount"))),
		"Body white flash must restore the original material value")
	_check(root.global_canvas_transform.is_equal_approx(base),
		"Hurt shake must restore the original canvas transform without drift")
	root.global_canvas_transform = Transform2D.IDENTITY
	print("PASS: player white flash, red screen pulse and independent hurt shake")


func _wait_for_hit_stop() -> void:
	var deadline: int = Time.get_ticks_msec() + 1000
	while not _authority.is_in_hit_stop() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_authority.is_in_hit_stop(), "Actual hit must start deferred hit stop")


func _wait_for_thinking_pause() -> void:
	var deadline: int = Time.get_ticks_msec() + 1000
	while not _authority.is_in_thinking_time() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_authority.is_in_thinking_time() and paused,
		"Thinking-time slowdown must eventually finish in a paused state")


## 与生产代码使用同一真实时钟；无头模式的帧 delta 可能经过平滑或钳制。
func _wait_real(seconds: float) -> void:
	var deadline: int = Time.get_ticks_usec() + int(seconds * 1_000_000.0)
	while Time.get_ticks_usec() < deadline:
		await process_frame


func _test_hit_stop_and_shake() -> void:
	_group.body.position = Vector2(450, 625)
	_group.body.weapon.restore_state(_idle)
	await physics_frame
	var base: Transform2D = Transform2D(0.05, Vector2(7, 11))
	root.global_canvas_transform = base
	for frame: int in range(14):
		_group.body.weapon.tick(frame == 0, 1, true)
	_check(int(_dummy.get("hit_count")) == 1, "Active sweep must damage once before stopping")
	var spark: Node = _dummy.get_node("HitSpark")
	_check(spark != null and bool(spark.call("is_playing")), "A real hit must start the target hit spark")
	_check(not paused, "Hit must allow remaining actors to finish this physics frame")
	await _wait_for_hit_stop()
	var frames: int = _probe.frames
	var state: Dictionary = _group.body.weapon.capture_state()
	var position: Vector2 = _group.body.position
	var initial_offset: Vector2 = root.global_canvas_transform.origin - base.origin
	_check(paused and not initial_offset.is_zero_approx(), "Hit stop must pause gameplay and shake screen")
	var spark_elapsed: float = float(spark.call("get_elapsed"))
	await _wait_real(0.03)
	_check(_probe.frames == frames and _group.body.position == position, "Gameplay physics must stay frozen during hit stop")
	_check(_group.body.weapon.capture_state() == state, "Weapon progress must stay frozen during hit stop")
	_check(not root.global_canvas_transform.origin.is_equal_approx(base.origin + initial_offset), "Shake must keep moving in real time while paused")
	_check(spark.process_mode == Node.PROCESS_MODE_ALWAYS and bool(spark.call("is_playing")) and float(spark.call("get_elapsed")) > spark_elapsed,
		"Hit spark must keep animating in real time during hit stop")
	await _wait_real(0.15)
	_check(not paused and not _authority.is_in_hit_stop(), "Hit stop must resume automatically")
	_check(root.global_canvas_transform.is_equal_approx(base), "Shake must restore original transform without drift")
	_check(_probe.frames > frames, "Physics must resume after hit stop")
	root.global_canvas_transform = Transform2D.IDENTITY
	for frame: int in range(10):
		_group.body.weapon.tick(false, 1, true)
		_group.preview_body.weapon.tick(frame == 0, 1, true)
		_group.predictor.weapon.tick(frame == 0, 1, true)
	await process_frame
	_check(not _authority.is_in_hit_stop(), "Same swing, preview and predictor must not retrigger feedback")
	print("PASS: actual hit, deferred freeze, real-time shake and clean resume")


func _test_heavy_hit_and_thinking_time() -> void:
	_group.body.position = Vector2(350, 625)
	var heavy: Dictionary = _idle.duplicate()
	heavy["phase"] = SwordWeapon.Phase.WINDUP
	heavy["combo_index"] = 2
	heavy["frames_left"] = 0
	_group.body.weapon.restore_state(heavy)
	var hits_before: int = int(_dummy.get("hit_count"))
	await physics_frame
	for frame: int in range(10):
		_group.body.weapon.tick(false, 1, true)
	_check(int(_dummy.get("hit_count")) == hits_before, "Reduced heavy sweep must not hit the old distant target")
	_group.body.position = Vector2(410, 625)
	_group.body.weapon.restore_state(heavy)
	await physics_frame
	for frame: int in range(10):
		_group.body.weapon.tick(false, 1, true)
	_check(int(_dummy.get("hit_count")) == hits_before + 1, "Heavy sweep must still hit a target within sword reach")
	_check(is_equal_approx(rad_to_deg(_group.body.weapon.get_swing_angle(1.0) - _group.body.weapon.get_swing_angle(0.0)), 220.0), "Heavy swing arc must be 220 degrees")
	_check(is_equal_approx(float(_authority.get("_pending_hit_stop_seconds")), _tuning.heavy_hit_stop_seconds), "Heavy hit must use heavy feedback duration")
	await _wait_for_hit_stop()
	_authority.enter_thinking_time()
	_check(_authority.is_entering_thinking_time() and not paused and not _authority.is_in_hit_stop(),
		"Thinking time must replace hit stop with an unpaused slowdown transition")
	_check(root.global_canvas_transform.is_equal_approx(Transform2D.IDENTITY), "Entering thinking time must clear shake")
	await _wait_real(_authority.thinking_entry_duration * 0.5)
	_check(Engine.time_scale > 0.0 and Engine.time_scale < 1.0 and not paused,
		"Thinking entry must visibly reduce world speed before pausing")
	await _wait_for_thinking_pause()
	_authority.request_hit_feedback(0)
	await _wait_real(0.2)
	_check(paused and _authority.is_in_thinking_time(), "Old hit-stop deadline must not unpause thinking time")
	_authority.request_exit_thinking_time()
	await _wait_real(0.04)
	_check(not paused and not _authority.is_in_thinking_time(), "Thinking exit must resume normally")
	print("PASS: expanded heavy hit and thinking-time pause ownership")


func _test_reset_slow_motion() -> void:
	_authority.trigger_reset_slow_motion()
	_authority.request_hit_feedback(0)
	await _wait_for_hit_stop()
	_check(Engine.time_scale < 1.0, "Hit stop must not cancel R slow motion")
	_check(is_equal_approx(Engine.time_scale / Engine.physics_ticks_per_second, 0.01), "Slow motion and hit stop must preserve fixed logical step")
	await _wait_real(0.4)
	_check(not paused and is_equal_approx(Engine.time_scale, 1.0), "Overlapping slow motion and hit stop must both finish")
	_check(Engine.physics_ticks_per_second == 100, "Physics TPS must return to 100")
	_tuning.hit_stop_enabled = false
	_authority.request_hit_feedback(2)
	await process_frame
	_check(not paused, "Disabling feedback in shared tuning must prevent hit stop")
	print("PASS: R slow-motion overlap and feedback toggle")


## 胜利暂停与最后一击顿帧可能重叠；顿帧结束不能擅自恢复战斗。
func _test_external_pause_ownership() -> void:
	_tuning.hit_stop_enabled = true
	_authority.request_hit_feedback(0)
	await _wait_for_hit_stop()
	_authority.request_external_pause(&"test_victory")
	await _wait_real(_tuning.hit_stop_seconds + 0.05)
	_check(not _authority.is_in_hit_stop() and paused
		and _authority.is_externally_paused(&"test_victory"),
		"External victory pause must survive the end of overlapping hit stop")
	_authority.release_external_pause(&"test_victory")
	_check(not paused, "Releasing the last external pause reason must resume gameplay")
	print("PASS: named external pause survives overlapping hit stop")


## 独立验证公开接口：暂停、变速、取消、并行和回调内创建计时器。
func _test_real_timer_api() -> void:
	for speed: float in [0.05, 3.0, 0.0]:
		Engine.time_scale = speed
		paused = true
		var completions: Array[int] = [0]
		var started: int = Time.get_ticks_usec()
		var timer: WorldTimeAuthority.RealTimeTimer = _authority.create_real_timer(0.06)
		timer.timeout.connect(func() -> void: completions[0] += 1)
		await _wait_real(0.02)
		_check(timer.get_progress() > 0.0 and timer.get_progress() < 1.0,
			"Timer progress must advance while paused at speed %s" % speed)
		while timer.is_running() and Time.get_ticks_usec() - started < 500_000:
			await process_frame
		var elapsed: float = float(Time.get_ticks_usec() - started) / 1_000_000.0
		_check(completions[0] == 1 and elapsed >= 0.06 and elapsed < 0.5,
			"Timeout must fire once in real time at speed %s" % speed)
		_check(is_zero_approx(timer.get_time_left()) and is_equal_approx(timer.get_progress(), 1.0),
			"Finished timer must have zero time left and full progress")
	Engine.time_scale = 1.0
	paused = false

	var canceled_events: Array[int] = [0]
	var canceled: WorldTimeAuthority.RealTimeTimer = _authority.create_real_timer(0.02)
	canceled.timeout.connect(func() -> void: canceled_events[0] += 1)
	canceled.cancel()
	await _wait_real(0.04)
	_check(canceled_events[0] == 0 and not canceled.is_running(), "Cancellation must suppress timeout")

	var order: Array[int] = []
	_authority.create_real_timer(0.01).timeout.connect(func() -> void: order.append(1))
	_authority.create_real_timer(0.03).timeout.connect(func() -> void: order.append(2))
	await _wait_real(0.05)
	_check(order == [1, 2], "Independent timers must keep their own deadlines")

	var callbacks: Array[int] = []
	var immediate: WorldTimeAuthority.RealTimeTimer = _authority.create_real_timer(-1.0)
	immediate.timeout.connect(func() -> void:
		callbacks.append(1)
		_authority.create_real_timer(0.0).timeout.connect(func() -> void: callbacks.append(2))
	)
	_check(callbacks.is_empty(), "Zero/negative duration must allow connecting before timeout")
	await _wait_real(0.03)
	_check(callbacks == [1, 2], "Timeout callback must be able to create another timer safely")
	_check((_authority.get("_real_timers") as Array).is_empty(), "Completed and canceled timers must be released")
	print("PASS: reusable real-time timer API under pause and speed changes")


## 高频地面查询应始终复用角色自己的碰撞结果对象。
func _test_ground_contact_reuse() -> void:
	var cached_contact: KinematicCollision2D = _group.body.get("_ground_contact") as KinematicCollision2D
	_check(cached_contact != null, "Actor must own a reusable ground-contact result")
	if cached_contact == null:
		return
	var contact_id: int = cached_contact.get_instance_id()
	for query_index: int in range(8):
		_group.body.is_grounded_for_simulation()
	_check((_group.body.get("_ground_contact") as KinematicCollision2D).get_instance_id() == contact_id,
		"Repeated ground queries must not replace or reallocate the cached result")
	print("PASS: ground detection reuses one collision result")


## 控制器离场时恢复进入前的全局状态，防止慢动作或暂停泄漏到下一场景。
func _test_authority_exit_restoration() -> void:
	_authority.reset_restore_duration = 1.0
	_authority.trigger_reset_slow_motion()
	_authority.request_external_pause(&"authority_exit_test")
	_check(Engine.time_scale < 1.0 and paused,
		"Exit-restoration setup must place the world in slow motion and pause")
	root.remove_child(_scene)
	_scene.queue_free()
	_check(is_equal_approx(Engine.time_scale, _baseline_time_scale)
		and Engine.physics_ticks_per_second == _baseline_physics_tps
		and Engine.max_physics_steps_per_frame == _baseline_max_physics_steps
		and paused == _baseline_tree_paused,
		"Removing WorldTimeAuthority must restore time scale, TPS, step budget and pause state")
	print("PASS: authority exit restores process-wide simulation state")
