class_name CommandReplayDelayController
extends DelayControllerBase

## 通用命令回放适配层：角色或物体只需实现 BaseActor 的命令与快照契约。
const CommandBuffer = preload("res://scenes/components/delay_command_buffer.gd")
const PredictionRunner = preload("res://scenes/components/delay_prediction_runner.gd")
## 蓝色预览实时采样对象命令，真实本体在固定帧数后执行同一命令。
## 它与玩家共用 DelayFrame 和 DelayCommandBuffer，不把预览体的位置快照写回真实本体。
## 延迟请求只在思考时间接收，并统一在退出思考时间的物理提交点生效。
@export var preview_scene: PackedScene
var reforecast_count: int = 0

var _slots: Array[DelayFrame] = []
## 保留 _timeline 调试入口；玩家与敌人的游标都实际归同一种命令缓冲所有。
var _command_buffer: CommandBuffer = CommandBuffer.new()
var _timeline: DelayTimelineBuffer = _command_buffer.timeline
var _initialized: bool = false
var _prediction_visual_active: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = 10
	add_to_group("command_replay_delay_controllers")
	# 控制器是对象子节点；延后一帧，确保本体的 @onready 状态和出生点都已初始化。
	_initialize_controller.call_deferred()


func _initialize_controller() -> void:
	if _initialized:
		return
	body = get_parent() as BaseActor
	_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	if body == null or preview_scene == null or _authority == null:
		push_error("CommandReplayDelayController: body, preview_scene or WorldTimeAuthority is missing")
		return

	preview_body = preview_scene.instantiate() as BaseActor
	if preview_body == null:
		push_error("CommandReplayDelayController: preview_scene must instantiate BaseActor")
		return
	preview_body.name = "DelayPreview"
	add_child(preview_body)
	preview_body.top_level = true
	predictor = preview_scene.instantiate() as BaseActor
	if predictor == null:
		push_error("CommandReplayDelayController: preview_scene must also instantiate the predictor")
		preview_body.queue_free()
		preview_body = null
		return
	predictor.name = "DelayPredictor"
	add_child(predictor)
	predictor.top_level = true
	predictor.visible = false
	if not initialize_delay_controller(body, preview_body, predictor):
		return
	# 命令回放控制器是三个副本唯一的物理时钟，防止预览体再被场景树额外推进一次。
	body.set_physics_process(false)
	preview_body.set_physics_process(false)
	predictor.set_physics_process(false)
	create_or_configure_delay_ui(body)
	_rebuild_history_buffer()
	_sync_preview_to_body(true)
	preview_body.visible = false

	register_thinking_time_prediction(
		Callable(self, "has_queued_delay_change"),
		Callable(self, "run_queued_delay_prediction"),
		Callable(self, "commit_thinking_delay_change")
	)
	_initialized = true


## 命令回放对象只允许在思考时间排队修改；输入、标签和滚轮算法仍复用公共 UI。
func _can_accept_delay_request() -> bool:
	return _initialized and _authority != null \
		and _authority.is_accepting_thinking_time_adjustments()


func delay_shortcuts_require_thinking_time() -> bool:
	return true


func get_delay_buffer_capacity() -> int:
	return _timeline.capacity


func has_queued_delay_change() -> bool:
	return _prediction_request_dirty


## 与玩家一样，缩短延迟时先用隐藏预测器重放保留下来的命令，预览体显示新终点。
func run_queued_delay_prediction() -> void:
	if not _prediction_request_dirty:
		return
	_prediction_request_dirty = false
	if _pending_delay > 0.0 and _pending_delay < delay_time:
		var start_index: int = _get_input_start_index(_pending_delay)
		_prediction_visual_active = _predict_from_body(start_index, false)
	elif _prediction_visual_active:
		_restore_live_preview_from_latest_frame()
		_prediction_visual_active = false


func commit_thinking_delay_change() -> void:
	if _pending_delay < 0.0:
		return
	var requested_delay: float = _pending_delay
	_pending_delay = -1.0
	_prediction_request_dirty = false
	if not is_equal_approx(requested_delay, delay_time):
		_apply_delay_change(requested_delay)
	elif _prediction_visual_active:
		_restore_live_preview_from_latest_frame()
		_prediction_visual_active = false


func _physics_process(delta: float) -> void:
	if not _initialized or get_tree().paused:
		return
	if is_zero_approx(delay_time):
		# 直接使用 BaseActor 契约，不要求对象另外实现同名的 _physics_process 包装函数。
		var immediate_command: Dictionary = body.capture_delay_command()
		body.simulate_delay_command(immediate_command, delta)
		_sync_preview_to_body(false)
		preview_body.visible = false
		return

	var delayed_frame: DelayFrame = _consume_command_frame()
	if delayed_frame != null:
		body.simulate_delay_command(delayed_frame.command, delta)
		# 帧内位置结果只是预览参考；出现误差时重算剩余未来，但继续回放同一输入流。
		_check_replay_divergence(delayed_frame)
	else:
		# 等历史时执行对象自己的等待策略：角色减速，弹幕冻结。
		body.tick_delay_waiting(delta)

	var command: Dictionary = preview_body.capture_delay_command()
	preview_body.simulate_delay_command(command, delta)
	_record_command_frame(command)
	preview_body.visible = true


func _apply_delay_change(new_delay: float) -> void:
	var old_delay: float = delay_time
	var clamped_delay: float = clampf(new_delay, 0.0, max_delay_time)
	var had_prediction_visual: bool = _prediction_visual_active
	set_delay_time_immediate(clamped_delay)
	set_divergence_diagnostics(&"")
	if is_zero_approx(delay_time):
		_prediction_visual_active = false
		_clear_history()
		_sync_preview_to_body(true)
		_sync_predictor_to_body()
		preview_body.visible = false
		return
	if is_zero_approx(old_delay):
		_clear_history()
		_sync_preview_to_body(true)
		_sync_predictor_to_body()
		_move_preview_to_waiting_endpoint()
	elif delay_time > old_delay and had_prediction_visual:
		_restore_live_preview_from_latest_frame()
	_command_buffer.apply_delay_change(old_delay, delay_time)
	if old_delay > 0.0 and delay_time < old_delay:
		if not _predict_from_body(_timeline.read_head, true):
			push_error("CommandReplayDelayController: failed to predict reduced delay")
	_prediction_visual_active = false
	preview_body.visible = true


## 碰撞、受伤等真实世界结果只让预览重新估算，不撤销延迟或输入。
func report_external_divergence(reason: StringName) -> void:
	if not _initialized or is_zero_approx(delay_time):
		return
	if reason != &"replay_mismatch":
		set_divergence_diagnostics(reason)
	else:
		last_divergence_reason = reason
	reforecast_count += 1
	_prediction_visual_active = false
	_reforecast_remaining_inputs()


## 生命周期重置时不保留上一轮命令历史。
func on_body_reset() -> void:
	if not _initialized:
		return
	_clear_delay_for_lifecycle(&"")


## 对象被击破意味着本轮生命周期结束，并清空其延迟。
func on_body_defeated() -> void:
	if not _initialized:
		return
	_clear_delay_for_lifecycle(&"body_defeated")


func _clear_delay_for_lifecycle(reason: StringName) -> void:
	clear_pending_delay_request()
	set_delay_time_immediate(0.0)
	set_divergence_diagnostics(reason)
	reforecast_count = 0
	_prediction_visual_active = false
	_clear_history()
	_sync_preview_to_body(true)
	_sync_predictor_to_body()
	preview_body.visible = false


func _sync_preview_to_body(reset_interpolation: bool) -> void:
	sync_preview_to_body(reset_interpolation)


func _sync_predictor_to_body() -> void:
	sync_predictor_to_body(true)


## 普通移动对象开启延迟时先计算等待减速终点；特殊对象可覆盖此策略。
func _move_preview_to_waiting_endpoint() -> void:
	var dt: float = 1.0 / float(DelayTimelineBuffer.BASE_PHYSICS_TPS)
	var acceleration: float = body.get_delay_waiting_deceleration()
	var stop_distance_x: float = CommandBuffer.get_waiting_stop_distance(
		body.velocity.x, acceleration, dt
	)
	preview_body.global_position.x += stop_distance_x
	preview_body.velocity = Vector2(0.0, body.velocity.y)
	preview_body.reset_physics_interpolation()


func _rebuild_history_buffer() -> void:
	_slots.clear()
	_command_buffer.configure(max_delay_time)
	_command_buffer.prepare_storage(_slots)


func _clear_history() -> void:
	_command_buffer.clear(_slots)


func _record_command_frame(command: Dictionary) -> void:
	var frame: DelayFrame = DelayFrame.new(
		command,
		preview_body.global_position,
		preview_body.velocity,
		preview_body.capture_delay_snapshot()
	)
	_command_buffer.record(_slots, frame)


func _consume_command_frame() -> DelayFrame:
	return _command_buffer.consume(_slots, delay_time) as DelayFrame


## 本体和预览执行同一命令；位置/速度只作为分歧校验答案。
func _check_replay_divergence(frame: DelayFrame) -> bool:
	var expected_position: Vector2 = frame.pos
	var expected_velocity: Vector2 = frame.vel
	var position_error: float = body.global_position.distance_to(expected_position)
	var velocity_error: float = body.velocity.distance_to(expected_velocity)
	# 实体障碍被玩家挡住是有效物理结果；障碍解除后的首帧再重算剩余未来。
	if body.was_solid_obstacle_motion_blocked():
		set_divergence_diagnostics(
			&"physical_obstruction", position_error, velocity_error, expected_position)
		return false
	if position_error <= divergence_position_tolerance \
			and velocity_error <= divergence_velocity_tolerance:
		return false
	set_divergence_diagnostics(&"replay_mismatch", position_error, velocity_error, expected_position)
	report_external_divergence(&"replay_mismatch")
	return true


## 从真实本体的即时状态重放仍在路上的命令，并刷新每帧预期结果与蓝色预览。
## 时间线读写头和 delay_time 都不改变，所以外力不会吞掉命令或解除玩家施加的延迟。
func _reforecast_remaining_inputs() -> void:
	if _timeline.read_head >= 0 and _timeline.write_head >= 0 \
			and _predict_from_body(_timeline.read_head, true):
		preview_body.visible = true
		return
	# 延迟刚开启、尚无可重放帧时至少让预览从最新真实状态重新起步。
	_sync_preview_to_body(true)
	_sync_predictor_to_body()
	preview_body.visible = true


func _get_input_start_index(target_delay: float) -> int:
	if _timeline.write_head < 0 or _timeline.capacity <= 0:
		return -1
	var target_frames: int = CommandBuffer.seconds_to_frames(target_delay)
	return posmod(_timeline.write_head - target_frames, _timeline.capacity)


## 从真实本体出发重放目标窗口；提交时同时重写预期结果，防止缩短延迟后拿旧轨迹误报分歧。
func _predict_from_body(start_index: int, rebase_frames: bool) -> bool:
	if start_index < 0 or _timeline.write_head < 0 or predictor == null:
		return false
	_sync_predictor_to_body()
	var dt: float = 1.0 / float(DelayTimelineBuffer.BASE_PHYSICS_TPS)
	PredictionRunner.run_window(
		_slots,
		start_index,
		_timeline.write_head,
		_timeline.capacity,
		Callable(self, "_step_command_prediction_frame").bind(dt, rebase_frames),
		Callable(self, "_step_command_prediction_empty").bind(dt)
	)
	var predicted_snapshot: Dictionary = predictor.capture_delay_snapshot()
	preview_body.restore_delay_snapshot(predicted_snapshot)
	preview_body.reset_physics_interpolation()
	return true


func _step_command_prediction_frame(frame: DelayFrame, dt: float, rebase_frame: bool) -> void:
	predictor.simulate_delay_command(frame.command, dt)
	if rebase_frame:
		frame.pos = predictor.global_position
		frame.vel = predictor.velocity
		frame.state = predictor.capture_delay_snapshot()


func _step_command_prediction_empty(dt: float) -> void:
	predictor.tick_delay_waiting(dt)


func _restore_live_preview_from_latest_frame() -> void:
	if _timeline.write_head < 0:
		_sync_preview_to_body(true)
		return
	var latest_frame: DelayFrame = _slots[_timeline.write_head]
	if latest_frame == null:
		_sync_preview_to_body(true)
		return
	preview_body.restore_delay_snapshot(latest_frame.state)
	preview_body.reset_physics_interpolation()


func is_mouse_over_delay_visual(mouse_position: Vector2) -> bool:
	if _is_point_inside_actor(body, mouse_position):
		return true
	return preview_body.visible and _is_point_inside_actor(preview_body, mouse_position)


func _is_point_inside_actor(actor: BaseActor, point: Vector2) -> bool:
	if actor == null:
		return false
	return actor.is_delay_selection_point(point)


## 测试与调试面板只读接口，避免直接依赖环形缓冲内部字段。
func get_preview_body() -> CharacterBody2D:
	return preview_body
