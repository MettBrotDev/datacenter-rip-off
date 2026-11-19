extends CanvasLayer
## In-game overlay: crosshair, interaction prompt, crew list, company stats, toasts,
## shop, pause menu and settings.

const UI = preload("res://scripts/ui.gd")
const Catalog = preload("res://scripts/catalog.gd")
const Shop = preload("res://scripts/shop.gd")
const Offer = preload("res://scripts/offer.gd")
const SETTINGS_MENU := "res://scripts/settings_menu.gd"

var _prompt: Label
var _list: VBoxContainer
var _values: Dictionary = {}    # stat name -> Label
var _toasts: VBoxContainer
var _pause: Control
var _shop: Control
var _heat: ColorRect
var _heat_text: Label
var _offer: Control
var _settings: Control


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
	_prompt = UI.label("", 19)
	_prompt.add_theme_constant_override("outline_size", 8)
	_prompt.add_theme_color_override("font_outline_color", UI.BG_DARK)
	_prompt.custom_minimum_size.y = 150
	_prompt.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	below.add_child(_prompt)

	# crew list, top left
	var crew := UI.panel()
	crew.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	crew.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	crew.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(crew)
	_list = VBoxContainer.new()
	crew.add_child(_list)

	# company stats + toasts, top right
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_SHRINK_END
	right.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_theme_constant_override("separation", 8)
	root.add_child(right)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	bar.add_theme_constant_override("separation", 8)
	right.add_child(bar)
	for stat: String in ["WEATHER", "HERE", "COMPUTE", "POWER", "NET PROFIT", "BALANCE"]:
		var tile := UI.panel(10)
		tile.custom_minimum_size.x = 96 if stat == "HERE" else 150
		bar.add_child(tile)
		var tv := VBoxContainer.new()
		tv.add_theme_constant_override("separation", 0)
		tile.add_child(tv)
		tv.add_child(UI.label(stat, 12, UI.DIM))
		_values[stat] = UI.label("-", 21)
		tv.add_child(_values[stat])
	_toasts = VBoxContainer.new()
	_toasts.alignment = BoxContainer.ALIGNMENT_END
	right.add_child(_toasts)

	# key hints, bottom right
	var hints := UI.panel(10)
	hints.size_flags_horizontal = Control.SIZE_SHRINK_END
	hints.size_flags_vertical = Control.SIZE_SHRINK_END
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hints)
	hints.add_child(UI.label("WASD Move   Shift Sprint   Space Jump   E Grab   Q Use   R Rotate   F Power   G Network   H Coolant   Esc Pause", 14, UI.DIM))

	_shop = Shop.new()
	_shop.world = get_parent()
	_shop.hide()
	_shop.closed.connect(_close_overlays)
	add_child(_shop)
	_offer = Offer.new()
	_offer.world = get_parent()
	_offer.hide()
	_offer.closed.connect(_close_overlays)
	add_child(_offer)
	_build_pause()


func set_prompt(text: String) -> void:
	_prompt.text = text


func set_players(players: Dictionary) -> void:
	for c in _list.get_children():
		c.queue_free()
	_list.add_child(UI.label("CREW %d/%d" % [players.size(), Net.MAX_PLAYERS], 12, UI.DIM))
	for id: int in players:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var color_bar := ColorRect.new()
		color_bar.color = players[id]["color"]
		color_bar.custom_minimum_size = Vector2(4, 20)
		row.add_child(color_bar)
		row.add_child(UI.label(players[id]["name"] + ("  (host)" if id == 1 else ""), 17))
		_list.add_child(row)


## capacity = watts available right now (grid + running generators); profit is $ per second.
func set_stats(money: float, tokens: float, watts: float, capacity: float, profit: float, tripped: bool) -> void:
	profit *= 60.0
	_values["COMPUTE"].text = "%.0f tok/s" % tokens
	_values["POWER"].text = "%d / %d W" % [watts, capacity]
	_values["POWER"].add_theme_color_override("font_color",
			UI.RED if tripped or watts > capacity else UI.TEXT)
	_values["NET PROFIT"].text = ("+" if profit >= 0.0 else "-") + UI.money(absf(profit)) + "/min"
	_values["NET PROFIT"].add_theme_color_override("font_color", UI.GREEN if profit >= 0.0 else UI.RED)
	_values["BALANCE"].text = UI.money(money)
	_values["BALANCE"].add_theme_color_override("font_color", UI.GREEN if money >= 0.0 else UI.RED)
	_shop.set_money(money)
	_offer.refresh()


## Temperature where the local player is standing.
func set_temp(degrees: float) -> void:
	_values["HERE"].text = "%d °C" % degrees
	_values["HERE"].add_theme_color_override("font_color",
			UI.RED if degrees >= 50.0 else (Color(1.0, 0.65, 0.2) if degrees >= 40.0 else UI.TEXT))


## 0..1: how close the local player is to passing out from the heat.
func set_exposure(amount: float) -> void:
	if _heat == null:
		_heat = ColorRect.new()
		_heat.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_heat.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_heat)
		move_child(_heat, 0)
		_heat_text = UI.label("", 22, Color(1.0, 0.8, 0.6))
		_heat_text.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		_heat_text.position.y = 120
		_heat_text.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_heat_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(_heat_text)
	_heat.color = Color(1.0, 0.25, 0.05, amount * 0.4)
	_heat_text.text = "" if amount < 0.3 else ("You are overheating. Get out." if amount < 0.75 else "You are about to pass out!")


func set_weather(index: int) -> void:
	var state: Dictionary = Catalog.WEATHER[index]
	_values["WEATHER"].text = state["name"]
	_values["WEATHER"].add_theme_color_override("font_color", UI.TEXT if state["solar"] > 0.0 else UI.DIM)


func toast(text: String) -> void:
	var p := UI.panel(10)
	p.size_flags_horizontal = Control.SIZE_SHRINK_END
	p.add_child(UI.label(text, 16))
	_toasts.add_child(p)
	if _toasts.get_child_count() > 5:
		_toasts.get_child(0).queue_free()
	p.create_tween().tween_callback(p.queue_free).set_delay(6.0)   # the tween dies with the panel


func open_offer(house_id: int) -> void:
	_offer.open(house_id)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func offer_reply(house_id: int, text: String, accepted: bool) -> void:
	_offer.reply(house_id, text, accepted)


func open_shop() -> void:
	_shop.show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _build_pause() -> void:
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
	resume.pressed.connect(_close_overlays)
	v.add_child(resume)
	if ResourceLoader.exists(SETTINGS_MENU):
		_settings = load(SETTINGS_MENU).new()
		_settings.hide()
		_settings.closed.connect(func(): _pause.show())
		add_child(_settings)
		var settings := UI.button("Settings")
		settings.pressed.connect(func(): _pause.hide(); _settings.show())
		v.add_child(settings)
	var leave := UI.button("Leave game")
	leave.pressed.connect(func(): Net.leave())
	v.add_child(leave)
	var quit := UI.button("Quit to desktop")
	quit.pressed.connect(func(): get_tree().quit())
	v.add_child(quit)


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel") and not Net.test_mode:
		if _shop.visible or _offer.visible or _pause.visible:
			_close_overlays()
		else:
			_pause.show()
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()


func _close_overlays() -> void:
	_shop.hide()
	_offer.hide()
	_pause.hide()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
