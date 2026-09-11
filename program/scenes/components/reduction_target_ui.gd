class_name ReductionTargetUi
extends Node2D

## 减小延迟时的目标影像：复制历史记录中的精灵状态，不驱动任何物理行为。
@onready var target_sprite: Sprite2D = $TargetSprite
@onready var time_marker: TimeMarkerUi = $TimeMarker
var _has_displayed_target: bool = false
var _displayed_position: Vector2 = Vector2.ZERO


func _ready() -> void:
	# 这是 Ctrl 调整时的纯视觉定位点，位置由 _process 直接更新，不能参与物理插值。
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## 更新纯视觉定位点；该节点已关闭物理插值，因此可直接跳到新的历史位置。
func show_at(record: Recording, seconds: float, target_position: Vector2) -> void:
	if record == null:
		hide_target()
		return
	if _has_displayed_target and _displayed_position.is_equal_approx(target_position):
		_apply_visual_state(record, seconds)
		return

	global_position = target_position
	if !visible:
		show()
	_displayed_position = target_position
	_has_displayed_target = true
	_apply_visual_state(record, seconds)


func hide_target() -> void:
	_has_displayed_target = false
	visible = false


func _apply_visual_state(record: Recording, seconds: float) -> void:
	target_sprite.texture = record.texture
	target_sprite.scale = record.scale
	target_sprite.region_enabled = record.region_enabled
	target_sprite.region_rect = record.region_rect
	target_sprite.hframes = record.hframes
	target_sprite.vframes = record.vframes
	target_sprite.frame = record.frame
	target_sprite.frame_coords = record.frame_coords
	target_sprite.centered = record.centered
	target_sprite.offset = record.offset
	target_sprite.flip_h = record.flip_h
	target_sprite.visible = record.texture != null
	time_marker.show_time(seconds, true)
