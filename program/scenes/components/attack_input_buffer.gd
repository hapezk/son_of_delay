class_name AttackInputBuffer
extends Node

## 在暂停期间保留攻击、跳跃、下穿和方向输入；角色本身依然会随顿帧停止。
var group: DelayedActorGroup
var _time_authority: WorldTimeAuthority
## 只记录通过 _unhandled_input 被游戏接收的左键，避免 UI 点击被轮询误当成攻击。
var _primary_attack_down: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	group = get_parent() as DelayedActorGroup
	_time_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority


func _process(_delta: float) -> void:
	if group == null or not _primary_attack_down:
		return
	# 窗口失焦等情况可能丢失 release 事件，以真实按键状态兜底清理。
	if not Input.is_action_pressed("attack"):
		_primary_attack_down = false
		_clear_attack_hold()
		return
	if _is_thinking_time() or (get_tree().paused and not _is_in_hit_stop()):
		return
	var input_actor: BaseActor = _get_input_actor()
	if input_actor == null or not input_actor.has_method("resume_held_attack_input"):
		return
	input_actor.call("resume_held_attack_input", get_viewport().get_mouse_position())


## 使用 _unhandled_input，确保 UI 消费的鼠标点击不会触发攻击。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo() or group == null:
		return
	if event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey
		_handle_self_delay_shortcut(key_event)
		if get_viewport().is_input_handled():
			return
		_handle_weapon_switch(key_event)
		if get_viewport().is_input_handled():
			return
	if event.is_action("interact"):
		_handle_interact(event)
		return
	if event.is_action("attack"):
		_handle_attack_input(event)
		return
	if event.is_action("secondary_attack"):
		_handle_secondary_attack_input(event)
		return
	_handle_hit_stop_movement_input(event)


## F 先交给当前输入角色记录；存在延迟时，本体稍后回放到该帧才真正拾取。
func _handle_interact(event: InputEvent) -> void:
	if not event.is_action_pressed("interact") or _is_thinking_time() or get_tree().paused:
		return
	var input_actor: BaseActor = _get_input_actor()
	if input_actor == null or not input_actor.has_method("begin_interact_input"):
		return
	input_actor.call("begin_interact_input")
	get_viewport().set_input_as_handled()


## 非思考时间 Q/E 快速调整玩家自己；思考时间必须交给鼠标目标的 DelayAdjustmentInput。
func _handle_self_delay_shortcut(event: InputEventKey) -> void:
	if not event.pressed:
		return
	var keycode: Key = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	if keycode not in [KEY_Q, KEY_E] or not group.has_method("request_self_delay_shortcut"):
		return
	if _is_thinking_time():
		return
	if bool(group.call("request_self_delay_shortcut", keycode)):
		get_viewport().set_input_as_handled()


func _handle_attack_input(event: InputEvent) -> void:
	if event.is_action_released("attack"):
		_clear_attack_hold()
		return
	if not event.is_action_pressed("attack") or _is_thinking_time():
		return
	# 顿帧期间可以缓存攻击；除此以外的暂停不接受新的游戏输入。
	if get_tree().paused and not _is_in_hit_stop():
		return
	_primary_attack_down = true
	var input_actor: BaseActor = _get_input_actor()
	if input_actor == null:
		return
	var screen_position: Vector2 = event.position if event is InputEventMouse else Vector2.INF
	input_actor.begin_attack_input(screen_position)
	get_viewport().set_input_as_handled()


## 右键切换当前武器的蓄力模式；思考时间中不接收战斗输入。
func _handle_secondary_attack_input(event: InputEvent) -> void:
	if not event.is_action_pressed("secondary_attack") or _is_thinking_time():
		return
	# 与剑击一致：命中顿帧允许缓存，其他暂停状态不接收新的战斗输入。
	if get_tree().paused and not _is_in_hit_stop():
		return
	var input_actor: BaseActor = _get_input_actor()
	if input_actor == null or not input_actor.has_method("toggle_charge_mode"):
		return
	var screen_position: Vector2 = event.position if event is InputEventMouse else Vector2.INF
	input_actor.call("toggle_charge_mode", screen_position)
	get_viewport().set_input_as_handled()


## 数字键只在正常游戏中切武器；思考时间内继续交给延迟预设使用。
func _handle_weapon_switch(event: InputEventKey) -> void:
	if not event.pressed or _is_thinking_time():
		return
	if get_tree().paused and not _is_in_hit_stop():
		return
	var slot: int = 0
	match event.keycode:
		KEY_1:
			slot = 1
		KEY_2:
			slot = 2
		KEY_3:
			slot = 3
	if slot == 0:
		return
	var input_actor: BaseActor = _get_input_actor()
	if input_actor == null or not input_actor.has_method("select_weapon"):
		return
	input_actor.call("select_weapon", slot)
	get_viewport().set_input_as_handled()


## 只在命中顿帧中缓冲移动。未暂停时由 Player 读取 Input 的连续状态，保持原有手感。
func _handle_hit_stop_movement_input(event: InputEvent) -> void:
	if not get_tree().paused or not _is_in_hit_stop():
		return
	var action: StringName = &""
	if event.is_action_pressed("ui_left"):
		action = &"ui_left"
	elif event.is_action_pressed("ui_right"):
		action = &"ui_right"
	elif event.is_action_pressed("ui_up"):
		action = &"ui_up"
	elif event.is_action_pressed("ui_down"):
		action = &"ui_down"
	if action == &"":
		return
	var input_actor: BaseActor = _get_input_actor()
	if input_actor == null:
		return
	input_actor.buffer_hit_stop_input(action)
	get_viewport().set_input_as_handled()


func _get_input_actor() -> BaseActor:
	return group.preview_body if group.can_delay and group.delay_time > 0.0 else group.body


func _clear_attack_hold() -> void:
	_primary_attack_down = false
	for actor: BaseActor in [group.body, group.preview_body, group.predictor]:
		if actor != null:
			actor.release_attack_input()


func _is_thinking_time() -> bool:
	if not is_instance_valid(_time_authority):
		_time_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	return _time_authority != null and _time_authority.is_in_thinking_time()


func _is_in_hit_stop() -> bool:
	if not is_instance_valid(_time_authority):
		_time_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	return _time_authority != null and _time_authority.is_in_hit_stop()
