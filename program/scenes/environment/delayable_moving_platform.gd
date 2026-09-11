class_name DelayableMovingPlatform
extends BaseActor

@export_group("Route")
@export var travel_offset: Vector2 = Vector2(320.0, 0.0)
@export_range(0.0, 2000.0, 5.0) var travel_speed: float = 120.0
@export_range(0.0, 10.0, 0.05) var endpoint_wait_seconds: float = 0.35
@export var start_at_end: bool = false
@export var movement_enabled: bool = true

@export_group("Lifecycle")
@export var reset_on_player_respawn: bool = true

@export_group("Collision")
@export var one_way_collision: bool = true
@export_range(0.0, 32.0, 0.5) var one_way_margin: float = 4.0

@onready var platform: MovingPlatform = $Platform


func _ready() -> void:
	# AnimatableBody2D 继续独占载人碰撞；BaseActor 外壳只负责延迟契约和快照。
	platform.set_physics_process(false)
	# 带控制器的实例从首帧起就只允许控制器驱动，避免 deferred 初始化前偷跑一格。
	if has_node("MovingPlatformDelayController"):
		set_physics_process(false)
	platform.remove_from_group("moving_platforms")
	platform.remove_from_group("player_respawn_reset")
	_apply_route_configuration()
	add_to_group("moving_platforms")
	add_to_group("delayable_moving_platforms")
	if reset_on_player_respawn:
		add_to_group("player_respawn_reset")


func _physics_process(delta: float) -> void:
	simulate_delay_command(capture_delay_command(), delta)


## 自动往返平台没有输入；每个空命令代表未来轨迹前进一步。
func capture_delay_command() -> Dictionary:
	return {}


func simulate_delay_command(_command: Dictionary, delta: float) -> void:
	platform.simulate_route(delta)


## 开启延迟后，权威平台在积累历史期间停在当前位置，不产生隐形载人位移。
func tick_delay_waiting(_delta: float) -> void:
	pass


func capture_simulation_state() -> Dictionary:
	return {"platform_motion": platform.capture_motion_state()}


func restore_simulation_state(state: Dictionary) -> void:
	var motion_state: Variant = state.get("platform_motion", {})
	if motion_state is Dictionary:
		platform.restore_motion_state(motion_state as Dictionary)


func configure_delay_replica(role: DelayReplicaRole) -> void:
	super.configure_delay_replica(role)
	var is_authority: bool = role == DelayReplicaRole.AUTHORITY
	platform.configure_collision_authority(is_authority, role == DelayReplicaRole.PREVIEW)
	platform.remove_from_group("moving_platforms")
	platform.remove_from_group("player_respawn_reset")
	if is_authority:
		add_to_group("moving_platforms")
		add_to_group("delayable_moving_platforms")
		if reset_on_player_respawn:
			add_to_group("player_respawn_reset")
		return
	remove_from_group("moving_platforms")
	remove_from_group("delayable_moving_platforms")
	remove_from_group("player_respawn_reset")


## 让控制器生成的预览和预测副本继承主场景实例上的路线覆盖值。
func copy_delay_configuration_to(replica: BaseActor) -> void:
	if not replica is DelayableMovingPlatform:
		return
	var platform_replica: DelayableMovingPlatform = replica as DelayableMovingPlatform
	platform_replica.travel_offset = travel_offset
	platform_replica.travel_speed = travel_speed
	platform_replica.endpoint_wait_seconds = endpoint_wait_seconds
	platform_replica.start_at_end = start_at_end
	platform_replica.movement_enabled = movement_enabled
	platform_replica.reset_on_player_respawn = reset_on_player_respawn
	platform_replica.one_way_collision = one_way_collision
	platform_replica.one_way_margin = one_way_margin
	platform_replica._apply_route_configuration()


func reset_combat(_clear_statistics: bool = false) -> void:
	platform.reset_motion()
	if delay_replica_role == DelayReplicaRole.AUTHORITY:
		notify_delay_body_reset()


func get_delay_ui_anchor_offset() -> Vector2:
	return platform.position + Vector2(0.0, -52.0)


func get_delay_selection_rect() -> Rect2:
	return Rect2(platform.position + Vector2(-80.0, -20.0), Vector2(160.0, 40.0))


func _process(_delta: float) -> void:
	# 标签属于静止外壳，需要显式跟随内部 AnimatableBody2D 的局部位置。
	var delay_ui: Node2D = get_node_or_null("DelayControlUi") as Node2D
	if delay_ui != null:
		delay_ui.position = get_delay_ui_anchor_offset()


func _apply_route_configuration() -> void:
	if platform == null:
		return
	platform.configure_route(
		travel_offset,
		travel_speed,
		endpoint_wait_seconds,
		start_at_end,
		movement_enabled,
		one_way_collision,
		one_way_margin
	)
