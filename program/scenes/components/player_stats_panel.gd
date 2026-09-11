class_name PlayerStatsPanel
extends PanelContainer

## 左上角玩家属性面板。只读取真实本体和延迟控制器，不持有第二份玩法数据。
@export var player_group_path: NodePath

@onready var health_label: Label = $Margin/VBox/HealthLabel
@onready var health_bar: ProgressBar = $Margin/VBox/HealthBar
@onready var player_delay_label: Label = $Margin/VBox/PlayerDelayLabel
@onready var delay_budget_label: Label = $Margin/VBox/DelayBudgetLabel
@onready var delay_budget_bar: ProgressBar = $Margin/VBox/DelayBudgetBar
@onready var delay_energy_label: Label = $Margin/VBox/DelayEnergyLabel
@onready var delay_energy_bar: ProgressBar = $Margin/VBox/DelayEnergyBar

var player_group: DelayedActorGroup
var player: BaseActor
## 保持为 Node，让属性面板不反向依赖某一种容量实现。
var delay_budget_manager: Node
var _last_signature: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_resolve_player()
	_refresh_panel(true)


func _process(_delta: float) -> void:
	if player_group == null or not is_instance_valid(player_group) \
			or player == null or not is_instance_valid(player):
		_resolve_player()
	if delay_budget_manager == null or not is_instance_valid(delay_budget_manager):
		_resolve_delay_budget()
	_refresh_panel()


func _resolve_player() -> void:
	player_group = get_node_or_null(player_group_path) as DelayedActorGroup
	player = player_group.body if player_group != null else null
	_resolve_delay_budget()


func _resolve_delay_budget() -> void:
	delay_budget_manager = get_tree().get_first_node_in_group("delay_budget_manager")


func _refresh_panel(force: bool = false) -> void:
	if player_group == null or player == null:
		health_label.text = "生命  -- / --"
		health_bar.value = 0.0
		player_delay_label.text = "玩家延迟  -- / --"
		delay_budget_label.text = "延迟容量  -- / --"
		delay_budget_bar.value = 0.0
		delay_energy_label.text = "时滞能量  -- / --"
		delay_energy_bar.value = 0.0
		return
	var current_health: float = float(player.get("current_health"))
	var max_health: float = float(player.get("max_health"))
	var requested_delay: float = player_group.get_requested_delay()
	var max_delay: float = player_group.get_effective_max_delay_time()
	var used_budget: float = requested_delay
	if delay_budget_manager != null:
		used_budget = float(delay_budget_manager.call("get_displayed_used_delay")) \
			if delay_budget_manager.has_method("get_displayed_used_delay") \
			else float(delay_budget_manager.call("get_used_delay"))
	var total_budget: float = float(delay_budget_manager.get("total_capacity")) \
		if delay_budget_manager != null else max_delay
	var feedback_text: String = str(delay_budget_manager.call("get_feedback_text")) \
		if delay_budget_manager != null else ""
	var current_energy: float = float(delay_budget_manager.get("current_energy")) \
		if delay_budget_manager != null else 0.0
	var maximum_energy: float = float(delay_budget_manager.get("maximum_energy")) \
		if delay_budget_manager != null else 1.0
	var signature: String = "%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%s" % [
		current_health, max_health, requested_delay, player_group.natural_delay_time,
		used_budget, total_budget, current_energy, maximum_energy, feedback_text,
	]
	if not force and signature == _last_signature:
		return
	_last_signature = signature
	health_label.text = "生命  %.0f / %.0f" % [current_health, max_health]
	health_label.modulate = Color("f0f4f6") if current_health > max_health * 0.3 else Color("ff8b8b")
	health_bar.max_value = maxf(max_health, 1.0)
	health_bar.value = current_health
	player_delay_label.text = "玩家延迟  %.2fs / 自然延迟 %.2fs" % [
		requested_delay, player_group.natural_delay_time]
	delay_budget_label.text = feedback_text if not feedback_text.is_empty() \
		else "延迟负载  %.2f / %.2fs" % [used_budget, total_budget]
	delay_budget_label.modulate = Color("ff8b8b") if not feedback_text.is_empty() \
		else Color("8ce1ff")
	delay_budget_bar.max_value = maxf(total_budget, 0.01)
	delay_budget_bar.value = used_budget
	delay_energy_label.text = "时滞能量  %.2f / %.2f" % [current_energy, maximum_energy]
	delay_energy_bar.max_value = maxf(maximum_energy, 0.01)
	delay_energy_bar.value = current_energy
