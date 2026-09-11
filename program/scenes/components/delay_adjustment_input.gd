class_name DelayAdjustmentInput
extends Node

## 所有可延迟对象共用的输入规则：快捷档位、Q/E 方向极值、滚轮加速和重叠目标仲裁。
## 具体对象只负责提供当前延迟、接收请求，以及判断鼠标是否指中自己的可视部分。
var adjustment_priority: int = 0
var shortcuts_require_thinking_time: bool = false

var _target: Node
var _authority: WorldTimeAuthority
var _hover_test: Callable
var _outside_zero_callback: Callable
var _tuning: Resource
var _step_seconds: float = 0.01
var _rapid_scroll_interval: float = 0.15
var _step_reset_interval: float = 0.2
var _snap_after_steps: int = 3
var _burst_steps: int = 0
var _last_scroll_msec: int = -1
var _active_step_seconds: float = 0.01


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("delay_adjustment_inputs")


## target 需公开 delay_time、max_delay_time、get_requested_delay() 与 request_delay_change()。
func configure(
	target: Node,
	authority: WorldTimeAuthority,
	hover_test: Callable,
	require_thinking_time_for_shortcuts: bool,
	priority: int,
	tuning: Resource,
	outside_zero_callback: Callable = Callable()
) -> void:
	_target = target
	_authority = authority
	_hover_test = hover_test
	shortcuts_require_thinking_time = require_thinking_time_for_shortcuts
	adjustment_priority = priority
	_tuning = tuning
	if _tuning != null:
		_step_seconds = clampf(float(_tuning.get("step_seconds")), 0.001, 1.0)
		_rapid_scroll_interval = maxf(float(_tuning.get("rapid_scroll_interval")), 0.01)
		_step_reset_interval = maxf(float(_tuning.get("step_reset_interval")), 0.01)
		_snap_after_steps = maxi(int(_tuning.get("snap_after_steps")), 1)
	_outside_zero_callback = outside_zero_callback
	reset_scroll_state()


func _process(_delta: float) -> void:
	reset_scroll_step_if_idle()


func _unhandled_input(event: InputEvent) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	if event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey
		if key_event.pressed and not key_event.is_echo():
			_handle_quick_shortcut(key_event)
		return
	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event as InputEventMouseButton
		if mouse_event.pressed:
			_handle_scroll_event(mouse_event)


func _handle_quick_shortcut(event: InputEventKey) -> void:
	var is_thinking: bool = is_thinking_time_active()
	if shortcuts_require_thinking_time and not is_thinking:
		return
	var mouse_position: Vector2 = get_mouse_world_position()
	if not is_mouse_in_range_at(mouse_position) or not _is_highest_priority_at(mouse_position):
		return
	var target_delay: float = shortcut_delay_for_key(event.keycode)
	# Q 可以返回动作级负延迟；其他未知键仍以 -1 作为“无快捷值”哨兵。
	if target_delay < 0.0 and event.keycode != KEY_Q:
		return
	if is_zero_approx(target_delay) and is_zero_approx(_get_requested_delay()):
		return
	if not _submit_delay_request(target_delay):
		return
	if is_zero_approx(target_delay) and not is_thinking and _outside_zero_callback.is_valid():
		_outside_zero_callback.call()
	get_viewport().set_input_as_handled()


func _handle_scroll_event(event: InputEventMouseButton) -> void:
	if not is_thinking_time_active():
		return
	var direction: int = scroll_direction_for_button(event.button_index)
	if direction == 0:
		return
	var mouse_position: Vector2 = get_mouse_world_position()
	if not is_mouse_in_range_at(mouse_position) or not _is_highest_priority_at(mouse_position):
		return
	if request_scroll_adjustment(direction):
		get_viewport().set_input_as_handled()


## 快速滚动逐级切换 0.01 -> 0.1 -> 1；最终值由对象公开的正负上下限钳制。
func request_scroll_adjustment(direction: int, now_msec: int = -1) -> bool:
	if direction == 0 or _target == null or not is_instance_valid(_target):
		return false
	var target_delay: float = calculate_scroll_target(
		_get_requested_delay(), direction, now_msec
	)
	return _submit_delay_request(target_delay)


## 纯输入算法入口也供回归测试比较玩家与敌人是否保持同一组滚轮语义。
func calculate_scroll_target(base_delay: float, direction: int, now_msec: int = -1) -> float:
	var current_msec: int = Time.get_ticks_msec() if now_msec < 0 else now_msec
	if _last_scroll_msec < 0 \
			or current_msec - _last_scroll_msec > int(_rapid_scroll_interval * 1000.0):
		_burst_steps = 0
	_last_scroll_msec = current_msec
	_burst_steps += 1

	var target_delay: float = base_delay + float(direction) * _active_step_seconds
	if _burst_steps >= _snap_after_steps:
		var next_step: float = minf(_active_step_seconds * 10.0, 100.0)
		if next_step > _active_step_seconds:
			_active_step_seconds = next_step
			target_delay = snap_to_next_step(base_delay, _active_step_seconds, direction)
		_burst_steps = 0
	return clampf(target_delay, _get_min_delay(), _get_max_delay())


## 停止滚动后恢复最细步长；传入时间参数可进行不依赖真实时钟的无头测试。
func reset_scroll_step_if_idle(now_msec: int = -1) -> void:
	if _last_scroll_msec < 0:
		return
	var current_msec: int = Time.get_ticks_msec() if now_msec < 0 else now_msec
	if current_msec - _last_scroll_msec <= int(_step_reset_interval * 1000.0):
		return
	reset_scroll_state()


func reset_scroll_state() -> void:
	_burst_steps = 0
	_last_scroll_msec = -1
	_active_step_seconds = _step_seconds


## 向上取前方档位、向下取后方档位，避免快速滚动时反向跳动。
func snap_to_next_step(value: float, target_step: float, direction: int) -> float:
	const EPSILON: float = 0.00001
	if direction > 0:
		return ceilf((value + EPSILON) / target_step) * target_step
	return floorf((value - EPSILON) / target_step) * target_step


func quick_delay_for_key(keycode: Key) -> float:
	match keycode:
		KEY_1:
			return 1.0
		KEY_2:
			return 2.0
		KEY_3:
			return 3.0
		KEY_R:
			return 0.0
	return -1.0


## 思考时间内 Q/E 作用于鼠标当前目标：Q 取该对象当前允许的负向极值，E 取正向极值。
## 1 / 2 / 3 始终只是正延迟秒数，不会因为玩家正在蓄力而改变含义。
func shortcut_delay_for_key(keycode: Key) -> float:
	if keycode == KEY_Q:
		return _get_min_delay()
	if keycode == KEY_E:
		return _get_max_delay()
	return quick_delay_for_key(keycode)


func scroll_direction_for_button(button_index: MouseButton) -> int:
	if button_index == MOUSE_BUTTON_WHEEL_UP:
		return 1
	if button_index == MOUSE_BUTTON_WHEEL_DOWN:
		return -1
	return 0


func is_mouse_in_range() -> bool:
	return is_mouse_in_range_at(get_mouse_world_position())


func is_mouse_in_range_at(mouse_position: Vector2) -> bool:
	return _hover_test.is_valid() and bool(_hover_test.call(mouse_position))


func get_mouse_world_position() -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() \
		* get_viewport().get_mouse_position()


func is_thinking_time_active() -> bool:
	if _authority == null or not is_instance_valid(_authority):
		_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	return _authority != null and _authority.is_in_thinking_time()


func get_active_step_seconds() -> float:
	return _active_step_seconds


func get_tuning() -> Resource:
	return _tuning


func _is_highest_priority_at(mouse_position: Vector2) -> bool:
	for node: Node in get_tree().get_nodes_in_group("delay_adjustment_inputs"):
		if node == self or not node.has_method("is_mouse_in_range_at"):
			continue
		var other_priority: int = int(node.get("adjustment_priority"))
		if other_priority > adjustment_priority \
				and bool(node.call("is_mouse_in_range_at", mouse_position)):
			return false
	return true


func _submit_delay_request(target_delay: float) -> bool:
	if not _target.has_method("request_delay_change"):
		return false
	var clamped_delay: float = clampf(target_delay, _get_min_delay(), _get_max_delay())
	var result: Variant = _target.call("request_delay_change", clamped_delay)
	return not (result is bool and not bool(result))


func _get_requested_delay() -> float:
	if _target.has_method("get_requested_delay"):
		return float(_target.call("get_requested_delay"))
	return _get_current_delay()


func _get_current_delay() -> float:
	return float(_target.get("delay_time")) if _target != null else 0.0


func _get_max_delay() -> float:
	if _target != null and _target.has_method("get_effective_max_delay_time"):
		return float(_target.call("get_effective_max_delay_time"))
	return float(_target.get("max_delay_time")) if _target != null else 0.0


func _get_min_delay() -> float:
	if _target != null and _target.has_method("get_effective_min_delay_time"):
		return float(_target.call("get_effective_min_delay_time"))
	return 0.0
