extends Control
## Full-screen settings overlay. Changes apply live through the Settings autoload.

signal closed

const UI = preload("res://scripts/ui.gd")

@onready var _settings: Node = get_node("/root/Settings")

var _ctl: Dictionary = {}   # key -> control
var _val: Dictionary = {}   # key -> value Label (sliders)
var _fmt: Dictionary = {}   # key -> Callable(float) -> String
var _refreshing := false
var _fps_values: Array[int] = [60, 120, 144, 240, 0]


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(0.01, 0.02, 0.05, 0.75)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var card := UI.panel(28)
	card.custom_minimum_size = Vector2(600, 0)
	center.add_child(card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	card.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	col.add_child(head)
	head.add_child(UI.chip("tune", UI.ACCENT, 42))
	var head_text := UI.bold("Settings", 26)
	head_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(head_text)
	col.add_child(UI.rule())

	var scroll := UI.scroll()
	scroll.custom_minimum_size = Vector2(0, 460)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 10)
	scroll.add_child(rows)

	_header(rows, "CONTROLS")
	_slider(rows, "mouse_sens", "Mouse sensitivity", 0.1, 3.0, 0.05, func(v: float) -> String: return "%.2fx" % v)
	_check(rows, "invert_y", "Invert Y")
	_header(rows, "VIDEO")
	_slider(rows, "fov", "Field of view", 60, 110, 1, func(v: float) -> String: return "%d°" % int(v))
	_slider(rows, "render_scale", "Render scale", 0.5, 1.0, 0.05, func(v: float) -> String: return "%d%%" % roundi(v * 100.0))
	_option(rows, "window_mode", "Window mode", ["Windowed", "Borderless fullscreen", "Exclusive fullscreen"])
	_check(rows, "vsync", "VSync")
	_option(rows, "max_fps", "Max FPS", ["60", "120", "144", "240", "Unlimited"])
	_option(rows, "msaa", "Anti-aliasing (MSAA)", ["Off", "2x", "4x", "8x"])
	_check(rows, "glow", "Glow")
	_check(rows, "ssao", "Ambient occlusion (SSAO)")
	_header(rows, "AUDIO")
	_slider(rows, "master_volume", "Master volume", 0.0, 1.0, 0.01, func(v: float) -> String: return "%d%%" % roundi(v * 100.0))
	_slider(rows, "sfx_volume", "Effects volume", 0.0, 1.0, 0.01, func(v: float) -> String: return "%d%%" % roundi(v * 100.0))
	_slider(rows, "ui_volume", "Interface volume", 0.0, 1.0, 0.01, func(v: float) -> String: return "%d%%" % roundi(v * 100.0))
	_slider(rows, "music_volume", "Music volume", 0.0, 1.0, 0.01, func(v: float) -> String: return "%d%%" % roundi(v * 100.0))
	_check(rows, "music_in_game", "Music while playing")

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	col.add_child(bottom)
	var reset_btn := UI.btn("Reset to defaults", "ghost")
	reset_btn.pressed.connect(_on_reset)
	bottom.add_child(reset_btn)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	var back := UI.btn("Back", "primary", 17)
	back.custom_minimum_size = Vector2(140, 0)
	back.pressed.connect(_close)
	bottom.add_child(back)

	visibility_changed.connect(func() -> void:
		if visible:
			_refresh())
	_refresh()


func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()


func _close() -> void:
	hide()
	closed.emit()


func _on_reset() -> void:
	_settings.reset()
	_refresh()


# --- row builders ---------------------------------------------------------

func _header(parent: Control, text: String) -> void:
	var l := UI.bold(text, 12, UI.ACCENT.lightened(0.3))
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 10)
	m.add_child(l)
	parent.add_child(m)


func _row(parent: Control, text: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 12)
	var l := UI.label(text, 17)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(l)
	parent.add_child(r)
	return r


func _slider(parent: Control, key: String, text: String, lo: float, hi: float, step: float, fmt: Callable) -> void:
	var r := _row(parent, text)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size = Vector2(200, 24)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UI.style_slider(s)
	r.add_child(s)
	var v := UI.label("", 16, UI.DIM)
	v.custom_minimum_size = Vector2(64, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	r.add_child(v)
	_ctl[key] = s
	_val[key] = v
	_fmt[key] = fmt
	s.value_changed.connect(func(x: float) -> void:
		v.text = fmt.call(x)
		if not _refreshing:
			_settings.set_value(key, x))


func _check(parent: Control, key: String, text: String) -> void:
	var r := _row(parent, text)
	var c := CheckButton.new()
	UI.style_check(c)
	r.add_child(c)
	_ctl[key] = c
	c.toggled.connect(func(on: bool) -> void:
		if not _refreshing:
			_settings.set_value(key, on))


func _option(parent: Control, key: String, text: String, items: Array) -> void:
	var r := _row(parent, text)
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(220, 0)
	o.add_theme_font_size_override("font_size", 16)
	UI.style_option(o)
	for t in items:
		o.add_item(str(t))
	r.add_child(o)
	_ctl[key] = o
	o.item_selected.connect(func(i: int) -> void:
		if _refreshing:
			return
		_settings.set_value(key, _fps_values[i] if key == "max_fps" else i))


# --- state ----------------------------------------------------------------

func _refresh() -> void:
	if _ctl.is_empty():
		return
	_refreshing = true
	for key: String in _ctl:
		var c: Control = _ctl[key]
		var v: Variant = _settings.get(key)
		if c is HSlider:
			(c as HSlider).value = float(v)
			(_val[key] as Label).text = (_fmt[key] as Callable).call(float(v))
		elif c is CheckButton:
			(c as CheckButton).button_pressed = bool(v)
		elif c is OptionButton:
			var idx := int(v)
			if key == "max_fps":
				idx = _fps_values.find(int(v))
				if idx < 0:
					idx = _fps_values.size() - 1
			(c as OptionButton).select(idx)
	_refreshing = false
