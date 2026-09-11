class_name DelayPredictionRunner
extends RefCounted

## 按环形时间线顺序重放一个闭区间。玩家与敌人只注入“如何执行一帧”的适配回调。
## 返回实际执行的帧数；无效窗口返回 0，任何情况下都不会越过一整圈容量。
static func run_window(
	storage: Array,
	start_index: int,
	end_index: int,
	capacity: int,
	frame_step: Callable,
	empty_step: Callable = Callable()
) -> int:
	if capacity <= 0 or storage.size() < capacity or start_index < 0 or end_index < 0 \
			or not frame_step.is_valid():
		return 0
	var slot_index: int = posmod(start_index, capacity)
	var final_index: int = posmod(end_index, capacity)
	var processed: int = 0
	while processed < capacity:
		var frame: Variant = storage[slot_index]
		if frame == null:
			if empty_step.is_valid():
				empty_step.call()
		else:
			frame_step.call(frame)
		processed += 1
		if slot_index == final_index:
			break
		slot_index = (slot_index + 1) % capacity
	return processed
