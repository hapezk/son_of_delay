class_name DelayTimelineBuffer
extends RefCounted

## 玩家输入与敌人 AI 命令共用的延迟时间线游标。
## 帧载荷仍由各系统强类型保存；这里统一秒数换算、环形读写头和增减延迟语义。
const BASE_PHYSICS_TPS: int = 100

var capacity: int = 0
var write_head: int = -1
var read_head: int = -1
var stall_frames: int = 0


static func seconds_to_frames(seconds: float) -> int:
	return maxi(roundi(maxf(seconds, 0.0) * BASE_PHYSICS_TPS), 0)


func configure(max_delay_seconds: float) -> void:
	capacity = maxi(ceili(maxf(max_delay_seconds, 0.0) * float(BASE_PHYSICS_TPS)) + 1, 2)
	reset()


func reset() -> void:
	write_head = -1
	read_head = -1
	stall_frames = 0


func advance_write() -> int:
	if capacity <= 0:
		return -1
	write_head = (write_head + 1) % capacity
	return write_head


## 返回本帧应消费的槽位；-1 表示历史尚未填满或正在为增加延迟等待。
func consume_index(delay_frames: int) -> int:
	if capacity <= 0:
		return -1
	if stall_frames > 0:
		stall_frames -= 1
		return -1
	if read_head < 0:
		if write_head < 0:
			return -1
		read_head = _wrap(write_head - maxi(delay_frames, 0))
	var result: int = read_head
	read_head = _wrap(read_head + 1)
	return result


## 所有对象采用同一切换规则：
## - 归零：清空游标，由真实本体恢复实时控制；
## - 0 -> 正数：从空历史开始填充；
## - 增加：保留历史和预览，仅让本体等待增加的帧数；
## - 缩短：保留历史，直接把读头推进到更接近写头的位置。
func apply_delay_change(old_delay_seconds: float, new_delay_seconds: float) -> void:
	var old_frames: int = seconds_to_frames(old_delay_seconds)
	var new_frames: int = seconds_to_frames(new_delay_seconds)
	if new_frames <= 0:
		reset()
		return
	if old_frames <= 0:
		read_head = _wrap(write_head - new_frames)
		stall_frames = 0
		return
	var delta_frames: int = new_frames - old_frames
	if delta_frames > 0:
		stall_frames += delta_frames
	elif delta_frames < 0:
		read_head = _wrap(write_head - new_frames)
		stall_frames = 0


func _wrap(index: int) -> int:
	return posmod(index, capacity) if capacity > 0 else -1
