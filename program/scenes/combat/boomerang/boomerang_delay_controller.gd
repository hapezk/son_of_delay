class_name BoomerangDelayController
extends "res://scenes/combat/projectile_delay_controller.gd"

## 回旋镖沿用弹幕的“延迟本体冻结、预览继续飞行”策略，只增加独立调试分组。
func _ready() -> void:
	add_to_group("boomerang_delay_controllers")
	super._ready()
