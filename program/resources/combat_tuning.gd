class_name CombatTuning
extends Resource

## 在 WorldTimeAuthority 的 Combat Tuning 中统一调整；三个角色共用配置，不共享战斗进度。
@export_group("Weapon Visual")
## 普通攻击与待机的剑身长度，重斩收招后恢复到这个值。
@export_range(24.0, 200.0, 1.0) var blade_length: float = 84.0

@export_group("Heavy Slash")
## 重斩起手时逐渐伸长到这个长度，收招时逐渐恢复 Blade Length。
@export_range(24.0, 200.0, 1.0) var heavy_blade_length: float = 110.0
## 第三段刀光与命中半径，单位为世界像素；实际范围不超过重斩剑身长度。
@export_range(24.0, 240.0, 1.0) var heavy_reach: float = 105.0
## 面向右侧时从上方后侧起剑，角度越小，向身后的回摆越大。
@export_range(-170.0, 0.0, 1.0) var heavy_start_degrees: float = -115.0
## 第三段收剑角度；与起剑角度的差决定完整挥动幅度。
@export_range(0.0, 170.0, 1.0) var heavy_end_degrees: float = 105.0

@export_group("Global Attack Speed")
## 角色层面的通用攻速，与当前武器自身的 Attack Speed Multiplier 相乘。
## 1 为原速；可用于后续作用于所有武器的通用升级或状态效果。
@export_range(0.1, 5.0, 0.05) var attack_speed_multiplier: float = 1.0

@export_group("Attack Movement")
## 地面起手、生效、收招期间的水平速度倍率；空中攻击不使用这个减速。
@export_range(0.0, 1.0, 0.05) var attack_move_multiplier: float = 0.2
## 蓄力模式的水平速度倍率；默认 0，后续升级可直接提高而无需改玩家移动逻辑。
@export_range(0.0, 1.0, 0.05) var charge_move_multiplier: float = 0.0
## 空中的水平加速、减速和反向加速度倍率；越小越难快速改变方向。
@export_range(0.05, 1.0, 0.05) var air_acceleration_multiplier: float = 0.25

@export_group("Charge Progression")
## 蓄力按逻辑时间增长；到达上限后保持三档，不再无限增加伤害。
@export_range(0.1, 10.0, 0.1) var charge_max_seconds: float = 3.0
## 连续伤害公式：基础伤害 * (1 + 蓄力秒数 * 本系数)。
@export_range(0.0, 2.0, 0.05) var charge_damage_per_second_coefficient: float = 0.35
## 蓄力达到一档所需的逻辑秒数；低于此值仍属于零档，只获得连续伤害倍率。
@export_range(0.1, 5.0, 0.1) var charge_tier_one_seconds: float = 1.0
## 蓄力达到二档所需的逻辑秒数；应不小于一档阈值。
@export_range(0.1, 5.0, 0.1) var charge_tier_two_seconds: float = 2.0
## 蓄力达到三档所需的逻辑秒数；应不小于二档阈值，通常也不大于 Charge Max Seconds。
@export_range(0.1, 5.0, 0.1) var charge_tier_three_seconds: float = 3.0

@export_group("Charged Sword")
## 一档前原地拔刀；一档起解锁动量，之后逐档增强。
@export_range(0.0, 1600.0, 10.0) var charged_sword_tier_one_impulse: float = 260.0
## 二档蓄力剑释放时沿鼠标瞄准方向加给玩家的瞬时速度，单位为像素/秒。
@export_range(0.0, 1600.0, 10.0) var charged_sword_tier_two_impulse: float = 440.0
## 三档沿鼠标方向叠加的最大动量，向上即升龙、水平或向下即突进。
@export_range(0.0, 1600.0, 10.0) var charged_sword_impulse: float = 620.0
## 蓄力剑的基础伤害；最终值再乘连续蓄力伤害倍率。
@export_range(1.0, 1000.0, 1.0) var charged_sword_damage: float = 15.0
## 零档、一档保持短距离拔刀，二档和三档再扩大判定与剑光。
@export_range(24.0, 240.0, 1.0) var charged_sword_base_reach: float = 84.0
## 二档蓄力剑的剑光长度和攻击判定半径，单位为世界像素。
@export_range(24.0, 240.0, 1.0) var charged_sword_tier_two_reach: float = 102.0
## 三档蓄力剑的最大剑光长度和攻击判定半径，单位为世界像素。
@export_range(24.0, 240.0, 1.0) var charged_sword_reach: float = 118.0

@export_group("Attack Input")
## 按住左键超过此时间才开始自动续段；短点按只会出第一段，单位为逻辑秒。
@export_range(0.0, 1.0, 0.01) var hold_repeat_delay: float = 0.15

@export_group("Hit Stop")
## 是否启用玩家剑攻击命中后的全局顿帧；关闭只移除暂停，不影响硬直、伤害和受击特效。
@export var hit_stop_enabled: bool = true
## 第一、二段真实命中时的顿帧时长，单位为真实秒。
@export_range(0.0, 0.3, 0.005) var hit_stop_seconds: float = 0.045
## 第三段命中时稍长的顿帧时长。
@export_range(0.0, 0.3, 0.005) var heavy_hit_stop_seconds: float = 0.085

@export_group("Screen Shake")
## 晃动仅在顿帧期间生效，结束时恢复原来的画面变换。
@export var shake_enabled: bool = true
## 第一、二段剑攻击命中时的镜头随机偏移强度，单位为屏幕像素。
@export_range(0.0, 20.0, 0.5) var shake_strength: float = 3.0
## 第三段与蓄力剑命中时的镜头随机偏移强度，单位为屏幕像素。
@export_range(0.0, 20.0, 0.5) var heavy_shake_strength: float = 5.0
## 每秒晃动频率，使用真实时间，不受游戏变速影响。
@export_range(1.0, 60.0, 1.0) var shake_frequency_hz: float = 40.0

@export_group("Player Hurt Feedback")
## 玩家伤害真正生效时才播放；无敌帧拒绝的重复命中不会触发。
@export var hurt_feedback_enabled: bool = true
## 角色被材质白化后恢复原色所需的真实时间。
@export_range(0.0, 1.0, 0.01) var hurt_character_flash_seconds: float = 0.16
## 全屏红光的渐隐时长与最大不透明度。
@export_range(0.0, 1.0, 0.01) var hurt_screen_flash_seconds: float = 0.22
## 玩家受伤时屏幕边缘红光的最大不透明度；0 表示完全不可见。
@export_range(0.0, 1.0, 0.01) var hurt_screen_flash_opacity: float = 0.24
## 玩家受伤时屏幕边缘闪光的颜色；透明度主要由 Hurt Screen Flash Opacity 控制。
@export var hurt_screen_flash_color: Color = Color(0.78, 0.03, 0.02, 1.0)
## 半径以内完全透明；数值越大，红光越贴近屏幕边缘。
@export_range(0.0, 1.4, 0.01) var hurt_screen_vignette_inner_radius: float = 0.58
## 从透明区过渡到红色边缘的宽度；数值越大，渐变越柔和。
@export_range(0.01, 1.0, 0.01) var hurt_screen_vignette_softness: float = 0.55
## 受伤震屏独立于攻击命中顿帧，保持轻微且短促。
@export_range(0.0, 1.0, 0.01) var hurt_shake_seconds: float = 0.16
## 玩家受伤时的镜头随机偏移强度，单位为屏幕像素。
@export_range(0.0, 20.0, 0.5) var hurt_shake_strength: float = 2.0

@export_group("Hit Effect")
## 真实命中时在受击目标上显示程序化火花；预览和预测攻击不会触发。
@export var hit_effect_enabled: bool = true
## 受击特效总时长，单位为真实秒；弹出后会在剩余时间内渐隐，不受顿帧和慢动作影响。
@export_range(0.03, 0.6, 0.01) var hit_effect_seconds: float = 0.22
## 从小菱形弹到目标尺寸所需的真实秒数；它应明显小于总时长。
@export_range(0.0, 0.2, 0.005) var hit_effect_grow_seconds: float = 0.035
## 刚命中时的菱形尺寸倍率；越小，快速放大的冲击感越明显。
@export_range(0.05, 1.0, 0.05) var hit_effect_start_scale: float = 0.35
## 渐隐结束前保留的不透明度；0 为完全透明，数值越高，消失前越清晰。
@export_range(0.0, 1.0, 0.05) var hit_effect_final_opacity: float = 0.30
## 第一、二段攻击的白色菱形半径，单位为世界像素。
@export_range(4.0, 120.0, 1.0) var hit_effect_size: float = 34.0
## 第三段重击使用的白色菱形半径，单位为世界像素。
@export_range(4.0, 160.0, 1.0) var heavy_hit_effect_size: float = 48.0
## 控制菱形横向厚度；1 为基础宽度，小于 1 更细长，大于 1 更饱满。
@export_range(0.1, 2.0, 0.05) var hit_effect_width_multiplier: float = 0.75
## 菱形整圈深色描边宽度，单位为像素；增加后在浅色背景上更醒目。
@export_range(1.0, 12.0, 0.5) var hit_effect_outline_width: float = 1.5


func get_charge_tier(charge_seconds: float) -> int:
	var clamped_seconds: float = clampf(charge_seconds, 0.0, charge_max_seconds)
	# 100 TPS 累加 0.01 会产生微小浮点误差；阈值需容忍“视觉上正好一秒”的帧。
	var threshold_seconds: float = clamped_seconds + 0.0001
	if threshold_seconds >= charge_tier_three_seconds:
		return 3
	if threshold_seconds >= charge_tier_two_seconds:
		return 2
	if threshold_seconds >= charge_tier_one_seconds:
		return 1
	return 0


func get_charge_damage_multiplier(charge_seconds: float) -> float:
	var clamped_seconds: float = clampf(charge_seconds, 0.0, charge_max_seconds)
	return 1.0 + clamped_seconds * charge_damage_per_second_coefficient


func get_charged_sword_impulse(charge_tier: int) -> float:
	match clampi(charge_tier, 0, 3):
		1: return charged_sword_tier_one_impulse
		2: return charged_sword_tier_two_impulse
		3: return charged_sword_impulse
	return 0.0


func get_charged_sword_reach(charge_tier: int) -> float:
	match clampi(charge_tier, 0, 3):
		2: return charged_sword_tier_two_reach
		3: return charged_sword_reach
	return charged_sword_base_reach
