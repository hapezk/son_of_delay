@tool
class_name DelayedActorGroup
extends DelayControllerBase

## 玩家延迟适配器。历史类名和场景路径继续保留，公共三体生命周期位于 DelayControllerBase。
const CommandBuffer = preload("res://scenes/components/delay_command_buffer.gd")
## 延迟预测模拟使用的逻辑时间基准；不随世界变速改变。
const BASE_PHYSICS_TPS: int = 100
signal prediction_diverged(reason: StringName, position_error: float, velocity_error: float)
signal player_respawned
signal charge_acceleration_finished(successful_release: bool, seconds: float)
signal weapon_unlocked(slot: int, weapon_name: String)

@onready var preview_system: PreviewSystem = $PreviewSystem
@onready var time_slice_system: Node = $TimeSliceSystem

@export_tool_button("刷新/生成子节点") var refresh_button: Callable = rebuild
@export_category("DelaySystem")
@export var actor_scene: PackedScene:
	set(v):
		actor_scene = v
		# 换资源时自动重建（仅在编辑器且已入树时）
		if Engine.is_editor_hint() and is_inside_tree():
			rebuild()
@export var can_delay: bool = false

## 思考时间显示预测切片时，正常历史切片使用的透明度倍率。
@export_range(0.0, 1.0, 0.01) var thinking_normal_slice_alpha_multiplier: float = 0.25

@export_category("Respawn")
## 玩家重生时是否复位加入 player_respawn_reset 分组的战斗目标。
@export var reset_combat_targets_on_respawn: bool = true

@export_category("PredictionDivergence")
## 分歧发生后蓝色预览飞回本体的逻辑帧数。
@export_range(1, 60, 1) var divergence_flashback_frames: int = 10

@export_category("ConvergenceSnap")
@export var snap_enabled: bool = true
@export var snap_max_dist: float = 48.0     # 残差超过这个值就不贴（视为异常，防大幅拽动）
@export var snap_still_speed: float = 10.0  # 速度低于此值视为"已静止"
@export var snap_lerp_speed: float = 12.0   # 贴合速率（越大越快，够大≈瞬移）

## 思考时间预测的独立切片池与缓存；蓝影、临时切片和最终提交共用同一次结果。
var prediction_slice_pool: Array[Sprite2D] = []
var _prediction_pool_node: Node
var _prediction_visible: bool = false
var _normal_slice_base_alphas: Array[float] = []
var _queued_prediction_delay: float = -1.0
var _cached_transition: Dictionary = {}
var _cached_delay: float = -1.0
var _cached_read_head: int = -2
var _cached_write_head: int = -2
var _divergence_flashback_frames_left: int = 0
var _preview_state_machine_was_processing: bool = true
var divergence_count: int = 0
var respawn_count: int = 0
var _respawn_global_position: Vector2 = Vector2.ZERO
## 负延迟不是实际回放延迟，而是蓄力期间锁定的延迟能量；蓄力结束前不会自动返还。
var _reserved_charge_acceleration_seconds: float = 0.0
var _pending_charge_acceleration_seconds: float = 0.0
var _has_pending_charge_acceleration: bool = false
## 负延迟是动作级叠加层；结束后恢复这里保存的普通持续延迟。
var _regular_delay_before_charge_acceleration: float = -1.0
var _charge_acceleration_energy_spent: float = 0.0
## 受伤闪回期间实际时间线暂时归零，但负载仍按这个持续设置计算。
var _preserved_delay_after_flashback: float = -1.0


func _sync_hidden_preview_to_body(reset_interpolation: bool) -> void:
	sync_preview_to_body(reset_interpolation)


func sync_predictor_to_body(reset_interpolation: bool = false) -> void:
	# 运行时修改过的公开配置仍需复制；模拟状态和携带物由 BaseActor 快照统一处理。
	for prop in body.get_property_list():
		var usage: int = prop.get("usage", 0)
		var name: String = prop.get("name", "")
		# 只复制脚本里用 var 声明的变量（排除内置和私有）
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			if not name.begins_with("_"):
				var val: Variant = body.get(name)
				if val is Object:   # 节点/状态机引用不拷
					continue
				predictor.set(name, val)
	super.sync_predictor_to_body(reset_interpolation)


func refresh() -> void:
	if Engine.is_editor_hint():
		rebuild()


func _ready() -> void:
	if Engine.is_editor_hint():
		if actor_scene == null:
			assert(actor_scene != null, "DelayedActorGroup: actor_scene 未赋值")
			return
		ensure_children()          # 首次打开场景时生成

	body = get_node_or_null("Body") as BaseActor
	preview_body = get_node_or_null("PreviewBody") as BaseActor
	predictor = get_node_or_null("Predictor") as BaseActor
	if not Engine.is_editor_hint():
		_apply_permanent_natural_delay()
		add_to_group(&"pickup_collectors")
		initialize_delay_controller(body, preview_body, predictor)
	configure()
	_connect_charge_refund_signals()
	if body != null:
		# 默认出生点就是场景中 Body 的初始全局位置；后续检查点可调用 set_respawn_point 覆盖。
		_respawn_global_position = body.global_position
	_ensure_attack_input_buffer()
	if not Engine.is_editor_hint() and can_delay:
		_create_prediction_slice_pool()
		_register_thinking_time_prediction()


## 玩家自然延迟来自跨关卡永久成长；场景切换不会把升级覆盖回默认值。
func _apply_permanent_natural_delay() -> void:
	var progression: Node = get_node_or_null("/root/DelayProgression")
	if progression == null:
		return
	natural_delay_time = clampf(
		float(progression.get("player_natural_delay")), 0.0, max_delay_time)
	_setting_delay_internally = true
	delay_time = natural_delay_time
	_setting_delay_internally = false
	var callback: Callable = Callable(self, "_on_player_natural_delay_changed")
	if progression.has_signal(&"player_natural_delay_changed") \
			and not progression.is_connected(&"player_natural_delay_changed", callback):
		progression.connect(&"player_natural_delay_changed", callback)


## 自然延迟降低时，已主动压低的实际延迟保持不变并释放负载；
## 尚未调整的玩家则直接获得更低的自然延迟。
func _on_player_natural_delay_changed(value: float) -> void:
	var old_natural_delay: float = natural_delay_time
	var old_regular_delay: float = _get_persistent_regular_delay()
	natural_delay_time = clampf(value, 0.0, max_delay_time)
	var target_delay: float = old_regular_delay
	if old_regular_delay >= old_natural_delay - 0.0001:
		target_delay = clampf(
			natural_delay_time + (old_regular_delay - old_natural_delay),
			0.0,
			max_delay_time
		)
	if _reserved_charge_acceleration_seconds > 0.0:
		_regular_delay_before_charge_acceleration = target_delay
		return
	_apply_internal_regular_delay(target_delay)


## 将本对象的预测任务注册到唯一的思考时间控制器。
func _register_thinking_time_prediction() -> void:
	register_thinking_time_prediction(
		Callable(self, "has_queued_delay_prediction"),
		Callable(self, "run_queued_delay_prediction"),
		Callable(self, "commit_thinking_delay_change")
	)


## 玩家与其他可延迟对象保持同一规则：只有思考时间内才能排队修改延迟。
## 闪回期间也继续拒绝请求，让玩家先看清恢复结果。
func _can_accept_delay_request() -> bool:
	return _divergence_flashback_frames_left <= 0 \
		and _authority != null \
		and _authority.is_accepting_thinking_time_adjustments()


## 蓄力期间允许把玩家目标延迟设为负值；正延迟仍沿用公共时间线实现。
func request_delay_change(new_delay: float) -> bool:
	if new_delay < 0.0:
		return _request_charge_acceleration(new_delay)
	# 已经兑现的快进不能直接改回 0，否则会先享受充能再立即取回能量。
	if _reserved_charge_acceleration_seconds > 0.0:
		return false
	var accepted: bool = super.request_delay_change(new_delay)
	if accepted:
		_has_pending_charge_acceleration = false
		_pending_charge_acceleration_seconds = 0.0
	return accepted


func _request_charge_acceleration(
	requested_delay: float,
	require_thinking_time: bool = true
) -> bool:
	if require_thinking_time and not _can_accept_delay_request():
		return false
	if not require_thinking_time and _divergence_flashback_frames_left > 0:
		return false
	if not _is_live_charge_mode_active():
		return false
	# 正延迟缩短只能跳过输入历史，不能顺便转化为动作加速；必须先单独提交到 0。
	if get_committed_delay_setting() > 0.0001:
		return false
	var available_acceleration: float = _get_available_charge_acceleration_load()
	if available_acceleration <= 0.0001:
		return false
	var requested_seconds: float = clampf(
		absf(requested_delay),
		0.0,
		available_acceleration
	)
	# 已兑现的充能只能继续加码，不能在攻击前降低占用。
	requested_seconds = maxf(
		requested_seconds,
		_reserved_charge_acceleration_seconds
	)
	var signed_delay: float = -requested_seconds
	var admission: Dictionary = _request_delay_admission(signed_delay)
	if not bool(admission.get("accepted", false)):
		return false
	var admitted_delay: float = float(admission.get("delay", signed_delay))
	if admitted_delay >= 0.0:
		return false
	requested_seconds = absf(admitted_delay)
	_clear_prediction_visuals()
	_pending_delay = -1.0
	_pending_charge_acceleration_seconds = requested_seconds
	_has_pending_charge_acceleration = true
	_prediction_request_dirty = true
	return true


## 非思考时间 Q/E 快速控制玩家自身。Q 先把已提交的正延迟压到 0；
## 只有本体已经处于 0 延迟且正在可加速动作中，下一次 Q 才申请负方向最大值。
func request_self_delay_shortcut(keycode: Key) -> bool:
	if _authority != null and _authority.is_in_thinking_time():
		return false
	var target_delay: float
	match keycode:
		KEY_Q:
			if _is_live_charge_mode_active() \
					and get_committed_delay_setting() <= 0.0001:
				target_delay = get_effective_min_delay_time()
				if is_zero_approx(target_delay):
					return false
			elif not is_zero_approx(get_requested_delay()):
				target_delay = 0.0
			else:
				return false
		KEY_E:
			target_delay = get_effective_max_delay_time()
		_:
			return false
	if _authority != null and _authority.is_in_thinking_time():
		return request_delay_change(target_delay)
	return _request_self_delay_outside_thinking(target_delay)


func _request_self_delay_outside_thinking(target_delay: float) -> bool:
	if _divergence_flashback_frames_left > 0:
		return false
	if target_delay < 0.0:
		var acceleration_accepted: bool = _request_charge_acceleration(target_delay, false)
		if acceleration_accepted:
			_commit_charge_acceleration()
		return acceleration_accepted
	if _reserved_charge_acceleration_seconds > 0.0:
		return false
	var clamped_delay: float = clampf(target_delay, 0.0, get_effective_max_delay_time())
	var admission: Dictionary = _request_delay_admission(clamped_delay)
	if not bool(admission.get("accepted", false)):
		return false
	clamped_delay = clampf(
		float(admission.get("delay", clamped_delay)),
		0.0,
		get_effective_max_delay_time()
	)
	_has_pending_charge_acceleration = false
	_pending_charge_acceleration_seconds = 0.0
	_pending_delay = clamped_delay
	_prediction_request_dirty = false
	if is_zero_approx(clamped_delay):
		on_outside_zero_requested()
	return true


func get_effective_min_delay_time() -> float:
	var available_acceleration: float = _get_available_charge_acceleration_load()
	if get_committed_delay_setting() <= 0.0001 \
			and (_is_live_charge_mode_active() \
				or _reserved_charge_acceleration_seconds > 0.0 \
				or _has_pending_charge_acceleration) \
			and available_acceleration > 0.0001:
		return -available_acceleration
	return 0.0


## 动作负延迟只能使用普通持续延迟之外的剩余负载；没有容量管理器时保留对象上限。
func _get_available_charge_acceleration_load() -> float:
	# get_available_delay() 已扣除“已提交”负载，尚未提交的请求不能再重复增加可用量。
	var current_acceleration: float = _reserved_charge_acceleration_seconds
	var additional_capacity: float = get_effective_max_delay_time()
	if _delay_admission_owner != null and is_instance_valid(_delay_admission_owner) \
			and _delay_admission_owner.has_method("get_available_delay"):
		additional_capacity = maxf(float(
			_delay_admission_owner.call("get_available_delay")), 0.0)
	return minf(
		current_acceleration + additional_capacity,
		get_effective_max_delay_time()
	)


## 普通延迟计算相对自然值的持续负载；动作负延迟在此基础上额外占用临时负载。
func get_delay_load_cost(requested_delay: float) -> float:
	if requested_delay < 0.0:
		var regular_delay: float = _get_persistent_regular_delay()
		var regular_load: float = absf(regular_delay - natural_delay_time)
		return regular_load + absf(requested_delay)
	return absf(
		clampf(requested_delay, 0.0, get_effective_max_delay_time()) - natural_delay_time)


func get_delay_energy_cost(requested_delay: float) -> float:
	return get_delay_load_cost(requested_delay)


func get_committed_delay_setting() -> float:
	if _reserved_charge_acceleration_seconds > 0.0:
		return -_reserved_charge_acceleration_seconds
	if _preserved_delay_after_flashback >= 0.0:
		return _preserved_delay_after_flashback
	return delay_time


func get_delay_setting_side(delay_setting: float) -> int:
	if delay_setting < 0.0:
		return -2
	return super.get_delay_setting_side(delay_setting)


## 负延迟只为本次动作新增的快进秒数付费；普通延迟仍走基类的自然值规则。
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
	var regular_delay: float = _get_persistent_regular_delay()
	var regular_load: float = absf(regular_delay - natural_delay_time)
	var current_acceleration: float = _reserved_charge_acceleration_seconds
	var desired_acceleration: float = maxf(absf(requested_delay), current_acceleration)
	var acceleration_room: float = maxf(maximum_target_load - regular_load, 0.0)
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
		return {
			"delay": regular_delay,
			"load": regular_load,
			"energy_spent": 0.0,
		}
	return {
		"delay": -final_acceleration,
		"load": regular_load + final_acceleration,
		"energy_spent": granted_increase,
	}


func apply_settled_delay_request(settled_delay: float) -> void:
	if settled_delay < 0.0:
		_pending_delay = -1.0
		_pending_charge_acceleration_seconds = absf(settled_delay)
		_has_pending_charge_acceleration = true
		_prediction_request_dirty = true
		_clear_prediction_visuals()
		return
	_has_pending_charge_acceleration = false
	_pending_charge_acceleration_seconds = 0.0
	super.apply_settled_delay_request(settled_delay)


func on_delay_energy_spent(amount: float, settled_delay: float) -> void:
	if settled_delay < 0.0:
		_charge_acceleration_energy_spent += maxf(amount, 0.0)


## 鼠标目标的滚轮、1 / 2 / 3 / R / Q / E 都只在思考时间响应。
## 非思考时间的玩家 Q/E 由 AttackInputBuffer 走自身快捷入口。
func delay_shortcuts_require_thinking_time() -> bool:
	return true


## 检查点只需更新这个位置；下一次死亡会在这里复位三份角色。
func set_respawn_point(new_global_position: Vector2) -> void:
	_respawn_global_position = new_global_position


## 死亡倒计时结束后的唯一重生入口：清空未来，再同步本体、预览体和预测器。
func respawn_player() -> void:
	if body == null or preview_body == null or predictor == null:
		return
	respawn_count += 1
	_finish_charge_acceleration(false, false)
	_pending_delay = -1.0
	_preserved_delay_after_flashback = -1.0
	_divergence_flashback_frames_left = 0
	_clear_prediction_visuals()
	preview_system.reset_to_initial_state()
	var slices: TimeSliceSystem = time_slice_system as TimeSliceSystem
	if slices != null:
		slices.reset_to_initial_state()

	_setting_delay_internally = true
	delay_time = natural_delay_time
	_setting_delay_internally = false
	for actor: BaseActor in [body, preview_body, predictor]:
		if actor.has_method("reset_for_respawn"):
			actor.call("reset_for_respawn", _respawn_global_position)

	body.inputed = is_zero_approx(delay_time)
	preview_body.inputed = not body.inputed
	predictor.inputed = true
	preview_body.modulate = Color(1.0, 1.0, 1.0, 0.5)
	preview_body.visible = delay_time > 0.0
	if preview_body.state_machine != null:
		preview_body.state_machine.set_physics_process(_preview_state_machine_was_processing)
	sync_predictor_to_body()

	if reset_combat_targets_on_respawn:
		for target: Node in get_tree().get_nodes_in_group("player_respawn_reset"):
			if target.has_method("reset_combat"):
				target.call("reset_combat", true)
	player_respawned.emit()


func on_body_respawn_requested() -> void:
	respawn_player()


## 本体回放一帧后核对预览当时记录的结果；动态碰撞会在这里产生位置或速度差。
func check_replay_divergence(actor: BaseActor, expected: Recording) -> bool:
	if actor != body or expected == null or delay_time <= 0.0 or _divergence_flashback_frames_left > 0:
		return false
	var position_error: float = actor.global_position.distance_to(expected.pos)
	var velocity_error: float = actor.velocity.distance_to(expected.vel)
	if position_error <= divergence_position_tolerance and velocity_error <= divergence_velocity_tolerance:
		return false
	last_divergence_body_position = actor.global_position
	last_divergence_expected_position = expected.pos
	return report_prediction_divergence(&"replay_mismatch", position_error, velocity_error)


## 受伤等预览无法模拟的外部结果从这里上报；伤害保留，只撤销已经不可信的未来。
func report_prediction_divergence(
	reason: StringName,
	position_error: float = 0.0,
	velocity_error: float = 0.0
) -> bool:
	if not can_delay or delay_time <= 0.0 or _divergence_flashback_frames_left > 0:
		return false

	var old_delay: float = delay_time
	divergence_count += 1
	last_divergence_reason = reason
	last_divergence_position_error = position_error
	last_divergence_velocity_error = velocity_error
	_pending_delay = -1.0
	_preserved_delay_after_flashback = old_delay
	_clear_prediction_visuals()
	preview_system.reset_to_initial_state()
	if time_slice_system != null:
		time_slice_system.on_delay_changed(old_delay, 0.0)

	_setting_delay_internally = true
	delay_time = 0.0
	_setting_delay_internally = false
	body.inputed = true
	preview_body.inputed = false
	predictor.inputed = true
	sync_predictor_to_body()

	# 保留分歧瞬间的蓝影位置，让它在慢动作中追回应当可信的真实本体。
	_divergence_flashback_frames_left = divergence_flashback_frames
	_preview_state_machine_was_processing = preview_body.state_machine.is_physics_processing()
	preview_body.state_machine.set_physics_process(false)
	preview_body.velocity = Vector2.ZERO
	preview_body.modulate = Color(1.0, 0.35, 0.55, 0.85)
	preview_body.show()

	var authority: WorldTimeAuthority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	if authority != null:
		authority.trigger_reset_slow_motion()
	prediction_diverged.emit(reason, position_error, velocity_error)
	return true


## BaseActor 的统一外部事件入口；玩家策略仍是清空未来并显示短暂分歧闪回。
func report_external_divergence(reason: StringName) -> void:
	report_prediction_divergence(reason)


func _tick_divergence_flashback() -> void:
	if _divergence_flashback_frames_left <= 0:
		return
	preview_body.global_position = preview_body.global_position.lerp(body.global_position, 0.35)
	preview_body.reset_physics_interpolation()
	_divergence_flashback_frames_left -= 1
	if _divergence_flashback_frames_left > 0:
		return
	_sync_hidden_preview_to_body(true)
	preview_body.modulate = Color(1.0, 1.0, 1.0, 0.5)
	preview_body.hide()
	preview_body.state_machine.set_physics_process(_preview_state_machine_was_processing)
	# 旧未来已经作废，但普通延迟设置仍保留。受伤击退结束前继续保持 0 延迟，
	# 避免新时间线的首条记录夹在外部受伤状态中。


## 闪回画面结束后，等待角色的外部运动状态结束，再从稳定本体恢复原延迟。
func _try_restore_delay_after_flashback() -> void:
	if _divergence_flashback_frames_left > 0 \
			or _preserved_delay_after_flashback < 0.0 \
			or body == null \
			or not body.is_delay_reentry_ready():
		return
	_pending_delay = _preserved_delay_after_flashback
	_preserved_delay_after_flashback = -1.0
	_prediction_request_dirty = false


## 思考时间时物理帧可能暂停；返回待生效值才能让 UI 立即反馈滚轮操作。
func get_requested_delay() -> float:
	if _has_pending_charge_acceleration:
		return -_pending_charge_acceleration_seconds
	if _reserved_charge_acceleration_seconds > 0.0:
		return -_reserved_charge_acceleration_seconds
	if _preserved_delay_after_flashback >= 0.0:
		return _preserved_delay_after_flashback
	return _pending_delay if _pending_delay >= 0.0 else delay_time


## 思考时间减小延迟时返回预测结果；其他情况仍返回原历史记录。
func get_delay_preview_sample(requested_delay: float) -> Dictionary:
	if requested_delay < 0.0:
		_clear_prediction_visuals()
		return {}
	if requested_delay >= delay_time:
		_clear_prediction_visuals()
		return _get_historical_delay_preview_sample(requested_delay)

	_queue_prediction(requested_delay)
	if not _is_transition_cache_valid(requested_delay):
		return {}
	return {
		"position": _cached_transition["position"],
		"record": _cached_transition["record"],
	}


func _get_historical_delay_preview_sample(requested_delay: float) -> Dictionary:
	if preview_system == null or preview_system.read_head < 0 or preview_system.write_head < 0:
		return {}
	var frame_offset: int = PreviewSystem.seconds_to_frames(clampf(requested_delay, 0.0, delay_time))
	var slot_idx: int = (preview_system.read_head + frame_offset) % preview_system.capacity
	var record: Recording = preview_system.slots[slot_idx]
	if record == null:
		return {}
	return {"position": record.pos, "record": record}


## 默认返回角色本体、预览体与时间切片；复杂对象可覆盖此方法提供更多可命中视觉。
func get_delay_adjustment_sprites() -> Array[Sprite2D]:
	var sprites: Array[Sprite2D] = []
	for actor: BaseActor in [body, preview_body]:
		if actor == null or actor.graphics == null:
			continue
		var sprite: Sprite2D = actor.graphics.get_node_or_null("Sprite2D") as Sprite2D
		if sprite != null:
			sprites.append(sprite)
	if time_slice_system != null and time_slice_system.has_method("get_visible_delay_slices"):
		for slice: Sprite2D in time_slice_system.call("get_visible_delay_slices"):
			sprites.append(slice)
	for prediction_slice: Sprite2D in prediction_slice_pool:
		if prediction_slice.visible:
			sprites.append(prediction_slice)
	return sprites

## 先将旧角色移出场景树，再生成同名角色，避免帧末删除造成误判。
func rebuild() -> void:
	# 没有可用角色场景时，保留现有节点。
	if actor_scene == null:
		return
	for node_name: String in ["Body", "PreviewBody", "Predictor"]:
		var old_actor: Node = get_node_or_null(node_name)
		if old_actor != null:
			remove_child(old_actor)
			old_actor.queue_free()
	ensure_children()
	body = get_node_or_null("Body") as BaseActor
	preview_body = get_node_or_null("PreviewBody") as BaseActor
	predictor = get_node_or_null("Predictor") as BaseActor
	configure()

func ensure_children() -> void:
	if not has_node("Body"):
		var b = actor_scene.instantiate() as BaseActor
		name = b.name + "Group"
		b.name = "Body"
		add_child(b)
		if Engine.is_editor_hint():
			name = b.name + "Group"
			b.owner = get_tree().edited_scene_root
	if not has_node("PreviewBody"):
		var p = actor_scene.instantiate() as BaseActor
		p.name = "PreviewBody"
		add_child(p)
		if Engine.is_editor_hint():
			p.owner = get_tree().edited_scene_root
	if not has_node("Predictor"):
		var pr = actor_scene.instantiate() as BaseActor
		pr.name = "Predictor"
		pr.process_mode = Node.PROCESS_MODE_INHERIT
		add_child(pr)
		pr.hide()
		if Engine.is_editor_hint():
			pr.owner = get_tree().edited_scene_root

func configure() -> void:
	# 编辑器只生成角色节点；非 @tool 角色的脚本变量需在游戏运行时绑定。
	if Engine.is_editor_hint():
		return
	if body == null or preview_body == null or predictor == null:
		return
	body.preview_system = preview_system
	preview_body.preview_system = preview_system
	predictor.preview_system = preview_system
	_configure_replica_roles()
	# 敌人只追踪真实本体；重复 configure 时先清掉其他模拟角色的旧分组状态。
	body.add_to_group("player_damage_body")
	preview_body.remove_from_group("player_damage_body")
	predictor.remove_from_group("player_damage_body")
	# predictor 需要保持在物理空间中才能使用 move_and_slide，但禁止 StateMachine 自动驱动
	predictor.process_mode = Node.PROCESS_MODE_INHERIT
	if predictor.state_machine != null:
		predictor.state_machine.process_mode = Node.PROCESS_MODE_DISABLED
	if not can_delay:
		preview_body.hide()
		body.inputed = true
		return
	preview_body.modulate = Color(1.0, 1.0, 1.0, 0.5)
	body.inputed = false if delay_time > 0.0 else true
	predictor.inputed = body.inputed
	preview_body.inputed = !body.inputed
	# 角色引用与配置就绪后，为真实 Body 补齐交互组件。
	_ensure_delay_control_ui()


## 运行时仅为可延迟对象的真实 Body 创建一份 UI，随 Body 一起释放。
func _ensure_delay_control_ui() -> void:
	if Engine.is_editor_hint() or not can_delay or body == null:
		return
	create_or_configure_delay_ui(body, Callable(self, "get_delay_preview_sample"))


func get_delay_buffer_capacity() -> int:
	return preview_system.capacity if preview_system != null else 0


func on_outside_zero_requested() -> void:
	if _authority == null or not is_instance_valid(_authority):
		_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	if _authority != null:
		_authority.trigger_reset_slow_motion()


## 玩家可通过本体、预览体和所有可见时间切片选中同一个延迟控制器。
func is_mouse_over_delay_visual(mouse_position: Vector2) -> bool:
	for sprite: Sprite2D in get_delay_adjustment_sprites():
		if sprite != null and sprite.is_visible_in_tree() and sprite.texture != null \
				and sprite.get_rect().has_point(sprite.to_local(mouse_position)):
			return true
	return false


## 输入缓冲器必须在顿帧暂停时继续接收按键，避免命中瞬间的左键被 SceneTree 吃掉。
func _ensure_attack_input_buffer() -> void:
	if Engine.is_editor_hint() or has_node("AttackInputBuffer"):
		return
	var buffer: AttackInputBuffer = AttackInputBuffer.new()
	buffer.name = "AttackInputBuffer"
	add_child(buffer)


func _connect_charge_refund_signals() -> void:
	for actor: BaseActor in [body, preview_body, predictor]:
		if actor == null or not actor.has_signal(&"charge_action_ended"):
			continue
		var callback: Callable = Callable(self, "_on_player_charge_action_ended").bind(actor)
		if not actor.is_connected(&"charge_action_ended", callback):
			actor.connect(&"charge_action_ended", callback)


func _on_player_charge_action_ended(successful_release: bool, source_actor: BaseActor) -> void:
	if is_zero_approx(_reserved_charge_acceleration_seconds) \
			and not _has_pending_charge_acceleration:
		return
	var live_actor: BaseActor = _get_live_charge_actor()
	if source_actor != live_actor:
		return
	_finish_charge_acceleration(true, not successful_release)


## 施放和取消都释放临时负载；只有已经扣款且未成功释放的动作返还一半能量。
func _finish_charge_acceleration(restore_regular_delay: bool, canceled: bool) -> void:
	if is_zero_approx(_reserved_charge_acceleration_seconds) \
			and not _has_pending_charge_acceleration:
		return
	var committed_seconds: float = _reserved_charge_acceleration_seconds
	var budget_manager: Node = _delay_admission_owner
	if budget_manager != null and is_instance_valid(budget_manager):
		if budget_manager.has_method("cancel_pending_request"):
			budget_manager.call("cancel_pending_request", self)
		if canceled and _charge_acceleration_energy_spent > 0.0 \
				and budget_manager.has_method("refund_canceled_action_energy"):
			budget_manager.call(
				"refund_canceled_action_energy", _charge_acceleration_energy_spent)
	var regular_delay: float = _get_persistent_regular_delay()
	_reserved_charge_acceleration_seconds = 0.0
	_pending_charge_acceleration_seconds = 0.0
	_has_pending_charge_acceleration = false
	_charge_acceleration_energy_spent = 0.0
	_clear_prediction_visuals()
	if restore_regular_delay:
		_regular_delay_before_charge_acceleration = -1.0
		_apply_internal_regular_delay(regular_delay)
	else:
		_regular_delay_before_charge_acceleration = -1.0
	# 未提交的思考时间请求不算施放；教学和后续任务只监听真正兑现的动作结果。
	if committed_seconds > 0.0:
		charge_acceleration_finished.emit(not canceled, committed_seconds)


func _get_persistent_regular_delay() -> float:
	if _regular_delay_before_charge_acceleration >= 0.0:
		return _regular_delay_before_charge_acceleration
	if _preserved_delay_after_flashback >= 0.0:
		return _preserved_delay_after_flashback
	return _pending_delay if _pending_delay >= 0.0 else delay_time


## 内部恢复持续设置不重复收费；正式切换仍由原有 _physics_process 完成。
func _apply_internal_regular_delay(target_delay: float) -> void:
	var clamped_delay: float = clampf(target_delay, 0.0, get_effective_max_delay_time())
	_pending_delay = clamped_delay
	_prediction_request_dirty = false


func get_charge_acceleration_seconds() -> float:
	return _pending_charge_acceleration_seconds if _has_pending_charge_acceleration \
		else _reserved_charge_acceleration_seconds


func _get_live_charge_actor() -> BaseActor:
	return preview_body if can_delay and delay_time > 0.0 else body


## 拾取提示跟随当前接收即时输入的角色；最终效果仍由真实本体在回放帧结算。
func get_pickup_prompt_position() -> Vector2:
	var live_actor: BaseActor = preview_body \
		if preview_body != null and preview_body.inputed else body
	return live_actor.global_position if live_actor != null else Vector2.INF


## 延迟有效时镜头跟随本体与预览体中点；闪回和零延迟期间只认真实本体。
func get_camera_focus_position() -> Vector2:
	if body == null:
		return Vector2.ZERO
	if _divergence_flashback_frames_left > 0 or delay_time <= 0.0 \
			or preview_body == null or not preview_body.visible:
		return body.global_position
	return (body.global_position + preview_body.global_position) * 0.5


func is_divergence_flashback_active() -> bool:
	return _divergence_flashback_frames_left > 0


## 武器解锁是关卡进度，不属于延迟回放状态；拾取时必须一次同步三份玩家。
func unlock_weapon_for_all(slot: int) -> bool:
	var newly_unlocked: bool = false
	for actor: BaseActor in [body, preview_body, predictor]:
		if actor != null and actor.has_method("unlock_weapon"):
			newly_unlocked = bool(actor.call("unlock_weapon", slot)) or newly_unlocked
	if not newly_unlocked:
		return false
	var weapon_name: String = "武器 %d" % slot
	if body != null and body.has_method("get_weapon_name_for_slot"):
		weapon_name = str(body.call("get_weapon_name_for_slot", slot))
	weapon_unlocked.emit(slot, weapon_name)
	return true


func is_weapon_unlocked(slot: int) -> bool:
	return body != null and body.has_method("is_weapon_unlocked") \
		and bool(body.call("is_weapon_unlocked", slot))


## 仅由真实本体消费到已录制的 F 输入后调用，并以此刻本体位置执行权威拾取。
func try_pick_up_nearest() -> bool:
	if body == null:
		return false
	var nearest_pickup: Node2D
	var nearest_distance_squared: float = INF
	for pickup_node: Node in get_tree().get_nodes_in_group(&"pickups"):
		var pickup: Node2D = pickup_node as Node2D
		if pickup == null or pickup.is_queued_for_deletion() \
				or not pickup.has_method("can_be_picked_up_from"):
			continue
		if not bool(pickup.call("can_be_picked_up_from", body.global_position)):
			continue
		var distance_squared: float = body.global_position.distance_squared_to(
			pickup.global_position)
		if distance_squared < nearest_distance_squared:
			nearest_pickup = pickup
			nearest_distance_squared = distance_squared
	return nearest_pickup != null and bool(nearest_pickup.call("collect", self))


## 兼容旧测试和外部调用；新交互统一使用通用拾取入口。
func try_pick_up_nearest_weapon() -> bool:
	return try_pick_up_nearest()


func _is_live_charge_mode_active() -> bool:
	var charge_actor: BaseActor = _get_live_charge_actor()
	return charge_actor != null and charge_actor.has_method("is_charge_mode_active") \
		and bool(charge_actor.call("is_charge_mode_active"))


## 时间控制器用它判断本帧是否真的需要临时开放物理服务器。
func has_queued_delay_prediction() -> bool:
	var requested_delay: float = get_requested_delay()
	var has_stale_visuals: bool = requested_delay >= delay_time and (
		_prediction_visible or not _cached_transition.is_empty()
	)
	return _prediction_request_dirty or has_stale_visuals


## UI 只排队；此方法由 WorldTimeAuthority 的暂停物理回调调用。
func run_queued_delay_prediction() -> void:
	var requested_delay: float = get_requested_delay()
	if requested_delay < 0.0:
		_clear_prediction_visuals()
		return
	if requested_delay >= delay_time:
		if _prediction_visible or not _cached_transition.is_empty():
			_clear_prediction_visuals()
		return
	if not _prediction_request_dirty:
		return
	_prediction_request_dirty = false
	var target_delay: float = _queued_prediction_delay
	if target_delay < 0.0 or target_delay >= delay_time:
		_clear_prediction_visuals()
		return

	var transition: Dictionary = preview_system.predict_delay_from_body(target_delay)
	if transition.is_empty():
		_clear_prediction_visuals()
		return
	_cache_transition(target_delay, transition)
	_show_prediction_visuals(transition)


## 退出思考时间前，在世界仍暂停的物理回调中提交缓存结果。
func commit_thinking_delay_change() -> void:
	if _has_pending_charge_acceleration:
		_commit_charge_acceleration()
		return
	var requested_delay: float = get_requested_delay()
	if requested_delay <= 0.0 or requested_delay >= delay_time:
		_clear_prediction_visuals()
		return

	if not _is_transition_cache_valid(requested_delay):
		var transition: Dictionary = preview_system.predict_delay_from_body(requested_delay)
		if transition.is_empty():
			return
		_cache_transition(requested_delay, transition)
	_apply_cached_reduction(requested_delay)


## 退出思考时间时兑现动作负延迟；普通延迟必须已经在更早的结算中降为 0。
func _commit_charge_acceleration() -> void:
	var charge_actor: BaseActor = _get_live_charge_actor()
	if charge_actor == null or not charge_actor.has_method("capture_charge_acceleration_state") \
			or not _is_live_charge_mode_active() \
			or get_committed_delay_setting() > 0.0001:
		_finish_charge_acceleration(true, true)
		return
	var charge_state: Dictionary = charge_actor.call("capture_charge_acceleration_state") as Dictionary
	var target_seconds: float = _pending_charge_acceleration_seconds
	var additional_seconds: float = maxf(
		target_seconds - _reserved_charge_acceleration_seconds,
		0.0
	)
	_has_pending_charge_acceleration = false
	_pending_charge_acceleration_seconds = 0.0
	if _regular_delay_before_charge_acceleration < 0.0:
		_regular_delay_before_charge_acceleration = delay_time
	if body.has_method("restore_charge_acceleration_state"):
		body.call("restore_charge_acceleration_state", charge_state)
	if additional_seconds > 0.0 and body.has_method("advance_charge_time"):
		body.call("advance_charge_time", additional_seconds)
	_reserved_charge_acceleration_seconds = target_seconds
	sync_preview_to_body(false)
	sync_predictor_to_body(false)

func _queue_prediction(requested_delay: float) -> void:
	var target_delay: float = clampf(requested_delay, 0.0, delay_time)
	if _is_transition_cache_valid(target_delay):
		return
	if _prediction_request_dirty and is_equal_approx(_queued_prediction_delay, target_delay):
		return
	_queued_prediction_delay = target_delay
	_prediction_request_dirty = true


func _cache_transition(target_delay: float, transition: Dictionary) -> void:
	_cached_transition = transition
	_cached_delay = target_delay
	_cached_read_head = preview_system.read_head
	_cached_write_head = preview_system.write_head


func _is_transition_cache_valid(target_delay: float) -> bool:
	return not _cached_transition.is_empty() \
		and is_equal_approx(_cached_delay, target_delay) \
		and _cached_read_head == preview_system.read_head \
		and _cached_write_head == preview_system.write_head


## 本体跳过被减掉的输入，预览体采用思考时间里缓存的预测器终点。
func _apply_cached_reduction(new_delay: float) -> void:
	# 思考时间提交也走通用时间线；玩家特有的轨迹重基准仍在下方完成。
	preview_system.on_delay_changed(delay_time, new_delay)
	var predicted_positions: Array[Vector2] = _cached_transition["positions"]
	var predicted_velocities: Array[Vector2] = _cached_transition["velocities"]
	var input_start_idx: int = int(_cached_transition["input_start_idx"])
	if not preview_system.rebase_recorded_trajectory(
		input_start_idx,
		predicted_positions,
		predicted_velocities
	):
		push_error("DelayedActorGroup: failed to rebase records after reducing delay")

	_setting_delay_internally = true
	delay_time = new_delay
	_setting_delay_internally = false
	_pending_delay = -1.0

	preview_body.global_position = _cached_transition["position"]
	preview_body.velocity = _cached_transition["velocity"]
	preview_body.restore_simulation_state(_cached_transition.get("actor_state", {}))
	var attachment_state: Variant = _cached_transition.get(
		"attachment_state",
		{"weapon": _cached_transition.get("weapon_state", {})}
	)
	if attachment_state is Dictionary:
		preview_body.restore_delay_attachment_state(attachment_state as Dictionary)
	preview_body.reset_physics_interpolation()
	body.inputed = false
	preview_body.inputed = true
	preview_body.show()

	# 先解除旧切片的思考时间压暗，再把预测切片状态原样交接给正常切片系统。
	_set_normal_slice_dimmed(false)
	var slices: TimeSliceSystem = time_slice_system as TimeSliceSystem
	if slices != null:
		slices.adopt_prediction(new_delay, _cached_transition, preview_system)
	_clear_prediction_visuals()


## 正常切片保留原轨迹，只在预测存在时整体压低透明度。
func _set_normal_slice_dimmed(dimmed: bool) -> void:
	var slices: TimeSliceSystem = time_slice_system as TimeSliceSystem
	if slices == null:
		return
	if dimmed:
		if _normal_slice_base_alphas.is_empty():
			for slice: Sprite2D in slices.slice_pool:
				_normal_slice_base_alphas.append(slice.modulate.a)
		for index: int in range(slices.slice_pool.size()):
			slices.slice_pool[index].modulate.a = _normal_slice_base_alphas[index] * thinking_normal_slice_alpha_multiplier
		return

	if _normal_slice_base_alphas.is_empty():
		return
	for index: int in range(slices.slice_pool.size()):
		slices.slice_pool[index].modulate.a = _normal_slice_base_alphas[index]
	_normal_slice_base_alphas.clear()


## 预测切片与正常切片一样：按相同间隔采样，并按年龄由淡到浓排列。
func _show_prediction_visuals(transition: Dictionary) -> void:
	var slices: TimeSliceSystem = time_slice_system as TimeSliceSystem
	if slices == null:
		return
	var positions: Array[Vector2] = transition["positions"]
	var records: Array[Recording] = transition["records"]
	if positions.is_empty() or records.is_empty():
		return
	var input_start_idx: int = transition["input_start_idx"]

	_set_normal_slice_dimmed(true)
	_prediction_visible = true
	var sample_frames: Array[int] = slices.get_prediction_sample_frames(
		positions.size(),
		_cached_delay,
		prediction_slice_pool.size()
	)

	for pool_index: int in range(prediction_slice_pool.size()):
		var slice: Sprite2D = prediction_slice_pool[pool_index]
		if pool_index >= sample_frames.size():
			slice.visible = false
			continue
		var frame_index: int = sample_frames[pool_index]
		var record: Recording = records[frame_index]
		if not slices.apply_record_to_slice(slice, record):
			slice.visible = false
			continue
		slice.global_position = positions[frame_index]
		slice.modulate = Color(
			slices.slice_color,
			slices.get_prediction_sample_alpha(frame_index, input_start_idx, _cached_delay, preview_system)
		)
		slice.visible = true
		slice.reset_physics_interpolation()


func _clear_prediction_visuals() -> void:
	for slice: Sprite2D in prediction_slice_pool:
		slice.visible = false
	_set_normal_slice_dimmed(false)
	_prediction_visible = false
	_prediction_request_dirty = false
	_queued_prediction_delay = -1.0
	_cached_transition.clear()
	_cached_delay = -1.0


func _create_prediction_slice_pool() -> void:
	var slices: TimeSliceSystem = time_slice_system as TimeSliceSystem
	if slices == null or not prediction_slice_pool.is_empty():
		return
	_prediction_pool_node = Node.new()
	_prediction_pool_node.name = "PredictionSlicePool"
	slices.add_child(_prediction_pool_node)
	var max_slice_count: int = slices.get_active_slice_count(max_delay_time)
	for pool_index: int in range(max_slice_count):
		var slice: Sprite2D = Sprite2D.new()
		slice.visible = false
		slice.z_index = -1
		_prediction_pool_node.add_child(slice)
		prediction_slice_pool.append(slice)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_tick_divergence_flashback()
	_try_restore_delay_after_flashback()

	if _pending_delay >= 0.0 and not is_equal_approx(_pending_delay, delay_time):
		var old_delay: float = delay_time
		var new_delay: float = clamp(_pending_delay, 0.0, max_delay_time)

		preview_system.on_delay_changed(old_delay, new_delay)
		if time_slice_system != null:
			time_slice_system.on_delay_changed(old_delay, new_delay)

		# 从 0 延迟切换到正延迟：preview 从 body 水平减速到 0 后的位置出发，水平速度为 0。
		# 逻辑状态必须在本帧录制前就位；若推迟到下一帧，第一条记录仍会留在旧位置，
		# 一个延迟周期后 Body 读到它就会被误判为 replay_mismatch。
		if is_equal_approx(old_delay, 0.0) and new_delay > 0.0:
			var sim_vel_x: float = body.velocity.x
			# 等待回放时，攻击中的本体同样先受移速上限约束，再水平减速。
			if body.weapon != null:
				var movement_multiplier: float = body.weapon.get_movement_multiplier(false, false, body.is_grounded_for_simulation())
				if movement_multiplier < 1.0:
					var speed_limit: float = body.move_speed * movement_multiplier
					sim_vel_x = clampf(sim_vel_x, -speed_limit, speed_limit)
			var dt: float = 1.0 / BASE_PHYSICS_TPS
			var deceleration: float = body.get_horizontal_acceleration(
				body.is_grounded_for_simulation())
			var stop_dist_x: float = CommandBuffer.get_waiting_stop_distance(
				sim_vel_x, deceleration, dt)
			var target_pos: Vector2 = body.global_position + Vector2(stop_dist_x, 0.0)
			sync_predictor_to_body()
			_sync_hidden_preview_to_body(false)
			preview_body.global_position = target_pos
			preview_body.velocity = Vector2(0.0, body.velocity.y)
			# Preview 上一帧处于隐藏状态，直接重置插值即可避免从旧位置拖出残影。
			preview_body.reset_physics_interpolation()
		# 正延迟之间切换：运行预测并更新 preview 位置
		elif old_delay > 0.0 and new_delay > 0.0:
			var target: Dictionary = preview_system.run_prediction_in_physics_process()
			if target is Dictionary:
				preview_body.global_position = target["pos"]
				preview_body.velocity = target["vel"]
				preview_body.restore_simulation_state(target.get("actor_state", {}))
				var attachment_state: Variant = target.get(
					"attachment_state",
					{"weapon": target.get("weapon_state", {})}
				)
				if attachment_state is Dictionary:
					preview_body.restore_delay_attachment_state(attachment_state as Dictionary)
				# 非缓存路径缩短延迟时也要重基准，不能只修预测缓存提交路径。
				if new_delay < old_delay and not preview_system.rebase_last_predicted_records():
					push_error("DelayedActorGroup: failed to rebase records after direct delay reduction")
		elif old_delay > 0.0 and is_equal_approx(new_delay, 0.0):
			sync_predictor_to_body()
			_sync_hidden_preview_to_body(true)

		_setting_delay_internally = true
		delay_time = new_delay
		_setting_delay_internally = false
		_pending_delay = -1.0

	if _divergence_flashback_frames_left > 0:
		body.inputed = true
		preview_body.inputed = false
		preview_body.show()
	elif can_delay and delay_time > 0.0:
		body.inputed = false
		preview_body.inputed = true
		preview_body.show()
	else:
		body.inputed = true
		preview_body.inputed = false
		_sync_hidden_preview_to_body(false)
		preview_body.hide()

	#update_convergence_snap(delta)


func update_convergence_snap(delta: float) -> void:
	if not snap_enabled:
		return
	if not (can_delay and delay_time > 0.0):
		return
	if body == null or preview_body == null:
		return
	# 关键：必须两者都静止，只清"追完之后的残差"，不碰正在追的过程
	if preview_body.velocity.length() > snap_still_speed:
		return
	if body.velocity.length() > snap_still_speed:
		return
	var offset: Vector2 = body.global_position - preview_body.global_position
	var dist: float = offset.length()
	if dist < 0.5 or dist > snap_max_dist:
		return
	preview_body.global_position += offset * min(snap_lerp_speed * delta, 1.0)
