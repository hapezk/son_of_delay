extends SceneTree

## 横板镜头纵切：死区触发、指数平滑、左右回收与关卡边界。
## --headless --path program --script res://test/side_scroll_camera_test.gd
var _scene: Node
var _camera: Camera2D
var _player: BaseActor
var _preview: BaseActor
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
	_camera = _scene.get_node("SideScrollCamera") as Camera2D
	_group = _scene.get_node("Actors/BodyGroup") as DelayedActorGroup
	_player = _group.body
	_preview = _group.preview_body
	_group.set_physics_process(false)
	_group.time_slice_system.set_physics_process(false)
	for actor: BaseActor in [_group.body, _group.preview_body, _group.predictor]:
		actor.state_machine.set_physics_process(false)
	for enemy: Node in _scene.get_node("Enemies").get_children():
		enemy.set_physics_process(false)
	for delay_controller: Node in get_nodes_in_group("enemy_delay_controller"):
		delay_controller.set_physics_process(false)
	_camera.set_physics_process(false)
	await process_frame

	var initial_position: Vector2 = _camera.global_position
	_check(_camera.is_current(),
		"Main scene must activate the side-scroll camera by default")
	_check(is_equal_approx(float(_camera.get("level_right")), 6400.0)
		and _camera.limit_right == 6400,
		"Extended main level and camera must share the 6400-pixel right boundary")
	var level: Node2D = _scene.get_node("SideScrollLevel") as Node2D
	var platform_b: Node2D = level.get_node("PlatformB") as Node2D
	var horizontal_platform: Node2D = _scene.get_node(
		"EnvironmentGameplay/HorizontalPlatform") as Node2D
	_check(platform_b.global_position.y >= 550.0 and horizontal_platform.global_position.y >= 550.0,
		"Previously unreachable platforms must stay within the player's ground-jump height")
	_check(_scene.get_node("Enemies").get_child_count() == 7
		and (_scene.get_node("FinishGoal") as Node2D).global_position.x > 6000.0,
		"Extended level must contain seven enemies and a finish goal beyond x=6000")
	var viewport_width: float = root.get_visible_rect().size.x
	var right_ratio: float = float(_camera.get("right_trigger_ratio"))
	var inside_right_edge: float = initial_position.x + (right_ratio - 0.5) * viewport_width - 20.0
	_player.global_position.x = inside_right_edge
	_preview.global_position.x = inside_right_edge
	_camera.call("_physics_process", 0.1)
	_check(_camera.global_position.is_equal_approx(initial_position),
		"Camera must remain still while the player focus stays inside the dead zone")

	# 常驻延迟时使用本体与预览体中点，避免任意一方贴住屏幕边缘。
	_player.global_position.x = inside_right_edge + 60.0
	_preview.global_position.x = inside_right_edge + 460.0
	var focus_x: float = (_player.global_position.x + _preview.global_position.x) * 0.5
	_camera.call("_physics_process", 0.1)
	_check(_camera.global_position.x > initial_position.x
		and _camera.global_position.x < focus_x,
		"Crossing the right trigger must start a smooth partial follow")
	var first_follow_x: float = _camera.global_position.x
	for frame: int in range(40):
		_camera.call("_physics_process", 0.01)
	_check(_camera.global_position.x > first_follow_x,
		"Repeated camera ticks must converge toward the horizontal target")
	_check(is_equal_approx(_camera.global_position.y, float(_camera.get("fixed_y"))),
		"Horizontal level camera must keep its authored vertical center")

	_player.global_position.x = 5000.0
	_preview.global_position.x = 5200.0
	for frame: int in range(200):
		_camera.call("_physics_process", 0.01)
	var half_width: float = viewport_width * 0.5
	var maximum_center: float = float(_camera.get("level_right")) - half_width
	_check(_camera.global_position.x <= maximum_center + 0.1,
		"Camera must never reveal space beyond the right level boundary")
	_player.global_position.x = -1000.0
	_preview.global_position.x = -800.0
	for frame: int in range(300):
		_camera.call("_physics_process", 0.01)
	var minimum_center: float = float(_camera.get("level_left")) + half_width
	_check(_camera.global_position.x >= minimum_center - 0.1,
		"Camera must follow back through the left dead zone without crossing the level boundary")
	_check(_camera.get("target") == _player,
		"Camera target must remain the authority body used to resolve its actor group")
	_check((_group.call("get_camera_focus_position") as Vector2).x == -900.0,
		"Stable player delay must expose the body-preview midpoint as camera focus")

	if _failures.is_empty():
		print("SIDE_SCROLL_CAMERA_TEST_PASS checks=%d" % _checks)
	else:
		for failure: String in _failures:
			push_error("SIDE_SCROLL_CAMERA_TEST_FAIL: " + failure)
	root.remove_child(_scene)
	_scene.queue_free()
	await process_frame
	quit(0 if _failures.is_empty() else 1)
