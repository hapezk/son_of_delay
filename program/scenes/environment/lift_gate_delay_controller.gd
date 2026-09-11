class_name LiftGateDelayController
extends "res://scenes/components/command_replay_delay_controller.gd"

## 升降门只补充实例参数复制；命令缓存、蓝色预览和延迟提交复用公共控制层。
func _ready() -> void:
	add_to_group("lift_gate_delay_controllers")
	super._ready()


func _initialize_controller() -> void:
	super._initialize_controller()
	if body == null or preview_body == null or predictor == null:
		return
	if body.has_method("copy_delay_configuration_to"):
		body.call("copy_delay_configuration_to", preview_body)
		body.call("copy_delay_configuration_to", predictor)
	_pin_delay_ui_to_closed_gate_center()
	sync_preview_to_body(true)
	sync_predictor_to_body(true)


## UI 仍由门管理生命周期，但 top_level 会解除对移动门板变换的继承。
func _pin_delay_ui_to_closed_gate_center() -> void:
	var delay_ui: Node2D = body.get_node_or_null("DelayControlUi") as Node2D
	if delay_ui == null:
		return
	var fixed_position: Vector2 = body.global_position
	if body.has_method("get_fixed_delay_ui_global_position"):
		fixed_position = body.call("get_fixed_delay_ui_global_position") as Vector2
	delay_ui.top_level = true
	delay_ui.global_position = fixed_position


func _move_preview_to_waiting_endpoint() -> void:
	# 真实门在积累延迟历史时保持不动；蓝色门从同一状态即时读取压力开关。
	preview_body.reset_physics_interpolation()
