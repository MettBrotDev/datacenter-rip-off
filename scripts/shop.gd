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
	var card := UI.panel(26)
	card.custom_minimum_size.x = 680
	center.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	card.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	v.add_child(head)
	head.add_child(UI.chip("shopping_cart", UI.ACCENT, 46))
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", -2)
	titles.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(titles)
	titles.add_child(UI.bold("Parts market", 26))
	titles.add_child(UI.caption("Dropped off at the garage door. No refunds."))
	var cash := VBoxContainer.new()
	cash.add_theme_constant_override("separation", -2)
	head.add_child(cash)
	var cash_caption := UI.caption("BALANCE")
	cash_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cash.add_child(cash_caption)
	_balance = UI.big("", UI.GREEN, 26)
	_balance.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cash.add_child(_balance)
	v.add_child(UI.rule())

	var scroll := UI.scroll()
	scroll.custom_minimum_size.y = 520
	v.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	scroll.add_child(rows)
	for kind: String in Catalog.SHOP:
		var def: Dictionary = Catalog.ITEMS[kind]
		var row_panel := UI.inset(10)
		rows.add_child(row_panel)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row_panel.add_child(row)
		row.add_child(UI.chip(_icon_for(def), _color_for(def), 36))
		var text := VBoxContainer.new()
		text.size_flags_horizontal = SIZE_EXPAND_FILL
		text.add_theme_constant_override("separation", 0)
		row.add_child(text)
		text.add_child(UI.bold(def["label"], 17))
		text.add_child(UI.caption(_describe(def)))
		var buy := UI.btn("+  " + UI.money(def["price"]), "primary", 15)
		buy.custom_minimum_size.x = 130
		buy.pressed.connect(func(): world.request_buy(kind))
		row.add_child(buy)
		_buttons[kind] = buy

	var close := UI.btn("Close  [Esc]", "secondary")
	close.pressed.connect(func(): closed.emit())
	v.add_child(close)


func _icon_for(def: Dictionary) -> String:
	if def.has("gen"):
		return "bolt"
	if def.get("group", "") == "gpu":
		return "memory"
	if def.has("tokens"):
		return "dns"
	if def.has("sockets"):
		return "power"
	return "inventory_2"


func _color_for(def: Dictionary) -> Color:
	if def.has("gen"):
		return UI.AMBER
	if def.has("tokens"):
		return UI.PURPLE
	if def.has("sockets"):
		return UI.CYAN
	return UI.ACCENT


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
