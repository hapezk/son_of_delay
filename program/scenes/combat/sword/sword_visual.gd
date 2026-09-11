class_name SwordVisual
extends Node2D

@export_category("Sword Visual")
@export_group("Pose")
## 蓄力时保持腰侧收刀姿势；释放前摇再转到由下向上挑的起剑角度。
@export_range(-180.0, 180.0, 1.0) var charged_sheath_degrees: float = 160.0
@export_range(-180.0, 180.0, 1.0) var idle_degrees: float = -43.0
@export var normal_grip_origin: Vector2 = Vector2(18.0, -4.0)
@export var charged_grip_origin: Vector2 = Vector2(10.0, 10.0)

@export_group("Colors")
@export var sword_color: Color = Color("f1f4e9")
@export var preview_sword_color: Color = Color("bceaff")
@export var accent_color: Color = Color("ffc978")
@export var preview_accent_color: Color = Color("76dbff")
@export var handle_color: Color = Color("785344")

@export_group("Trail")
@export_range(0.0, 1.0, 0.01) var active_trail_opacity: float = 0.32
@export_range(0.0, 1.0, 0.01) var recovery_trail_opacity: float = 0.18
@export_range(0.01, 1.0, 0.01) var recovery_trail_portion: float = 0.35
@export_range(0.1, 10.0, 0.1) var trail_outline_width: float = 3.0

## 只绘制武器，不读取输入、计时或结算伤害；暂停和预测都由武器逻辑驱动。
var _reach: float = 84.0
## 武器按当前攻击阶段传入剑身长度，重斩收招后恢复普通长度。
var _blade_length: float = 84.0
var _start_angle: float = -1.20
var _end_angle: float = 1.05
var _phase: StringName = &"idle"
var _progress: float = 0.0
var _facing: int = 1
var _preview: bool = false
var _aim_rotation: float = 0.0
var _charge_seconds: float = 0.0
var _charge_tier: int = 0


## 刀光范围、角度与命中判定一致；剑身长度由独立的外观参数控制。
func show_pose(phase: StringName, progress: float, facing: int, preview: bool,
		reach: float, start_angle: float, end_angle: float, blade_length: float,
		aim_rotation: float, charge_seconds: float = 0.0, charge_tier: int = 0) -> void:
	_reach = reach
	_blade_length = blade_length
	_start_angle = start_angle
	_end_angle = end_angle
	_phase = phase
	_progress = progress
	_facing = facing
	_preview = preview
	_aim_rotation = aim_rotation
	_charge_seconds = charge_seconds
	_charge_tier = charge_tier
	queue_redraw()


## 命中查询和程序绘制共用握剑原点，调节 Inspector 后不会出现图形与判定错位。
func get_grip_origin(charged_pose: bool, facing: int) -> Vector2:
	var base_origin: Vector2 = charged_grip_origin if charged_pose else normal_grip_origin
	return Vector2(base_origin.x * (-1 if facing < 0 else 1), base_origin.y)


func _draw() -> void:
	var accent: Color = preview_accent_color if _preview else accent_color
	var idle_angle: float = deg_to_rad(idle_degrees)
	var sheath_angle: float = deg_to_rad(charged_sheath_degrees)
	var angle: float = idle_angle
	var reach: float = _reach
	match _phase:
		&"charge":
			angle = sheath_angle
		&"charged_windup":
			angle = lerpf(sheath_angle, _start_angle, _progress)
		&"charged_active":
			angle = lerpf(_start_angle, _end_angle, _progress)
		&"charged_recovery":
			angle = lerpf(_end_angle, idle_angle, _progress)
		&"windup":
			angle = lerpf(idle_angle, _start_angle, _progress)
		&"active":
			angle = lerpf(_start_angle, _end_angle, _progress)
		&"recovery":
			angle = lerpf(_end_angle, idle_angle, _progress)
	# 放在 Graphics 外，攻击中转身不会翻转已经锁定方向的这一剑。
	var charged_pose: bool = _phase in [&"charge", &"charged_windup", &"charged_active", &"charged_recovery"]
	var grip_origin: Vector2 = get_grip_origin(charged_pose, _facing)
	draw_set_transform(grip_origin, _aim_rotation, Vector2(_facing, 1.0))
	if _phase in [&"active", &"charged_active"] and _progress > 0.0:
		_draw_trail(_start_angle, angle, reach, accent, active_trail_opacity)
	elif _phase in [&"recovery", &"charged_recovery"] and _progress < recovery_trail_portion:
		_draw_trail(_start_angle, _end_angle, reach, accent,
			recovery_trail_opacity * (1.0 - _progress / recovery_trail_portion))
	elif _phase == &"windup":
		draw_arc(Vector2.ZERO, reach, minf(_start_angle, _end_angle),
			maxf(_start_angle, _end_angle), 24, Color(accent, 0.14), 1.0, true)
	elif _phase == &"charge":
		draw_circle(Vector2.ZERO, 15.0, Color(accent, 0.10))
		for tier_index: int in range(3):
			var radius: float = 20.0 + tier_index * 5.0
			var tier_progress: float = clampf(_charge_seconds - float(tier_index), 0.0, 1.0)
			draw_arc(Vector2.ZERO, radius, -PI, PI, 24, Color(accent, 0.18), 1.0, true)
			if tier_progress > 0.0:
				draw_arc(Vector2.ZERO, radius, -PI * 0.5,
					-PI * 0.5 + TAU * tier_progress, 24, Color(accent, 0.78), 2.5, true)

	# 用简单多边形作为试作剑身，之后可替换素材而不改攻击逻辑。
	draw_set_transform(grip_origin, _aim_rotation + angle * _facing, Vector2(_facing, 1.0))
	var blade: PackedVector2Array = PackedVector2Array([
		Vector2(10, -3), Vector2(_blade_length - 12, -3), Vector2(_blade_length, 0),
		Vector2(_blade_length - 12, 4), Vector2(10, 4),
	])
	draw_colored_polygon(blade, preview_sword_color if _preview else sword_color)
	draw_line(Vector2(12, 0), Vector2(_blade_length - 8, 0), accent, 1.5, true)
	draw_line(Vector2(8, -9), Vector2(8, 10), accent, 4.0, true)
	draw_line(Vector2(-9, 0), Vector2(6, 0), handle_color, 6.0, true)
	draw_set_transform(Vector2.ZERO)


func _draw_trail(start: float, end: float, radius: float, color: Color, alpha: float) -> void:
	var points: PackedVector2Array = PackedVector2Array()
	for index: int in range(17):
		var angle: float = lerpf(start, end, float(index) / 16.0)
		points.append(Vector2.from_angle(angle) * radius)
	for index: int in range(16, -1, -1):
		var angle: float = lerpf(start, end, float(index) / 16.0)
		points.append(Vector2.from_angle(angle) * radius * 0.48)
	draw_colored_polygon(points, Color(color, alpha))
	draw_arc(Vector2.ZERO, radius, minf(start, end), maxf(start, end), 24,
		Color(color, alpha * 2.0), trail_outline_width, true)
