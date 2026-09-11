class_name TimeMarkerUi
extends Node2D

## 单个时间标记的可编辑视觉场景。
## 预览体与时间切片共用，后续替换美术时只需修改对应 tscn。
@export var head_offset: Vector2 = Vector2(0.0, -72.0):
	set(value):
		head_offset = value
		_update_label_position()

@onready var label: Label = $Label


func _ready() -> void:
	_update_label_position()


## 用秒数更新文字；hidden 参数使调用方能在重叠时保留预览文字。
func show_time(seconds: float, should_show: bool) -> void:
	visible = should_show
	if should_show:
		label.text = "%.2fs" % maxf(seconds, 0.0)


func _update_label_position() -> void:
	if label != null:
		# Control.position 是左上角，减半尺寸后才能让文字真正居中于角色头顶。
		label.position = head_offset - label.size * 0.5
