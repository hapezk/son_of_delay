class_name FallingTrapDelayController
extends "res://scenes/components/command_replay_delay_controller.gd"

## 坠落机关只适配实例配置；三副本、预测、提交、UI 与环形缓冲全部复用公共层。
func _ready() -> void:
	add_to_group("falling_trap_delay_controllers")
	super._ready()


func _initialize_controller() -> void:
	super._initialize_controller()
	if body == null or preview_body == null or predictor == null:
		return
	if body.has_method("copy_delay_configuration_to"):
		body.call("copy_delay_configuration_to", preview_body)
		body.call("copy_delay_configuration_to", predictor)
	# 蓝色与隐藏副本需要模拟地形，但不能被重叠的真实陷阱自身挡住。
	for replica: BaseActor in [preview_body, predictor]:
		replica.add_collision_exception_with(body)
		body.add_collision_exception_with(replica)
	sync_preview_to_body(true)
	sync_predictor_to_body(true)


func _move_preview_to_waiting_endpoint() -> void:
	# 权威陷阱填充延迟历史时原地冻结；蓝色预览从同一瞬时状态继续受重力运动。
	preview_body.reset_physics_interpolation()
