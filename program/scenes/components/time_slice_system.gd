class_name TimeSliceSystem
extends Node

## 时间切片系统（直接赋值版 + 程序动画归零）
## 归零时：所有可见切片同时向 body 快速飞去，不再用 tween 多米诺
## 采样频率始终与 DelayedActorGroup 的逻辑时间基准一致。
const LOGIC_PHYSICS_TPS: int = DelayedActorGroup.BASE_PHYSICS_TPS

# 配置（可在编辑器 Inspector 调整）
@export_range(1, 120, 1) var capture_interval_frames: int = 10 ## 采样间隔（逻辑物理帧数）
@export var start_alpha: float = 0.8             ## 刚生成时的不透明度
@export var end_alpha: float = 0.2                 ## 最老时的不透明度
@export var slice_color: Color = Color(0.5, 0.7, 1.0, 1.0)  ## 切片色调（alpha 由计算控制）

# 节点引用
var group: DelayedActorGroup
var pool_node: Node

# 单一对象池：Sprite2D 本身，大小固定为最大可能切片数
var slice_pool: Array[Sprite2D] = []

# 每个对象池槽位对应的 PreviewSystem slot 索引（-1 表示未使用）
var slot_indices: Array[int] = []

# 环形缓冲游标
var write_idx: int = 0
var total_captured: int = 0

# 运行时
var _frame_counter: int = 0
var _cached_active: int = 0

# 延迟减小拉回
var _pending_pull_back: bool = false
var _old_preview_pos: Vector2 = Vector2.ZERO
var _pull_back_new_active: int = 0

# 归零归位动画
var _returning: bool = false
var _reset_on_finish: bool = false
var _return_frame_count: int = 0
var RETURN_MAX_FRAMES: int = 10  # 约 0.1s 一次性飞完，不管到没到

# 当前帧切片数量（供外部日志读取）
var current_active: int = 0


func _ready() -> void:
	group = get_parent() as DelayedActorGroup
	pool_node = get_node_or_null("SlicePool")

	if group == null:
		push_error("TimeSliceSystem: DelayedActorGroup parent not found")
		return
	if pool_node == null:
		push_error("TimeSliceSystem: SlicePool not found")
		return

	var max_slice_count: int = maxi(int(group.max_delay_time * LOGIC_PHYSICS_TPS / float(capture_interval_frames)), 1)

	for i: int in range(max_slice_count):
		var s := Sprite2D.new()
		s.visible = false
		s.z_index = -1  # 切片在本体后面，被本体遮挡
		pool_node.add_child(s)
		slice_pool.append(s)
		slot_indices.append(-1)

	if group != null and group.delay_time > 0.0:
		_cached_active = _compute_active(group.delay_time)


# 根据当前延迟计算应该显示多少个切片
func _compute_active(d: float) -> int:
	var delay_frames: int = PreviewSystem.seconds_to_frames(d)
	var active_count: int = floori(float(delay_frames) / float(capture_interval_frames))
	return maxi(mini(active_count, slice_pool.size()), 1)


## 对外提供切片数量，调用方不需要访问内部缓存计算方法。
func get_active_slice_count(delay_seconds: float) -> int:
	return _compute_active(delay_seconds)


## 对外复制一帧角色视觉快照，供预测切片复用正常切片的渲染规则。
func apply_record_to_slice(target: Sprite2D, record: Recording) -> bool:
	return _copy_sprite_state(target, record)


## 从预测轨迹中每 capture_interval_frames 取样，并确保包含预测终点。
func get_prediction_sample_frames(position_count: int, target_delay: float, max_sample_count: int = -1) -> Array[int]:
	var sample_frames: Array[int] = []
	if position_count <= 0:
		return sample_frames
	var desired_count: int = get_active_slice_count(target_delay)
	if max_sample_count >= 0:
		desired_count = mini(desired_count, max_sample_count)
	desired_count = mini(desired_count, position_count)
	var newest_frame: int = position_count - 1
	var oldest_frame: int = maxi(newest_frame - (desired_count - 1) * capture_interval_frames, 0)
	for sample_index: int in range(desired_count):
		sample_frames.append(mini(oldest_frame + sample_index * capture_interval_frames, newest_frame))
	return sample_frames


## 使用正常切片的槽位年龄公式计算预测切片透明度。
func get_prediction_sample_alpha(
	frame_index: int,
	input_start_idx: int,
	target_delay: float,
	preview: PreviewSystem
) -> float:
	var input_idx: int = (input_start_idx + frame_index) % preview.capacity
	var age_frames: int = (preview.write_head - input_idx + preview.capacity) % preview.capacity
	var life_frames: int = maxi(get_active_slice_count(target_delay) * capture_interval_frames, 1)
	var age_ratio: float = clampf(float(age_frames) / float(life_frames), 0.0, 1.0)
	return lerpf(start_alpha, end_alpha, age_ratio)


## 将思考时间里的预测切片直接接管为正常切片，并从该环形缓冲状态继续采样。
func adopt_prediction(new_delay: float, transition: Dictionary, preview: PreviewSystem) -> void:
	if transition.is_empty() or preview == null:
		return
	var positions: Array[Vector2] = transition["positions"]
	var records: Array[Recording] = transition["records"]
	var input_start_idx: int = transition["input_start_idx"]
	var sample_frames: Array[int] = get_prediction_sample_frames(positions.size(), new_delay, slice_pool.size())

	_reset_buffer()
	_cached_active = get_active_slice_count(new_delay)
	var visible_count: int = 0
	for pool_index: int in range(sample_frames.size()):
		var frame_index: int = sample_frames[pool_index]
		var normal_slice: Sprite2D = slice_pool[pool_index]
		var record: Recording = records[frame_index]
		var slot_idx: int = (input_start_idx + frame_index) % preview.capacity
		if not apply_record_to_slice(normal_slice, record):
			continue
		normal_slice.global_position = positions[frame_index]
		normal_slice.modulate = Color(
			slice_color,
			get_prediction_sample_alpha(frame_index, input_start_idx, new_delay, preview)
		)
		normal_slice.visible = true
		normal_slice.reset_physics_interpolation()
		slot_indices[pool_index] = slot_idx
		visible_count += 1

	# write_idx 指向下一次常规拍照要覆盖的位置，顺序保持“最旧 -> 最新”。
	if not slice_pool.is_empty():
		write_idx = sample_frames.size() % slice_pool.size()
	total_captured = sample_frames.size()
	_frame_counter = 0
	current_active = visible_count


# 外部通知：延迟发生变化
func on_delay_changed(old_d: float, new_d: float) -> void:
	if _returning:
		if new_d > 0.0:
			_returning = false
			_reset_on_finish = false
			_reset_buffer()
			_cached_active = _compute_active(new_d)
		return

	if _pending_pull_back:
		return

	# 正延迟 -> 0：播放归零归位动画
	if old_d > 0.0 and is_equal_approx(new_d, 0.0):
		_start_return_to_zero()
		return

	# 0 -> 正延迟：清空旧状态，从头开始拍照
	if is_equal_approx(old_d, 0.0) and new_d > 0.0:
		_reset_buffer()
		_cached_active = _compute_active(new_d)
		return

	# 正延迟之间
	if old_d > 0.0 and new_d > 0.0:
		var new_active: int = _compute_active(new_d)
		if new_d < old_d:
			# 延迟减小：记录 preview 旧位置，下一帧重新渲染切片
			_pending_pull_back = true
			_old_preview_pos = group.preview_body.global_position
			_pull_back_new_active = new_active
		else:
			_cached_active = new_active
		return


## 死亡重生不能播放旧轨迹的归位动画，直接清空全部时间切片。
func reset_to_initial_state() -> void:
	_reset_buffer()
	current_active = 0


# 从 Recording 中读取 Sprite2D 快照到目标切片；无有效贴图时由调用方隐藏该切片。
func _copy_sprite_state(target: Sprite2D, rec: Recording) -> bool:
	if rec == null or rec.texture == null:
		return false

	target.texture = rec.texture
	target.scale = rec.scale
	target.region_enabled = rec.region_enabled
	target.region_rect = rec.region_rect
	target.hframes = rec.hframes
	target.vframes = rec.vframes
	target.frame = rec.frame
	target.frame_coords = rec.frame_coords
	target.centered = rec.centered
	target.offset = rec.offset
	target.flip_h = rec.flip_h
	return true


# 延迟减小时：优先用预测器重新渲染轨迹，否则回退到水平平移
func _apply_pull_back() -> void:
	var ps: PreviewSystem = group.preview_system
	if ps != null and ps.last_predicted_positions.size() > 0:
		_apply_predicted_trajectory(ps)
	else:
		_apply_pull_back_legacy()


# 新版：从 predictor 轨迹中采样位置，重新放置切片
func _apply_predicted_trajectory(ps: PreviewSystem) -> void:
	var positions: Array[Vector2] = ps.last_predicted_positions
	var n: int = slice_pool.size()
	var new_active: int = _pull_back_new_active
	var input_start: int = ps.last_predict_input_start_idx
	var cap: int = ps.capacity

	var kept: int = 0
	var life_frames: int = maxi(new_active * capture_interval_frames, 1)

	# 从 newest 到 oldest 采样：每 capture_interval_frames 取一个 predicted 点
	for i: int in range(slice_pool.size()):
		var idx: int = (write_idx - 1 - i + n) % n
		var s: Sprite2D = slice_pool[idx]

		if kept < new_active:
			var pos_idx: int = positions.size() - 1 - kept * capture_interval_frames
			if pos_idx < 0:
				# 预测轨迹不够长，按隐藏处理
				if s.visible or s.texture != null or slot_indices[idx] >= 0:
					s.texture = null
					s.visible = false
					slot_indices[idx] = -1
				continue

			# 对应输入槽的 Sprite2D 快照
			var input_idx: int = (input_start + pos_idx) % cap
			var rec: Recording = ps.slots[input_idx]
			if not _copy_sprite_state(s, rec):
				s.texture = null
				s.visible = false
				slot_indices[idx] = -1
				continue

			_teleport_slice(s, positions[pos_idx])
			s.visible = true
			s.reset_physics_interpolation()

			# alpha：越老越淡
			var age_frames: int = (kept + 1) * capture_interval_frames
			var age_ratio: float = clamp(float(age_frames) / float(life_frames), 0.0, 1.0)
			s.modulate = Color(slice_color, lerp(start_alpha, end_alpha, age_ratio))

			slot_indices[idx] = input_idx
			kept += 1
		else:
			if s.visible or s.texture != null or slot_indices[idx] >= 0:
				s.texture = null
				s.visible = false
				slot_indices[idx] = -1

	total_captured = kept
	_cached_active = new_active
	_pending_pull_back = false


# 旧版：整体水平平移（predictor 不可用时回退）
func _apply_pull_back_legacy() -> void:
	var pull_back_x: float = group.preview_body.global_position.x - _old_preview_pos.x
	var n: int = slice_pool.size()
	var new_active: int = _pull_back_new_active
	var ps: PreviewSystem = group.preview_system

	var kept: int = 0
	var life_frames: int = maxi(new_active * capture_interval_frames, 1)

	# 从 newest 到 oldest 处理：保留 new_active 个在新窗口内的有效切片，其余隐藏
	for i: int in range(slice_pool.size()):
		var idx: int = (write_idx - 1 - i + n) % n
		var s: Sprite2D = slice_pool[idx]

		if kept < new_active and slot_indices[idx] >= 0:
			var target_slot: int = slot_indices[idx]
			if ps != null and not _is_in_window(target_slot, ps.read_head, ps.write_head, ps.capacity):
				# 不在新窗口内，按隐藏处理
				s.texture = null
				s.visible = false
				slot_indices[idx] = -1
				continue

			var pos: Vector2 = s.global_position
			pos.x += pull_back_x
			_teleport_slice(s, pos)
			s.visible = true
			s.reset_physics_interpolation()

			# 设置 alpha：按当前 write_head 计算年龄
			if ps != null:
				var age_frames: int = (ps.write_head - target_slot + ps.capacity) % ps.capacity
				var age_ratio: float = clamp(float(age_frames) / float(life_frames), 0.0, 1.0)
				s.modulate.a = lerp(start_alpha, end_alpha, age_ratio)
			else:
				s.modulate.a = start_alpha

			kept += 1
		else:
			if s.visible or s.texture != null or slot_indices[idx] >= 0:
				s.texture = null
				s.visible = false
				slot_indices[idx] = -1

	total_captured = kept
	_cached_active = new_active
	_pending_pull_back = false


# 重置整个对象池
func _reset_buffer() -> void:
	for i: int in range(slice_pool.size()):
		var s: Sprite2D = slice_pool[i]
		s.texture = null
		s.visible = false
		s.reset_physics_interpolation()
		slot_indices[i] = -1
	write_idx = 0
	total_captured = 0
	_frame_counter = 0
	_cached_active = 0
	# 快速切换时强制结束动画状态，防止残留
	_returning = false
	_pending_pull_back = false
	_return_frame_count = 0
	# 若当前仍有正延迟，重新计算 active 数量，避免动画结束后切片系统失效
	if group != null and group.delay_time > 0.0:
		_cached_active = _compute_active(group.delay_time)


func _hide_all_slices() -> void:
	for s: Sprite2D in slice_pool:
		s.visible = false


## 为通用延迟调节控制器提供当前可命中的切片图像。
func get_visible_delay_slices() -> Array[Sprite2D]:
	var visible_slices: Array[Sprite2D] = []
	for slice: Sprite2D in slice_pool:
		if slice.visible:
			visible_slices.append(slice)
	return visible_slices


func _count_visible_slices() -> int:
	var count: int = 0
	for s: Sprite2D in slice_pool:
		if s.visible:
			count += 1
	return count


# 启动归零动画：所有可见切片同时向 body 飞去
func _start_return_to_zero() -> void:
	_returning = true
	_reset_on_finish = true
	_return_frame_count = 0
	var remaining: int = _count_visible_slices()
	if remaining <= 0:
		_reset_buffer()
		_returning = false
		return
	# 不再递归，交给 _physics_process 统一处理


func _physics_process(_delta: float) -> void:
	if group == null or group.body == null or group.preview_body == null or pool_node == null:
		return

	# 归零动画期间：所有可见切片同时向 body 快速飞去（一次性，限时 RETURN_MAX_FRAMES 帧）
	if _returning:
		var body_pos: Vector2 = group.body.global_position
		var fly_speed: float = 20.0       # lerp 系数，越大越快

		for s: Sprite2D in slice_pool:
			if not s.visible:
				continue
			var offset: Vector2 = body_pos - s.global_position
			s.global_position += offset * min(fly_speed * _delta, 1.0)

		_return_frame_count += 1
		if _return_frame_count >= RETURN_MAX_FRAMES:
			_returning = false
			if _reset_on_finish:
				_reset_buffer()
		return

	# 延迟减小：优先处理拉回，本帧不再采样/更新
	if _pending_pull_back:
		_apply_pull_back()
		_update_alpha()
		return

	# 无延迟时不工作
	if group.delay_time <= 0.0:
		_hide_all_slices()
		return

	_frame_counter += 1
	if _frame_counter >= capture_interval_frames:
		_frame_counter = 0
		_capture_frame()

	_update_slices()


# 采样：从 PreviewSystem.slots 读取历史位置与 Sprite2D 快照
func _capture_frame() -> void:
	var ps: PreviewSystem = group.preview_system
	if ps == null or ps.write_head < 0:
		return

	var s: Sprite2D = slice_pool[write_idx]

	# 直接取当前 write_head 对应的记录
	var slot_idx: int = ps.write_head
	var slot: Recording = ps.slots[slot_idx] if slot_idx >= 0 and slot_idx < ps.slots.size() else null

	if not _copy_sprite_state(s, slot):
		s.texture = null
		s.visible = false
		slot_indices[write_idx] = -1
		return
	s.modulate = Color(slice_color, start_alpha)
	_teleport_slice(s, slot.pos)
	s.visible = true
	s.reset_physics_interpolation()

	slot_indices[write_idx] = slot_idx

	write_idx = (write_idx + 1) % slice_pool.size()
	total_captured += 1


# 根据当前 active 数量显示切片，超出或不合法的隐藏
func _update_slices() -> void:
	var ps: PreviewSystem = group.preview_system
	if ps == null or ps.write_head < 0 or ps.read_head < 0 or _cached_active <= 0:
		_hide_all_slices()
		return

	var active: int = _cached_active
	var shown: int = 0
	var n: int = slice_pool.size()
	var limit: int = mini(total_captured, n)
	var should_show: Array[bool] = []
	should_show.resize(n)

	for i: int in range(limit):
		if shown >= active:
			break
		var tex_idx: int = (write_idx - 1 - i + n) % n
		var s: Sprite2D = slice_pool[tex_idx]

		if s.texture == null:
			continue

		var target_slot: int = slot_indices[tex_idx]
		if not _is_in_window(target_slot, ps.read_head, ps.write_head, ps.capacity):
			continue

		should_show[tex_idx] = true
		shown += 1

	for i: int in range(n):
		var s: Sprite2D = slice_pool[i]
		if s.visible != should_show[i]:
			s.visible = should_show[i]
			if s.visible:
				s.reset_physics_interpolation()

	current_active = shown
	_update_alpha()


func _teleport_slice(slice: Sprite2D, new_position: Vector2) -> void:
	slice.global_position = new_position
	slice.reset_physics_interpolation()


func _update_alpha() -> void:
	var ps: PreviewSystem = group.preview_system
	if ps == null or _cached_active <= 0:
		return

	var active: int = _cached_active
	var life_frames: int = maxi(active * capture_interval_frames, 1)
	var shown: int = 0
	var n: int = slice_pool.size()
	var limit: int = mini(total_captured, n)
	for i: int in range(limit):
		if shown >= active:
			break
		var tex_idx: int = (write_idx - 1 - i + n) % n
		var s: Sprite2D = slice_pool[tex_idx]
		if s.texture == null or not s.visible:
			continue
		var target_slot: int = slot_indices[tex_idx]
		if not _is_in_window(target_slot, ps.read_head, ps.write_head, ps.capacity):
			continue
		var age_frames: int = (ps.write_head - target_slot + ps.capacity) % ps.capacity
		var age_ratio: float = clamp(float(age_frames) / float(life_frames), 0.0, 1.0)
		s.modulate.a = lerp(start_alpha, end_alpha, age_ratio)
		shown += 1


func _is_in_window(slot_idx: int, read_head: int, write_head: int, capacity: int) -> bool:
	if capacity <= 0:
		return false
	if write_head >= read_head:
		return slot_idx >= read_head and slot_idx <= write_head
	else:
		return slot_idx >= read_head or slot_idx <= write_head
