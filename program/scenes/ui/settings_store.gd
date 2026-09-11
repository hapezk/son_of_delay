class_name SettingsStore
extends RefCounted

## 菜单共用的轻量设置存储；保存到 user://，不会写入项目资源目录。
const SETTINGS_PATH: String = "user://settings.cfg"
const DEFAULT_MASTER_VOLUME: float = 0.8
const DEFAULT_FULLSCREEN: bool = false


static func load_settings() -> Dictionary:
	var settings: Dictionary = {
		"master_volume": DEFAULT_MASTER_VOLUME,
		"fullscreen": DEFAULT_FULLSCREEN,
	}
	var config: ConfigFile = ConfigFile.new()
	var load_error: Error = config.load(SETTINGS_PATH)
	if load_error == OK:
		settings["master_volume"] = clampf(
			float(config.get_value("audio", "master_volume", DEFAULT_MASTER_VOLUME)),
			0.0,
			1.0
		)
		settings["fullscreen"] = bool(
			config.get_value("display", "fullscreen", DEFAULT_FULLSCREEN))
	return settings


static func apply_settings(settings: Dictionary) -> void:
	var master_volume: float = clampf(
		float(settings.get("master_volume", DEFAULT_MASTER_VOLUME)), 0.0, 1.0)
	var master_bus_index: int = AudioServer.get_bus_index("Master")
	if master_bus_index >= 0:
		AudioServer.set_bus_mute(master_bus_index, is_zero_approx(master_volume))
		AudioServer.set_bus_volume_db(
			master_bus_index, linear_to_db(maxf(master_volume, 0.0001)))

	var fullscreen: bool = bool(settings.get("fullscreen", DEFAULT_FULLSCREEN))
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


static func save_settings(master_volume: float, fullscreen: bool) -> void:
	var config: ConfigFile = ConfigFile.new()
	config.set_value("audio", "master_volume", clampf(master_volume, 0.0, 1.0))
	config.set_value("display", "fullscreen", fullscreen)
	var save_error: Error = config.save(SETTINGS_PATH)
	if save_error != OK:
		push_error("SettingsStore: failed to save settings (%s)" % save_error)
