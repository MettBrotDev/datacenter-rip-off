extends SubViewport
## The company dashboard, drawn once and shown on every ops screen in the world.
## The headline numbers are always there. Everything detailed (room temperatures, what a
## generator is carrying, how hot the coolant is) only appears if a sensor for it is installed.

const UI = preload("res://scripts/ui.gd")
const Catalog = preload("res://scripts/catalog.gd")
const Sim = preload("res://scripts/sim.gd")
const FLOW := 20.0              # litres per minute a running pump moves
const WATTS_PER_DEGREE := 1395.0   # heat that flow carries per degree of warming

var _values: Dictionary = {}    # tile name -> [value label, small label]
var _weather: Label
var _sensors: VBoxContainer
var _alerts: VBoxContainer
var _earners: VBoxContainer
var _footer: Label
var _log: Array[String] = []


func _ready() -> void:
	size = Vector2i(1280, 720)
	disable_3d = true
	render_target_update_mode = SubViewport.UPDATE_ONCE
	var bg := ColorRect.new()
	bg.color = Color(0.015, 0.03, 0.065)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	margin.add_child(v)

	var head := HBoxContainer.new()
	v.add_child(head)
	head.add_child(UI.chip("bolt", UI.ACCENT, 72))
	head.add_child(UI.bold("   RIP OFF ", 54))
	var ops := UI.bold("OPS", 54, UI.ACCENT)
	ops.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(ops)
	_weather = UI.label("", 28, UI.DIM)
	_weather.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_weather)
	var live := UI.label("   ● LIVE", 28, UI.RED)
	live.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(live)

	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override("separation", 14)
	v.add_child(tiles)
	for stat: String in ["TOKENS", "BALANCE", "POWER", "NET PROFIT"]:
		var tile := UI.panel(16)
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tiles.add_child(tile)
		var tv := VBoxContainer.new()
		tv.add_theme_constant_override("separation", 0)
		tile.add_child(tv)
		tv.add_child(UI.bold(stat, 24, UI.DIM))
		var value := UI.bold("-", 56)
		tv.add_child(value)
		var small := UI.label("", 24, UI.DIM)
		tv.add_child(small)
		_values[stat] = [value, small]

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(body)
	_sensors = _column(body, "SENSORS", 3.0)
	_earners = _column(body, "TOP EARNERS", 2.0)
	_alerts = _column(body, "WHAT JUST HAPPENED", 2.0)
	_footer = UI.label("", 20, UI.DIM)
	v.add_child(_footer)


## Something happened: newest first, the last five stay on the board.
func alert(text: String) -> void:
	_log.push_front(text)
	if _log.size() > 5:
		_log.pop_back()


func refresh(world: Node3D) -> void:
	var state: Dictionary = Catalog.WEATHER[world.weather]
	_weather.text = "%s, %d °C outside" % [state["name"], world.outside_temp]
	var stored: String = ""
	var earners: Array[String] = []
	if not world.co.is_empty():
		stored = "%s stored" % UI.num(world.co["tokens"])
		var live: Array = (world.co["live"] as Array).duplicate()
		live.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["peak"] * a["hype"] > b["peak"] * b["hype"])
		for item: Dictionary in live.slice(0, 4):
			earners.append("%s  %s/min" % [str(item["name"]).split(" (")[0], UI.money(float(item["peak"]) * float(item["hype"]))])
	_tile("TOKENS", "%.0f /s" % world.tokens, stored, UI.TEXT)
	_tile("BALANCE", UI.money(world.money), "", UI.GREEN if world.money >= 0.0 else UI.RED)
	var short: bool = world.watts > world.capacity or world.tripped
	_tile("POWER", "%d W" % world.watts, "of %d W available" % world.capacity, UI.RED if short else UI.TEXT)
	_tile("NET PROFIT", "+%s" % UI.money(world.profit * 60.0), "per minute", UI.GREEN)
	_fill(_sensors, readings(world), 30, UI.TEXT,
			"No sensors installed.\nBuy a thermometer, power meter or coolant sensor\nand what they measure shows up here.")
	_fill(_earners, earners, 24, UI.GREEN, "Nothing is live yet.")
	_fill(_alerts, _log, 24, UI.DIM, "Nothing yet. Suspicious.")
	var places: Array[String] = []
	for c: int in world.circuits():
		places.append(world.circuits()[c][1] + (" (BREAKER OFF)" if world.tripped_circuits.has(c) else ""))
	_footer.text = "Ours: " + ", ".join(places)
	render_target_update_mode = SubViewport.UPDATE_ONCE


## One line per installed sensor, saying what it measures right now.
static func readings(world: Node3D) -> Array[String]:
	var out: Array[String] = []
	var items: Dictionary = world.items
	var ids := items.keys()
	ids.sort()
	for id: int in ids:
		var it: Node3D = items[id]
		if not it.def.has("sensor") or it.holder != 0:
			continue
		match it.def["sensor"]:
			"room":
				var where: Array = world.circuits().get(world.circuit_at(it.global_position), ["outside"])
				out.append("Thermometer, %s: %d °C" % [where[-1], world.temp_at(it.global_position)])
			"power":
				var end := Sim.power_end(it, items, world)
				if end > 0:
					var gen: Node3D = items[end]
					var extra := "   fuel %d%%" % ceilf(gen.fuel * 100.0) if gen.def["gen"]["kind"] == "fuel" else ""
					out.append("Power meter, %s: %d of %d W%s%s" % [gen.label.to_lower(), gen.load, gen.def["gen"]["watts"],
						extra, "" if gen.status == 3 else "   NOT RUNNING"])
				elif end < 0 and world.circuits().has(-end - 1):
					var c := -end - 1
					out.append("Power meter, wiring of %s: %d of %d W" % [world.circuits()[c][1], world.wiring.get(c, 0.0), world.circuits()[c][0]])
				else:
					out.append("Power meter: not plugged into anything")
			"coolant":
				var pump: Node3D = items.get(Sim.pump_id(it, items))
				if pump == null:
					out.append("Coolant sensor: not on a loop")
					continue
				var flowing: bool = pump.status == 3
				var tank: Node3D = items.get(pump.coolant_to)
				var level := "no reservoir" if tank == null else ("reservoir on the tap" if tank.coolant_to < 0 else "reservoir %d%%" % ceilf(tank.fuel * 100.0))
				out.append("Coolant: %d °C out, %d °C back   %d l/min   carrying %d W   %s" % [pump.heat,
					pump.heat + pump.load / WATTS_PER_DEGREE, FLOW if flowing else 0.0, pump.load, level])
	return out


func _column(parent: Control, title: String, weight: float) -> VBoxContainer:
	var panel := UI.panel(16)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = weight
	parent.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	v.add_child(UI.bold(title, 24, UI.DIM))
	var lines := VBoxContainer.new()
	lines.add_theme_constant_override("separation", 4)
	v.add_child(lines)
	return lines


func _tile(stat: String, value: String, small: String, color: Color) -> void:
	_values[stat][0].text = value
	_values[stat][0].add_theme_color_override("font_color", color)
	_values[stat][1].text = small


func _fill(box: VBoxContainer, lines: Array, font: int, color: Color, empty: String) -> void:
	for child in box.get_children():
		child.queue_free()
	var shown: Array = lines.slice(0, 6) if not lines.is_empty() else [empty]
	for text: String in shown:
		var line := UI.label(text, font, color if not lines.is_empty() else UI.DIM)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(line)
