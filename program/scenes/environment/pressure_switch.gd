class_name PressureSwitch
extends Area2D

## 地面压力开关只识别真实玩家；预览体没有碰撞层，不会重复触发。
@export var target_group: StringName = &"player_damage_body"

@onready var sensor_shape: CollisionShape2D = $SensorShape
@onready var plate_visual: Polygon2D = $VisualRoot/Plate
@onready var glow_visual: Polygon2D = $VisualRoot/Glow

var _pressed_bodies: Dictionary[int, Node2D] = {}


func _ready() -> void:
	add_to_group("pressure_switches")
	monitoring = true
	monitorable = false
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_update_visual(false)


func _physics_process(_delta: float) -> void:
	_update_visual(is_pressed())


func is_pressed() -> bool:
	for instance_id: int in _pressed_bodies.keys():
		var stored_body: Node2D = _pressed_bodies[instance_id]
		if not is_instance_valid(stored_body):
			_pressed_bodies.erase(instance_id)
		elif stored_body.is_in_group(target_group):
			return true
	# 首次物理刷新时信号可能尚未派发，查询列表作为同帧回退。
	for body: Node2D in get_overlapping_bodies():
		if body.is_in_group(target_group):
			return true
	return _has_target_shape_overlap()


func get_trigger_half_width() -> float:
	var rectangle: RectangleShape2D = sensor_shape.shape as RectangleShape2D
	return rectangle.size.x * 0.5 if rectangle != null else 0.0


func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group(target_group):
		_pressed_bodies[body.get_instance_id()] = body


func _on_body_exited(body: Node2D) -> void:
	_pressed_bodies.erase(body.get_instance_id())


## 传送、重生或预测提交后，Area2D 的重叠缓存可能晚一帧；直接比较真实碰撞矩形补齐该帧。
func _has_target_shape_overlap() -> bool:
	var sensor_rectangle: RectangleShape2D = sensor_shape.shape as RectangleShape2D
	if sensor_rectangle == null:
		return false
	var sensor_size: Vector2 = sensor_rectangle.size * sensor_shape.global_scale.abs()
	var sensor_rect: Rect2 = Rect2(
		sensor_shape.global_position - sensor_size * 0.5,
		sensor_size
	)
	for target: Node in get_tree().get_nodes_in_group(target_group):
		if not target is Node2D:
			continue
		var target_shape: CollisionShape2D = target.get_node_or_null(
			"BaseCollision") as CollisionShape2D
		if target_shape == null or target_shape.disabled \
				or not target_shape.shape is RectangleShape2D:
			continue
		var target_rectangle: RectangleShape2D = target_shape.shape as RectangleShape2D
		var target_size: Vector2 = target_rectangle.size * target_shape.global_scale.abs()
		var target_rect: Rect2 = Rect2(
			target_shape.global_position - target_size * 0.5,
			target_size
		)
		if sensor_rect.intersects(target_rect, true):
			return true
	return false


func _update_visual(pressed: bool) -> void:
	plate_visual.position.y = 3.0 if pressed else 0.0
	glow_visual.position.y = plate_visual.position.y
	plate_visual.color = Color("79ffe0") if pressed else Color("43bda9")
	glow_visual.color = Color(0.30, 1.65, 1.25, 0.95) if pressed \
		else Color(0.20, 0.72, 0.62, 0.72)
