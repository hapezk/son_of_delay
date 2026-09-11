extends Node2D

## 此脚本同时服务于纯预测场景（PlayerGroup）与战斗手测场景（BodyGroup），
## 不能在 @onready 初始化器里写死其中一个路径，否则另一个场景会得到 null。
const MELEE_ENEMY_SCENE: PackedScene = preload(
	"res://scenes/combat/enemies/melee_enemy.tscn")

@export_group("Weapon Tuning Dummies")
## 开启后，仅在手动战斗测试场景中把原来的近战/远程敌人原地替换为不会还手的训练假人。
## 正式 main.tscn 不会被修改；纯预测测试场景没有 Enemies，也不会受影响。
@export var replace_enemies_with_training_dummies: bool = true
## 每个训练假人的最大生命值；使用高血量避免调试连段时频繁触发胜利和重开。
@export_range(1.0, 1000000.0, 100.0) var tuning_dummy_max_health: float = 10000.0
## 训练假人承受硬直的倍率；最终硬直仍等于武器基础硬直乘此值。
@export_range(0.0, 5.0, 0.05) var tuning_dummy_hurt_stun_multiplier: float = 1.0
## 训练假人承受击退的倍率；0 固定原地，1 正常，2 约为双倍理想距离。
@export_range(0.0, 5.0, 0.05) var tuning_dummy_knockback_multiplier: float = 1.0

var group: DelayedActorGroup
var body: BaseActor
var preview: BaseActor
@onready var camera: Camera2D = $Camera2D
@onready var time_authority: WorldTimeAuthority = $Main/WorldTimeAuthority
var time_slice: TimeSliceSystem

var physics_frames: int = 0
var report: PackedStringArray = PackedStringArray()
var hud: Label
var prediction_group: DelayedActorGroup
var headless_verifier: HeadlessPredictionVerifier
var _auto_prediction_test_enabled: bool = false
var _auto_prediction_test_started: bool = false
## 输入或延迟状态变化后逐帧记录一小段时间，专门捕获“刚设置就回收”的瞬间。
var _detailed_trace_frames_left: int = 0
var _last_control_signature: String = ""
var _last_saved_report_path: String = ""
## 只追踪远程敌人的权威弹体；键为实例 ID，值为发射者路径。
var _tracked_hostile_projectiles: Dictionary[int, String] = {}
var _hostile_projectile_min_distance: Dictionary[int, float] = {}
var _last_hostile_projectile_count: int = -1
const HUD_MARGIN: float = 20.0
const HUD_PANEL_GAP: float = 16.0
const DETAILED_TRACE_FRAMES: int = 240
const PROJECTILE_TRACE_INTERVAL_FRAMES: int = 5
const MAX_REPORT_LINES: int = 8000
const LATEST_REPORT_PATH: String = "user://manual_prediction_trace_latest.txt"


func _ready() -> void:
	# 此节点必须保持默认的 PAUSABLE 模式。
	# Main 是它的子节点；若此处设为 ALWAYS，角色和时间切片会继承 ALWAYS，
	# 从而绕过场景树暂停。只有 WorldTimeAuthority 自己需要 ALWAYS。
	report.clear()
	_replace_combat_enemies_with_training_dummies()
	group = get_node_or_null("Main/Actors/PlayerGroup") as DelayedActorGroup
	if group == null:
		group = get_node_or_null("Main/Actors/BodyGroup") as DelayedActorGroup
	if group == null:
		push_error("ManualTimeScaleRunner: Main/Actors 下未找到 PlayerGroup 或 BodyGroup")
		set_process(false)
		set_physics_process(false)
		return
	body = group.body
	preview = group.preview_body
	time_slice = group.time_slice_system as TimeSliceSystem
	# Group 在默认优先级执行后，再记录切换后的最终状态。
	process_physics_priority = 100
	# 战斗主场景已有横板镜头时不要用测试相机覆盖；旧纯预测场景仍使用本地后备相机。
	var gameplay_camera: Camera2D = get_node_or_null("Main/SideScrollCamera") as Camera2D
	if gameplay_camera != null:
		gameplay_camera.make_current()
		camera.enabled = false
	else:
		camera.make_current()
	var canvas: CanvasLayer = CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)
	hud = Label.new()
	hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud.add_theme_font_size_override("font_size", 18)
	hud.add_theme_color_override("font_color", Color.YELLOW)
	canvas.add_child(hud)
	get_viewport().size_changed.connect(_update_hud_layout)
	_update_hud_layout()

	# 正式 DelayedActorGroup 已自行注册到唯一的思考时间控制器。
	prediction_group = group
	if not group.prediction_diverged.is_connected(_on_prediction_diverged):
		group.prediction_diverged.connect(_on_prediction_diverged)
	_last_saved_report_path = ProjectSettings.globalize_path(LATEST_REPORT_PATH)
	_last_control_signature = _build_control_signature()
	_detailed_trace_frames_left = DETAILED_TRACE_FRAMES
	log_line("BEGIN report=%s" % _last_saved_report_path)
	_connect_ranged_projectile_diagnostics()
	log_runtime_state("INITIAL", 0.0)

	_auto_prediction_test_enabled = OS.get_cmdline_user_args().has("--auto-prediction-test")
	if _auto_prediction_test_enabled and prediction_group != null:
		headless_verifier = HeadlessPredictionVerifier.new()
		headless_verifier.process_mode = Node.PROCESS_MODE_ALWAYS
		headless_verifier.process_physics_priority = 1000
		headless_verifier.configure(prediction_group, time_authority, time_slice)
		add_child(headless_verifier)
		Input.action_press("ui_right")


## CombatRoomController 延后一帧收集敌人；父包装器在此之前同步替换，计数和胜利监听会绑定新假人。
func _replace_combat_enemies_with_training_dummies() -> void:
	if not replace_enemies_with_training_dummies:
		return
	var target_root: Node2D = get_node_or_null("Main/Enemies") as Node2D
	if target_root == null:
		return
	var target_names: PackedStringArray = PackedStringArray()
	var target_positions: Array[Vector2] = []
	for target: Node in target_root.get_children():
		if not target.has_method("is_defeated"):
			continue
		target_names.append(String(target.name))
		target_positions.append((target as Node2D).position if target is Node2D else Vector2.ZERO)
		# 先从父节点移除，确保稍后 CombatRoomController 只收集替换后的假人。
		target_root.remove_child(target)
		# 旧延迟控制器在 _ready() 中安排过延后初始化；立即释放可取消其离树后的悬空回调。
		target.free()

	for index: int in range(target_positions.size()):
		var dummy: MeleeEnemy = MELEE_ENEMY_SCENE.instantiate() as MeleeEnemy
		if dummy == null:
			push_error("ManualTimeScaleRunner: melee_enemy.tscn 无法实例化 MeleeEnemy")
			continue
		dummy.name = StringName(target_names[index])
		dummy.position = target_positions[index]
		dummy.max_health = tuning_dummy_max_health
		dummy.attack_enabled = false
		dummy.damage_enabled = false
		dummy.move_speed = 0.0
		dummy.hurt_stun_multiplier = tuning_dummy_hurt_stun_multiplier
		dummy.knockback_received_multiplier = tuning_dummy_knockback_multiplier
		dummy.add_to_group("weapon_tuning_dummy")
		target_root.add_child(dummy)


## HUD 宽度始终贴合窗口，避免测试操作说明被截断。
func _update_hud_layout() -> void:
	if hud == null:
		return
	var viewport_width: float = get_viewport_rect().size.x
	var hud_top: float = HUD_MARGIN
	var stats_panel: Control = get_tree().get_first_node_in_group("player_stats_panel") as Control
	if stats_panel != null and is_instance_valid(stats_panel):
		hud_top = maxf(hud_top, stats_panel.get_global_rect().end.y + HUD_PANEL_GAP)
	hud.position = Vector2(HUD_MARGIN, hud_top)
	hud.size = Vector2(maxf(viewport_width - HUD_MARGIN * 2.0, 240.0), 0.0)


func _input(event: InputEvent) -> void:
	var event_description: String = _describe_relevant_input(event)
	if not event_description.is_empty():
		log_line("INPUT " + event_description)
		_detailed_trace_frames_left = DETAILED_TRACE_FRAMES
	if not (event is InputEventKey and event.is_pressed() and not event.is_echo()):
		return
	match event.keycode:
		KEY_F8:
			save_report_now("MANUAL_F8")
		KEY_ESCAPE:
			save_and_quit()


func save_and_quit() -> void:
	log_line("END frame=%d" % physics_frames)
	var timestamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	var timestamp_path: String = "user://manual_time_scale_report_%s.txt" % timestamp
	_write_report(timestamp_path)
	_write_report("user://manual_time_scale_report_latest.txt")
	_write_report(LATEST_REPORT_PATH)
	get_tree().quit()


## 不退出场景也能落盘；复现后按 F8，日志路径会同时显示在 HUD 与 Godot 输出中。
func save_report_now(tag: String) -> void:
	log_line("SAVE tag=%s frame=%d" % [tag, physics_frames])
	_write_report(LATEST_REPORT_PATH)
	print("MANUAL_PREDICTION_TRACE_SAVED: %s" % _last_saved_report_path)


func _write_report(path: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(report))
		file.close()


func log_line(message: String) -> void:
	report.append("%d %s" % [Time.get_ticks_usec(), message])
	if report.size() > MAX_REPORT_LINES:
		report.remove_at(0)


## 发射、飞行、碰撞和销毁四层日志共同定位“看似命中但未扣血”的真正分支。
func _connect_ranged_projectile_diagnostics() -> void:
	var connected_emitters: int = 0
	for enemy_node: Node in get_tree().get_nodes_in_group("enemy_damage_body"):
		if not enemy_node.has_signal(&"projectile_fired"):
			continue
		var callback: Callable = Callable(self, "_on_ranged_projectile_fired").bind(enemy_node)
		if not enemy_node.is_connected(&"projectile_fired", callback):
			enemy_node.connect(&"projectile_fired", callback)
		connected_emitters += 1
	log_line("PROJECTILE_DIAGNOSTICS_READY emitters=%d trace_interval_frames=%d" % [
		connected_emitters, PROJECTILE_TRACE_INTERVAL_FRAMES
	])


func _on_ranged_projectile_fired(projectile: BaseActor, shooter: Node) -> void:
	if not projectile is DelayableProjectile:
		log_line("PROJECTILE_SPAWN_UNSUPPORTED shooter=%s projectile=%s class=%s" % [
			str(shooter.get_path()), str(projectile.get_path()), projectile.get_class()
		])
		return
	var hostile_projectile: DelayableProjectile = projectile as DelayableProjectile
	var projectile_id: int = hostile_projectile.get_instance_id()
	var shooter_path: String = str(shooter.get_path())
	_tracked_hostile_projectiles[projectile_id] = shooter_path
	_hostile_projectile_min_distance[projectile_id] = hostile_projectile.global_position.distance_to(body.global_position)
	if not hostile_projectile.diagnostic_event.is_connected(_on_hostile_projectile_diagnostic):
		hostile_projectile.diagnostic_event.connect(_on_hostile_projectile_diagnostic)
	var exit_callback: Callable = Callable(self, "_on_hostile_projectile_tree_exiting").bind(projectile_id)
	if not hostile_projectile.tree_exiting.is_connected(exit_callback):
		hostile_projectile.tree_exiting.connect(exit_callback)

	var live_aim: Vector2 = (body.global_position - hostile_projectile.global_position).normalized()
	var aim_error_degrees: float = 0.0
	if not live_aim.is_zero_approx():
		aim_error_degrees = absf(rad_to_deg(angle_difference(
			hostile_projectile.travel_direction.angle(), live_aim.angle()
		)))
	var player_can_receive: bool = body.has_method("can_receive_hit") and bool(body.call("can_receive_hit"))
	log_line(("PROJECTILE_SPAWN frame=%d id=%d name=%s shooter=%s shooter_pos=%s projectile_pos=%s "
		+ "direction=%s velocity=%s live_aim=%s aim_error_deg=%.3f speed=%.2f move_speed=%.2f "
		+ "damage=%.2f lifetime=%.3f collision=(layer:%d mask:%d shape:%s) "
		+ "bounce=(enabled:%s count:%d/%d) penetration=%d/%d player=(pos:%s vel:%s hp:%.2f invul:%.3f can_receive:%s shape:%s)") % [
		physics_frames, projectile_id, hostile_projectile.name, shooter_path,
		str((shooter as Node2D).global_position) if shooter is Node2D else "n/a",
		str(hostile_projectile.global_position), str(hostile_projectile.travel_direction),
		str(hostile_projectile.velocity), str(live_aim), aim_error_degrees,
		hostile_projectile.velocity.length(), hostile_projectile.move_speed,
		hostile_projectile.damage, hostile_projectile.remaining_lifetime,
		hostile_projectile.collision_layer, hostile_projectile.collision_mask,
		_describe_actor_collision_shape(hostile_projectile),
		str(hostile_projectile.bounce_enabled), hostile_projectile.bounce_count,
		hostile_projectile.max_bounces, hostile_projectile.penetration_count,
		hostile_projectile.max_penetrations, str(body.global_position), str(body.velocity),
		float(body.get("current_health")), float(body.get("_hurt_invulnerability_left")),
		str(player_can_receive), _describe_actor_collision_shape(body)
	])


func _on_hostile_projectile_diagnostic(projectile: BaseActor, event: Dictionary) -> void:
	log_line("PROJECTILE_EVENT frame=%d id=%d source=%s data=%s" % [
		physics_frames, projectile.get_instance_id(),
		_tracked_hostile_projectiles.get(projectile.get_instance_id(), "unknown"), str(event)
	])


func _on_hostile_projectile_tree_exiting(projectile_id: int) -> void:
	log_line("PROJECTILE_EXIT frame=%d id=%d source=%s min_player_distance=%.3f" % [
		physics_frames, projectile_id, _tracked_hostile_projectiles.get(projectile_id, "unknown"),
		_hostile_projectile_min_distance.get(projectile_id, -1.0)
	])
	_tracked_hostile_projectiles.erase(projectile_id)
	_hostile_projectile_min_distance.erase(projectile_id)


## 每帧更新最近距离，每五帧落一次位置；数量变化则立刻写入，避免短命弹体漏记。
func _trace_hostile_projectiles() -> void:
	var projectile_nodes: Array[Node] = get_tree().get_nodes_in_group("hostile_projectiles")
	var projectile_count: int = projectile_nodes.size()
	var count_changed: bool = projectile_count != _last_hostile_projectile_count
	if count_changed:
		var container: Node = get_tree().get_first_node_in_group("hostile_projectile_container")
		var container_children: int = container.get_child_count() if container != null else -1
		log_line("PROJECTILE_COUNT frame=%d active=%d container_children=%d tracked=%d" % [
			physics_frames, projectile_count, container_children, _tracked_hostile_projectiles.size()
		])
		_last_hostile_projectile_count = projectile_count
	var should_write_trace: bool = count_changed or physics_frames % PROJECTILE_TRACE_INTERVAL_FRAMES == 0
	for projectile_node: Node in projectile_nodes:
		if not projectile_node is DelayableProjectile:
			continue
		var projectile: DelayableProjectile = projectile_node as DelayableProjectile
		var projectile_id: int = projectile.get_instance_id()
		var distance_to_player: float = projectile.global_position.distance_to(body.global_position)
		var previous_minimum: float = _hostile_projectile_min_distance.get(projectile_id, INF)
		_hostile_projectile_min_distance[projectile_id] = minf(previous_minimum, distance_to_player)
		if not should_write_trace:
			continue
		var controller: DelayControllerBase = projectile.get_node_or_null("ProjectileDelayController") as DelayControllerBase
		var delay_text: String = "none"
		if controller != null:
			delay_text = "delay:%.3f requested:%.3f preview=(visible:%s pos:%s vel:%s)" % [
				controller.delay_time, controller.get_requested_delay(),
				str(controller.preview_body.visible) if controller.preview_body != null else "n/a",
				str(controller.preview_body.global_position) if controller.preview_body != null else "n/a",
				str(controller.preview_body.velocity) if controller.preview_body != null else "n/a",
			]
		var player_can_receive: bool = body.has_method("can_receive_hit") and bool(body.call("can_receive_hit"))
		log_line(("PROJECTILE_TRACE frame=%d id=%d source=%s pos=%s vel=%s speed=%.2f direction=%s "
			+ "remaining=%.3f active=%s distance_to_player=%.3f min_distance=%.3f collision=(layer:%d mask:%d) "
			+ "player=(pos:%s vel:%s hp:%.2f invul:%.3f can_receive:%s) controller={%s}") % [
			physics_frames, projectile_id, _tracked_hostile_projectiles.get(projectile_id, "unknown"),
			str(projectile.global_position), str(projectile.velocity), projectile.velocity.length(),
			str(projectile.travel_direction), projectile.remaining_lifetime, str(projectile.active),
			distance_to_player, _hostile_projectile_min_distance[projectile_id],
			projectile.collision_layer, projectile.collision_mask, str(body.global_position),
			str(body.velocity), float(body.get("current_health")),
			float(body.get("_hurt_invulnerability_left")), str(player_can_receive), delay_text
		])


func _describe_actor_collision_shape(actor: BaseActor) -> String:
	if actor.base_collision == null or actor.base_collision.shape == null:
		return "none"
	var shape: Shape2D = actor.base_collision.shape
	if shape is CircleShape2D:
		return "Circle(r=%.2f scale=%s)" % [(shape as CircleShape2D).radius, str(actor.base_collision.scale)]
	if shape is RectangleShape2D:
		return "Rectangle(size=%s scale=%s)" % [
			str((shape as RectangleShape2D).size), str(actor.base_collision.scale)
		]
	if shape is CapsuleShape2D:
		return "Capsule(r=%.2f h=%.2f scale=%s)" % [
			(shape as CapsuleShape2D).radius, (shape as CapsuleShape2D).height,
			str(actor.base_collision.scale)
		]
	return "%s(scale=%s)" % [shape.get_class(), str(actor.base_collision.scale)]


func log_runtime_state(tag: String, physics_delta: float) -> void:
	var gap: float = (body.global_position - preview.global_position).length()
	var shown_slices: int = 0
	if time_slice != null:
		for slice: Sprite2D in time_slice.slice_pool:
			if slice.visible:
				shown_slices += 1
	var preview_system_state: PreviewSystem = group.preview_system
	var expected_text: String = "expected=none"
	if preview_system_state != null and preview_system_state.capacity > 0 and preview_system_state.read_head >= 0:
		# Body.consume() 会先推进读头，因此上一格就是本帧刚刚尝试回放的记录。
		var consumed_index: int = (preview_system_state.read_head - 1 + preview_system_state.capacity) % preview_system_state.capacity
		var expected: Recording = preview_system_state.slots[consumed_index]
		if expected != null:
			expected_text = "expected_idx=%d pos=%s vel=%s input=(%.1f,%s,%s)" % [
				consumed_index, str(expected.pos), str(expected.vel), expected.move_dir,
				str(expected.jump_pressed), str(expected.attack_pressed)
			]
	var body_simulation: Dictionary = body.capture_simulation_state()
	var preview_simulation: Dictionary = preview.capture_simulation_state()
	log_line("%s frame=%d tps=%d physics_delta=%.6f paused=%s thinking=%s delay=%.3f requested=%.3f pending=%.3f gap=%.3f slices=%d divergence=%d/%s pos_err=%.3f vel_err=%.3f flash=%d heads=(w:%d r:%d stall:%d) body={input:%s pos:%s vel:%s ground:%s hp:%.1f coyote:%.3f jump_req:%.3f} preview={input:%s visible:%s pos:%s vel:%s ground:%s coyote:%.3f jump_req:%.3f} raw_input={axis:%.1f jump:%s attack:%s} %s" % [
		tag, physics_frames, Engine.physics_ticks_per_second, physics_delta, str(get_tree().paused),
		str(time_authority.is_in_thinking_time()),
		group.delay_time, group.get_requested_delay(), group._pending_delay, gap, shown_slices,
		group.divergence_count, str(group.last_divergence_reason),
		group.last_divergence_position_error, group.last_divergence_velocity_error,
		group._divergence_flashback_frames_left,
		preview_system_state.write_head, preview_system_state.read_head, preview_system_state.stall_frames,
		str(body.inputed), str(body.global_position), str(body.velocity), str(body.is_grounded_for_simulation()),
		float(body.get("current_health")), float(body_simulation.get("coyote_time_left", 0.0)),
		float(body_simulation.get("jump_request_time_left", 0.0)),
		str(preview.inputed), str(preview.visible), str(preview.global_position), str(preview.velocity),
		str(preview.is_grounded_for_simulation()), float(preview_simulation.get("coyote_time_left", 0.0)),
		float(preview_simulation.get("jump_request_time_left", 0.0)),
		Input.get_axis("ui_left", "ui_right"), str(Input.is_action_pressed("ui_up")),
		str(Input.is_action_pressed("attack")), expected_text
	])


## 只把会影响这次复现的键鼠事件写入日志，鼠标移动不会刷屏。
func _describe_relevant_input(event: InputEvent) -> String:
	if event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey
		var keycode: Key = key_event.keycode if key_event.keycode != KEY_NONE else key_event.physical_keycode
		if keycode not in [KEY_A, KEY_D, KEY_W, KEY_S, KEY_SPACE, KEY_1, KEY_2, KEY_3, KEY_R, KEY_F8, KEY_ESCAPE]:
			return ""
		return "key=%s code=%d pressed=%s echo=%s" % [
			OS.get_keycode_string(keycode), int(keycode), str(key_event.pressed), str(key_event.echo)
		]
	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event as InputEventMouseButton
		if mouse_event.button_index not in [
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN
		]:
			return ""
		return "mouse_button=%d pressed=%s pos=%s" % [
			mouse_event.button_index, str(mouse_event.pressed), str(mouse_event.position)
		]
	return ""


## 控制权、待提交延迟或分歧状态改变时，自动开启逐帧追踪窗口。
func _build_control_signature() -> String:
	return "%.4f|%.4f|%.4f|%d|%s|%s|%s|%s|%s" % [
		group.delay_time, group.get_requested_delay(), group._pending_delay,
		group.divergence_count, str(group.last_divergence_reason), str(body.inputed),
		str(preview.inputed), str(preview.visible), str(time_authority.is_in_thinking_time())
	]


func _on_prediction_diverged(reason: StringName, position_error: float, velocity_error: float) -> void:
	_detailed_trace_frames_left = DETAILED_TRACE_FRAMES
	log_line("EVENT prediction_diverged reason=%s position_error=%.6f velocity_error=%.6f" % [
		str(reason), position_error, velocity_error
	])
	log_runtime_state("DIVERGENCE_SIGNAL", 0.0)
	# 自动覆盖 latest，即使复现后直接停止运行，也能保留关键现场。
	_write_report(LATEST_REPORT_PATH)
	print("MANUAL_PREDICTION_DIVERGED: reason=%s report=%s" % [str(reason), _last_saved_report_path])

func _physics_process(_delta: float) -> void:
	physics_frames += 1
	_trace_hostile_projectiles()
	var control_signature: String = _build_control_signature()
	if control_signature != _last_control_signature:
		log_line("STATE_CHANGE old=%s new=%s" % [_last_control_signature, control_signature])
		_last_control_signature = control_signature
		_detailed_trace_frames_left = DETAILED_TRACE_FRAMES
	if _detailed_trace_frames_left > 0:
		log_runtime_state("TRACE", _delta)
		_detailed_trace_frames_left -= 1
	elif physics_frames % 60 == 0:
		log_runtime_state("PHYSICS", _delta)
	if _auto_prediction_test_enabled:
		if physics_frames == 180:
			Input.action_release("ui_right")
		elif physics_frames >= 220 and not _auto_prediction_test_started:
			_auto_prediction_test_started = true
			# 使用非二进制精确小数，顺便验证 100 TPS 的 roundi 帧量化不会少一帧。
			var target_delay: float = 0.29
			headless_verifier.begin(target_delay)
			time_authority.enter_thinking_time()
	# 测试减延迟目标时保持固定视角，方便观察本体、预览体与目标影像的相对位置。


func _process(delta: float) -> void:
	var gap: float = (body.global_position - preview.global_position).length()
	var physics_delta: float = 0.0
	if Engine.physics_ticks_per_second > 0:
		physics_delta = Engine.time_scale / float(Engine.physics_ticks_per_second)
	hud.text = (
		"思考时间: %s  场景暂停: %s\n" % [str(time_authority.is_in_thinking_time()), str(get_tree().paused)] +
		"调度TPS: %d  物理delta: %.4f  process delta: %.4f\n" % [Engine.physics_ticks_per_second, physics_delta, delta] +
		"物理帧: %d  延迟: %.1fs  间距: %.1f\n" % [physics_frames, group.delay_time, gap] +
		"空格：思考时间（暂停/恢复） | 思考时间中指向对象 + 1/2/3/R 或滚轮：修改延迟\n" +
		"远程弹诊断：每 5 帧记录位置，并记录发射、碰撞、扣血结果与销毁原因\n" +
		"F8：立即保存诊断日志 | ESC：保存并退出\n" +
		"日志：%s" % _last_saved_report_path
	)


## 可选无头验证器：比较预测终点、临时切片和恢复后的正常切片。
class HeadlessPredictionVerifier:
	extends Node

	var group: DelayedActorGroup
	var time_authority: WorldTimeAuthority
	var time_slice: TimeSliceSystem
	var _active: bool = false
	var _captured_prediction: bool = false
	var _requesting_thinking_reset: bool = false
	var _verifying_thinking_reset: bool = false
	var _target_delay: float = 0.0
	var _expected_preview_position: Vector2 = Vector2.ZERO
	var _expected_slice_positions: Array[Vector2] = []
	var _expected_slice_alphas: Array[float] = []
	var _expected_slice_textures: Array[Texture2D] = []


	func configure(
		target_group: DelayedActorGroup,
		target_authority: WorldTimeAuthority,
		target_time_slice: TimeSliceSystem
	) -> void:
		group = target_group
		time_authority = target_authority
		time_slice = target_time_slice


	func begin(target_delay: float) -> void:
		_target_delay = target_delay
		_active = true
		_captured_prediction = false
		_requesting_thinking_reset = false
		_verifying_thinking_reset = false


	func _physics_process(_delta: float) -> void:
		if not _active:
			return
		if _verifying_thinking_reset:
			_verify_thinking_reset_finished()
			return
		if _requesting_thinking_reset:
			_request_reset_when_thinking_time_is_ready()
			return
		if not _captured_prediction:
			_capture_prediction_when_ready()
			return
		if time_authority.is_in_thinking_time():
			return
		_verify_committed_state()


	func _capture_prediction_when_ready() -> void:
		if time_authority.is_entering_thinking_time():
			return
		if not time_authority.is_in_thinking_time() or not get_tree().paused:
			_fail("世界未保持在思考时间暂停状态")
			return
		# 延迟请求必须等减速入场结束后再提交，避免它在仍运行的世界里提前生效。
		group.request_delay_change(_target_delay)
		var sample: Dictionary = group.get_delay_preview_sample(_target_delay)
		if sample.is_empty():
			return
		_expected_preview_position = sample["position"]
		if _expected_preview_position.distance_to(group.body.global_position) <= 0.1:
			_fail("预测终点仍与本体重合，预测器没有产生有效位移")
			return

		_expected_slice_positions.clear()
		_expected_slice_alphas.clear()
		_expected_slice_textures.clear()
		for slice: Sprite2D in group.prediction_slice_pool:
			if not slice.visible:
				continue
			_expected_slice_positions.append(slice.global_position)
			_expected_slice_alphas.append(slice.modulate.a)
			_expected_slice_textures.append(slice.texture)
		if _expected_slice_positions.is_empty():
			_fail("预测完成后没有生成临时切片")
			return
		# 思考时间内即使调用 R 慢动作接口，也必须保持正常预测步长和暂停状态。
		time_authority.trigger_reset_slow_motion()
		if time_authority.is_reset_slow_motion_active() \
			or not is_equal_approx(Engine.time_scale, 1.0) \
			or Engine.physics_ticks_per_second != WorldTimeAuthority.BASE_PHYSICS_TPS \
			or not get_tree().paused:
			_fail("思考时间内触发了 R 慢动作或解除了暂停")
			return

		_captured_prediction = true
		time_authority.request_exit_thinking_time()


	func _verify_committed_state() -> void:
		if not is_equal_approx(group.delay_time, _target_delay):
			_fail("恢复后延迟没有提交为 %.2f" % _target_delay)
			return
		if group.preview_body.global_position.distance_to(_expected_preview_position) > 0.01:
			_fail("恢复后的预览体没有落在预测终点")
			return

		var actual_slices: Array[Sprite2D] = []
		for slice: Sprite2D in time_slice.slice_pool:
			if slice.visible:
				actual_slices.append(slice)
		if actual_slices.size() != _expected_slice_positions.size():
			_fail("正常切片数量与临时切片不一致：%d != %d" % [actual_slices.size(), _expected_slice_positions.size()])
			return

		for index: int in range(actual_slices.size()):
			var actual: Sprite2D = actual_slices[index]
			if actual.global_position.distance_to(_expected_slice_positions[index]) > 0.01:
				_fail("第 %d 张正常切片位置与临时切片不一致" % index)
				return
			if absf(actual.modulate.a - _expected_slice_alphas[index]) > 0.001:
				_fail("第 %d 张正常切片透明度与临时切片不一致" % index)
				return
			if actual.texture != _expected_slice_textures[index]:
				_fail("第 %d 张正常切片贴图与临时切片不一致" % index)
				return

		# 新规则下，非思考时间不能用 R 或公共请求入口修改玩家延迟。
		if group.request_delay_change(0.0):
			_fail("非思考时间错误接受了玩家延迟归零请求")
			return
		_requesting_thinking_reset = true
		time_authority.enter_thinking_time()


	func _request_reset_when_thinking_time_is_ready() -> void:
		if time_authority.is_entering_thinking_time():
			return
		if not time_authority.is_in_thinking_time() or not get_tree().paused:
			_fail("玩家延迟归零前没有进入稳定的思考时间暂停")
			return
		if not group.request_delay_change(0.0):
			_fail("思考时间内拒绝了玩家延迟归零请求")
			return
		_requesting_thinking_reset = false
		_verifying_thinking_reset = true
		time_authority.request_exit_thinking_time()


	func _verify_thinking_reset_finished() -> void:
		if time_authority.is_in_thinking_time():
			return
		if not is_zero_approx(group.delay_time):
			_fail("退出思考时间后玩家延迟没有归零")
			return

		_active = false
		Input.action_release("ui_right")
		print("AUTO_PREDICTION_AND_THINKING_RESET_TEST_PASS delay=%.2f" % _target_delay)
		get_tree().quit(0)


	func _fail(message: String) -> void:
		_active = false
		Input.action_release("ui_right")
		push_error("AUTO_PREDICTION_TEST_FAIL: " + message)
		get_tree().paused = false
		get_tree().quit(1)
