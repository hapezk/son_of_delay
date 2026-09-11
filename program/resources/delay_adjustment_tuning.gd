class_name DelayAdjustmentTuning
extends Resource

## 玩家与敌人共享同一份输入手感参数，避免各场景分别覆盖后逐渐产生差异。
@export_range(0.01, 0.20, 0.01) var step_seconds: float = 0.01
@export_range(0.05, 0.5, 0.01) var rapid_scroll_interval: float = 0.10
## 停止滚动多久后，将快速滚动提升的步长恢复为 step_seconds。
@export_range(0.05, 2.0, 0.01) var step_reset_interval: float = 0.20
@export_range(2, 12, 1) var snap_after_steps: int = 6
