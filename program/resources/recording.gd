class_name Recording
extends DelayFrame

#region Input
var move_dir: float
var jump_pressed: bool
## 下穿平台是一次性移动指令；延迟本体必须在对应历史帧再执行。
var drop_pressed: bool = false
## 拾取是一次性世界交互；预览体只记录，本体回放到该帧时才执行。
var interact_pressed: bool = false
## 记录点击和当时朝向；回放时不读取当前鼠标或角色朝向。
var attack_pressed: bool = false
var attack_facing: int = 1
## 相对左右基础朝向的鼠标瞄准旋转（弧度），避免回放读取现在的鼠标位置。
var attack_aim_rotation: float = 0.0
## 保留两个发射器的独立一次性指令；现在由选中的武器把左键映射到对应指令。
var secondary_attack_pressed: bool = false
var secondary_aim_direction: Vector2 = Vector2.RIGHT
## 法杖直线弹与回旋镖分别记录，两个武器可以拥有独立的输入与冷却。
var straight_shot_pressed: bool = false
var straight_shot_aim_direction: Vector2 = Vector2.RIGHT
## 武器选择和蓄力状态属于输入时间线；本体回放时不能读取玩家此刻的选择。
var weapon_slot: int = 1
var charge_mode: bool = false
var charged_attack_pressed: bool = false
var charged_aim_direction: Vector2 = Vector2.RIGHT
## 蓄力秒数随输入帧记录；延迟本体据此还原连续伤害和 1/2/3 档能力。
var charge_elapsed_seconds: float = 0.0
#endregion

#region Sprite2DSnapshot
var texture: Texture2D
var scale: Vector2 = Vector2.ONE
var region_enabled: bool = false
var region_rect: Rect2 = Rect2()
var hframes: int = 1
var vframes: int = 1
var frame: int = 0
var frame_coords: Vector2i = Vector2i.ZERO
var centered: bool = true
var offset: Vector2 = Vector2.ZERO
var flip_h: bool = false
#endregion

func _init(
	_move_dir: float,
	_jump_pressed: bool,
	_pos: Vector2,
	_vel: Vector2,
	_attack_pressed: bool = false,
	_attack_facing: int = 1,
	_attack_aim_rotation: float = 0.0,
	_secondary_attack_pressed: bool = false,
	_secondary_aim_direction: Vector2 = Vector2.RIGHT,
	_straight_shot_pressed: bool = false,
	_straight_shot_aim_direction: Vector2 = Vector2.RIGHT,
	_drop_pressed: bool = false,
	_weapon_slot: int = 1,
	_charge_mode: bool = false,
	_charged_attack_pressed: bool = false,
	_charged_aim_direction: Vector2 = Vector2.RIGHT,
	_charge_elapsed_seconds: float = 0.0,
	_interact_pressed: bool = false,
):
	super({
		"move_dir": _move_dir,
		"jump_pressed": _jump_pressed,
		"drop_pressed": _drop_pressed,
		"attack_pressed": _attack_pressed,
		"attack_facing": _attack_facing,
		"attack_aim_rotation": _attack_aim_rotation,
		"secondary_attack_pressed": _secondary_attack_pressed,
		"secondary_aim_direction": _secondary_aim_direction,
		"straight_shot_pressed": _straight_shot_pressed,
		"straight_shot_aim_direction": _straight_shot_aim_direction,
		"weapon_slot": _weapon_slot,
		"charge_mode": _charge_mode,
		"charged_attack_pressed": _charged_attack_pressed,
		"charged_aim_direction": _charged_aim_direction,
		"charge_elapsed_seconds": _charge_elapsed_seconds,
		"interact_pressed": _interact_pressed,
	}, _pos, _vel)
	move_dir = _move_dir
	jump_pressed = _jump_pressed
	drop_pressed = _drop_pressed
	pos = _pos
	vel = _vel
	attack_pressed = _attack_pressed
	attack_facing = _attack_facing
	attack_aim_rotation = _attack_aim_rotation
	secondary_attack_pressed = _secondary_attack_pressed
	secondary_aim_direction = _secondary_aim_direction
	straight_shot_pressed = _straight_shot_pressed
	straight_shot_aim_direction = _straight_shot_aim_direction
	weapon_slot = _weapon_slot
	charge_mode = _charge_mode
	charged_attack_pressed = _charged_attack_pressed
	charged_aim_direction = _charged_aim_direction
	charge_elapsed_seconds = _charge_elapsed_seconds
	interact_pressed = _interact_pressed
