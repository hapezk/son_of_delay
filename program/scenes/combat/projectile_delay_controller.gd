class_name ProjectileDelayController
extends "res://scenes/components/command_replay_delay_controller.gd"

## 弹幕与敌人共用命令回放层，只覆盖“开启延迟时不预先减速”的物体策略。
func _ready() -> void:
	add_to_group("projectile_delay_controllers")
	super._ready()


func _move_preview_to_waiting_endpoint() -> void:
	# 弹幕本体在填充历史时冻结，预览从同一位置、同一速度继续推演。
	preview_body.reset_physics_interpolation()
