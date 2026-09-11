@tool
class_name PickupBase
extends Node2D

signal picked_up(pickup: Node2D, collector: Node)

@export_category("Pickup")
## 玩家中心进入这个半径后显示提示，并允许在权威帧完成拾取。
@export_range(24.0, 200.0, 1.0) var pickup_radius: float = 82.0

@export_category("Presentation")
@export_range(0.0, 16.0, 0.5) var bob_height: float = 5.0
@export_range(0.0, 8.0, 0.1) var bob_speed: float = 2.2
@export_range(0.0, 8.0, 0.1) var glow_speed: float = 3.2
## HDR 2D 中超过 1.0 的颜色才会成为可独立控制的 Glow 光源。
@export_range(1.0, 8.0, 0.1) var glow_hdr_multiplier: float = 4.0
@export var effect_color: Color = Color("ffb34f")

@onready var visual_root: Node2D = $VisualRoot
@onready var glow: Polygon2D = $VisualRoot/Glow
@onready var particles: CPUParticles2D = $VisualRoot/Particles
@onready var prompt_label: Label = $Prompt

var _elapsed_seconds: float = 0.0
var _visual_base_y: float = 0.0
var _glow_base_scale: Vector2 = Vector2.ONE


func _ready() -> void:
	_visual_base_y = visual_root.position.y
	_glow_base_scale = glow.scale
	prompt_label.text = "F(拾取)"
	set_effect_color(effect_color)
	if not Engine.is_editor_hint():
		add_to_group(&"pickups")
		prompt_label.visible = false


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_elapsed_seconds += delta
	visual_root.position.y = _visual_base_y \
		+ sin(_elapsed_seconds * bob_speed) * bob_height
	var pulse: float = (sin(_elapsed_seconds * glow_speed) + 1.0) * 0.5
	glow.modulate = Color(1.0, 1.0, 1.0, lerpf(0.3, 0.72, pulse))
	glow.scale = _glow_base_scale * lerpf(0.92, 1.12, pulse)
	prompt_label.visible = _is_live_player_close()


func can_be_picked_up_from(player_position: Vector2) -> bool:
	return player_position.distance_squared_to(global_position) \
		<= pickup_radius * pickup_radius


## 子类成功应用具体效果后，基类统一发送信号并结束拾取物生命周期。
func collect(collector: Node) -> bool:
	if is_queued_for_deletion() or not _apply_pickup(collector):
		return false
	picked_up.emit(self, collector)
	queue_free()
	return true


## 子类只需设置强调色，不需要各自维护辉光和粒子节点。
func set_effect_color(new_color: Color) -> void:
	effect_color = new_color
	if not is_node_ready():
		return
	# 超亮 RGB 交给 WorldEnvironment 生成真实 Bloom，Alpha 仍负责呼吸节奏。
	glow.color = Color(
		new_color.r * glow_hdr_multiplier,
		new_color.g * glow_hdr_multiplier,
		new_color.b * glow_hdr_multiplier,
		1.0
	)
	var particle_hdr_multiplier: float = glow_hdr_multiplier * 0.65
	particles.modulate = Color(
		new_color.r * particle_hdr_multiplier,
		new_color.g * particle_hdr_multiplier,
		new_color.b * particle_hdr_multiplier,
		0.85
	)


## 提示跟随当前真正接收输入的玩家；正延迟时通常是 PreviewBody。
func _is_live_player_close() -> bool:
	for collector: Node in get_tree().get_nodes_in_group(&"pickup_collectors"):
		if not collector.has_method("get_pickup_prompt_position"):
			continue
		var player_position: Vector2 = collector.call("get_pickup_prompt_position")
		if can_be_picked_up_from(player_position):
			return true
	return false


## 具体拾取物覆盖此方法，实现武器解锁、恢复生命等业务效果。
func _apply_pickup(_collector: Node) -> bool:
	push_error("PickupBase: subclass must implement _apply_pickup()")
	return false
