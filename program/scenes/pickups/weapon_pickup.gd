@tool
class_name WeaponPickup
extends "res://scenes/pickups/pickup_base.gd"

signal collected(slot: int, weapon_name: String)

const WEAPON_NAMES: Dictionary[int, String] = {
	2: "回旋镖",
	3: "法杖",
}
const WEAPON_COLORS: Dictionary[int, Color] = {
	2: Color("ffb34f"),
	3: Color("8d7dff"),
}

@export_enum("回旋镖:2", "法杖:3") var weapon_slot: int = 2:
	set(value):
		weapon_slot = clampi(value, 2, 3)
		if is_inside_tree():
			_update_visuals()
@onready var gem: Polygon2D = $VisualRoot/Gem
@onready var outline: Line2D = $VisualRoot/Outline
@onready var icon_label: Label = $VisualRoot/Icon


func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		# 兼容现有武器解锁测试；通用拾取查询使用基类的 pickups 分组。
		add_to_group(&"weapon_pickups")
	_update_visuals()


## 武器拾取只负责解锁效果；提示、动画、信号与销毁由 PickupBase 统一处理。
func _apply_pickup(player_group: Node) -> bool:
	if player_group == null or not player_group.has_method("unlock_weapon_for_all"):
		return false
	if not bool(player_group.call("unlock_weapon_for_all", weapon_slot)):
		return false
	var weapon_name: String = get_weapon_name()
	collected.emit(weapon_slot, weapon_name)
	return true


func get_weapon_name() -> String:
	return WEAPON_NAMES.get(weapon_slot, "未知武器") as String


func _update_visuals() -> void:
	if not is_node_ready():
		return
	var accent: Color = WEAPON_COLORS.get(weapon_slot, Color.WHITE) as Color
	set_effect_color(accent)
	gem.color = accent
	outline.default_color = accent.lightened(0.35)
	icon_label.text = "↩" if weapon_slot == 2 else "✦"
