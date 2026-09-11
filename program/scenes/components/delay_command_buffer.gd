class_name DelayCommandBuffer
extends RefCounted

const TimelineBuffer = preload("res://scenes/components/delay_timeline_buffer.gd")

## 所有可延迟角色共用的“命令帧”缓冲：预览体写入当前命令和预期结果，
## 真实本体在若干帧后取出同一帧并重新执行。角色自身只负责解释命令内容。
var timeline: TimelineBuffer = TimelineBuffer.new()


static func seconds_to_frames(seconds: float) -> int:
	return TimelineBuffer.seconds_to_frames(seconds)


func configure(max_delay_seconds: float) -> void:
	timeline.configure(max_delay_seconds)


## storage 由调用者保留强类型（玩家是 Recording，敌人是 DelayFrame）。
## 这里统一容量、清空、读写游标以及“空帧”的表示。
func prepare_storage(storage: Array, empty_frame: Variant = null) -> void:
	storage.resize(timeline.capacity)
	clear(storage, empty_frame)


func clear(storage: Array, empty_frame: Variant = null) -> void:
	timeline.reset()
	for index: int in range(storage.size()):
		storage[index] = empty_frame


func record(storage: Array, frame: Variant) -> int:
	var write_index: int = timeline.advance_write()
	if write_index >= 0 and write_index < storage.size():
		storage[write_index] = frame
	return write_index


## 返回延迟后应执行的命令帧；历史未填满或增加延迟的等待期返回 empty_frame。
func consume(storage: Array, delay_seconds: float, empty_frame: Variant = null) -> Variant:
	var delay_frames: int = seconds_to_frames(delay_seconds)
	var read_index: int = timeline.consume_index(delay_frames)
	if read_index < 0 or read_index >= storage.size():
		return empty_frame
	return storage[read_index]


func apply_delay_change(old_delay_seconds: float, new_delay_seconds: float) -> void:
	timeline.apply_delay_change(old_delay_seconds, new_delay_seconds)


## 0 -> 正延迟时，本体会在等待历史期间逐帧减速；预览体从同一等待终点起跑。
## 玩家和敌人共用这段离散积分，避免两者出现一帧或一段距离的语义差异。
static func get_waiting_stop_distance(
	initial_velocity_x: float,
	deceleration_per_second: float,
	delta: float
) -> float:
	if delta <= 0.0 or deceleration_per_second <= 0.0:
		return 0.0
	var simulated_velocity_x: float = initial_velocity_x
	var step: float = deceleration_per_second * delta
	var distance: float = 0.0
	while absf(simulated_velocity_x) > 0.001:
		simulated_velocity_x = move_toward(simulated_velocity_x, 0.0, step)
		distance += simulated_velocity_x * delta
	return distance
