class_name ScreenDamageFlash
extends CanvasLayer

## 程序化圆形渐变遮罩：中心透明，越靠近屏幕边缘和四角红光越强。
const VIGNETTE_SHADER_CODE: String = """
shader_type canvas_item;

uniform vec4 flash_color : source_color = vec4(0.78, 0.03, 0.02, 1.0);
uniform float flash_opacity : hint_range(0.0, 1.0) = 0.0;
uniform float inner_radius : hint_range(0.0, 1.4) = 0.58;
uniform float edge_softness : hint_range(0.01, 1.0) = 0.55;

void fragment() {
	vec2 centered_uv = (UV - vec2(0.5)) * 2.0;
	float radius = length(centered_uv);
	float edge_mask = smoothstep(inner_radius, inner_radius + edge_softness, radius);
	COLOR = vec4(flash_color.rgb, flash_color.a * flash_opacity * edge_mask);
}
"""

## 受伤暗角只负责表现，不拦截鼠标，也不参与游戏世界的暂停与变速。
var overlay: ColorRect
var _vignette_material: ShaderMaterial
var _active: bool = false
var _started_usec: int = 0
var _duration: float = 0.0
var _flash_color: Color = Color(0.78, 0.03, 0.02, 1.0)
var _max_opacity: float = 0.0
var _current_opacity: float = 0.0
var _inner_radius: float = 0.58
var _edge_softness: float = 0.55


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	overlay = ColorRect.new()
	overlay.name = "Overlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.color = Color.WHITE
	var vignette_shader: Shader = Shader.new()
	vignette_shader.code = VIGNETTE_SHADER_CODE
	_vignette_material = ShaderMaterial.new()
	_vignette_material.shader = vignette_shader
	overlay.material = _vignette_material
	overlay.visible = false
	add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_resize_overlay()
	get_viewport().size_changed.connect(_resize_overlay)


func _resize_overlay() -> void:
	if overlay == null:
		return
	overlay.position = Vector2.ZERO
	overlay.size = get_viewport().get_visible_rect().size


func start(
	duration: float,
	color: Color,
	max_opacity: float,
	inner_radius: float,
	edge_softness: float
) -> void:
	_duration = maxf(duration, 0.0)
	_flash_color = color
	_max_opacity = clampf(max_opacity, 0.0, 1.0)
	_inner_radius = clampf(inner_radius, 0.0, 1.4)
	_edge_softness = clampf(edge_softness, 0.01, 1.0)
	_vignette_material.set_shader_parameter("flash_color", _flash_color)
	_vignette_material.set_shader_parameter("inner_radius", _inner_radius)
	_vignette_material.set_shader_parameter("edge_softness", _edge_softness)
	_started_usec = Time.get_ticks_usec()
	_active = _duration > 0.0 and _max_opacity > 0.0
	if not _active:
		stop()
		return
	overlay.visible = true
	_update_overlay(0.0)


func is_playing() -> bool:
	return _active


func get_opacity() -> float:
	return _current_opacity if overlay != null and overlay.visible else 0.0


func _process(_delta: float) -> void:
	if not _active:
		return
	var elapsed: float = float(Time.get_ticks_usec() - _started_usec) / 1_000_000.0
	if elapsed >= _duration:
		stop()
		return
	_update_overlay(elapsed / _duration)


func _update_overlay(progress: float) -> void:
	# 受伤瞬间最亮，随后快速衰减，避免长时间遮挡战斗画面。
	var fade: float = pow(1.0 - clampf(progress, 0.0, 1.0), 2.0)
	_current_opacity = _max_opacity * fade
	_vignette_material.set_shader_parameter("flash_opacity", _current_opacity)


func stop() -> void:
	_active = false
	_current_opacity = 0.0
	if overlay != null:
		overlay.visible = false
	if _vignette_material != null:
		_vignette_material.set_shader_parameter("flash_opacity", 0.0)
