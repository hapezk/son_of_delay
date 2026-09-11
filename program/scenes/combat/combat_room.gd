extends Node

## 正式关卡控制器：统计敌人，并要求玩家清场后抵达终点才完成游戏。
enum RoomState { PLAYING, VICTORY, DEFEAT }

const VICTORY_PAUSE_REASON: StringName = &"combat_victory"
const MAIN_MENU_SCENE_PATH: String = "res://scenes/ui/main_menu.tscn"

@onready var player_group: DelayedActorGroup = get_node("../Actors/BodyGroup") as DelayedActorGroup
@onready var enemy_root: Node2D = get_node("../Enemies") as Node2D
@onready var time_authority: WorldTimeAuthority = get_node("../WorldTimeAuthority") as WorldTimeAuthority
@onready var result_layer: CanvasLayer = get_node("../CombatResult") as CanvasLayer
@onready var result_title: Label = get_node("../CombatResult/Backdrop/ResultTitle") as Label
@onready var result_hint: Label = get_node("../CombatResult/Backdrop/ResultHint") as Label
@onready var restart_button: Button = get_node("../CombatResult/Backdrop/RestartButton") as Button
@onready var main_menu_button: Button = get_node("../CombatResult/Backdrop/MainMenuButton") as Button
@onready var quit_button: Button = get_node("../CombatResult/Backdrop/QuitButton") as Button
@onready var wave_status: Label = get_node("../CombatHelp/WaveStatus") as Label
@onready var finish_area: Area2D = get_node("../FinishGoal/FinishArea") as Area2D
@onready var finish_status: Label = get_node("../FinishGoal/Status") as Label

var room_state: RoomState = RoomState.PLAYING
var _enemies: Array[Node] = []
var _initialized: bool = false
var _player_inside_finish: bool = false


func _ready() -> void:
	# 结果出现时即使命中顿帧正在暂停世界，也要继续拦截会改变时间轴的按键。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 控制器与角色组是同级节点；延后一帧可确保 DelayedActorGroup 已填好 body 引用。
	_initialize_room.call_deferred()


func _initialize_room() -> void:
	if _initialized:
		return
	_initialized = true
	for child: Node in enemy_root.get_children():
		if not child.has_method("is_defeated"):
			continue
		_enemies.append(child)
		if child.has_signal("defeated"):
			child.connect("defeated", Callable(self, "_on_enemy_defeated"))
	if player_group.body.has_signal("died"):
		player_group.body.connect("died", Callable(self, "_on_player_died"))
	player_group.player_respawned.connect(_on_player_respawned)
	restart_button.pressed.connect(restart_round)
	main_menu_button.pressed.connect(_return_to_main_menu)
	quit_button.pressed.connect(_quit_game)
	finish_area.body_entered.connect(_on_finish_body_entered)
	finish_area.body_exited.connect(_on_finish_body_exited)
	_begin_playing_round()


func _input(event: InputEvent) -> void:
	if room_state == RoomState.PLAYING or event.is_echo():
		return
	var blocks_time_control: bool = event.is_action_pressed("thinking_time")
	if event is InputEventKey and event.pressed:
		blocks_time_control = blocks_time_control or event.keycode in [KEY_1, KEY_2, KEY_3, KEY_R]
	if blocks_time_control:
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if room_state != RoomState.VICTORY or event.is_echo():
		return
	if event is InputEventKey and event.pressed and event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		restart_round()
		get_viewport().set_input_as_handled()


## 胜利界面与按钮共用；玩家战败仍沿用死亡系统的自动重生。
func restart_round() -> void:
	if room_state != RoomState.VICTORY:
		return
	time_authority.release_external_pause(VICTORY_PAUSE_REASON)
	player_group.respawn_player()


func _on_enemy_defeated(_enemy: CharacterBody2D) -> void:
	_update_wave_status()
	if room_state == RoomState.PLAYING and _count_alive_enemies() == 0 \
			and _player_inside_finish:
		_complete_game()


## 终点只识别真实玩家；预览体没有 player_damage_body 分组，不会误结算。
func _on_finish_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player_damage_body"):
		return
	_player_inside_finish = true
	if room_state == RoomState.PLAYING and _count_alive_enemies() == 0:
		_complete_game()
	else:
		_update_finish_status()


func _on_finish_body_exited(body: Node2D) -> void:
	if not body.is_in_group("player_damage_body"):
		return
	_player_inside_finish = false
	_update_finish_status()


## 清场和抵达终点两个条件都满足后，显示最终结算并暂停世界。
func _complete_game() -> void:
	if room_state != RoomState.PLAYING:
		return
	room_state = RoomState.VICTORY
	_update_wave_status()
	_update_finish_status()
	result_title.text = "游戏完成"
	result_title.modulate = Color("8ff0a4")
	result_hint.text = "已清理全部追猎者并抵达终点"
	restart_button.visible = true
	restart_button.text = "重新开始（Enter）"
	main_menu_button.visible = true
	quit_button.visible = true
	result_layer.visible = true
	# 延迟到本物理帧结束，让最后一击先登记顿帧；顿帧结束后仍会保留胜利暂停。
	_pause_victory.call_deferred()


func _on_player_died() -> void:
	# 同一物理帧发生互杀时以玩家死亡为准，避免尸体旁仍显示胜利。
	if room_state == RoomState.DEFEAT:
		return
	time_authority.release_external_pause(VICTORY_PAUSE_REASON)
	room_state = RoomState.DEFEAT
	result_title.text = "战败"
	result_title.modulate = Color("ff8585")
	result_hint.text = "正在返回出生点……"
	restart_button.visible = false
	main_menu_button.visible = false
	quit_button.visible = false
	result_layer.visible = true
	_update_wave_status()


func _on_player_respawned() -> void:
	_begin_playing_round()


func _begin_playing_round() -> void:
	time_authority.release_external_pause(VICTORY_PAUSE_REASON)
	_clear_round_projectiles()
	room_state = RoomState.PLAYING
	_player_inside_finish = false
	result_layer.visible = false
	_update_wave_status()
	_update_finish_status()


## 所有弹幕属于单轮生命周期；重开时一并移除敌方弹幕与玩家回旋镖。
func _clear_round_projectiles() -> void:
	for projectile: Node in get_tree().get_nodes_in_group("round_projectiles"):
		if is_instance_valid(projectile):
			projectile.queue_free()


## 保留旧测试和调试入口；现在实际执行完整的单轮弹幕清理。
func _clear_hostile_projectiles() -> void:
	_clear_round_projectiles()


func _update_wave_status() -> void:
	var alive: int = _count_alive_enemies()
	wave_status.text = "战斗房间 · 剩余敌人 %d / %d" % [alive, _enemies.size()]
	if room_state == RoomState.VICTORY:
		wave_status.text += " · 游戏完成"
	elif room_state == RoomState.DEFEAT:
		wave_status.text += " · 玩家战败"
	elif alive == 0:
		wave_status.text += " · 前往终点"
	_update_finish_status()


func _update_finish_status() -> void:
	if finish_status == null:
		return
	var alive: int = _count_alive_enemies()
	if room_state == RoomState.VICTORY:
		finish_status.text = "旅程完成"
	elif alive == 0:
		finish_status.text = "终点已开放\n进入光门完成游戏"
	else:
		finish_status.text = "终点封锁\n剩余敌人 %d" % alive


func _count_alive_enemies() -> int:
	var alive: int = 0
	for enemy: Node in _enemies:
		if is_instance_valid(enemy) and not bool(enemy.call("is_defeated")):
			alive += 1
	return alive


func _pause_victory() -> void:
	if room_state == RoomState.VICTORY:
		time_authority.request_external_pause(VICTORY_PAUSE_REASON)


func _return_to_main_menu() -> void:
	time_authority.release_external_pause(VICTORY_PAUSE_REASON)
	var change_error: Error = get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)
	if change_error != OK:
		push_error("CombatRoom: failed to return to main menu (%s)" % error_string(change_error))


func _quit_game() -> void:
	get_tree().quit()
