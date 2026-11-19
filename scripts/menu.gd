extends Control
## Main menu: name, colour, host or join. Remembers choices in user://settings.cfg.

const UI = preload("res://scripts/ui.gd")
const SETTINGS := "user://settings.cfg"

var _name: LineEdit
var _ip: LineEdit
var _status: Label
var _swatches: Array[Button] = []
var _color_idx := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	_color_idx = clampi(cfg.get_value("player", "color", 0), 0, Net.PALETTE.size() - 1)

	var bg := ColorRect.new()
	bg.color = UI.BG_DARK
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)
	var card := UI.panel(28)
	card.custom_minimum_size.x = 460
	center.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	card.add_child(v)

	v.add_child(UI.label("RACK & RUIN", 40))
	v.add_child(UI.label("A datacenter. What could go wrong.", 16, UI.DIM))
	v.add_child(_gap(8))
	v.add_child(UI.label("NAME", 13, UI.DIM))
	_name = UI.field("Your name", cfg.get_value("player", "name", ""))
	_name.max_length = 16
	v.add_child(_name)

	v.add_child(UI.label("COLOUR", 13, UI.DIM))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	for i in Net.PALETTE.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(40, 40)
		b.pressed.connect(_pick_color.bind(i))
		row.add_child(b)
		_swatches.append(b)
	_pick_color(_color_idx)

	v.add_child(_gap(8))
	var host := UI.button("Host a game", true)
	host.pressed.connect(_host)
	v.add_child(host)
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	v.add_child(join_row)
	_ip = UI.field("Host IP address", cfg.get_value("player", "ip", ""))
	_ip.size_flags_horizontal = SIZE_EXPAND_FILL
	_ip.text_submitted.connect(func(_t): _join())
	join_row.add_child(_ip)
	var join := UI.button("Join")
	join.custom_minimum_size.x = 100
	join.pressed.connect(_join)
	join_row.add_child(join)

	_status = UI.label("", 15, UI.RED)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)
	v.add_child(UI.label("Up to 4 players · UDP port %d" % Net.PORT, 13, UI.DIM))


func set_status(text: String, color := UI.RED) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _gap(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = h
	return c


func _pick_color(i: int) -> void:
	_color_idx = i
	for j in _swatches.size():
		var border := Color.WHITE if j == i else Color(0, 0, 0, 0)
		var s := UI.box(Net.PALETTE[j], 20, border, 0)
		s.set_border_width_all(3)
		for state in ["normal", "hover", "pressed", "focus"]:
			_swatches[j].add_theme_stylebox_override(state, s)


func _apply() -> void:
	var n := _name.text.strip_edges()
	Net.my_name = n if n != "" else "Player"
	Net.my_color = Net.PALETTE[_color_idx]
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", n)
	cfg.set_value("player", "color", _color_idx)
	cfg.set_value("player", "ip", _ip.text.strip_edges())
	cfg.save(SETTINGS)


func _host() -> void:
	_apply()
	set_status(Net.host())


func _join() -> void:
	_apply()
	var ip := _ip.text.strip_edges()
	if ip == "":
		set_status("Enter the host's IP address")
		return
	var err := Net.join(ip)
	if err != "":
		set_status(err)
	else:
		set_status("Connecting to %s…" % ip, UI.DIM)
