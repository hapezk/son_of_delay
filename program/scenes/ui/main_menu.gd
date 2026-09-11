extends Control

## 主菜单只负责场景导航与基础显示/音量设置。
const TUTORIAL_SCENE_PATH: String = "res://scenes/tutorial/tutorial_level.tscn"
const SETTINGS_STORE: Script = preload("res://scenes/ui/settings_store.gd")

@onready var main_panel: PanelContainer = $MainPanel as PanelContainer
@onready var settings_panel: PanelContainer = $SettingsPanel as PanelContainer
@onready var start_button: Button = $MainPanel/Margin/VBox/StartButton as Button
@onready var settings_button: Button = $MainPanel/Margin/VBox/SettingsButton as Button
@onready var quit_button: Button = $MainPanel/Margin/VBox/QuitButton as Button
@onready var volume_slider: HSlider = \
	$SettingsPanel/Margin/VBox/VolumeSlider as HSlider
@onready var volume_value: Label = \
	$SettingsPanel/Margin/VBox/VolumeHeader/VolumeValue as Label
@onready var fullscreen_toggle: CheckButton = \
	$SettingsPanel/Margin/VBox/FullscreenToggle as CheckButton
@onready var back_button: Button = $SettingsPanel/Margin/VBox/BackButton as Button

var _settings: Dictionary = {}
var _scene_change_started: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 从任意暂停中的关卡返回主菜单时，确保新菜单处于正常运行状态。
	get_tree().paused = false
	Engine.time_scale = 1.0

	start_button.pressed.connect(_on_start_pressed)
	settings_button.pressed.connect(_show_settings)
	quit_button.pressed.connect(_on_quit_pressed)
	volume_slider.value_changed.connect(_on_volume_changed)
	fullscreen_toggle.toggled.connect(_on_fullscreen_toggled)
	back_button.pressed.connect(_show_main_menu)

	_settings = SETTINGS_STORE.load_settings()
	volume_slider.value = float(_settings.get("master_volume", 0.8)) * 100.0
	fullscreen_toggle.button_pressed = bool(_settings.get("fullscreen", false))
	SETTINGS_STORE.apply_settings(_settings)
	_update_volume_value()
	start_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel") or event.is_echo():
		return
	if settings_panel.visible:
		_show_main_menu()
		get_viewport().set_input_as_handled()


func _on_start_pressed() -> void:
	if _scene_change_started:
		return
	_scene_change_started = true
	start_button.disabled = true
	var change_error: Error = get_tree().change_scene_to_file(TUTORIAL_SCENE_PATH)
	if change_error != OK:
		_scene_change_started = false
		start_button.disabled = false
		push_error("MainMenu: failed to open tutorial scene (%s)" % change_error)


func _show_settings() -> void:
	main_panel.visible = false
	settings_panel.visible = true
	volume_slider.grab_focus()


func _show_main_menu() -> void:
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


func _on_quit_pressed() -> void:
	get_tree().quit()
