class_name DelayControllerBase
extends Node

const DELAY_CONTROL_UI_SCENE: PackedScene = preload("res://scenes/components/delay_control_ui.tscn")
const DEFAULT_ADJUSTMENT_TUNING: Resource = preload("res://resources/delay_adjustment_tuning.tres")

## 可延迟对象共同拥有的最小控制层。
## 本类只管理三体引用、延迟请求、思考时间注册和公共 UI；具体命令由子类适配器解释。
@export_category("Delay")
@export var max_delay_time: float = 3.0
## 对象不受玩家能力影响时本来拥有的延迟；敌人与机关默认为零。
@export_range(0.0, 3.0, 0.01) var natural_delay_time: float = 0.0
@export var adjustment_tuning: Resource = DEFAULT_ADJUSTMENT_TUNING
@export var adjustment_priority: int = 0
@export_range(0.0, 32.0, 0.1) var divergence_position_tolerance: float = 2.0
@export_range(0.0, 200.0, 1.0) var divergence_velocity_tolerance: float = 20.0

@export var delay_time: float = 0.0:
	set(value):
		var clamped_delay: float = clampf(value, 0.0, max_delay_time)
		if Engine.is_editor_hint() or not is_inside_tree() or _setting_delay_internally:
			delay_time = clamped_delay
			return
		request_delay_change(clamped_delay)

var body: BaseActor
var preview_body: BaseActor
var predictor: BaseActor
## 兼容已有诊断脚本；所有新代码统一使用 predictor。
var predictor_body: BaseActor:
	get:
		return predictor
	set(value):
		predictor = value

var last_divergence_reason: StringName = &""
var last_divergence_position_error: float = 0.0
var last_divergence_velocity_error: float = 0.0
var last_divergence_body_position: Vector2 = Vector2.ZERO
var last_divergence_expected_position: Vector2 = Vector2.ZERO

var _authority: WorldTimeAuthority
var _pending_delay: float = -1.0
var _setting_delay_internally: bool = false
var _prediction_request_dirty: bool = false
var _delay_control_ui: DelayControlUi
## 容量等玩法规则通过回调接入；公共延迟模型不依赖具体资源系统。
var _delay_admission_owner: Node
var _delay_request_admission: Callable


## 子类取得自己的本体、预览体和预测体后，只需从这里初始化公共部分。
func initialize_delay_controller(
	authority_body: BaseActor,
	live_preview: BaseActor,
	hidden_predictor: BaseActor
) -> bool:
	body = authority_body
	preview_body = live_preview
	predictor = hidden_predictor
	_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	if body == null or preview_body == null or predictor == null:
		push_error("DelayControllerBase: body, preview_body and predictor are required")
		return false
	add_to_group("delay_controllers")
	_connect_delay_budget_manager()
	for actor: BaseActor in [body, preview_body, predictor]:
		actor.bind_delay_controller(self)
	_configure_replica_roles()
	return true


## 玩法适配器可以限制请求时机，但不需要重复钳制和 pending 状态。
func request_delay_change(new_delay: float) -> bool:
	if not _can_accept_delay_request():
		return false
	var clamped_delay: float = clampf(new_delay, 0.0, get_effective_max_delay_time())
	var admission: Dictionary = _request_delay_admission(clamped_delay)
	if not bool(admission.get("accepted", false)):
		return false
	clamped_delay = clampf(
		float(admission.get("delay", clamped_delay)),
		0.0,
		get_effective_max_delay_time()
	)
	_pending_delay = clamped_delay
	_prediction_request_dirty = true
	_on_delay_request_queued()
	return true


## 容量管理器可在即时请求中返回部分结算值；思考时间内则先原样排队。
func _request_delay_admission(requested_delay: float) -> Dictionary:
	if not _delay_request_admission.is_valid():
		return {"accepted": true, "delay": requested_delay}
	var result: Variant = _delay_request_admission.call(self, requested_delay)
	if result is Dictionary:
		return result as Dictionary
	if result is bool:
		return {"accepted": bool(result), "delay": requested_delay}
	if result is float or result is int:
		return {"accepted": true, "delay": float(result)}
	return {"accepted": false, "delay": get_requested_delay()}


func _can_accept_delay_request() -> bool:
	return true


func _on_delay_request_queued() -> void:
	pass


func set_delay_request_admission(owner: Node, admission: Callable) -> void:
	_delay_admission_owner = owner
	_delay_request_admission = admission


func clear_delay_request_admission(owner: Node) -> void:
	if _delay_admission_owner != owner:
		return
	_delay_admission_owner = null
	_delay_request_admission = Callable()


func _connect_delay_budget_manager() -> void:
	var budget_manager: Node = get_tree().get_first_node_in_group("delay_budget_manager")
	if budget_manager != null and budget_manager.has_method("register_controller"):
		budget_manager.call("register_controller", self)


func _exit_tree() -> void:
	# 弹幕等短生命周期对象离场时立即移除思考时间回调，不能留下 Freed Object。
	if _authority != null and is_instance_valid(_authority) \
			and _authority.has_method("remove_thinking_time_prediction"):
		_authority.call("remove_thinking_time_prediction", self)
	if _delay_admission_owner != null and is_instance_valid(_delay_admission_owner) \
			and _delay_admission_owner.has_method("unregister_controller"):
		_delay_admission_owner.call("unregister_controller", self)


func get_requested_delay() -> float:
	return _pending_delay if _pending_delay >= 0.0 else delay_time


## 已生效值与思考时间待提交值分开，容量管理器据此计算真正新增的负载。
func get_committed_delay_setting() -> float:
	return delay_time


## 运行时误改 max_delay_time 不得越过已经分配的环形容量。
## 扩大窗口应在对象创建前配置，或由适配器显式重建缓冲后再开放新上限。
func get_effective_max_delay_time() -> float:
	var capacity: int = get_delay_buffer_capacity()
	if capacity <= 1:
		return maxf(max_delay_time, 0.0)
	var allocated_seconds: float = float(capacity - 1) / float(DelayTimelineBuffer.BASE_PHYSICS_TPS)
	return minf(maxf(max_delay_time, 0.0), allocated_seconds)


## 普通延迟对象不能设置负值；玩家适配器会在蓄力期间覆盖这个下限。
func get_effective_min_delay_time() -> float:
	return 0.0


## 负载只计算相对自然延迟的偏移；自然状态本身不占用玩家的负载槽。
func get_delay_load_cost(requested_delay: float) -> float:
	var clamped_delay: float = clampf(requested_delay, 0.0, get_effective_max_delay_time())
	return absf(clamped_delay - natural_delay_time)


## 保留旧接口名供现有诊断工具调用；语义现已明确为“延迟负载”而不是蓝条。
func get_delay_energy_cost(requested_delay: float) -> float:
	return get_delay_load_cost(requested_delay)


## 同方向只为新增负载付费；跨过自然值则先免费释放旧负载，再为新方向付费。
func get_delay_change_energy_cost(current_delay: float, requested_delay: float) -> float:
	var current_load: float = get_delay_load_cost(current_delay)
	var requested_load: float = get_delay_load_cost(requested_delay)
	var current_side: int = get_delay_setting_side(current_delay)
	var requested_side: int = get_delay_setting_side(requested_delay)
	if requested_side == 0 or (current_side == requested_side and requested_load <= current_load):
		return 0.0
	if current_side != 0 and requested_side != 0 and current_side != requested_side:
		return requested_load
	return maxf(requested_load - current_load, 0.0)


## 返回目标位于自然值哪一侧；玩家会额外使用 -2 表示动作级负延迟。
func get_delay_setting_side(delay_setting: float) -> int:
	var offset: float = delay_setting - natural_delay_time
	if is_zero_approx(offset):
		return 0
	return 1 if offset > 0.0 else -1


## 将可用容量和能量换算成最终可提交值，支持资源不足时部分结算。
func resolve_delay_request_with_resources(
	requested_delay: float,
	maximum_target_load: float,
	available_energy: float
) -> Dictionary:
	var current_delay: float = get_committed_delay_setting()
	var current_load: float = get_delay_load_cost(current_delay)
	var requested_load: float = get_delay_load_cost(requested_delay)
	var current_side: int = get_delay_setting_side(current_delay)
	var requested_side: int = get_delay_setting_side(requested_delay)
	var same_side: bool = current_side == requested_side or current_side == 0 \
		or requested_side == 0
	var base_load: float = current_load if same_side else 0.0
	if requested_side == 0 or (same_side and requested_load <= current_load):
		return {
			"delay": requested_delay,
			"load": requested_load,
			"energy_spent": 0.0,
		}
	var load_room: float = maxf(maximum_target_load - base_load, 0.0)
	var desired_increase: float = maxf(requested_load - base_load, 0.0)
	var granted_increase: float = minf(
		desired_increase,
		minf(load_room, maxf(available_energy, 0.0))
	)
	var final_load: float = base_load + granted_increase
	return {
		"delay": get_delay_setting_from_load(final_load, requested_delay),
		"load": final_load,
		"energy_spent": granted_increase,
	}


func get_delay_setting_from_load(load: float, requested_delay: float) -> float:
	var side: int = get_delay_setting_side(requested_delay)
	return clampf(
		natural_delay_time + float(side) * maxf(load, 0.0),
		0.0,
		get_effective_max_delay_time()
	)


## 容量管理器在退出思考时间前用最终结算值覆盖预览请求，不会再次进入准入回调。
func apply_settled_delay_request(settled_delay: float) -> void:
	_pending_delay = clampf(settled_delay, 0.0, get_effective_max_delay_time())
	_prediction_request_dirty = true
	_on_delay_request_queued()


## 一次性动作能力可记录本次真实支付的能量；普通延迟对象无需处理。
func on_delay_energy_spent(_amount: float, _settled_delay: float) -> void:
	pass


func get_delay_buffer_capacity() -> int:
	return 0


## 子类提交计算完的数值时绕过公开 setter，避免把提交再次排入队列。
func set_delay_time_immediate(new_delay: float) -> void:
	_setting_delay_internally = true
	delay_time = clampf(new_delay, 0.0, get_effective_max_delay_time())
	_setting_delay_internally = false


func clear_pending_delay_request() -> void:
	_pending_delay = -1.0
	_prediction_request_dirty = false


## 玩家和敌人都通过同一个公共入口注册思考时间任务。
func register_thinking_time_prediction(
	has_work: Callable,
	run_prediction: Callable,
	commit_change: Callable
) -> bool:
	if _authority == null or not is_instance_valid(_authority):
		_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	if _authority == null:
		push_warning("DelayControllerBase: WorldTimeAuthority not found; thinking-time prediction disabled")
		return false
	_authority.configure_thinking_time_prediction(self, has_work, run_prediction, commit_change)
	return true


## 所有单位复用同一个 UI 场景；文字、命中范围、快捷键门槛和减延迟预览由适配器提供。
func create_or_configure_delay_ui(
	ui_parent: Node2D,
	reduction_sample_provider: Callable = Callable()
) -> DelayControlUi:
	if ui_parent == null:
		return null
	_delay_control_ui = ui_parent.get_node_or_null("DelayControlUi") as DelayControlUi
	if _delay_control_ui == null:
		_delay_control_ui = DELAY_CONTROL_UI_SCENE.instantiate() as DelayControlUi
		_delay_control_ui.name = "DelayControlUi"
		_delay_control_ui.configure(
			self,
			_authority,
			Callable(self, "is_mouse_over_delay_visual"),
			delay_shortcuts_require_thinking_time(),
			adjustment_priority,
			adjustment_tuning,
			Callable(self, "on_outside_zero_requested"),
			Callable(self, "get_delay_ui_text"),
			reduction_sample_provider
		)
		ui_parent.add_child(_delay_control_ui)
	else:
		_delay_control_ui.configure(
			self,
			_authority,
			Callable(self, "is_mouse_over_delay_visual"),
			delay_shortcuts_require_thinking_time(),
			adjustment_priority,
			adjustment_tuning,
			Callable(self, "on_outside_zero_requested"),
			Callable(self, "get_delay_ui_text"),
			reduction_sample_provider
		)
	_delay_control_ui.position = get_delay_ui_offset()
	return _delay_control_ui


func delay_shortcuts_require_thinking_time() -> bool:
	return false


func get_delay_ui_offset() -> Vector2:
	return body.get_delay_ui_anchor_offset() if body != null else Vector2.ZERO


func get_delay_ui_text() -> String:
	return "延迟\n%.2fs" % get_requested_delay()


func on_outside_zero_requested() -> void:
	pass


func is_mouse_over_delay_visual(_mouse_position: Vector2) -> bool:
	return false


func get_adjustment_input() -> Node:
	return _delay_control_ui.get_adjustment_input() if _delay_control_ui != null else null


## 三个副本只通过 BaseActor 的公共契约取得各自权限。
func _configure_replica_roles() -> void:
	body.configure_delay_replica(BaseActor.DelayReplicaRole.AUTHORITY)
	preview_body.configure_delay_replica(BaseActor.DelayReplicaRole.PREVIEW)
	predictor.configure_delay_replica(BaseActor.DelayReplicaRole.PREDICTOR)


func sync_preview_to_body(reset_interpolation: bool = true) -> void:
	if body == null or preview_body == null:
		return
	preview_body.restore_delay_snapshot(body.capture_delay_snapshot())
	if reset_interpolation:
		preview_body.reset_physics_interpolation()


func sync_predictor_to_body(reset_interpolation: bool = true) -> void:
	if body == null or predictor == null:
		return
	predictor.restore_delay_snapshot(body.capture_delay_snapshot())
	predictor.visible = false
	if reset_interpolation:
		predictor.reset_physics_interpolation()


## 统一保存分歧诊断；“重置未来”还是“保留命令并重算”由具体适配器决定。
func set_divergence_diagnostics(
	reason: StringName,
	position_error: float = 0.0,
	velocity_error: float = 0.0,
	expected_position: Vector2 = Vector2.INF
) -> void:
	last_divergence_reason = reason
	last_divergence_position_error = position_error
	last_divergence_velocity_error = velocity_error
	if body != null:
		last_divergence_body_position = body.global_position
		last_divergence_expected_position = body.global_position \
			if expected_position == Vector2.INF else expected_position


## 默认策略只记录诊断；玩家和敌人适配器分别覆盖为“清空未来”和“软重预测”。
func report_external_divergence(reason: StringName) -> void:
	set_divergence_diagnostics(reason)


func on_body_reset() -> void:
	pass


func on_body_defeated() -> void:
	pass


func on_body_respawn_requested() -> void:
	pass
