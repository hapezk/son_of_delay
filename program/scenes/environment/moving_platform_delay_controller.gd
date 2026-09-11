class_name MovingPlatformDelayController
extends "res://scenes/components/command_replay_delay_controller.gd"

## 平台保留 AnimatableBody2D 载人能力，只在此处适配公共 BaseActor 命令回放层。
func _ready() -> void:
	add_to_group("moving_platform_delay_controllers")
	super._ready()


func _initialize_controller() -> void:
	super._initialize_controller()
	if body == null or preview_body == null or predictor == null:
		return
	if body.has_method("copy_delay_configuration_to"):
		body.call("copy_delay_configuration_to", preview_body)
		body.call("copy_delay_configuration_to", predictor)
	sync_preview_to_body(true)
	sync_predictor_to_body(true)


func _move_preview_to_waiting_endpoint() -> void:
	# 静态外壳没有速度；蓝色平台从权威平台当前轨迹状态继续前进。
	preview_body.velocity = Vector2.ZERO
	preview_body.reset_physics_interpolation()
