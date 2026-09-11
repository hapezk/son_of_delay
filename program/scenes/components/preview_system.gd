class_name PreviewSystem
extends Node

const CommandBuffer = preload("res://scenes/components/delay_command_buffer.gd")
const PredictionRunner = preload("res://scenes/components/delay_prediction_runner.gd")
## 录制、回放与预测的逻辑时间基准；不随世界变速改变。
const BASE_PHYSICS_TPS: int = DelayTimelineBuffer.BASE_PHYSICS_TPS

var slots: Array[Recording]
## 玩家原有的“记录输入、延迟后重放”流程现在由通用命令缓冲持有。
var _command_buffer: CommandBuffer = CommandBuffer.new()
## 兼容时间切片与诊断工具的只读入口；实际游标由 _command_buffer 统一管理。
var _timeline: DelayTimelineBuffer = _command_buffer.timeline
## 保留原公开属性，时间切片和诊断测试无需知道游标已经由通用时间线持有。
var write_head: int:
	get:
		return _timeline.write_head
	set(value):
		_timeline.write_head = value
var read_head: int:
	get:
		return _timeline.read_head
	set(value):
		_timeline.read_head = value
var stall_frames: int:
	get:
		return _timeline.stall_frames
	set(value):
		_timeline.stall_frames = value
var predict_write_head: int = -1
var predict_read_head: int = -1
var predict_stall: int = 0
var capacity: int:
	get:
		return _timeline.capacity
var parent: Node

# on_delay_changed 准备的参数，供 _physics_process 中调用
var _pred_state_idx: int = -1
var _pred_input_start_idx: int = -1

# 最近一次预测器跑出来的轨迹（非零延迟减小后供切片系统重新渲染）
var last_predicted_positions: Array[Vector2] = []
var last_predicted_velocities: Array[Vector2] = []
var last_predict_input_start_idx: int = -1


## 所有延迟系统共用同一换算，避免 0.29 等十进制小数被 int() 意外截少一帧。
static func seconds_to_frames(seconds: float) -> int:
	return CommandBuffer.seconds_to_frames(seconds)


func _ready() -> void:
	if parent == null:
		parent = get_parent()
	if not (parent is DelayedActorGroup):
		push_error("PreviewSystem parent must be DelayedActorGroup")
		return
	_command_buffer.configure(parent.max_delay_time)
	_command_buffer.prepare_storage(slots)


func reset_to_initial_state() -> void:
	_command_buffer.clear(slots)
	predict_write_head = -1
	predict_read_head = -1
	predict_stall = 0
	last_predicted_positions.clear()
	last_predicted_velocities.clear()
	last_predict_input_start_idx = -1


func record(frame: Recording) -> void:
	if frame == null:
		return
	_capture_sprite_state(frame)
	_command_buffer.record(slots, frame)


func _capture_sprite_state(slot: Recording) -> void:
	if parent == null or not (parent is DelayedActorGroup) or parent.preview_body == null:
		return
	var preview_graphics: Node2D = parent.preview_body.graphics
	if preview_graphics == null:
		return
	var preview_sprite: Sprite2D = preview_graphics.get_node_or_null("Sprite2D") as Sprite2D
	if preview_sprite == null or preview_sprite.texture == null:
		return

	slot.texture = preview_sprite.texture
	slot.scale = preview_sprite.scale
	slot.region_enabled = preview_sprite.region_enabled
	slot.region_rect = preview_sprite.region_rect
	slot.hframes = preview_sprite.hframes
	slot.vframes = preview_sprite.vframes
	slot.frame = preview_sprite.frame
	slot.frame_coords = preview_sprite.frame_coords
	slot.centered = preview_sprite.centered
	slot.offset = preview_sprite.offset
	slot.flip_h = preview_graphics.scale.x < 0.0


func consume() -> Recording:
	return _command_buffer.consume(slots, parent.delay_time) as Recording


func predict_consume() -> Recording:
	if predict_stall > 0:
		predict_stall -= 1
		return null
	var need: int = seconds_to_frames(parent.delay_time)
	if predict_read_head < 0:
		if predict_write_head < 0:
			return null
		predict_read_head = (predict_write_head - need + capacity) % capacity
	var f := slots[predict_read_head]
	predict_read_head = (predict_read_head + 1) % capacity
	return f


func run_prediction_in_physics_process() -> Dictionary:
	return run_prediction(_pred_state_idx, _pred_input_start_idx)


func run_prediction(_state_idx: int, input_start_idx: int) -> Dictionary:
	var dt: float = 1.0 / BASE_PHYSICS_TPS

	parent.sync_predictor_to_body()
	var predictor: BaseActor = parent.predictor

	last_predicted_positions.clear()
	last_predicted_velocities.clear()
	last_predict_input_start_idx = input_start_idx

	# Phase 1: stall（仅增大时有，减小为 0 直接跳过）
	for i in predict_stall:
		predictor.tick_physics(predictor.get_next_state(predictor.state_machine.current_state), dt)
		last_predicted_positions.append(predictor.global_position)
		last_predicted_velocities.append(predictor.velocity)

	# Phase 2: 重放 input_start_idx -> write_head（含 write_head，与本体回放范围一致）
	# null 槽仍需推进读头；角色在该帧没有输入并暂停竖直运动，不能 break。
	PredictionRunner.run_window(
		slots,
		input_start_idx,
		write_head,
		capacity,
		Callable(self, "_step_player_prediction_frame").bind(dt),
		Callable(self, "_step_player_prediction_empty").bind(dt)
	)

	var attachment_state: Dictionary = predictor.capture_delay_attachment_state()
	return {
		"pos": predictor.global_position, "vel": predictor.velocity,
		"actor_state": predictor.capture_simulation_state(),
		"attachment_state": attachment_state,
		# 兼容现有诊断测试；新携带物统一读取 attachment_state。
		"weapon_state": predictor.weapon.capture_state() if predictor.weapon != null else {},
	}


func _step_player_prediction_frame(_frame: Variant, dt: float) -> void:
	_step_player_prediction(dt)


func _step_player_prediction_empty(dt: float) -> void:
	_step_player_prediction(dt)


func _step_player_prediction(dt: float) -> void:
	var predictor: BaseActor = parent.predictor
	predictor.tick_physics(predictor.get_next_state(predictor.state_machine.current_state), dt)
	last_predicted_positions.append(predictor.global_position)
	last_predicted_velocities.append(predictor.velocity)


## 从本体状态预测目标延迟对应的完整轨迹。必须在真实物理回调中调用。
func predict_delay_from_body(target_delay: float) -> Dictionary:
	if parent == null or not (parent is DelayedActorGroup) or parent.predictor == null:
		return {}
	if read_head < 0 or write_head < 0:
		return {}

	var clamped_delay: float = clampf(target_delay, 0.0, parent.delay_time)
	var target_frames: int = seconds_to_frames(clamped_delay)
	var input_start_idx: int = (write_head - target_frames + capacity) % capacity

	# 临时改用目标延迟的预测读头，结束后恢复正式回放状态。
	var saved_predict_write_head: int = predict_write_head
	var saved_predict_read_head: int = predict_read_head
	var saved_predict_stall: int = predict_stall
	var saved_state_idx: int = _pred_state_idx
	var saved_input_start_idx: int = _pred_input_start_idx

	predict_write_head = write_head
	predict_read_head = input_start_idx
	predict_stall = 0
	_pred_state_idx = read_head
	_pred_input_start_idx = input_start_idx

	var result: Dictionary = run_prediction_in_physics_process()
	var positions: Array[Vector2] = last_predicted_positions.duplicate()
	var velocities: Array[Vector2] = last_predicted_velocities.duplicate()
	var records: Array[Recording] = []
	for frame_index: int in range(positions.size()):
		var record_idx: int = (input_start_idx + frame_index) % capacity
		records.append(slots[record_idx])

	predict_write_head = saved_predict_write_head
	predict_read_head = saved_predict_read_head
	predict_stall = saved_predict_stall
	_pred_state_idx = saved_state_idx
	_pred_input_start_idx = saved_input_start_idx

	if result.is_empty() or positions.is_empty() or velocities.size() != positions.size() or records.is_empty():
		return {}
	var final_record: Recording = records.back()
	if final_record == null:
		final_record = slots[write_head]
	if final_record == null:
		return {}
	return {
		"position": result["pos"],
		"velocity": result["vel"],
		"actor_state": result.get("actor_state", {}),
		"attachment_state": result.get("attachment_state", {}),
		"weapon_state": result["weapon_state"],
		"positions": positions,
		"velocities": velocities,
		"records": records,
		"input_start_idx": input_start_idx,
		"record": final_record,
	}


## 缩短延迟会让本体跳过一段旧输入，并从当前位置重新演算剩余轨迹。
## 输入内容仍可复用，但旧记录中的位置/速度已不再是合法比较基准，必须一起重基准。
func rebase_last_predicted_records() -> bool:
	if last_predict_input_start_idx < 0:
		return false
	return rebase_recorded_trajectory(
		last_predict_input_start_idx,
		last_predicted_positions,
		last_predicted_velocities
	)


## 将一段预测结果写回对应环形槽，只改运动结果，不改移动、跳跃、攻击等输入。
func rebase_recorded_trajectory(
	input_start_idx: int,
	positions: Array[Vector2],
	velocities: Array[Vector2]
) -> bool:
	if capacity <= 0 or input_start_idx < 0 or positions.is_empty() \
		or positions.size() != velocities.size() or positions.size() > capacity:
		return false
	for frame_index: int in range(positions.size()):
		var slot_idx: int = (input_start_idx + frame_index) % capacity
		var record: Recording = slots[slot_idx]
		# 尚未填满缓冲时可能跨过 null 槽；它们本来就不会触发回放核对。
		if record == null:
			continue
		record.pos = positions[frame_index]
		record.vel = velocities[frame_index]
	return true


func on_delay_changed(old_d: float, new_d: float) -> Variant:
	var delta_frames: int = seconds_to_frames(new_d) - seconds_to_frames(old_d)
	var old_read_head: int = read_head
	_command_buffer.apply_delay_change(old_d, new_d)
	predict_write_head = write_head
	predict_read_head = read_head

	# 切换到 0 延迟：预览系统停止工作并重置到初始状态
	if is_equal_approx(new_d, 0.0):
		reset_to_initial_state()
		return null

	# 从 0 延迟切换到正延迟：preview 复制 body 当前状态并接管输入，不运行预测
	if is_equal_approx(old_d, 0.0) and new_d > 0.0:
		predict_read_head = read_head
		predict_stall = 0
		return null

	# 正延迟之间切换：通用时间线已经完成等待帧或读头推进，这里只同步预测游标。
	if delta_frames > 0:
		predict_stall = stall_frames
		_pred_state_idx = read_head
		_pred_input_start_idx = read_head
	elif delta_frames < 0 and old_read_head >= 0:
		predict_read_head = read_head
		predict_stall = 0
		_pred_state_idx = old_read_head
		_pred_input_start_idx = read_head
	return null
