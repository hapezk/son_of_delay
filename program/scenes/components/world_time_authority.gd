class_name WorldTimeAuthority
extends Node

## 一次性真实时间计时器，由时间控制器统一检查；不使用受变速影响的 delta。
## cancel() 静默取消，不发出 timeout；到期信号在下一次画面处理帧发出。
class RealTimeTimer:
	extends RefCounted
	signal timeout
	var _started_usec: int
	var _duration: float
	var _running: bool = true
	var _elapsed_on_stop: float = 0.0

	func _init(seconds: float) -> void:
		_started_usec = Time.get_ticks_usec()
		_duration = maxf(seconds, 0.0)

	func is_running() -> bool:
		return _running

	## 已经过的真实秒数，结束或取消后固定，不再继续增长。
	func get_elapsed() -> float:
		if not _running:
			return _elapsed_on_stop
		return minf(float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0, _duration)

	func get_time_left() -> float:
		return maxf(_duration - get_elapsed(), 0.0) if _running else 0.0

	## 0～1 的完成比例，适合慢动作恢复、晃动衰减等渐变效果。
	func get_progress() -> float:
		return get_elapsed() / _duration if _duration > 0.0 else 1.0

	func cancel() -> void:
		_elapsed_on_stop = get_elapsed()
		_running = false

	func _poll() -> void:
		if not _running or get_elapsed() < _duration:
			return
		_elapsed_on_stop = _duration
		_running = false
		timeout.emit()


## 统一管理思考暂停、命中顿帧与 R 归零慢动作，避免各自修改时间造成冲突。
const BASE_PHYSICS_TPS: int = 100
const BASE_MAX_PHYSICS_STEPS: int = 8
const DEFAULT_COMBAT_TUNING: CombatTuning = preload("res://resources/combat_tuning.tres")
const DAMAGE_SCREEN_FLASH_SCRIPT: Script = preload("res://scenes/components/screen_damage_flash.gd")

@export_category("Combat")
## 展开此资源即可调整重斩、攻击移速、顿帧与晃动；所有角色读取同一套参数。
@export var combat_tuning: CombatTuning = DEFAULT_COMBAT_TUNING

@export_category("ThinkingTime")
## 按下思考时间后，用真实时间把世界快速减速；结束时才正式暂停并开放延迟调整。
@export_range(0.0, 1.0, 0.01) var thinking_entry_duration: float = 0.2

@export_category("ResetSlowMotion")
## 独立的重置慢动作反馈参数；延迟输入现已限制在思考时间内。
@export_range(0.05, 1.0, 0.05) var reset_slow_scale: float = 0.25
## 慢动作恢复到正常速度所需的真实时间，不受当前 time_scale 影响。
@export_range(0.0, 2.0, 0.05) var reset_restore_duration: float = 0.3

var _is_thinking_time: bool = false
var _thinking_entry_active: bool = false
var _exit_requested: bool = false
## 预测提交后的解暂停必须留到正常空闲帧，避免二维物理连续 step 而未 flush 查询。
var _resume_pending: bool = false
var _thinking_entry_start_scale: float = 1.0
var _thinking_entry_timer: RealTimeTimer
var _reset_slow_motion_active: bool = false
var _real_timers: Array[RealTimeTimer] = []
var _reset_slow_timer: RealTimeTimer
var _hit_stop_active: bool = false
var _hit_stop_timer: RealTimeTimer
var _pending_hit_stop_seconds: float = 0.0
var _pending_shake_strength: float = 0.0
var _hit_stop_scheduled: bool = false
## 胜利界面等系统以原因登记暂停；任一原因存在时都不会被顿帧结束误解除。
var _external_pause_reasons: Dictionary[StringName, bool] = {}
var _screen_shake: ScreenShake
var _screen_shake_timer: RealTimeTimer
var _screen_shake_owned_by_hit_stop: bool = false
var _damage_screen_flash: CanvasLayer
## Engine 与 SceneTree 状态是进程级全局量；控制器离场时必须归还接管前的值。
var _baseline_captured: bool = false
var _baseline_time_scale: float = 1.0
var _baseline_physics_tps: int = 60
var _baseline_max_physics_steps: int = 8
var _baseline_tree_paused: bool = false

## 玩家和敌人的延迟系统都通过回调参与同一次思考时间提交。
## owner 用于去重和自动清理已离开场景的参与者，时间控制器不依赖具体角色类型。
var _thinking_prediction_participants: Array[Dictionary] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_baseline_time_scale = Engine.time_scale
	_baseline_physics_tps = Engine.physics_ticks_per_second
	_baseline_max_physics_steps = Engine.max_physics_steps_per_frame
	_baseline_tree_paused = get_tree().paused
	_baseline_captured = true
	add_to_group("world_time_authority")
	_screen_shake = ScreenShake.new()
	_screen_shake.name = "ScreenShake"
	add_child(_screen_shake)
	_damage_screen_flash = DAMAGE_SCREEN_FLASH_SCRIPT.new() as CanvasLayer
	_damage_screen_flash.name = "DamageScreenFlash"
	add_child(_damage_screen_flash)
	# 思考时间通过暂停 SceneTree 实现；保留 100 TPS 和 0.01 秒物理步长供预测器使用。
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = BASE_PHYSICS_TPS
	Engine.max_physics_steps_per_frame = BASE_MAX_PHYSICS_STEPS


func _process(_delta: float) -> void:
	_finish_pending_resume()
	# 遍历快照，允许 timeout 回调创建或取消其他计时器，避免修改遍历中的数组。
	for timer: RealTimeTimer in _real_timers.duplicate():
		timer._poll()
		if not timer.is_running():
			_real_timers.erase(timer)
	if _screen_shake_timer != null and _screen_shake_timer.is_running():
		_screen_shake.tick(_screen_shake_timer.get_elapsed())
	if _thinking_entry_active and _thinking_entry_timer != null:
		var entry_progress: float = _thinking_entry_timer.get_progress()
		_apply_simulation_speed(lerpf(_thinking_entry_start_scale, 0.0, entry_progress))
	if not _reset_slow_motion_active:
		return
	var progress: float = _reset_slow_timer.get_progress()
	_apply_simulation_speed(lerpf(reset_slow_scale, 1.0, progress))


## seconds 单位为真实秒；即使 SceneTree 暂停或 time_scale 为 0，也照常计时。
## 用法：await world_time_authority.create_real_timer(0.1).timeout
## 0 或负数在下一次处理时到期；控制器退出场景时，未完成的计时器全部取消。
func create_real_timer(seconds: float) -> RealTimeTimer:
	var timer: RealTimeTimer = RealTimeTimer.new(seconds)
	_real_timers.append(timer)
	return timer


func _exit_tree() -> void:
	for timer: RealTimeTimer in _real_timers:
		timer.cancel()
	_real_timers.clear()
	_thinking_entry_timer = null
	_reset_slow_timer = null
	_hit_stop_timer = null
	_screen_shake_timer = null
	_thinking_prediction_participants.clear()
	_external_pause_reasons.clear()
	_is_thinking_time = false
	_thinking_entry_active = false
	_exit_requested = false
	_resume_pending = false
	_reset_slow_motion_active = false
	_hit_stop_active = false
	_hit_stop_scheduled = false
	_pending_hit_stop_seconds = 0.0
	_pending_shake_strength = 0.0
	if _baseline_captured:
		Engine.time_scale = _baseline_time_scale
		Engine.physics_ticks_per_second = _baseline_physics_tps
		Engine.max_physics_steps_per_frame = _baseline_max_physics_steps
		get_tree().paused = _baseline_tree_paused


## 注册思考时间内的预测任务。重复注册同一 owner 时会更新回调，不会执行两次。
## 三个回调依次表示：是否有任务、执行预测、退出前提交。
func configure_thinking_time_prediction(
	owner: Node,
	has_prediction_work: Callable,
	run_prediction_work: Callable,
	commit_prediction_work: Callable
) -> void:
	if owner == null:
		return
	_remove_invalid_thinking_time_participants()
	var participant: Dictionary = {
		"owner": owner,
		"has_work": has_prediction_work,
		"run": run_prediction_work,
		"commit": commit_prediction_work,
	}
	for index: int in range(_thinking_prediction_participants.size()):
		if _thinking_prediction_participants[index].get("owner") == owner:
			_thinking_prediction_participants[index] = participant
			return
	_thinking_prediction_participants.append(participant)


## 短生命周期对象应在离场时主动注销；同时顺手清掉未正常注销的旧引用。
func remove_thinking_time_prediction(owner: Node) -> void:
	for index: int in range(_thinking_prediction_participants.size() - 1, -1, -1):
		var stored_owner: Variant = _thinking_prediction_participants[index].get("owner")
		if not is_instance_valid(stored_owner) or stored_owner == owner:
			_thinking_prediction_participants.remove_at(index)


func _remove_invalid_thinking_time_participants() -> void:
	for index: int in range(_thinking_prediction_participants.size() - 1, -1, -1):
		var stored_owner: Variant = _thinking_prediction_participants[index].get("owner")
		if not is_instance_valid(stored_owner):
			_thinking_prediction_participants.remove_at(index)

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("thinking_time") or event.is_echo():
		return
	if _is_thinking_time or _thinking_entry_active:
		request_exit_thinking_time()
	else:
		enter_thinking_time()
	get_viewport().set_input_as_handled()


## 暂停期间仍会收到真实物理回调；只在确实需要预测或提交时开放物理服务器。
func _physics_process(_delta: float) -> void:
	if not _is_thinking_time:
		return

	var has_queued_work: bool = false
	var active_participants: Array[Dictionary] = []
	for participant: Dictionary in _thinking_prediction_participants:
		# 先以 Variant 验证引用；对 Freed Object 直接执行 `as Node` 会触发调试器错误。
		var owner_value: Variant = participant.get("owner")
		if not is_instance_valid(owner_value):
			continue
		var owner: Node = owner_value as Node
		if owner == null or not owner.is_inside_tree():
			continue
		active_participants.append(participant)
		var has_work: Callable = participant.get("has_work", Callable()) as Callable
		if has_work.is_valid() and bool(has_work.call()):
			has_queued_work = true
	_thinking_prediction_participants = active_participants
	var needs_prediction_server: bool = has_queued_work or _exit_requested

	if needs_prediction_server:
		PhysicsServer2D.set_active(true)
		# 退出前先按玩家的选择顺序结算负载与能量。最终值可能因资源不足被部分缩短，
		# 因此必须在各控制器最后一次预测与提交之前完成。
		if _exit_requested:
			var budget_manager: Node = get_tree().get_first_node_in_group("delay_budget_manager")
			if budget_manager != null and budget_manager.has_method("settle_pending_requests"):
				budget_manager.call("settle_pending_requests")
		for participant: Dictionary in active_participants:
			var run_work: Callable = participant.get("run", Callable()) as Callable
			if run_work.is_valid():
				run_work.call()
		if _exit_requested:
			for participant: Dictionary in active_participants:
				var commit_work: Callable = participant.get("commit", Callable()) as Callable
				if commit_work.is_valid():
					commit_work.call()
		PhysicsServer2D.set_active(false)

	if _exit_requested:
		_exit_requested = false
		_is_thinking_time = false
		# 此处仍位于暂停态物理回调；同帧解暂停会让 GodotPhysics2D 在 flush 前再次 step。
		_resume_pending = true


func enter_thinking_time() -> void:
	if _is_thinking_time or _thinking_entry_active or _resume_pending:
		return
	# 进入过渡和 R 慢动作、命中顿帧互斥，避免多个系统同时写 Engine.time_scale。
	_cancel_reset_slow_motion()
	_cancel_hit_stop()
	_refresh_tree_pause()
	_exit_requested = false
	_thinking_entry_start_scale = Engine.time_scale
	_thinking_entry_active = true
	if is_zero_approx(thinking_entry_duration):
		_finish_thinking_entry()
		return
	_thinking_entry_timer = create_real_timer(thinking_entry_duration)
	_thinking_entry_timer.timeout.connect(_finish_thinking_entry)


## 减速只负责入场观感；正式暂停后恢复 1x / 100 TPS，供暂停态预测器稳定演算。
func _finish_thinking_entry() -> void:
	_thinking_entry_timer = null
	if not _thinking_entry_active:
		return
	_thinking_entry_active = false
	_apply_simulation_speed(1.0)
	_is_thinking_time = true
	_refresh_tree_pause()


func _cancel_thinking_entry() -> void:
	if _thinking_entry_timer != null:
		_thinking_entry_timer.cancel()
		_thinking_entry_timer = null
	_thinking_entry_active = false
	_apply_simulation_speed(1.0)
	_refresh_tree_pause()


## 退出必须延迟到下一次物理回调，确保先提交预测结果再恢复世界。
func request_exit_thinking_time() -> void:
	if _thinking_entry_active:
		_cancel_thinking_entry()
		return
	if _is_thinking_time:
		_exit_requested = true


## 待恢复阶段仍保持暂停，因此对外继续视为思考时间，直到正常空闲帧真正恢复世界。
func is_in_thinking_time() -> bool:
	return _is_thinking_time or _resume_pending


## 预测已经提交后不再接收新的延迟请求；UI 可继续显示到世界实际恢复。
func is_accepting_thinking_time_adjustments() -> bool:
	return _is_thinking_time and not _exit_requested and not _resume_pending


## UI 与测试可区分“正在减速”和“已经暂停”；延迟调节只认后者。
func is_entering_thinking_time() -> bool:
	return _thinking_entry_active


## 外部系统用命名原因申请暂停，避免直接写 SceneTree.paused 后被思考时间或顿帧覆盖。
func request_external_pause(reason: StringName) -> void:
	if reason == &"":
		return
	_external_pause_reasons[reason] = true
	_refresh_tree_pause()


func release_external_pause(reason: StringName) -> void:
	_external_pause_reasons.erase(reason)
	_refresh_tree_pause()


func is_externally_paused(reason: StringName) -> bool:
	return _external_pause_reasons.has(reason)


func _refresh_tree_pause() -> void:
	get_tree().paused = _is_thinking_time or _resume_pending \
		or _hit_stop_active or not _external_pause_reasons.is_empty()


## 正常 _process 位于物理 step 之外；只在这里完成思考时间退出并恢复物理服务器。
func _finish_pending_resume() -> void:
	if not _resume_pending:
		return
	_resume_pending = false
	_refresh_tree_pause()


## 独立的重置慢动作反馈入口；思考时间内调用不会改变速度或暂停状态。
func trigger_reset_slow_motion() -> void:
	if is_in_thinking_time() or _thinking_entry_active:
		return
	_cancel_reset_slow_motion()
	_reset_slow_motion_active = not is_zero_approx(reset_restore_duration)
	_apply_simulation_speed(reset_slow_scale)
	if _reset_slow_motion_active:
		_reset_slow_timer = create_real_timer(reset_restore_duration)
		_reset_slow_timer.timeout.connect(_finish_reset_slow_motion)
	else:
		_apply_simulation_speed(1.0)


func is_reset_slow_motion_active() -> bool:
	return _reset_slow_motion_active


func _cancel_reset_slow_motion() -> void:
	if _reset_slow_timer != null:
		_reset_slow_timer.cancel()
		_reset_slow_timer = null
	if not _reset_slow_motion_active and is_equal_approx(Engine.time_scale, 1.0):
		return
	_reset_slow_motion_active = false
	_apply_simulation_speed(1.0)


func _finish_reset_slow_motion() -> void:
	_reset_slow_timer = null
	_reset_slow_motion_active = false
	_apply_simulation_speed(1.0)


## 同时量化 time_scale 与 TPS，让每个非零物理帧始终保持 0.01 秒逻辑步长。
func _apply_simulation_speed(requested_scale: float) -> void:
	var physics_tps: int = maxi(roundi(BASE_PHYSICS_TPS * clampf(requested_scale, 0.05, 1.0)), 1)
	var quantized_scale: float = float(physics_tps) / float(BASE_PHYSICS_TPS)
	Engine.time_scale = quantized_scale
	Engine.physics_ticks_per_second = physics_tps
	Engine.max_physics_steps_per_frame = BASE_MAX_PHYSICS_STEPS


func get_combat_tuning() -> CombatTuning:
	return combat_tuning if combat_tuning != null else DEFAULT_COMBAT_TUNING


## 玩家受伤的红光与轻震使用真实时间；是否发生预测分歧由角色组另行处理。
func request_player_hurt_feedback() -> void:
	var tuning: CombatTuning = get_combat_tuning()
	if not tuning.hurt_feedback_enabled:
		return
	_damage_screen_flash.call(
		"start",
		tuning.hurt_screen_flash_seconds,
		tuning.hurt_screen_flash_color,
		tuning.hurt_screen_flash_opacity,
		tuning.hurt_screen_vignette_inner_radius,
		tuning.hurt_screen_vignette_softness
	)
	_start_screen_shake(
		tuning.hurt_shake_seconds,
		tuning.hurt_shake_strength,
		tuning.shake_frequency_hz,
		false
	)


func _start_screen_shake(
	duration: float,
	strength: float,
	frequency: float,
	owned_by_hit_stop: bool
) -> void:
	_cancel_screen_shake()
	if duration <= 0.0 or strength <= 0.0:
		return
	_screen_shake_owned_by_hit_stop = owned_by_hit_stop
	_screen_shake_timer = create_real_timer(duration)
	_screen_shake_timer.timeout.connect(_finish_screen_shake)
	_screen_shake.start(duration, strength, frequency)


func _cancel_screen_shake() -> void:
	if _screen_shake_timer != null:
		_screen_shake_timer.cancel()
		_screen_shake_timer = null
	_screen_shake_owned_by_hit_stop = false
	_screen_shake.stop()


func _finish_screen_shake() -> void:
	_screen_shake_timer = null
	_screen_shake_owned_by_hit_stop = false
	_screen_shake.stop()


## 仅真实命中的武器请求反馈。同一物理帧的多个命中取较强效果，不累加时长。
func request_hit_feedback(combo_index: int) -> void:
	var tuning: CombatTuning = get_combat_tuning()
	if is_in_thinking_time() or _thinking_entry_active or not tuning.hit_stop_enabled:
		return
	if get_tree().paused and not _hit_stop_active:
		return
	var duration: float = tuning.heavy_hit_stop_seconds if combo_index == 2 else tuning.hit_stop_seconds
	if duration <= 0.0:
		return
	var strength: float = tuning.heavy_shake_strength if combo_index == 2 else tuning.shake_strength
	_pending_hit_stop_seconds = maxf(_pending_hit_stop_seconds, duration)
	_pending_shake_strength = maxf(_pending_shake_strength, strength if tuning.shake_enabled else 0.0)
	if not _hit_stop_scheduled:
		_hit_stop_scheduled = true
		# 让这一物理帧的本体与预览体都执行完，再暂停，保持录制回放帧序一致。
		_begin_hit_stop.call_deferred()


func _begin_hit_stop() -> void:
	_hit_stop_scheduled = false
	if _pending_hit_stop_seconds <= 0.0 or is_in_thinking_time() or _thinking_entry_active:
		return
	var duration: float = _pending_hit_stop_seconds
	if _hit_stop_timer != null:
		# 新的较短顿帧不能提前结束已有顿帧，也不把时长相加。
		duration = maxf(duration, _hit_stop_timer.get_time_left())
		_hit_stop_timer.cancel()
	_hit_stop_active = true
	_hit_stop_timer = create_real_timer(duration)
	_hit_stop_timer.timeout.connect(_finish_hit_stop)
	_refresh_tree_pause()
	_start_screen_shake(duration, _pending_shake_strength, get_combat_tuning().shake_frequency_hz, true)
	_pending_hit_stop_seconds = 0.0
	_pending_shake_strength = 0.0


func is_in_hit_stop() -> bool:
	return _hit_stop_active


func _cancel_hit_stop() -> void:
	_hit_stop_active = false
	if _hit_stop_timer != null:
		_hit_stop_timer.cancel()
		_hit_stop_timer = null
	_pending_hit_stop_seconds = 0.0
	_pending_shake_strength = 0.0
	if _screen_shake_owned_by_hit_stop:
		_cancel_screen_shake()


func _finish_hit_stop() -> void:
	_cancel_hit_stop()
	# 顿帧结束只释放自己的暂停，思考时间或胜利界面的暂停仍然保留。
	_refresh_tree_pause()
