extends Control
## The parts shop overlay (opened from the laptop on the workbench).

const UI = preload("res://scripts/ui.gd")
const Catalog = preload("res://scripts/catalog.gd")

signal closed

var world: Node3D

var _balance: Label
var _buttons: Dictionary = {}   # kind -> Button


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.01, 0.02, 0.05, 0.6)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)
	var card := UI.panel(24)
	card.custom_minimum_size.x = 640
	center.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	card.add_child(v)

	var head := HBoxContainer.new()
	v.add_child(head)
	var title := UI.label("PARTS MARKET", 28)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(title)
	_balance = UI.label("", 24, UI.GREEN)
	head.add_child(_balance)
	v.add_child(UI.label("Dropped off at the garage door. No refunds.", 14, UI.DIM))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 520
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	scroll.add_child(rows)
	for kind: String in Catalog.SHOP:
		var def: Dictionary = Catalog.ITEMS[kind]
		var row_panel := PanelContainer.new()
		row_panel.add_theme_stylebox_override("panel", UI.box(UI.BG_DARK, 8, UI.BORDER, 10))
		rows.add_child(row_panel)
		var row := HBoxContainer.new()
		row_panel.add_child(row)
		var text := VBoxContainer.new()
		text.size_flags_horizontal = SIZE_EXPAND_FILL
		text.add_theme_constant_override("separation", 0)
		row.add_child(text)
		text.add_child(UI.label(def["label"], 19))
		text.add_child(UI.label(_describe(def), 14, UI.DIM))
		var buy := UI.button("+  " + UI.money(def["price"]), true)
		buy.custom_minimum_size.x = 130
		buy.pressed.connect(func(): world.request_buy(kind))
		row.add_child(buy)
		_buttons[kind] = buy

	var close := UI.button("Close  [Esc]")
	close.pressed.connect(func(): closed.emit())
	v.add_child(close)


func set_money(money: float) -> void:
	_balance.text = UI.money(money)
	for kind: String in _buttons:
		_buttons[kind].disabled = Catalog.ITEMS[kind]["price"] > money


func _describe(def: Dictionary) -> String:
	var bits: Array[String] = []
	if def.has("gen"):
		var gen: Dictionary = def["gen"]
		bits.append("makes %d W" % gen["watts"])
		bits.append({"pedal": "someone has to pedal", "solar": "outdoors only, free power",
			"fuel": "%d min per jerry can at full load" % (gen.get("burn", 0.0) / 60.0)}[gen["kind"]])
	if def.has("tokens"):
		bits.append("%s tokens/s" % def["tokens"])
	if def.has("watts"):
		bits.append("%d W" % def["watts"])
	if def.has("sockets"):
		bits.append("%d %s sockets" % [def["sockets"], "power" if def["provides"] == "power" else "network"])
	if def.has("slots"):
		bits.append("holds %d %ss" % [def["slots"]["at"].size(), def["slots"]["accepts"]])
	if def.get("group", "") == "gpu":
		bits.append("mounts on a server")
	return " · ".join(bits) if not bits.is_empty() else "It's a box."
