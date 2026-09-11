extends Node

## 线性教学只保存关卡内进度；玩家重生不会倒退已经完成的课程。
enum Lesson {
	MOVE,
	JUMP,
	DROP_THROUGH,
	SWORD_REPEAT,
	SWORD_CHARGE,
	PICK_UP_BOOMERANG,
	USE_BOOMERANG,
	PICK_UP_STAFF,
	USE_STAFF,
	ENTER_THINKING_TIME,
	FINE_TUNE_DELAY,
	REDUCE_SELF_DELAY,
	RESTORE_NATURAL_DELAY,
	SET_GATE_DELAY,
	ACTIVATE_GATE_SWITCH,
	PASS_DELAY_GATE,
	REACH_EXIT,
	COMPLETE,
}

const LESSON_COUNT: int = int(Lesson.COMPLETE)
const REQUIRED_SWORD_HITS: int = 3
const REQUIRED_GATE_DELAY: float = 0.9
const DELAY_CHECKPOINT: Vector2 = Vector2(2700.0, 625.0)
const PLAYER_HALF_WIDTH: float = 24.0
const MAIN_LEVEL_SCENE_PATH: String = "res://scenes/main.tscn"
const TUTORIAL_COMPLETE_PAUSE_REASON: StringName = &"tutorial_complete"

const LESSON_TITLES: PackedStringArray = [
	"移动",
	"跳跃",
	"下穿薄平台",
	"普通攻击",
	"蓄力攻击",
	"拾取回旋镖",
	"使用回旋镖",
	"拾取法杖",
	"使用法杖",
	"进入思考时间",
	"鼠标微调延迟",
	"消除自然延迟",
	"释放延迟负载",
	"设置升降门延迟",
	"启动升降门",
	"通过升降门",
	"抵达出口",
]
const LESSON_HINTS: PackedStringArray = [
	"蓝色预览体会立即响应输入，真实本体则会在 1 秒后重放相同动作。\n按住 A / D 左右移动；先观察两者之间的距离，再向右走到障碍前。",
	"按 W 跳跃。蓝色预览体会先展示路线和落点，真实本体将在 1 秒后起跳。\n利用预览判断是否能够越过前方方块，然后继续向右。",
	"绿色薄平台可以从下方穿过，也能主动向下离开。\n跳到平台上并站稳，再按 S 下穿；空中提前按 S 不会完成本课。",
	"鼠标瞄准假人左键使用普通攻击，按住可自动普攻。\n连续命中完整的三段连击；松开左键会停止自动攻击，假人上方会记录段数。",
	"鼠标右键进入蓄力模式，蓄力时间越久效果越强。\n瞄准假人等待蓄力阶段提升，再点击左键释放；再次按右键可以取消蓄力。",
	"靠近橙色回旋镖，头顶出现“F（拾取）”后按 F。\n拾取会永久解锁该武器；随后按数字键 2，把当前武器切换为回旋镖。",
	"回旋镖会沿鼠标方向飞出，达到最远距离后自动返回。\n瞄准前方假人点击左键；去程和回程都能命中，让它至少造成一次伤害。",
	"靠近紫色法杖，头顶出现“F（拾取）”后按 F。\n拾取会永久解锁该武器；随后按数字键 3，把当前武器切换为法杖。",
	"法杖会朝鼠标方向攻击：近距离由杖身命中，较远处会发射法术弹。\n瞄准前方假人点击左键，观察攻击方向，并至少造成一次伤害。",
	"按空格进入思考时间。世界会暂停，移动和攻击暂时停止，但仍可选择对象。\n把鼠标移到玩家、敌人或机关所在位置，目标上会显示待设定的延迟秒数。",
	"思考时间内把鼠标指向玩家，向下滚一格，把 1.00 秒微调为 0.99 秒。\n慢滚每格调整 0.01 秒；连续快滚会逐步加速到 0.1、1 秒档，向上滚则增加。",
	"保持鼠标指向玩家，按 R 将待设定值直接归零，再按空格提交。\n数字键 1 / 2 / 3 可快速预设秒数；提交后消耗 1 点能量并占用 1 秒负载。",
	"等能量恢复后，再按空格进入思考时间，指向玩家按 1，再按空格提交。\n恢复到 1 秒自然延迟不消耗能量，并释放之前占用的全部延迟负载。",
	"等待左上角时滞能量恢复，再按空格进入思考时间。\n鼠标指向整条竖直升降门所在位置，按 1 设为 1 秒，再按空格提交。",
	"踩住地面开关会发出开门命令，但升降门要等待已设置的 1 秒才执行。\n保持站在开关上，观察固定在门洞中央的延迟文字，直到真实门完全升起。",
	"离开开关后，关门命令同样会等待 1 秒才执行。\n门升起后立即按住 D 向右冲刺，在倒计时结束、升降门落下前穿过门洞。",
	"你已经完成从分配延迟、触发机关到利用延迟窗口通行的完整流程。\n继续向右移动，进入前方发光的教学出口；到达终点才算完成教学。",
]

@onready var player_group: DelayedActorGroup = get_node(
	"../Actors/BodyGroup") as DelayedActorGroup
@onready var sword_dummy: MeleeEnemy = get_node(
	"../TutorialCourse/SwordDummy") as MeleeEnemy
@onready var boomerang_target: MeleeEnemy = get_node(
	"../TutorialCourse/BoomerangTarget") as MeleeEnemy
@onready var staff_target: MeleeEnemy = get_node(
	"../TutorialCourse/StaffTarget") as MeleeEnemy
@onready var lift_gate_delay_controller: Node = get_node(
	"../TutorialCourse/LiftGate/LiftGateDelayController")
@onready var lift_gate: Node = get_node("../TutorialCourse/LiftGate")
@onready var pressure_switch: Node = get_node("../TutorialCourse/PressureSwitch")
@onready var world_time_authority: WorldTimeAuthority = get_node(
	"../WorldTimeAuthority") as WorldTimeAuthority

@onready var gate_after_drop: StaticBody2D = get_node(
	"../TutorialCourse/Gates/GateAfterDrop") as StaticBody2D
@onready var gate_after_sword: StaticBody2D = get_node(
	"../TutorialCourse/Gates/GateAfterSword") as StaticBody2D
@onready var gate_after_boomerang: StaticBody2D = get_node(
	"../TutorialCourse/Gates/GateAfterBoomerang") as StaticBody2D
@onready var gate_after_staff: StaticBody2D = get_node(
	"../TutorialCourse/Gates/GateAfterStaff") as StaticBody2D
@onready var lesson_title: Label = get_node(
	"../TutorialUI/LessonPanel/Margin/VBox/LessonTitle") as Label
@onready var lesson_hint: Label = get_node(
	"../TutorialUI/LessonPanel/Margin/VBox/LessonHint") as Label
@onready var completion_backdrop: ColorRect = get_node(
	"../TutorialUI/CompletionBackdrop") as ColorRect
@onready var completion_continue_button: Button = get_node(
	"../TutorialUI/CompletionBackdrop/ContinueButton") as Button

var _lesson: Lesson = Lesson.MOVE
var _transition_started: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	completion_backdrop.visible = false
	completion_continue_button.pressed.connect(_go_to_main_level)
	_update_lesson_ui()


func _process(_delta: float) -> void:
	if _lesson == Lesson.COMPLETE or player_group == null:
		return
	var player: BaseActor = _get_live_player()
	if player == null:
		return
	# 玩家完成延迟设置后，以实际路线结果为准：越门追到出口课，到终点直接完成。
	if _lesson >= Lesson.ACTIVATE_GATE_SWITCH:
		if player.global_position.x >= 3500.0:
			_set_lesson(Lesson.COMPLETE)
			return
		if _lesson <= Lesson.PASS_DELAY_GATE \
				and player.global_position.x >= _get_gate_pass_x():
			_set_lesson(Lesson.REACH_EXIT)
			return

	match _lesson:
		Lesson.MOVE:
			if player.global_position.x >= 360.0:
				_set_lesson(Lesson.JUMP)
		Lesson.JUMP:
			if player.global_position.x >= 680.0:
				_set_lesson(Lesson.DROP_THROUGH)
		Lesson.DROP_THROUGH:
			if player.has_method("is_dropping_through_platform") \
					and bool(player.call("is_dropping_through_platform")):
				_set_lesson(Lesson.SWORD_REPEAT)
		Lesson.SWORD_REPEAT:
			if sword_dummy.hit_count >= REQUIRED_SWORD_HITS \
					and sword_dummy.last_combo == 3:
				_set_lesson(Lesson.SWORD_CHARGE)
		Lesson.SWORD_CHARGE:
			if sword_dummy.last_combo == 4:
				_set_lesson(Lesson.PICK_UP_BOOMERANG)
		Lesson.PICK_UP_BOOMERANG:
			if player_group.is_weapon_unlocked(2) \
					and int(player.get("equipped_weapon")) == 2:
				_set_lesson(Lesson.USE_BOOMERANG)
		Lesson.USE_BOOMERANG:
			if boomerang_target.hit_count > 0:
				_set_lesson(Lesson.PICK_UP_STAFF)
		Lesson.PICK_UP_STAFF:
			if player_group.is_weapon_unlocked(3) \
					and int(player.get("equipped_weapon")) == 3:
				_set_lesson(Lesson.USE_STAFF)
		Lesson.USE_STAFF:
			if staff_target.hit_count > 0:
				_set_lesson(Lesson.ENTER_THINKING_TIME)
		Lesson.ENTER_THINKING_TIME:
			if world_time_authority.is_in_thinking_time():
				_set_lesson(Lesson.FINE_TUNE_DELAY)
		Lesson.FINE_TUNE_DELAY:
			# 必须在思考时间中先做一次 0.01 秒级微调，才能进入快捷归零教学。
			var requested_delay: float = player_group.get_requested_delay()
			if world_time_authority.is_in_thinking_time() \
					and requested_delay > 0.0 \
					and requested_delay < player_group.natural_delay_time:
				_set_lesson(Lesson.REDUCE_SELF_DELAY)
		Lesson.REDUCE_SELF_DELAY:
			if is_zero_approx(player_group.delay_time):
				_set_lesson(Lesson.RESTORE_NATURAL_DELAY)
		Lesson.RESTORE_NATURAL_DELAY:
			if is_equal_approx(
					player_group.delay_time, player_group.natural_delay_time):
				_set_lesson(Lesson.SET_GATE_DELAY)
		Lesson.SET_GATE_DELAY:
			# 必须退出思考时间并正式提交；只排队一个数值不算完成。
			if float(lift_gate_delay_controller.get("delay_time")) >= REQUIRED_GATE_DELAY:
				_set_lesson(Lesson.ACTIVATE_GATE_SWITCH)
		Lesson.ACTIVATE_GATE_SWITCH:
			# 门完全升起意味着开关的开启命令已经实际通过延迟时间线。
			if bool(pressure_switch.call("is_pressed")) \
					and bool(lift_gate.call("is_fully_open")):
				_set_lesson(Lesson.PASS_DELAY_GATE)
		Lesson.PASS_DELAY_GATE:
			if player.global_position.x >= _get_gate_pass_x():
				_set_lesson(Lesson.REACH_EXIT)
		Lesson.REACH_EXIT:
			if player.global_position.x >= 3500.0:
				_set_lesson(Lesson.COMPLETE)


func _unhandled_input(event: InputEvent) -> void:
	if _lesson != Lesson.COMPLETE or event.is_echo():
		return
	if event is InputEventKey and event.pressed \
			and event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		get_viewport().set_input_as_handled()
		_go_to_main_level()


func _exit_tree() -> void:
	if world_time_authority != null and is_instance_valid(world_time_authority) \
			and world_time_authority.is_inside_tree():
		world_time_authority.release_external_pause(TUTORIAL_COMPLETE_PAUSE_REASON)


func get_lesson_index() -> int:
	return int(_lesson)


func is_complete() -> bool:
	return _lesson == Lesson.COMPLETE


func _get_gate_pass_x() -> float:
	var gate_node: Node2D = lift_gate as Node2D
	return gate_node.global_position.x \
		+ float(lift_gate.get("gate_width")) * 0.5 + PLAYER_HALF_WIDTH + 8.0


func _get_live_player() -> BaseActor:
	if player_group.preview_body != null and player_group.preview_body.inputed:
		return player_group.preview_body
	return player_group.body


func _set_lesson(new_lesson: Lesson) -> void:
	if new_lesson <= _lesson:
		return
	_lesson = new_lesson
	match _lesson:
		Lesson.SWORD_REPEAT:
			_open_gate(gate_after_drop)
		Lesson.PICK_UP_BOOMERANG:
			_open_gate(gate_after_sword)
		Lesson.PICK_UP_STAFF:
			_open_gate(gate_after_boomerang)
		Lesson.REDUCE_SELF_DELAY:
			_open_gate(gate_after_staff)
			# 机关区失败后从附近继续，不必重跑已经掌握的武器课程。
			player_group.set_respawn_point(DELAY_CHECKPOINT)
		Lesson.COMPLETE:
			completion_backdrop.visible = true
			world_time_authority.request_external_pause(TUTORIAL_COMPLETE_PAUSE_REASON)
			completion_continue_button.grab_focus()
	_update_lesson_ui()


## 教学完成按钮与 Enter 共用同一入口，且只允许触发一次场景切换。
func _go_to_main_level() -> void:
	if _lesson != Lesson.COMPLETE or _transition_started:
		return
	_transition_started = true
	world_time_authority.release_external_pause(TUTORIAL_COMPLETE_PAUSE_REASON)
	var change_error: Error = get_tree().change_scene_to_file(MAIN_LEVEL_SCENE_PATH)
	if change_error != OK:
		_transition_started = false
		world_time_authority.request_external_pause(TUTORIAL_COMPLETE_PAUSE_REASON)
		push_error("TutorialController: failed to open main level (%s)" % change_error)


func _open_gate(gate: StaticBody2D) -> void:
	var collision: CollisionShape2D = gate.get_node(
		"CollisionShape2D") as CollisionShape2D
	var visual: Polygon2D = gate.get_node("Visual") as Polygon2D
	var label: Label = gate.get_node("GateLabel") as Label
	collision.set_deferred("disabled", true)
	visual.modulate = Color(1.0, 1.0, 1.0, 0.14)
	label.visible = false


func _update_lesson_ui() -> void:
	if _lesson == Lesson.COMPLETE:
		lesson_title.text = "教学完成"
		lesson_hint.text = "你已经掌握移动、武器基础、玩家自然延迟、精确调节与机关延迟控制。"
		return
	lesson_title.text = "教学 %d / %d · %s" % [
		int(_lesson) + 1,
		LESSON_COUNT,
		LESSON_TITLES[int(_lesson)],
	]
	lesson_hint.text = LESSON_HINTS[int(_lesson)]
