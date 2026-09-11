class_name SpikeTrap
extends Area2D

signal state_changed(new_state: TrapState)
signal target_hit(target: Node, damage: float)

enum TrapState { INACTIVE, WARNING, ACTIVE }

@export_group("Damage")
## 地刺每次有效接触造成的基础伤害。
@export_range(0.0, 1000.0, 1.0) var damage: float = 20.0
## 地刺命中提供的基础硬直秒数；最终值会乘受击者的 Hurt Stun Multiplier。
@export_range(0.0, 3.0, 0.01) var hit_stun_seconds: float = 0.20
## 地刺命中的基础水平击退距离，单位为世界像素；最终值会乘受击者的击退倍率。
@export_range(0.0, 1000.0, 0.5) var knockback_distance: float = 32.7
## 同一目标持续站在尖刺上时的再次结算间隔；目标自身无敌时间仍拥有最终决定权。
@export_range(0.05, 5.0, 0.05) var repeat_hit_seconds: float = 0.50
## 第一层为玩家本体，第三层为敌人本体；预览体与预测体均不在这两层。
@export_flags_2d_physics var damage_collision_mask: int = 5
## 默认敌我不分，但仍通过权威受击组排除所有蓝色预览和隐藏预测副本。
@export var damage_target_groups: Array[StringName] = [
	&"player_damage_body",
	&"enemy_damage_body",
]

@export_group("Cycle")
## 关闭时保持 starts_active 指定的常驻状态；开启后按收起、预警、激活循环。
@export var cycle_enabled: bool = false
## 场景开始或重置时是否立即处于可造成伤害的激活状态。
@export var starts_active: bool = true
## 循环开启时，地刺完全收起并不造成伤害的持续逻辑秒数。
@export_range(0.05, 20.0, 0.05) var inactive_seconds: float = 1.20
## 循环开启时，从收起到激活之间显示预警颜色的持续逻辑秒数；0 表示跳过预警。
@export_range(0.0, 5.0, 0.05) var warning_seconds: float = 0.35
## 循环开启时，地刺保持伸出并可造成伤害的持续逻辑秒数。
@export_range(0.05, 20.0, 0.05) var active_seconds: float = 0.90

@export_group("Lifecycle")
## 玩家死亡重生时是否清空命中冷却并恢复 Starts Active 指定的初始阶段。
@export var reset_on_player_respawn: bool = true

var current_state: TrapState = TrapState.ACTIVE
var _state_time_left: float = 0.0
var _hit_cooldowns: Dictionary[int, float] = {}

@onready var visual_root: Node2D = $VisualRoot
@onready var spike_visual: Polygon2D = $VisualRoot/Spikes
@onready var base_visual: Polygon2D = $VisualRoot/Base


func _ready() -> void:
	add_to_group("traps")
	if reset_on_player_respawn:
		add_to_group("player_respawn_reset")
	monitoring = true
	monitorable = false
	collision_mask = damage_collision_mask
	_set_state(TrapState.ACTIVE if starts_active else TrapState.INACTIVE)


## 陷阱沿用伤害来源契约，受击者再乘自己的硬直倍率。
func get_hit_stun_seconds() -> float:
	return maxf(hit_stun_seconds, 0.0)


func get_knockback_distance() -> float:
	return maxf(knockback_distance, 0.0)


## 循环和伤害都使用物理逻辑时间，因此会自然服从统一的慢动作、思考暂停与命中顿帧。
func _physics_process(delta: float) -> void:
	_tick_hit_cooldowns(delta)
	if cycle_enabled:
		_tick_cycle(delta)
	if current_state == TrapState.ACTIVE:
		_damage_overlapping_targets()


## 供按钮、开关或关卡脚本直接控制；手动设置不会修改 cycle_enabled。
func set_active(active: bool) -> void:
	_set_state(TrapState.ACTIVE if active else TrapState.INACTIVE)


func reset_cycle() -> void:
	_hit_cooldowns.clear()
	_set_state(TrapState.ACTIVE if starts_active else TrapState.INACTIVE)


## 接入现有轮次复位契约；重生时清掉目标冷却并恢复初始机关阶段。
func reset_combat(_clear_statistics: bool = false) -> void:
	reset_cycle()


func is_damage_active() -> bool:
	return current_state == TrapState.ACTIVE


func _tick_cycle(delta: float) -> void:
	_state_time_left = maxf(_state_time_left - delta, 0.0)
	if _state_time_left > 0.0:
		return
	match current_state:
		TrapState.INACTIVE:
			_set_state(TrapState.WARNING if warning_seconds > 0.0 else TrapState.ACTIVE)
		TrapState.WARNING:
			_set_state(TrapState.ACTIVE)
		TrapState.ACTIVE:
			_set_state(TrapState.INACTIVE)


func _set_state(new_state: TrapState) -> void:
	current_state = new_state
	match current_state:
		TrapState.INACTIVE:
			_state_time_left = inactive_seconds
		TrapState.WARNING:
			_state_time_left = warning_seconds
		TrapState.ACTIVE:
			_state_time_left = active_seconds
	_apply_state_visuals()
	state_changed.emit(current_state)


func _apply_state_visuals() -> void:
	match current_state:
		TrapState.INACTIVE:
			visual_root.position.y = 22.0
			spike_visual.color = Color(0.30, 0.34, 0.38, 0.72)
			base_visual.color = Color(0.18, 0.22, 0.25, 1.0)
		TrapState.WARNING:
			visual_root.position.y = 12.0
			spike_visual.color = Color(1.0, 0.72, 0.22, 0.92)
			base_visual.color = Color(0.44, 0.29, 0.12, 1.0)
		TrapState.ACTIVE:
			visual_root.position.y = 0.0
			spike_visual.color = Color(1.0, 0.28, 0.24, 1.0)
			base_visual.color = Color(0.42, 0.12, 0.14, 1.0)


func _tick_hit_cooldowns(delta: float) -> void:
	for instance_id: int in _hit_cooldowns.keys():
		var time_left: float = maxf(_hit_cooldowns[instance_id] - delta, 0.0)
		if time_left <= 0.0:
			_hit_cooldowns.erase(instance_id)
		else:
			_hit_cooldowns[instance_id] = time_left


func _damage_overlapping_targets() -> void:
	for body: Node2D in get_overlapping_bodies():
		if not _is_damage_target(body) or not body.has_method("receive_hit"):
			continue
		var instance_id: int = body.get_instance_id()
		if _hit_cooldowns.has(instance_id):
			continue
		var horizontal_direction: float = signf(body.global_position.x - global_position.x)
		if is_zero_approx(horizontal_direction):
			horizontal_direction = 1.0
		var impact_direction: Vector2 = Vector2(horizontal_direction, -0.35).normalized()
		var accepted: bool = bool(body.call("receive_hit", damage, self, 1, impact_direction))
		if not accepted:
			continue
		_hit_cooldowns[instance_id] = repeat_hit_seconds
		target_hit.emit(body, damage)


func _is_damage_target(body: Node) -> bool:
	for target_group: StringName in damage_target_groups:
		if body.is_in_group(target_group):
			return true
	return false
