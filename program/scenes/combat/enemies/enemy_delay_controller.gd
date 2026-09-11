class_name EnemyDelayController
extends "res://scenes/components/command_replay_delay_controller.gd"

var _reserved_action_acceleration: float = 0.0
var _pending_action_acceleration: float = 0.0
var _has_pending_action_acceleration: bool = false
var _regular_delay_before_action: float = -1.0
var _action_energy_spent: float = 0.0


## 敌人只声明自己的语义分组；命令帧回放、三体生命周期和软重预测来自公共适配层。
func _ready() -> void:
	add_to_group("enemy_delay_controller")
	super._ready()


func _initialize_controller() -> void:
	super._initialize_controller()
	if body == null or not body.has_signal(&"delay_action_ended"):
		return
	var callback: Callable = Callable(self, "_on_delay_action_ended")
	if not body.is_connected(&"delay_action_ended", callback):
		body.connect(&"delay_action_ended", callback)


func request_delay_change(new_delay: float) -> bool:
	if new_delay >= 0.0:
		if _reserved_action_acceleration > 0.0:
			return false
		var accepted: bool = super.request_delay_change(new_delay)
		if accepted:
			_has_pending_action_acceleration = false
			_pending_action_acceleration = 0.0
		return accepted
	if not _can_accept_delay_request():
		return false
	# 正延迟必须先按普通时间线独立归零，不能在一次负延迟申请里免费跳过。
	if get_committed_delay_setting() > 0.0001:
		return false
	var action_actor: BaseActor = _get_action_actor()
	if not _is_acceleratable(action_actor):
		return false
	var available_acceleration: float = _get_available_action_acceleration_load()
	if available_acceleration <= 0.0001:
		return false
	var requested_seconds: float = minf(
		absf(new_delay),
		minf(_get_acceleratable_seconds(action_actor), available_acceleration)
	)
	requested_seconds = maxf(requested_seconds, _reserved_action_acceleration)
	var admission: Dictionary = _request_delay_admission(-requested_seconds)
	if not bool(admission.get("accepted", false)):
		return false
	var admitted_delay: float = float(admission.get("delay", -requested_seconds))
	if admitted_delay >= 0.0:
		return false
	_pending_delay = -1.0
	_pending_action_acceleration = absf(admitted_delay)
	_has_pending_action_acceleration = true
	_prediction_request_dirty = true
	return true


func get_effective_min_delay_time() -> float:
	var can_enter_negative: bool = get_committed_delay_setting() <= 0.0001 \
		and (_is_acceleratable(_get_action_actor()) \
			or _reserved_action_acceleration > 0.0 \
			or _has_pending_action_acceleration)
	return -_get_available_action_acceleration_load() if can_enter_negative else 0.0


## 敌人的动作加速与玩家一致，只能使用所有持续延迟之外尚未占用的负载。
func _get_available_action_acceleration_load() -> float:
	# get_available_delay() 只基于已提交负载，待提交请求不能重复算成新的剩余容量。
	var current_acceleration: float = _reserved_action_acceleration
	var additional_capacity: float = get_effective_max_delay_time()
	if _delay_admission_owner != null and is_instance_valid(_delay_admission_owner) \
			and _delay_admission_owner.has_method("get_available_delay"):
		additional_capacity = maxf(float(
			_delay_admission_owner.call("get_available_delay")), 0.0)
	return minf(
		current_acceleration + additional_capacity,
		get_effective_max_delay_time()
	)


func get_requested_delay() -> float:
	if _has_pending_action_acceleration:
		return -_pending_action_acceleration
	if _reserved_action_acceleration > 0.0:
		return -_reserved_action_acceleration
	return super.get_requested_delay()


func get_committed_delay_setting() -> float:
	return -_reserved_action_acceleration if _reserved_action_acceleration > 0.0 \
		else delay_time


func get_delay_setting_side(delay_setting: float) -> int:
	return -2 if delay_setting < 0.0 else super.get_delay_setting_side(delay_setting)


func get_delay_load_cost(requested_delay: float) -> float:
	if requested_delay < 0.0:
		return absf(requested_delay)
	return maxf(requested_delay, 0.0)


func get_delay_change_energy_cost(current_delay: float, requested_delay: float) -> float:
	if requested_delay < 0.0:
		var current_acceleration: float = absf(current_delay) if current_delay < 0.0 else 0.0
		return maxf(absf(requested_delay) - current_acceleration, 0.0)
	return super.get_delay_change_energy_cost(current_delay, requested_delay)


func resolve_delay_request_with_resources(
	requested_delay: float,
	maximum_target_load: float,
	available_energy: float
) -> Dictionary:
	if requested_delay >= 0.0:
		return super.resolve_delay_request_with_resources(
			requested_delay, maximum_target_load, available_energy)
	var current_acceleration: float = _reserved_action_acceleration
	var desired_acceleration: float = maxf(absf(requested_delay), current_acceleration)
	var acceleration_room: float = maxf(maximum_target_load, 0.0)
	var desired_increase: float = maxf(desired_acceleration - current_acceleration, 0.0)
	var granted_increase: float = minf(
		desired_increase,
		minf(
			maxf(acceleration_room - current_acceleration, 0.0),
			maxf(available_energy, 0.0)
		)
	)
	var final_acceleration: float = current_acceleration + granted_increase
	if is_zero_approx(final_acceleration):
		return {"delay": delay_time, "load": delay_time, "energy_spent": 0.0}
	return {
		"delay": -final_acceleration,
		"load": final_acceleration,
		"energy_spent": granted_increase,
	}


func apply_settled_delay_request(settled_delay: float) -> void:
	if settled_delay < 0.0:
		_pending_delay = -1.0
		_pending_action_acceleration = absf(settled_delay)
		_has_pending_action_acceleration = true
		_prediction_request_dirty = true
		return
	_has_pending_action_acceleration = false
	_pending_action_acceleration = 0.0
	super.apply_settled_delay_request(settled_delay)


func on_delay_energy_spent(amount: float, settled_delay: float) -> void:
	if settled_delay < 0.0:
		_action_energy_spent += maxf(amount, 0.0)


func run_queued_delay_prediction() -> void:
	if _has_pending_action_acceleration:
		_prediction_request_dirty = false
		return
	super.run_queued_delay_prediction()


func commit_thinking_delay_change() -> void:
	if _has_pending_action_acceleration:
		_commit_action_acceleration()
		return
	super.commit_thinking_delay_change()


func _commit_action_acceleration() -> void:
	var action_actor: BaseActor = _get_action_actor()
	if not _is_acceleratable(action_actor) \
			or get_committed_delay_setting() > 0.0001:
		_finish_action_acceleration(true, true)
		return
	if _regular_delay_before_action < 0.0:
		# 负延迟入口已强制要求普通延迟为 0；动作结束后仍恢复到这个已提交值。
		_regular_delay_before_action = delay_time
	var simulation_state: Dictionary = action_actor.capture_simulation_state()
	var target_seconds: float = _pending_action_acceleration
	var additional_seconds: float = maxf(target_seconds - _reserved_action_acceleration, 0.0)
	_has_pending_action_acceleration = false
	_pending_action_acceleration = 0.0
	_apply_delay_change(0.0)
	body.restore_simulation_state(simulation_state)
	_reserved_action_acceleration = target_seconds
	if additional_seconds > 0.0:
		body.call("advance_delay_action_time", additional_seconds)
	if _reserved_action_acceleration > 0.0:
		_sync_preview_to_body(false)
		_sync_predictor_to_body()


func _on_delay_action_ended(successful: bool) -> void:
	if _reserved_action_acceleration <= 0.0 and not _has_pending_action_acceleration:
		return
	_finish_action_acceleration(true, not successful)


func _finish_action_acceleration(restore_regular_delay: bool, canceled: bool) -> void:
	var budget_manager: Node = _delay_admission_owner
	if budget_manager != null and is_instance_valid(budget_manager):
		if budget_manager.has_method("cancel_pending_request"):
			budget_manager.call("cancel_pending_request", self)
		if canceled and _action_energy_spent > 0.0 \
				and budget_manager.has_method("refund_canceled_action_energy"):
			budget_manager.call("refund_canceled_action_energy", _action_energy_spent)
	var regular_delay: float = _get_persistent_regular_delay()
	_reserved_action_acceleration = 0.0
	_pending_action_acceleration = 0.0
	_has_pending_action_acceleration = false
	_action_energy_spent = 0.0
	_regular_delay_before_action = -1.0
	if restore_regular_delay and not is_equal_approx(delay_time, regular_delay):
		_apply_delay_change(regular_delay)


func _get_persistent_regular_delay() -> float:
	if _regular_delay_before_action >= 0.0:
		return _regular_delay_before_action
	return _pending_delay if _pending_delay >= 0.0 else delay_time


func _get_action_actor() -> BaseActor:
	if delay_time > 0.0 and _is_acceleratable(preview_body):
		return preview_body
	return body


func _is_acceleratable(actor: BaseActor) -> bool:
	return actor != null and actor.has_method("is_delay_acceleratable_action_active") \
		and bool(actor.call("is_delay_acceleratable_action_active"))


func _get_acceleratable_seconds(actor: BaseActor) -> float:
	if actor == null or not actor.has_method("get_delay_acceleratable_seconds"):
		return 0.0
	return maxf(float(actor.call("get_delay_acceleratable_seconds")), 0.0)


func on_body_reset() -> void:
	_finish_action_acceleration(false, false)
	super.on_body_reset()


func on_body_defeated() -> void:
	_finish_action_acceleration(false, false)
	super.on_body_defeated()
