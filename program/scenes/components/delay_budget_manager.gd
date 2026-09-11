class_name DelayBudgetManager
extends Node

signal delay_load_changed(used: float, capacity: float)
signal delay_energy_changed(current: float, maximum: float)

## 延迟负载限制“同时维持多少时间偏移”；自然延迟不占负载。
@export_range(0.0, 3.0, 0.01) var total_capacity: float = 1.0
@export_range(0.01, 30.0, 0.01) var maximum_energy: float = 1.0
## 按游戏逻辑时间恢复；默认 100 TPS 下每帧恢复约 0.01。
@export_range(0.0, 30.0, 0.01) var energy_regeneration_per_second: float = 1.0
@export_range(0.0, 1.0, 0.01) var canceled_action_refund_ratio: float = 0.5
## 结算反馈使用真实时间，思考时间暂停时也能正常显示和消失。
@export_range(0.1, 5.0, 0.1) var rejection_feedback_seconds: float = 1.5

var current_energy: float = 1.0

var _controllers: Array[Node] = []
var _pending_order: Array[Node] = []
var _pending_requests: Dictionary[int, float] = {}
var _feedback_text: String = ""
var _feedback_expires_msec: int = 0
var _authority: WorldTimeAuthority
var _settling_requests: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("delay_budget_manager")
	_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	_apply_permanent_progression()
	current_energy = maximum_energy
	_register_existing_controllers.call_deferred()


func _process(delta: float) -> void:
	# 暂停、思考时间、顿帧和胜利界面都不提供免费回能时间。
	if get_tree().paused or current_energy >= maximum_energy:
		return
	var old_energy: float = current_energy
	current_energy = _quantize(minf(
		current_energy + maxf(energy_regeneration_per_second, 0.0) * maxf(delta, 0.0),
		maximum_energy
	))
	if not is_equal_approx(old_energy, current_energy):
		delay_energy_changed.emit(current_energy, maximum_energy)


func _apply_permanent_progression() -> void:
	var progression: Node = get_node_or_null("/root/DelayProgression")
	if progression == null:
		return
	total_capacity = clampf(
		float(progression.get("delay_load_capacity")), 0.0, 3.0)
	maximum_energy = maxf(float(progression.get("delay_energy_capacity")), 0.01)
	var load_callback: Callable = Callable(self, "_on_progression_load_capacity_changed")
	var energy_callback: Callable = Callable(self, "_on_progression_energy_capacity_changed")
	if progression.has_signal(&"delay_load_capacity_changed") \
			and not progression.is_connected(&"delay_load_capacity_changed", load_callback):
		progression.connect(&"delay_load_capacity_changed", load_callback)
	if progression.has_signal(&"delay_energy_capacity_changed") \
			and not progression.is_connected(&"delay_energy_capacity_changed", energy_callback):
		progression.connect(&"delay_energy_capacity_changed", energy_callback)


func _on_progression_load_capacity_changed(value: float) -> void:
	total_capacity = clampf(_quantize(value), 0.0, 3.0)
	delay_load_changed.emit(get_used_delay(), total_capacity)


func _on_progression_energy_capacity_changed(value: float) -> void:
	maximum_energy = maxf(_quantize(value), 0.01)
	current_energy = minf(current_energy, maximum_energy)
	delay_energy_changed.emit(current_energy, maximum_energy)


func _register_existing_controllers() -> void:
	for controller: Node in get_tree().get_nodes_in_group("delay_controllers"):
		register_controller(controller)


func register_controller(controller: Node) -> void:
	if controller == null or not is_instance_valid(controller):
		return
	_cleanup_controllers()
	if not _controllers.has(controller):
		_controllers.append(controller)
	if controller.has_method("set_delay_request_admission"):
		controller.call(
			"set_delay_request_admission",
			self,
			Callable(self, "try_reserve_delay")
		)
	# 玩家死亡重开本轮时，能量和未提交方案也必须一起回到本轮初始状态。
	if controller.has_signal(&"player_respawned"):
		var respawn_callback: Callable = Callable(self, "_on_player_respawned")
		if not controller.is_connected(&"player_respawned", respawn_callback):
			controller.connect(&"player_respawned", respawn_callback)


func unregister_controller(controller: Node) -> void:
	cancel_pending_request(controller)
	_controllers.erase(controller)
	if controller != null and is_instance_valid(controller) \
			and controller.has_method("clear_delay_request_admission"):
		controller.call("clear_delay_request_admission", self)
	delay_load_changed.emit(get_used_delay(), total_capacity)


func _on_player_respawned() -> void:
	_pending_order.clear()
	_pending_requests.clear()
	current_energy = maximum_energy
	clear_rejection_feedback()
	delay_load_changed.emit(get_used_delay(), total_capacity)
	delay_energy_changed.emit(current_energy, maximum_energy)


## 思考时间内只登记目标与首次选择顺序；资源在退出思考时间时统一结算。
## 玩家专属的即时快捷键仍可走同一入口，并立即得到部分结算结果。
func try_reserve_delay(controller: Node, requested_delay: float) -> Dictionary:
	register_controller(controller)
	var quantized_delay: float = _quantize(requested_delay)
	if _settling_requests:
		return {"accepted": true, "delay": quantized_delay}
	if _is_accepting_thinking_adjustments():
		_queue_request(controller, quantized_delay)
		clear_rejection_feedback()
		return {"accepted": true, "delay": quantized_delay}
	return _settle_immediate_request(controller, quantized_delay)


func _queue_request(controller: Node, requested_delay: float) -> void:
	var instance_id: int = controller.get_instance_id()
	if not _pending_requests.has(instance_id):
		_pending_order.append(controller)
	_pending_requests[instance_id] = requested_delay


func cancel_pending_request(controller: Node) -> void:
	if controller == null:
		return
	_pending_requests.erase(controller.get_instance_id())
	_pending_order.erase(controller)


## 免费释放先统一生效，再按照首次选中顺序用容量和能量处理新增负载。
func settle_pending_requests() -> void:
	if _pending_order.is_empty():
		return
	_cleanup_controllers()
	_settling_requests = true
	var ordered: Array[Node] = _get_valid_pending_order()
	var settled_values: Dictionary[int, float] = {}
	var energy_spent: Dictionary[int, float] = {}
	var running_load: float = _get_committed_load_total()

	# 第一阶段只处理不花能量的缩短或回归自然值，让释放出的容量可供本次结算使用。
	for controller: Node in ordered:
		var requested: float = _pending_requests[controller.get_instance_id()]
		var current: float = _get_committed_setting(controller)
		if _get_change_energy_cost(controller, current, requested) > 0.0001:
			continue
		running_load -= _get_load_cost(controller, current)
		settled_values[controller.get_instance_id()] = requested
		running_load += _get_load_cost(controller, requested)
		energy_spent[controller.get_instance_id()] = 0.0

	var was_partial: bool = false
	var partial_delay: float = 0.0
	for controller: Node in ordered:
		var instance_id: int = controller.get_instance_id()
		if settled_values.has(instance_id):
			continue
		var requested: float = _pending_requests[instance_id]
		var current: float = _get_committed_setting(controller)
		var current_load: float = _get_load_cost(controller, current)
		running_load = maxf(running_load - current_load, 0.0)
		var maximum_target_load: float = maxf(total_capacity - running_load, 0.0)
		var result: Dictionary = _resolve_request(
			controller, requested, maximum_target_load, current_energy)
		var settled: float = _quantize(float(result.get("delay", current)))
		var settled_load: float = maxf(float(result.get("load", current_load)), 0.0)
		var spent: float = _quantize(maxf(float(result.get("energy_spent", 0.0)), 0.0))
		settled_values[instance_id] = settled
		energy_spent[instance_id] = spent
		running_load += settled_load
		current_energy = _quantize(maxf(current_energy - spent, 0.0))
		if not is_equal_approx(settled, requested):
			was_partial = true
			partial_delay = settled

	for controller: Node in ordered:
		var instance_id: int = controller.get_instance_id()
		if not settled_values.has(instance_id):
			continue
		var settled: float = settled_values[instance_id]
		controller.call("apply_settled_delay_request", settled)
		var spent: float = energy_spent.get(instance_id, 0.0)
		if spent > 0.0 and controller.has_method("on_delay_energy_spent"):
			controller.call("on_delay_energy_spent", spent, settled)

	_pending_order.clear()
	_pending_requests.clear()
	_settling_requests = false
	if was_partial:
		_set_feedback("资源不足 · 实际 %.2fs" % partial_delay)
	else:
		clear_rejection_feedback()
	delay_load_changed.emit(running_load, total_capacity)
	delay_energy_changed.emit(current_energy, maximum_energy)


func _settle_immediate_request(controller: Node, requested_delay: float) -> Dictionary:
	var current: float = _get_committed_setting(controller)
	var load_without_target: float = maxf(
		_get_committed_load_total() - _get_load_cost(controller, current), 0.0)
	var maximum_target_load: float = maxf(total_capacity - load_without_target, 0.0)
	var result: Dictionary = _resolve_request(
		controller, requested_delay, maximum_target_load, current_energy)
	var settled: float = _quantize(float(result.get("delay", current)))
	var spent: float = _quantize(maxf(float(result.get("energy_spent", 0.0)), 0.0))
	current_energy = _quantize(maxf(current_energy - spent, 0.0))
	if spent > 0.0 and controller.has_method("on_delay_energy_spent"):
		controller.call("on_delay_energy_spent", spent, settled)
	if not is_equal_approx(settled, requested_delay):
		_set_feedback("资源不足 · 实际 %.2fs" % settled)
	else:
		clear_rejection_feedback()
	delay_load_changed.emit(
		load_without_target + _get_load_cost(controller, settled), total_capacity)
	delay_energy_changed.emit(current_energy, maximum_energy)
	return {"accepted": not is_equal_approx(settled, current), "delay": settled}


func _resolve_request(
	controller: Node,
	requested_delay: float,
	maximum_target_load: float,
	available_energy: float
) -> Dictionary:
	if controller.has_method("resolve_delay_request_with_resources"):
		return controller.call(
			"resolve_delay_request_with_resources",
			requested_delay,
			maximum_target_load,
			available_energy
		) as Dictionary
	return {
		"delay": requested_delay,
		"load": maxf(requested_delay, 0.0),
		"energy_spent": 0.0,
	}


## 取消已经提交的动作负延迟时返还能量；上限之外的部分不会储存。
func refund_canceled_action_energy(energy_spent_for_action: float) -> float:
	var requested_refund: float = maxf(energy_spent_for_action, 0.0) \
		* clampf(canceled_action_refund_ratio, 0.0, 1.0)
	var old_energy: float = current_energy
	current_energy = _quantize(minf(current_energy + requested_refund, maximum_energy))
	var actual_refund: float = current_energy - old_energy
	if actual_refund > 0.0:
		delay_energy_changed.emit(current_energy, maximum_energy)
	return actual_refund


func get_used_delay() -> float:
	_cleanup_controllers()
	return _get_committed_load_total()


func get_projected_used_delay() -> float:
	var projected: float = get_used_delay()
	for controller: Node in _get_valid_pending_order():
		var current: float = _get_committed_setting(controller)
		var requested: float = _pending_requests[controller.get_instance_id()]
		projected -= _get_load_cost(controller, current)
		projected += _get_load_cost(controller, requested)
	return maxf(projected, 0.0)


func get_displayed_used_delay() -> float:
	return get_projected_used_delay() if _is_accepting_thinking_adjustments() else get_used_delay()


func get_available_delay() -> float:
	return maxf(total_capacity - get_used_delay(), 0.0)


func get_feedback_text() -> String:
	if Time.get_ticks_msec() >= _feedback_expires_msec:
		clear_rejection_feedback()
	return _feedback_text


func clear_rejection_feedback() -> void:
	_feedback_text = ""
	_feedback_expires_msec = 0


func _set_feedback(message: String) -> void:
	_feedback_text = message
	_feedback_expires_msec = Time.get_ticks_msec() \
		+ roundi(rejection_feedback_seconds * 1000.0)


func get_registered_controller_count() -> int:
	_cleanup_controllers()
	return _controllers.size()


func set_current_energy_for_test(value: float) -> void:
	current_energy = _quantize(clampf(value, 0.0, maximum_energy))
	delay_energy_changed.emit(current_energy, maximum_energy)


func _cleanup_controllers() -> void:
	for index: int in range(_controllers.size() - 1, -1, -1):
		if is_instance_valid(_controllers[index]):
			continue
		_controllers.remove_at(index)
	for index: int in range(_pending_order.size() - 1, -1, -1):
		if is_instance_valid(_pending_order[index]):
			continue
		_pending_order.remove_at(index)


func _get_valid_pending_order() -> Array[Node]:
	var result: Array[Node] = []
	for controller: Node in _pending_order:
		if controller != null and is_instance_valid(controller) \
				and _pending_requests.has(controller.get_instance_id()):
			result.append(controller)
	return result


func _get_committed_load_total() -> float:
	var total: float = 0.0
	for controller: Node in _controllers:
		if controller != null and is_instance_valid(controller):
			total += _get_load_cost(controller, _get_committed_setting(controller))
	return _quantize(total)


func _get_committed_setting(controller: Node) -> float:
	if controller.has_method("get_committed_delay_setting"):
		return float(controller.call("get_committed_delay_setting"))
	return float(controller.get("delay_time"))


func _get_load_cost(controller: Node, delay_setting: float) -> float:
	if controller.has_method("get_delay_load_cost"):
		return maxf(float(controller.call("get_delay_load_cost", delay_setting)), 0.0)
	if controller.has_method("get_delay_energy_cost"):
		return maxf(float(controller.call("get_delay_energy_cost", delay_setting)), 0.0)
	return maxf(delay_setting, 0.0)


func _get_change_energy_cost(controller: Node, current: float, requested: float) -> float:
	if controller.has_method("get_delay_change_energy_cost"):
		return maxf(float(controller.call(
			"get_delay_change_energy_cost", current, requested)), 0.0)
	return maxf(_get_load_cost(controller, requested) - _get_load_cost(controller, current), 0.0)


func _is_accepting_thinking_adjustments() -> bool:
	if _authority == null or not is_instance_valid(_authority):
		_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	return _authority != null and _authority.is_accepting_thinking_time_adjustments()


func _quantize(value: float) -> float:
	return roundf(value * 100.0) / 100.0
