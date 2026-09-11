class_name BoomerangLauncher
extends "res://scenes/combat/delay_weapon_launcher_base.gd"

## 回旋镖只保留武器身份；冷却、数量上限、三体权限和生成过程全部来自公共发射器。

@export_group("Held Boomerang Visual")
## 玩家手中待机回旋镖的外接半径，单位为像素；只影响手持图形，不改变飞出后的判定范围。
@export_range(8.0, 40.0, 1.0) var held_radius: float = 18.0
## 手持回旋镖中心沿鼠标瞄准方向离玩家中心的距离，单位为像素。
@export_range(0.0, 96.0, 1.0) var held_distance: float = 24.0
## 三角星凹入顶点相对 Held Radius 的比例；越小凹槽越深、星形越尖。
@export_range(0.05, 1.0, 0.01) var held_inner_radius_multiplier: float = 0.32
## 手持回旋镖中心圆相对 Held Radius 的比例。
@export_range(0.05, 1.0, 0.01) var held_core_radius_multiplier: float = 0.22
## 未进入蓄力模式时，手持回旋镖主体的颜色。
@export var held_color: Color = Color("2be8bd")
## 进入蓄力模式后，手持回旋镖主体和蓄力圆环的基准颜色。
@export var charged_color: Color = Color("ffe05c")
## 手持回旋镖中心圆的颜色，普通和蓄力状态共用。
@export var held_core_color: Color = Color("fff1a3")
## 第一圈蓄力进度环与回旋镖外缘之间的间距，单位为像素。
@export_range(0.0, 40.0, 1.0) var charge_ring_offset: float = 6.0
## 三个蓄力档位圆环之间的间距，单位为像素。
@export_range(0.0, 20.0, 1.0) var charge_ring_spacing: float = 5.0
## 已充能圆弧的线宽，单位为像素。
@export_range(0.1, 10.0, 0.1) var charge_ring_width: float = 3.0


func _draw() -> void:
	if not weapon_equipped:
		return
	var direction: Vector2 = pose_aim_direction.normalized()
	var center: Vector2 = direction * held_distance
	var color: Color = charged_color if charge_pose_active else held_color
	var points: PackedVector2Array = PackedVector2Array()
	for index: int in range(6):
		var radius: float = held_radius \
			if index % 2 == 0 else held_radius * held_inner_radius_multiplier
		points.append(center + Vector2.from_angle(direction.angle() + index * PI / 3.0) * radius)
	draw_colored_polygon(points, color)
	draw_circle(center, held_radius * held_core_radius_multiplier, held_core_color)
	if charge_pose_active:
		for tier_index: int in range(3):
			var radius: float = held_radius + charge_ring_offset + tier_index * charge_ring_spacing
			var tier_progress: float = clampf(charge_pose_seconds - float(tier_index), 0.0, 1.0)
			draw_arc(center, radius, -PI, PI, 24, Color(color, 0.18), 1.0, true)
			if tier_progress > 0.0:
				draw_arc(center, radius, -PI * 0.5, -PI * 0.5 + TAU * tier_progress,
					24, Color(color, 0.78), charge_ring_width, true)
