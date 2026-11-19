extends Control
## The parts market (opened from the laptop on the workbench): categories down the left, the
## parts of that category as cards in the middle, and on the right everything about the
## selected part with a quantity and a Buy button.

const UI = preload("res://scripts/ui.gd")
const Catalog = preload("res://scripts/catalog.gd")
const COLORS := {"purple": UI.PURPLE, "amber": UI.AMBER, "cyan": UI.CYAN, "blue": UI.ACCENT, "green": UI.GREEN, "grey": UI.DIM}

const NAMES := {"gpu": "GPU", "server": "server"}

signal closed

var world: Node3D

var _money := 0.0
var _category := "all"
var _selected := ""
var _count := 1
var _balance: Label
var _grid: GridContainer
var _heading: Label
var _cards: Dictionary = {}       # kind -> {"panel": PanelContainer, "price": Label}
var _order: Array = []            # every part, shelf by shelf, cheapest first
var _detail: VBoxContainer        # rebuilt whenever another part is selected
var _count_label: Label
var _total: Label
var _buy: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.01, 0.02, 0.05, 0.65)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)
	var card := UI.panel(24)
	card.custom_minimum_size = Vector2(1320, 790)
	center.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	card.add_child(v)

	# header: title, balance, close
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	v.add_child(head)
	head.add_child(UI.chip("shopping_cart", UI.ACCENT, 48))
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", -2)
	titles.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(titles)
	titles.add_child(UI.bold("Parts market", 28))
	titles.add_child(UI.caption("Everything arrives as a parcel on the driveway. Unpack it before it rains. No refunds."))
	var cash := VBoxContainer.new()
	cash.add_theme_constant_override("separation", -2)
	head.add_child(cash)
	var cash_caption := UI.caption("BALANCE")
	cash_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cash.add_child(cash_caption)
	_balance = UI.big("", UI.GREEN, 28)
	_balance.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cash.add_child(_balance)
	var close := UI.btn(UI.ic("close") + "  Close", "secondary")
	close.size_flags_vertical = SIZE_SHRINK_CENTER
	close.pressed.connect(func(): closed.emit())
	head.add_child(close)
	v.add_child(UI.rule())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 16)
	body.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(body)

	# left: categories
	var side := VBoxContainer.new()
	side.custom_minimum_size.x = 232
	side.add_theme_constant_override("separation", 6)
	body.add_child(side)
	side.add_child(UI.caption("CATEGORIES"))
	var group := ButtonGroup.new()
	var everything := {"key": "all", "name": "Everything", "icon": "apps"}
	for cat: Dictionary in [everything] + Catalog.CATEGORIES:
		var count := 0
		for kind: String in Catalog.SHOP:
			if cat["key"] == "all" or Catalog.SHOP_INFO[kind][0] == cat["key"]:
				count += 1
		var b := UI.choice_button("%s   %s   (%d)" % [UI.ic(cat["icon"]), cat["name"], count], group)
		b.custom_minimum_size.y = 46
		b.button_pressed = cat["key"] == _category
		b.pressed.connect(_show_category.bind(cat["key"], cat["name"]))
		side.add_child(b)
	var spacer := Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	side.add_child(spacer)
	var note := UI.wrap(UI.caption("Used parts are cheap for a reason. Electronics hate rain. Things with no fans need water."))
	side.add_child(note)

	# middle: the parts
	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", 8)
	body.add_child(middle)
	_heading = UI.bold("Everything", 20)
	middle.add_child(_heading)
	var scroll := UI.scroll()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	middle.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_grid)
	for cat: Dictionary in Catalog.CATEGORIES:   # shelf by shelf, cheapest first
		var shelf: Array = Catalog.SHOP.filter(func(kind: String) -> bool: return Catalog.SHOP_INFO[kind][0] == cat["key"])
		shelf.sort_custom(func(a: String, b: String) -> bool: return Catalog.ITEMS[a]["price"] < Catalog.ITEMS[b]["price"])
		_order.append_array(shelf)
	for kind: String in _order:
		_grid.add_child(_part_card(kind))

	# right: the selected part
	var detail_panel := UI.inset(18, 12)
	detail_panel.custom_minimum_size.x = 360
	body.add_child(detail_panel)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 10)
	detail_panel.add_child(_detail)
	_select(_order[0])


func set_money(money: float) -> void:
	_money = money
	_balance.text = UI.money(money)
	for kind: String in _cards:
		var affordable: bool = Catalog.ITEMS[kind]["price"] <= money
		_cards[kind]["price"].add_theme_color_override("font_color", UI.GREEN if affordable else UI.RED)
	_refresh_buy()


# --- building blocks ----------------------------------------------------------------------

func _part_card(kind: String) -> PanelContainer:
	var def: Dictionary = Catalog.ITEMS[kind]
	var cat := _cat(kind)
	var panel := UI.inset(12, 11)
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.custom_minimum_size.y = 118
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	v.add_child(top)
	top.add_child(UI.chip(cat["icon"], COLORS[cat["color"]], 38))
	var name_label := UI.wrap(UI.bold(def["label"], 16))
	name_label.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(name_label)
	var gist := UI.wrap(UI.caption(_gist(def)))
	gist.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(gist)
	var price := UI.big(UI.money(def["price"]), UI.GREEN, 20)
	v.add_child(price)
	UI.click_card(panel, _select.bind(kind))
	_cards[kind] = {"panel": panel, "price": price}
	return panel


func _show_category(key: String, title: String) -> void:
	_category = key
	_heading.text = title
	var first := ""
	for kind: String in _order:
		var shown: bool = key == "all" or Catalog.SHOP_INFO[kind][0] == key
		_cards[kind]["panel"].visible = shown
		if shown and first == "":
			first = kind
	if not _cards[_selected]["panel"].visible and first != "":
		_select(first)


func _select(kind: String) -> void:
	if _selected != "":
		_cards[_selected]["panel"].add_theme_stylebox_override("panel", UI.box(UI.BG_DARK, 11, UI.BORDER, 12))
	_selected = kind
	_count = 1
	_cards[kind]["panel"].add_theme_stylebox_override("panel",
			UI.box(Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.16), 11, UI.ACCENT, 12))
	for child in _detail.get_children():
		child.queue_free()
	var def: Dictionary = Catalog.ITEMS[kind]
	var cat := _cat(kind)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	_detail.add_child(head)
	head.add_child(UI.chip(cat["icon"], COLORS[cat["color"]], 52))
	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", 0)
	names.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(names)
	names.add_child(UI.wrap(UI.bold(def["label"], 22)))
	names.add_child(UI.caption(cat["name"].to_upper()))
	_detail.add_child(UI.wrap(UI.label(Catalog.SHOP_INFO[kind][1], 15, UI.DIM)))
	_detail.add_child(UI.rule())

	for row: Array in _facts(def):
		var line := HBoxContainer.new()
		var key := UI.label(row[0], 15, UI.DIM)
		key.size_flags_horizontal = SIZE_EXPAND_FILL
		line.add_child(key)
		line.add_child(UI.bold(row[1], 15))
		_detail.add_child(line)
	var warnings := _warnings(def)
	if not warnings.is_empty():
		var pills := HFlowContainer.new()
		pills.add_theme_constant_override("h_separation", 6)
		pills.add_theme_constant_override("v_separation", 6)
		_detail.add_child(pills)
		for warning: Array in warnings:
			pills.add_child(UI.pill(warning[0], warning[1]))

	var spacer := Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	_detail.add_child(spacer)
	_detail.add_child(UI.rule())

	# quantity and buy
	var qty := HBoxContainer.new()
	qty.add_theme_constant_override("separation", 8)
	_detail.add_child(qty)
	var how_many := UI.label("How many", 15, UI.DIM)
	how_many.size_flags_horizontal = SIZE_EXPAND_FILL
	qty.add_child(how_many)
	var less := UI.btn("-", "secondary", 20)
	less.custom_minimum_size.x = 42
	less.pressed.connect(_change_count.bind(-1))
	qty.add_child(less)
	_count_label = UI.bold("1", 20)
	_count_label.custom_minimum_size.x = 36
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qty.add_child(_count_label)
	var more := UI.btn("+", "secondary", 20)
	more.custom_minimum_size.x = 42
	more.pressed.connect(_change_count.bind(1))
	qty.add_child(more)
	var sum := HBoxContainer.new()
	_detail.add_child(sum)
	var total_caption := UI.label("Total", 15, UI.DIM)
	total_caption.size_flags_horizontal = SIZE_EXPAND_FILL
	sum.add_child(total_caption)
	_total = UI.big("", UI.GREEN, 26)
	sum.add_child(_total)
	_buy = UI.btn("", "primary", 17)
	_buy.custom_minimum_size.y = 50
	_buy.pressed.connect(_purchase)
	_detail.add_child(_buy)
	_refresh_buy()


func _change_count(by: int) -> void:
	_count = clampi(_count + by, 1, 10)
	_refresh_buy()


func _refresh_buy() -> void:
	if _buy == null or _selected == "":
		return
	var total: float = Catalog.ITEMS[_selected]["price"] * _count
	_count_label.text = str(_count)
	_total.text = UI.money(total)
	_total.add_theme_color_override("font_color", UI.GREEN if total <= _money else UI.RED)
	_buy.disabled = total > _money
	_buy.text = "%s  Buy %s" % [UI.ic("shopping_cart"), "it" if _count == 1 else "%d of them" % _count] \
			if total <= _money else "You are %s short" % UI.money(total - _money)


func _purchase() -> void:
	for i in _count:
		world.request_buy(_selected)
	_count = 1
	_refresh_buy()


# --- what to say about a part ---------------------------------------------------------------

func _cat(kind: String) -> Dictionary:
	for cat: Dictionary in Catalog.CATEGORIES:
		if cat["key"] == Catalog.SHOP_INFO[kind][0]:
			return cat
	return Catalog.CATEGORIES[-1]


## The one line under a part's name on its card: the number that matters most.
func _gist(def: Dictionary) -> String:
	if def.has("gen"):
		return "Makes %s W" % UI.num(def["gen"]["watts"])
	if def.has("tokens"):
		return "%d tokens/s  ·  %d W" % [def["tokens"], def.get("watts", 0.0)]
	if def.has("radiator"):
		return "Sheds %d W per degree" % def["radiator"]
	if def.has("cool"):
		return "Cools the room  ·  %d W" % def["watts"]
	if def.has("sockets"):
		return "%d %s sockets" % [def["sockets"], {"power": "power", "net": "network", "coolant": "hose"}[def["provides"]]]
	if def.has("slots"):
		return "Holds %d %ss" % [def["slots"]["at"].size(), NAMES[def["slots"]["accepts"]]]
	if def.has("sensor"):
		return {"room": "Shows a room's temperature", "power": "Shows a power source's load", "coolant": "Shows a coolant loop"}[def["sensor"]]
	if def.has("watts"):
		return "Uses %d W" % def["watts"]
	return ""


## Label and value rows for the detail panel.
func _facts(def: Dictionary) -> Array:
	var rows := []
	if def.has("tokens"):
		rows.append(["Makes", "%d tokens a second" % def["tokens"]])
	if def.has("gen"):
		var gen: Dictionary = def["gen"]
		rows.append(["Generates", "%s W" % UI.num(gen["watts"])])
		rows.append(["Runs on", {"pedal": "someone pedalling", "solar": "sunshine", "fuel": "jerry cans"}[gen["kind"]]])
		if gen.has("burn"):
			rows.append(["One tank lasts", "%d min at full load" % (gen["burn"] / 60.0)])
	if def.has("watts"):
		rows.append(["Power draw", "%d W" % def["watts"]])
	if def.has("max_watts"):
		rows.append(["Rated for", "%s W" % UI.num(def["max_watts"])])
	if def.has("sockets"):
		rows.append(["Sockets", "%d (%s)" % [def["sockets"], {"power": "power", "net": "network", "coolant": "coolant hose"}[def["provides"]]]])
	if def.has("slots"):
		rows.append(["Holds", "%d %ss" % [def["slots"]["at"].size(), NAMES[def["slots"]["accepts"]]]])
	if def.get("group", "") == "gpu":
		rows.append(["Goes on", "a server (two per server)"])
	if def.has("radiator"):
		rows.append(["Sheds", "%d W per degree above the air" % def["radiator"]])
	if def.has("cool"):
		var cool: Dictionary = def["cool"]
		rows.append(["Cooling", "removes %s W" % UI.num(cool["remove"]) if cool.has("remove") else "vents %d W per degree" % cool["vent"]])
	if def.get("power_port", false) or def.get("net_port", false) or def.get("coolant_port", false):
		var cables: Array[String] = []
		for port: Array in [["power_port", "power"], ["net_port", "network"], ["coolant_port", "coolant"]]:
			if def.get(port[0], false):
				cables.append(port[1])
		rows.append(["Its own cables", ", ".join(cables)])
	rows.append(["Weight", ("%.1f kg" if def["mass"] < 10.0 else "%d kg") % def["mass"]])
	return rows


## Coloured badges: the things you will wish you had read.
func _warnings(def: Dictionary) -> Array:
	var out := []
	if def.get("used", false):
		out.append(["Used: 1 in 8 is dead on arrival", UI.AMBER])
	if def.get("liquid", false):
		out.append(["No fans: needs a coolant loop", UI.CYAN])
	if def.get("fragile", false):
		out.append(["Ruined by rain and puddles", UI.RED])
	if def.get("gen", {}).get("kind", "") == "solar":
		out.append(["Outdoors only, weather permitting", UI.AMBER])
	if def.has("max_watts"):
		out.append(["Catches fire if overloaded", UI.RED])
	if def.has("radiator"):
		out.append(["Put it outdoors", UI.CYAN])
	if def.get("wall", false):
		out.append(["Can go on a wall", UI.ACCENT])
	if def.get("solid", false):
		out.append(["Big: blocks the way", UI.DIM])
	if def.get("feeds", false) or def.get("bus", false):
		out.append(["Only works inside a building you own", UI.ACCENT])
	return out
