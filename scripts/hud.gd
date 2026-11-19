extends CanvasLayer
## In-game overlay: crosshair, interaction prompt, player list, key hints, pause menu.

const UI = preload("res://scripts/ui.gd")

var _prompt: Label
var _list: VBoxContainer
var _pause: Control


func _ready() -> void:
	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		root.add_theme_constant_override("margin_" + side, 20)
	add_child(root)

	# crosshair + prompt
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(6, 6)
	dot.add_theme_stylebox_override("panel", UI.box(Color(1, 1, 1, 0.85), 3, Color(0, 0, 0, 0.5), 0))
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(dot)
	var below := CenterContainer.new()
	below.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(below)
	_prompt = UI.label("", 20)
	_prompt.add_theme_constant_override("outline_size", 8)
	_prompt.add_theme_color_override("font_outline_color", UI.BG_DARK)
	_prompt.custom_minimum_size.y = 130
	_prompt.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	below.add_child(_prompt)

	# player list, top left
	var players := UI.panel()
	players.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	players.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	players.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(players)
	_list = VBoxContainer.new()
	players.add_child(_list)

	# key hints, bottom right
	var hints := UI.panel(10)
	hints.size_flags_horizontal = Control.SIZE_SHRINK_END
	hints.size_flags_vertical = Control.SIZE_SHRINK_END
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hints)
	hints.add_child(UI.label("WASD Move   Shift Sprint   Space Jump   E Use   Esc Pause", 15, UI.DIM))

	# pause menu
	_pause = ColorRect.new()
	_pause.color = Color(0.01, 0.02, 0.05, 0.6)
	_pause.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pause.hide()
	add_child(_pause)
	var pc := CenterContainer.new()
	pc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pause.add_child(pc)
	var card := UI.panel(24)
	card.custom_minimum_size.x = 300
	pc.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	card.add_child(v)
	v.add_child(UI.label("PAUSED", 28))
	v.add_child(UI.label("The datacenter keeps running.", 14, UI.DIM))
	var resume := UI.button("Resume", true)
	resume.pressed.connect(_set_paused.bind(false))
	v.add_child(resume)
	var leave := UI.button("Leave game")
	leave.pressed.connect(func(): Net.leave())
	v.add_child(leave)
	var quit := UI.button("Quit to desktop")
	quit.pressed.connect(func(): get_tree().quit())
	v.add_child(quit)


func set_prompt(text: String) -> void:
	_prompt.text = text


func set_players(players: Dictionary) -> void:
	for c in _list.get_children():
		c.queue_free()
	_list.add_child(UI.label("CREW %d/%d" % [players.size(), Net.MAX_PLAYERS], 13, UI.DIM))
	for id: int in players:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var bar := ColorRect.new()
		bar.color = players[id]["color"]
		bar.custom_minimum_size = Vector2(4, 20)
		row.add_child(bar)
		row.add_child(UI.label(players[id]["name"] + ("  (host)" if id == 1 else ""), 17))
		_list.add_child(row)


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		_set_paused(not _pause.visible)


func _set_paused(on: bool) -> void:
	_pause.visible = on
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if on else Input.MOUSE_MODE_CAPTURED
