class_name DelayControlUi
extends Node2D

const DELAY_ADJUSTMENT_INPUT_SCRIPT: Script = preload("res://scenes/components/delay_adjustment_input.gd")
const DEFAULT_ADJUSTMENT_TUNING: Resource = preload("res://resources/delay_adjustment_tuning.tres")

## 所有可延迟对象共用的显示与输入壳。
## 具体对象只注入文字、命中范围、快捷键时机和可选的减延迟预览数据。
@export var adjustment_tuning: Resource = DEFAULT_ADJUSTMENT_TUNING
@export var adjustment_priority: int = 0 ## 重叠时优先响应数值更高的对象。

@onready var delay_label: Label = $DelayLabel
@onready var reduction_target: ReductionTargetUi = $ReductionTarget

## UI 挂在真实 Body 下，但调整目标是它对应的 DelayControllerBase 适配器。
var target: Node
var world_time_authority: WorldTimeAuthority
var _is_thinking_time: bool = false
var _is_mouse_in_range: bool = false
var _adjustment_input: Node
var _target_hover_test: Callable
var _outside_zero_callback: Callable
var _label_text_provider: Callable
var _reduction_sample_provider: Callable
var _shortcuts_require_thinking_time: bool = false


func configure(
	delay_target: Node,
	authority: WorldTimeAuthority,
	hover_test: Callable,
	require_thinking_time_for_shortcuts: bool,
	priority: int,
	tuning: Resource,
	outside_zero_callback: Callable = Callable(),
	label_text_provider: Callable = Callable(),
	reduction_sample_provider: Callable = Callable()
) -> void:
	target = delay_target
	world_time_authority = authority
	_target_hover_test = hover_test
	_shortcuts_require_thinking_time = require_thinking_time_for_shortcuts
	adjustment_priority = priority
	adjustment_tuning = tuning
	_outside_zero_callback = outside_zero_callback
	_label_text_provider = label_text_provider
	_reduction_sample_provider = reduction_sample_provider
	if is_node_ready():
		_create_adjustment_input()
		_update_visuals()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 兼容旧场景中手动挂载的玩家 UI；新控制器会在入树前显式 configure()。
	if target == null:
		var body: BaseActor = get_parent() as BaseActor
		if body != null and body.get_parent() is DelayControllerBase:
			target = body.get_parent() as DelayControllerBase
			_target_hover_test = Callable(target, "is_mouse_over_delay_visual")
			_label_text_provider = Callable(target, "get_delay_ui_text")
			_reduction_sample_provider = Callable(target, "get_delay_preview_sample") \
				if target.has_method("get_delay_preview_sample") else Callable()
	world_time_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	_create_adjustment_input()
	_update_visuals()


func _process(_delta: float) -> void:
	_is_thinking_time = _is_thinking_time_active()
	if target == null or not is_instance_valid(target):
		visible = false
		return
	# 非思考时间不扫描本体、预览体或切片，避免多对象场景的空闲开销。
	if not _is_thinking_time:
		visible = false
		reduction_target.hide_target()
		return
	visible = true
	_is_mouse_in_range = _adjustment_input != null \
		and bool(_adjustment_input.call("is_mouse_in_range"))
	delay_label.text = str(_label_text_provider.call()) if _label_text_provider.is_valid() \
		else "延迟\n%.2fs" % _get_requested_delay()
	_update_visuals()
	_update_reduction_target_marker()


## 输入组件持有全部通用规则；同一个 UI 可服务玩家、敌人和后续物理对象。
func _create_adjustment_input() -> void:
	if target == null:
		return
	if _adjustment_input != null and is_instance_valid(_adjustment_input):
		remove_child(_adjustment_input)
		_adjustment_input.queue_free()
	_adjustment_input = DELAY_ADJUSTMENT_INPUT_SCRIPT.new() as Node
	_adjustment_input.name = "DelayAdjustmentInput"
	_adjustment_input.call(
		"configure",
		target,
		world_time_authority,
		Callable(self, "is_mouse_over_delay_visual"),
		_shortcuts_require_thinking_time,
		adjustment_priority,
		adjustment_tuning,
		_outside_zero_callback
	)
	add_child(_adjustment_input)


func _update_visuals() -> void:
	var should_show: bool = _is_thinking_time
	delay_label.visible = should_show
	if should_show:
		delay_label.modulate.a = 1.0 if _is_mouse_in_range else 0.38


## 鼠标位于本体、预览体、任一时间切片或目标影像的实际 Sprite2D 矩形内时可调整。
func is_mouse_over_delay_visual(mouse_position: Vector2) -> bool:
	if reduction_target.visible and _is_mouse_over_sprite(reduction_target.target_sprite, mouse_position):
		return true
	return _target_hover_test.is_valid() and bool(_target_hover_test.call(mouse_position))


func _is_mouse_over_sprite(sprite: Sprite2D, mouse_position: Vector2) -> bool:
	return sprite != null and sprite.is_visible_in_tree() and sprite.texture != null and sprite.get_rect().has_point(sprite.to_local(mouse_position))


## 平时不显示时间轴；仅在思考时间中将延迟调小时，显示减小后的预览目标位置。
func _update_reduction_target_marker() -> void:
	var requested_delay: float = _get_requested_delay()
	var current_delay: float = float(target.get("delay_time")) if target != null else 0.0
	if not _is_thinking_time or not _reduction_sample_provider.is_valid() \
			or requested_delay >= current_delay:
		reduction_target.hide_target()
		return

	var sample: Variant = _reduction_sample_provider.call(requested_delay)
	if not (sample is Dictionary) or (sample as Dictionary).is_empty():
		reduction_target.hide_target()
		return

	var target_position: Vector2 = sample["position"] as Vector2
	var target_record: Recording = sample["record"] as Recording
	if target_record == null:
		reduction_target.hide_target()
		return
	reduction_target.show_at(target_record, requested_delay, target_position)


## 时间控制器可能比本组件更晚进入场景树，因此丢失引用时会重新获取。
func _is_thinking_time_active() -> bool:
	if world_time_authority == null or not is_instance_valid(world_time_authority):
		world_time_authority = get_tree().get_first_node_in_group("world_time_authority") as WorldTimeAuthority
	return world_time_authority != null and world_time_authority.is_in_thinking_time()


func get_adjustment_input() -> Node:
	return _adjustment_input


func _get_requested_delay() -> float:
	if target != null and target.has_method("get_requested_delay"):
		return float(target.call("get_requested_delay"))
	return float(target.get("delay_time")) if target != null else 0.0
