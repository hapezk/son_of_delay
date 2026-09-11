extends Node

signal delay_load_capacity_changed(value: float)
signal delay_energy_capacity_changed(value: float)
signal player_natural_delay_changed(value: float)

## 跨关卡保存的延迟系统永久成长。当前 GameJam 版本只保存本次游戏进程，
## 后续若接入存档，只需序列化这三个公开数值即可。
const DEFAULT_DELAY_LOAD_CAPACITY: float = 1.0
const MAX_DELAY_LOAD_CAPACITY: float = 3.0
const DEFAULT_DELAY_ENERGY_CAPACITY: float = 1.0
const DEFAULT_PLAYER_NATURAL_DELAY: float = 1.0

var delay_load_capacity: float = DEFAULT_DELAY_LOAD_CAPACITY
var delay_energy_capacity: float = DEFAULT_DELAY_ENERGY_CAPACITY
var player_natural_delay: float = DEFAULT_PLAYER_NATURAL_DELAY


## 永久提高可同时维持的延迟负载，硬上限仍为三秒。
func upgrade_delay_load_capacity(amount: float) -> float:
	delay_load_capacity = clampf(
		delay_load_capacity + maxf(amount, 0.0),
		0.0,
		MAX_DELAY_LOAD_CAPACITY
	)
	delay_load_capacity = _quantize(delay_load_capacity)
	delay_load_capacity_changed.emit(delay_load_capacity)
	return delay_load_capacity


## 能量上限同样作为永久参数，方便后期让一次结算能够承担更大的调整。
func upgrade_delay_energy_capacity(amount: float) -> float:
	delay_energy_capacity = maxf(
		_quantize(delay_energy_capacity + maxf(amount, 0.0)),
		0.01
	)
	delay_energy_capacity_changed.emit(delay_energy_capacity)
	return delay_energy_capacity


## 降低玩家自然延迟；自然延迟永远不会低于零。
func reduce_player_natural_delay(amount: float) -> float:
	player_natural_delay = _quantize(maxf(
		player_natural_delay - maxf(amount, 0.0),
		0.0
	))
	player_natural_delay_changed.emit(player_natural_delay)
	return player_natural_delay


## 新存档或测试可以显式恢复初始永久属性；普通换关不会调用这里。
func reset_progression() -> void:
	delay_load_capacity = DEFAULT_DELAY_LOAD_CAPACITY
	delay_energy_capacity = DEFAULT_DELAY_ENERGY_CAPACITY
	player_natural_delay = DEFAULT_PLAYER_NATURAL_DELAY
	delay_load_capacity_changed.emit(delay_load_capacity)
	delay_energy_capacity_changed.emit(delay_energy_capacity)
	player_natural_delay_changed.emit(player_natural_delay)


func _quantize(value: float) -> float:
	return roundf(value * 100.0) / 100.0
