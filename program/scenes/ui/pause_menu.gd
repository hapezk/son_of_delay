extends CanvasLayer

## 与 WorldTimeAuthority 共用暂停原因，防止关闭菜单时误解除思考时间或胜利暂停。
const PAUSE_REASON: StringName = &"pause_menu"
const MAIN_MENU_SCENE_PATH: String = "res://scenes/ui/main_menu.tscn"
const SETTINGS_STORE: Script = preload("res://scenes/ui/settings_store.gd")

@onready var main_panel: PanelContainer = $Backdrop/Center/MainPanel as PanelContainer
@onready var settings_panel: PanelContainer = \
	$Backdrop/Center/SettingsPanel as PanelContainer
@onready var continue_button: Button = \
	$Backdrop/Center/MainPanel/Margin/VBox/ContinueButton as Button
@onready var restart_button: Button = \
	$Backdrop/Center/MainPanel/Margin/VBox/RestartButton as Button
@onready var settings_button: Button = \
	$Backdrop/Center/MainPanel/Margin/VBox/SettingsButton as Button
@onready var main_menu_button: Button = \
	$Backdrop/Center/MainPanel/Margin/VBox/MainMenuButton as Button
@onready var volume_slider: HSlider = \
	$Backdrop/Center/SettingsPanel/Margin/VBox/VolumeSlider as HSlider
@onready var volume_value: Label = \
	$Backdrop/Center/SettingsPanel/Margin/VBox/VolumeHeader/VolumeValue as Label
@onready var fullscreen_toggle: CheckButton = \
	$Backdrop/Center/SettingsPanel/Margin/VBox/FullscreenToggle as CheckButton
@onready var back_button: Button = \
	$Backdrop/Center/SettingsPanel/Margin/VBox/BackButton as Button

var _settings: Dictionary = {}
var _is_open: bool = false
var _using_time_authority: bool = false
var _tree_was_paused: bool = false
var _pause_authority: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	continue_button.pressed.connect(_close_pause)
	restart_button.pressed.connect(_restart_level)
	settings_button.pressed.connect(_show_settings)
	main_menu_button.pressed.connect(_return_to_main_menu)
	volume_slider.value_changed.connect(_on_volume_changed)
	fullscreen_toggle.toggled.connect(_on_fullscreen_toggled)
	back_button.pressed.connect(_show_pause_panel)

	_settings = SETTINGS_STORE.load_settings()
	volume_slider.value = float(_settings.get("master_volume", 0.8)) * 100.0
	fullscreen_toggle.button_pressed = bool(_settings.get("fullscreen", false))
	SETTINGS_STORE.apply_settings(_settings)
	_update_volume_value()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel") or event.is_echo():
		return
	if not _is_open:
		_open_pause()
	elif settings_panel.visible:
		_show_pause_panel()
	else:
		_close_pause()
	get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	# 场景切换或退出时，只释放本菜单登记的暂停原因。
	_release_pause_state()


func _open_pause() -> void:
	if _is_open:
		return
	_is_open = true
	visible = true
	main_panel.visible = true
	settings_panel.visible = false

	_tree_was_paused = get_tree().paused
	_pause_authority = get_tree().get_first_node_in_group("world_time_authority")
	_using_time_authority = _pause_authority != null \
		and _pause_authority.has_method("request_external_pause")
	if _using_time_authority:
		_pause_authority.call("request_external_pause", PAUSE_REASON)
	else:
		get_tree().paused = true
	continue_button.grab_focus()


func _close_pause() -> void:
	if not _is_open:
		return
	_release_pause_state()
	visible = false
	main_panel.visible = true
	settings_panel.visible = false


func _release_pause_state() -> void:
	if not _is_open:
		return
	_is_open = false
	if _using_time_authority and is_instance_valid(_pause_authority) \
			and _pause_authority.is_inside_tree():
		_pause_authority.call("release_external_pause", PAUSE_REASON)
	elif get_tree() != null:
		get_tree().paused = _tree_was_paused
	_using_time_authority = false
	_pause_authority = null


func _show_settings() -> void:
	main_panel.visible = false
	settings_panel.visible = true
	volume_slider.grab_focus()


func _show_pause_panel() -> void:
	settings_panel.visible = false
	main_panel.visible = true
	settings_button.grab_focus()


func _on_volume_changed(value: float) -> void:
	_settings["master_volume"] = value / 100.0
	_apply_and_save_settings()
	_update_volume_value()


func _on_fullscreen_toggled(enabled: bool) -> void:
	_settings["fullscreen"] = enabled
	_apply_and_save_settings()


func _apply_and_save_settings() -> void:
	SETTINGS_STORE.apply_settings(_settings)
	SETTINGS_STORE.save_settings(
		float(_settings.get("master_volume", 0.8)),
		bool(_settings.get("fullscreen", false))
	)


func _update_volume_value() -> void:
	volume_value.text = "%d%%" % roundi(volume_slider.value)


func _restart_level() -> void:
	_release_pause_state()
	# 若从思考时间里重开，确保旧场景临时关闭的物理服务器先恢复。
	PhysicsServer2D.set_active(true)
	var reload_error: Error = get_tree().reload_current_scene()
	if reload_error != OK:
		push_error("PauseMenu: failed to restart current scene (%s)" % reload_error)
		_open_pause()


func _return_to_main_menu() -> void:
	_release_pause_state()
	PhysicsServer2D.set_active(true)
	var change_error: Error = get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)
	if change_error != OK:
		push_error("PauseMenu: failed to return to main menu (%s)" % change_error)
		_open_pause()
