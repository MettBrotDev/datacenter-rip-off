extends Node
## User settings (autoload "Settings"): stored in user://options.cfg, applied to the engine live.

signal changed

const PATH := "user://options.cfg"
const SECTION := "options"

var mouse_sens: float = 1.0
var invert_y: bool = false
var fov: float = 70.0
var master_volume: float = 0.8
var window_mode: int = 0
var vsync: bool = true
var max_fps: int = 0
var render_scale: float = 1.0
var msaa: int = 1
var glow: bool = true
var ssao: bool = true

const KEYS: Array[String] = [
	"mouse_sens", "invert_y", "fov", "master_volume", "window_mode", "vsync",
	"max_fps", "render_scale", "msaa", "glow", "ssao",
]


func _ready() -> void:
	_load()
	apply()


func set_value(key: String, value: Variant) -> void:
	if not KEYS.has(key):
		push_warning("Settings: unknown key '%s'" % key)
		return
	set(key, value)
	_clamp_all()
	apply()
	_save()
	changed.emit()


func reset() -> void:
	mouse_sens = 1.0
	invert_y = false
	fov = 70.0
	master_volume = 0.8
	window_mode = 0
	vsync = true
	max_fps = 0
	render_scale = 1.0
	msaa = 1
	glow = true
	ssao = true
	apply()
	_save()
	changed.emit()


## True when the game was started with any of the test flags (see main.gd).
func _is_test_run() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		for flag: String in ["--bot", "--probe", "--shot", "--selftest"]:
			if arg.begins_with(flag):
				return true
	return false


func apply() -> void:
	var headless := DisplayServer.get_name() == "headless"
	if not headless and _is_test_run():
		# automated runs: always a small plain window that stays out of the way, whatever is saved
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_size(Vector2i(1280, 720))
	elif not headless:
		match window_mode:
			1:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			2:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
			_:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_vsync_mode(
				DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = max_fps
	var vp := get_viewport()
	if vp != null:
		vp.scaling_3d_scale = render_scale
		match msaa:
			0:
				vp.msaa_3d = Viewport.MSAA_DISABLED
			1:
				vp.msaa_3d = Viewport.MSAA_2X
			2:
				vp.msaa_3d = Viewport.MSAA_4X
			_:
				vp.msaa_3d = Viewport.MSAA_8X
	var bus := AudioServer.get_bus_index("Master")
	if bus >= 0:
		AudioServer.set_bus_mute(bus, master_volume <= 0.001)
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(master_volume, 0.0001)))


func _clamp_all() -> void:
	mouse_sens = clampf(float(mouse_sens), 0.1, 3.0)
	fov = clampf(float(fov), 60.0, 110.0)
	master_volume = clampf(float(master_volume), 0.0, 1.0)
	window_mode = clampi(int(window_mode), 0, 2)
	max_fps = maxi(int(max_fps), 0)
	render_scale = clampf(float(render_scale), 0.5, 1.0)
	msaa = clampi(int(msaa), 0, 3)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for k in KEYS:
		if cfg.has_section_key(SECTION, k):
			var v: Variant = cfg.get_value(SECTION, k)
			if typeof(v) == typeof(get(k)) or (typeof(v) in [TYPE_INT, TYPE_FLOAT] and typeof(get(k)) in [TYPE_INT, TYPE_FLOAT]):
				set(k, v)
	_clamp_all()


func _save() -> void:
	var cfg := ConfigFile.new()
	for k in KEYS:
		cfg.set_value(SECTION, k, get(k))
	cfg.save(PATH)
