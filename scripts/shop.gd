extends Control
## The parts market (opened from the laptop on the workbench): categories down the left, the
## parts of that category as cards in the middle, and on the right everything about the
## selected part with a quantity and a Buy button.

const UI = preload("res://scripts/ui.gd")
const Catalog = preload("res://scripts/catalog.gd")
const UsedMarket = preload("res://scripts/used_market.gd")
const COLORS := {"purple": UI.PURPLE, "amber": UI.AMBER, "cyan": UI.CYAN, "blue": UI.ACCENT, "green": UI.GREEN, "grey": UI.DIM}


signal closed

var world: Node3D

var _money := 0.0
var _category := "all"
var _selected := ""
var _count := 1
var _balance: Label
var _shelves: VBoxContainer       # one block (heading + grid of cards) per category / sub-category
var _blocks: Array = []           # {"cat", "sub", "box", "head", "kinds"}
var _subbar: HFlowContainer       # the sub-category pills under the heading
var _sub: Dictionary = {}         # category key -> the sub-category chosen there ("all" = everything)
var _cat_buttons: Dictionary = {}
var _heading: Label
var _cards: Dictionary = {}       # kind -> {"panel": PanelContainer, "price": Label}
var _order: Array = []            # every part, shelf by shelf, sub-category by sub-category, by tier then price
var _detail: VBoxContainer        # rebuilt whenever another part is selected
var _count_label: Label
var _total: Label
var _buy: Button
var _mode := "new"                # "new" or "used"
var _mode_buttons: Dictionary = {}
var _new_body: HBoxContainer
var _used_body: HBoxContainer
var _staple_grid: GridContainer
var _offer_grid: GridContainer
var _offer_note: Label
var _used_cards: Dictionary = {}  # "s:kind" or "l:id" -> {"panel", "price", "left"}
var _used_ids: Array = []         # the listing ids the offer grid was built for
var _used_sel := ""
var _used_sel_price := -1
var _used_detail: VBoxContainer
var _used_buy: Button
var _used_haggle: Button
var _used_left: Label


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
	var modes := HBoxContainer.new()   # New / Second-hand
	modes.add_theme_constant_override("separation", 6)
	modes.size_flags_vertical = SIZE_SHRINK_CENTER
	head.add_child(modes)
	var mode_group := ButtonGroup.new()
	for mode: Array in [["new", "New", "inventory_2"], ["used", "Second-hand", "recycling"]]:
		var mb := UI.choice_button("%s  %s" % [UI.ic(mode[2]), mode[1]], mode_group)
		mb.custom_minimum_size = Vector2(170, 44)
		mb.button_pressed = mode[0] == _mode
		mb.pressed.connect(set_mode.bind(mode[0]))
		modes.add_child(mb)
		_mode_buttons[mode[0]] = mb
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
	_new_body = body
	body.add_theme_constant_override("separation", 16)
	body.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(body)
	_build_used(v)

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
		_cat_buttons[cat["key"]] = b
		side.add_child(b)
	var spacer := Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	side.add_child(spacer)
	var note := UI.wrap(UI.caption("Everything here is new. For cheaper and riskier, try the second-hand market. Electronics hate rain. Things with no fans need water."))
	side.add_child(note)

	# middle: the parts
	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", 8)
	body.add_child(middle)
	_heading = UI.bold("Everything", 20)
	middle.add_child(_heading)
	_subbar = HFlowContainer.new()
	_subbar.add_theme_constant_override("h_separation", 6)
	_subbar.add_theme_constant_override("v_separation", 6)
	_subbar.visible = false
	middle.add_child(_subbar)
	var scroll := UI.scroll()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	middle.add_child(scroll)
	_shelves = VBoxContainer.new()
	_shelves.size_flags_horizontal = SIZE_EXPAND_FILL
	_shelves.add_theme_constant_override("separation", 12)
	scroll.add_child(_shelves)
	for cat: Dictionary in Catalog.CATEGORIES:   # shelf by shelf, then sub-category by sub-category
		var subs: Array = cat.get("subs", [{"key": "", "name": ""}])
		for sub: Dictionary in subs:
			var kinds: Array = Catalog.SHOP.filter(func(kind: String) -> bool: return _belongs(kind, cat["key"], sub["key"]))
			if kinds.is_empty():
				continue
			kinds.sort_custom(_cheaper_first)
			var box := VBoxContainer.new()
			box.add_theme_constant_override("separation", 6)
			_shelves.add_child(box)
			var sub_head := UI.caption("", COLORS[cat["color"]])
			sub_head.text = "%s   %s" % [UI.ic(cat["icon"]), sub["name"].to_upper()]
			box.add_child(sub_head)
			var grid := GridContainer.new()
			grid.columns = 3
			grid.size_flags_horizontal = SIZE_EXPAND_FILL
			grid.add_theme_constant_override("h_separation", 10)
			grid.add_theme_constant_override("v_separation", 10)
			box.add_child(grid)
			for kind: String in kinds:
				grid.add_child(_part_card(kind))
			_order.append_array(kinds)
			_blocks.append({"cat": cat["key"], "sub": sub["key"], "box": box, "head": sub_head, "kinds": kinds})

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
	if _mode == "used":
		_sync_used()


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


## Does this part sit in this category and sub-category ("" = any / the category has none)?
func _belongs(kind: String, cat: String, sub: String) -> bool:
	var info: Array = Catalog.SHOP_INFO[kind]
	return info[0] == cat and (sub == "" or (info.size() > 2 and info[2] == sub))


## Tier first (machines count by the tier they take), then price.
func _cheaper_first(a: String, b: String) -> bool:
	var da: Dictionary = Catalog.ITEMS[a]
	var db: Dictionary = Catalog.ITEMS[b]
	var ta: int = da.get("tier", da.get("max_tier", 0))
	var tb: int = db.get("tier", db.get("max_tier", 0))
	if ta != tb:
		return ta < tb
	return da["price"] < db["price"]


## Opens the market on a category and sub-category, e.g. "compute/gpu" (for tests and shortcuts).
func open_to(path: String) -> void:
	var bits := path.split("/")
	set_mode("new")
	var key: String = bits[0] if bits[0] != "" else "all"
	if bits.size() > 1:
		_sub[key] = bits[1]
	if _cat_buttons.has(key):
		_cat_buttons[key].button_pressed = true
		_show_category(key, "Everything" if key == "all" else _cat_named(key)["name"])


func _cat_named(key: String) -> Dictionary:
	for cat: Dictionary in Catalog.CATEGORIES:
		if cat["key"] == key:
			return cat
	return Catalog.CATEGORIES[0]


func _show_category(key: String, title: String) -> void:
	_category = key
	_heading.text = title
	_rebuild_subbar()
	_apply_filter()


func _choose_sub(sub: String) -> void:
	_sub[_category] = sub
	_apply_filter()


## The pill row under the heading: "All" and each sub-category with its count, for categories that have them.
func _rebuild_subbar() -> void:
	for child in _subbar.get_children():
		child.queue_free()
	var subs: Array = _cat_named(_category).get("subs", []) if _category != "all" else []
	_subbar.visible = not subs.is_empty()
	if subs.is_empty():
		return
	var group := ButtonGroup.new()
	var chosen: String = _sub.get(_category, "all")
	var total := 0
	var entries: Array = []
	for sub: Dictionary in subs:
		var n := Catalog.SHOP.filter(func(kind: String) -> bool: return _belongs(kind, _category, sub["key"])).size()
		total += n
		entries.append([sub["key"], "%s  (%d)" % [sub["name"], n]])
	entries.push_front(["all", "All  (%d)" % total])
	for entry: Array in entries:
		var b := UI.choice_button(entry[1], group)
		b.custom_minimum_size.y = 36
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.button_pressed = entry[0] == chosen
		b.pressed.connect(_choose_sub.bind(entry[0]))
		_subbar.add_child(b)


## Shows the cards of the chosen category and sub-category, grouped under their sub-category headings.
func _apply_filter() -> void:
	var chosen: String = _sub.get(_category, "all")
	var first := ""
	var has_subs: bool = _category != "all" and _cat_named(_category).has("subs")
	for block: Dictionary in _blocks:
		var in_cat: bool = _category == "all" or block["cat"] == _category
		var in_sub: bool = not has_subs or chosen == "all" or block["sub"] == chosen
		block["box"].visible = in_cat and in_sub
		block["head"].visible = block["sub"] != "" and not (has_subs and chosen != "all")
		for kind: String in block["kinds"]:
			_cards[kind]["panel"].visible = in_cat and in_sub
			if in_cat and in_sub and first == "":
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
	_detail_part(_detail, kind, Catalog.SHOP_INFO[kind][1], [])

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


## Name, blurb, facts and warning pills of a part, into `box`. `extra` = more pills [[text, colour]].
func _detail_part(box: VBoxContainer, kind: String, blurb: String, extra: Array) -> void:
	var def: Dictionary = Catalog.ITEMS[kind]
	var cat := _cat(kind)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	box.add_child(head)
	head.add_child(UI.chip(cat["icon"], COLORS[cat["color"]], 52))
	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", 0)
	names.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(names)
	names.add_child(UI.wrap(UI.bold(def["label"], 22)))
	names.add_child(UI.caption(cat["name"].to_upper()))
	box.add_child(UI.wrap(UI.label(blurb, 15, UI.DIM)))
	box.add_child(UI.rule())
	for row: Array in _facts(def):
		var line := HBoxContainer.new()
		var key := UI.label(row[0], 15, UI.DIM)
		key.size_flags_horizontal = SIZE_EXPAND_FILL
		line.add_child(key)
		line.add_child(UI.bold(row[1], 15))
		box.add_child(line)
	var warnings := _warnings(def) + extra
	if not warnings.is_empty():
		var pills := HFlowContainer.new()
		pills.add_theme_constant_override("h_separation", 6)
		pills.add_theme_constant_override("v_separation", 6)
		box.add_child(pills)
		for warning: Array in warnings:
			pills.add_child(UI.pill(warning[0], warning[1]))


# --- the second-hand market -------------------------------------------------------------------

func set_mode(mode: String) -> void:
	_mode = mode
	_new_body.visible = mode == "new"
	_used_body.visible = mode == "used"
	if _mode_buttons.has(mode):
		_mode_buttons[mode].button_pressed = true
	if mode == "used":
		_sync_used()


func _build_used(parent: VBoxContainer) -> void:
	_used_body = HBoxContainer.new()
	_used_body.add_theme_constant_override("separation", 16)
	_used_body.size_flags_vertical = SIZE_EXPAND_FILL
	_used_body.visible = false
	parent.add_child(_used_body)
	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", 8)
	_used_body.add_child(middle)
	var scroll := UI.scroll()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	middle.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)
	column.add_child(UI.section("Always in stock", "Same cheap beginner parts, same odds: 1 in 8 is dead on arrival.", "inventory", UI.ACCENT))
	_staple_grid = _used_grid()
	column.add_child(_staple_grid)
	for kind: String in UsedMarket.STAPLES:
		_staple_grid.add_child(_used_card("s:" + kind, kind))
	column.add_child(UI.section("Offers from the neighbourhood", "They come and go. Nobody has checked the photos.", "storefront", UI.AMBER))
	_offer_grid = _used_grid()
	column.add_child(_offer_grid)
	_offer_note = UI.wrap(UI.caption("No offers right now. Check back in a minute."))
	column.add_child(_offer_note)
	var panel := UI.inset(18, 12)
	panel.custom_minimum_size.x = 360
	_used_body.add_child(panel)
	_used_detail = VBoxContainer.new()
	_used_detail.add_theme_constant_override("separation", 10)
	panel.add_child(_used_detail)
	_select_used("s:" + UsedMarket.STAPLES[0])


func _used_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	return grid


## "Ryzer 5, 2x 16 GB stick, 2x RTX 4070" for the parts a rig is advertised with.
func _parts_line(parts: Array) -> String:
	var counts := {}
	for part: String in parts:
		counts[part] = counts.get(part, 0) + 1
	var bits: Array[String] = []
	for part: String in counts:
		var label: String = str(Catalog.ITEMS[part]["label"]).replace(" (used)", "")
		bits.append(label if counts[part] == 1 else "%dx %s" % [counts[part], label])
	return ", ".join(bits)


## What is behind a card key: {"kind", "price", "was", "seller", "text", "left" (-1 = always)} or {}.
func _used_entry(key: String) -> Dictionary:
	var kind := key.substr(2)
	if key.begins_with("s:"):
		return {"kind": kind, "price": Catalog.ITEMS[kind]["price"], "was": 0, "seller": UsedMarket.STAPLE_SELLER,
			"text": Catalog.SHOP_INFO[kind][1], "left": -1.0, "haggled": true, "staple": true}
	if world == null:
		return {}
	for l: Dictionary in world.used.get("listings", []):
		if str(l["id"]) == kind:
			return l
	return {}


func _used_card(key: String, kind: String) -> PanelContainer:
	var def: Dictionary = Catalog.ITEMS[kind]
	var cat := _cat(kind)
	var entry := _used_entry(key)
	var panel := UI.inset(12, 11)
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.custom_minimum_size.y = 150
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	v.add_child(top)
	top.add_child(UI.chip(cat["icon"], COLORS[cat["color"]], 34))
	var rig: bool = not entry.get("parts", []).is_empty()
	var name_label := UI.wrap(UI.bold(("Complete rig: %s" % def["label"]) if rig else def["label"], 15))
	name_label.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(name_label)
	var seller := UI.caption(("%s   ·   %s" % [entry.get("seller", ""), _parts_line(entry["parts"])]) if rig else entry.get("seller", ""))
	seller.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(seller)
	var text := UI.wrap(UI.caption(entry.get("text", "")))
	text.max_lines_visible = 2
	text.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(text)
	var bottom := HBoxContainer.new()
	v.add_child(bottom)
	var price := UI.big("", UI.GREEN, 19)
	bottom.add_child(price)
	var left := UI.caption("")
	left.size_flags_horizontal = SIZE_EXPAND_FILL
	left.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bottom.add_child(left)
	UI.click_card(panel, _select_used.bind(key))
	_used_cards[key] = {"panel": panel, "price": price, "left": left}
	_update_used_card(key)
	return panel


func _update_used_card(key: String) -> void:
	var entry := _used_entry(key)
	if entry.is_empty():
		return
	var kind: String = entry["kind"]
	var card: Dictionary = _used_cards[key]
	card["price"].text = UI.money(entry["price"]) if entry.get("staple", false) else "%s   new %s" % [UI.money(entry["price"]), UI.money(entry.get("new", Catalog.ITEMS[kind]["price"]))]
	card["price"].add_theme_color_override("font_color", UI.GREEN if entry["price"] <= _money else UI.RED)
	card["left"].text = "" if entry["left"] < 0.0 else UI.mmss(entry["left"])


## Called whenever the balance is: rebuilds the offer cards only when the offers changed.
func _sync_used() -> void:
	var listings: Array = world.used.get("listings", []) if world != null else []
	var ids := listings.map(func(l: Dictionary) -> int: return l["id"])
	if ids != _used_ids:
		_used_ids = ids
		for key: String in _used_cards.keys():
			if key.begins_with("l:"):
				_used_cards[key]["panel"].queue_free()
				_used_cards.erase(key)
		for l: Dictionary in listings:
			_offer_grid.add_child(_used_card("l:%d" % l["id"], l["kind"]))
		_offer_note.visible = listings.is_empty()
		if _used_entry(_used_sel).is_empty():
			_select_used("s:" + UsedMarket.STAPLES[0])
	for key: String in _used_cards:
		_update_used_card(key)
	var entry := _used_entry(_used_sel)
	if not entry.is_empty():
		if int(entry["price"]) != _used_sel_price:
			_select_used(_used_sel)
		_refresh_used_buy(entry)


func _select_used(key: String) -> void:
	var old: Dictionary = _used_cards.get(_used_sel, {})
	if not old.is_empty():
		old["panel"].add_theme_stylebox_override("panel", UI.box(UI.BG_DARK, 11, UI.BORDER, 12))
	var entry := _used_entry(key)
	if entry.is_empty():
		return
	_used_sel = key
	_used_sel_price = int(entry["price"])
	_used_cards[key]["panel"].add_theme_stylebox_override("panel",
			UI.box(Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.16), 11, UI.ACCENT, 12))
	for child in _used_detail.get_children():
		child.queue_free()
	var kind: String = entry["kind"]
	var staple: bool = entry.get("staple", false)
	_detail_part(_used_detail, kind, Catalog.SHOP_INFO[kind][1], [] if staple else
			[["Condition: found out when unpacked", UI.AMBER], ["No refunds", UI.DIM]])
	_used_detail.add_child(UI.rule())
	var seller := HBoxContainer.new()
	_used_detail.add_child(seller)
	var seller_key := UI.label("Seller", 15, UI.DIM)
	seller_key.size_flags_horizontal = SIZE_EXPAND_FILL
	seller.add_child(seller_key)
	seller.add_child(UI.bold(entry["seller"], 15))
	if not staple:
		_used_detail.add_child(UI.wrap(UI.label("\"%s\"" % entry["text"], 15, UI.AMBER)))
	if not entry.get("parts", []).is_empty():
		_used_detail.add_child(UI.wrap(UI.label("Comes with, says the seller: %s. Arrives with the lid screwed on." % _parts_line(entry["parts"]), 15, UI.TEXT)))
	var spacer := Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	_used_detail.add_child(spacer)
	_used_detail.add_child(UI.rule())
	var price_row := HBoxContainer.new()
	_used_detail.add_child(price_row)
	var price_key := UI.label("Asking price", 15, UI.DIM)
	price_key.size_flags_horizontal = SIZE_EXPAND_FILL
	price_row.add_child(price_key)
	var new_price: float = entry.get("new", Catalog.ITEMS[kind]["price"])
	price_row.add_child(UI.big(UI.money(entry["price"]), UI.GREEN, 26))
	var off := int(round((1.0 - entry["price"] / new_price) * 100.0))
	_used_detail.add_child(UI.caption("Catalog price, new or not." if staple else "New it costs %s, so this is %d%% off." % [UI.money(new_price), off]))
	_used_left = UI.caption("")
	_used_detail.add_child(_used_left)
	_used_haggle = UI.btn(UI.ic("handshake") + "  Offer less", "secondary", 16)
	_used_haggle.visible = not staple
	_used_haggle.pressed.connect(_haggle)
	_used_detail.add_child(_used_haggle)
	_used_buy = UI.btn("", "primary", 17)
	_used_buy.custom_minimum_size.y = 50
	_used_buy.pressed.connect(_purchase_used)
	_used_detail.add_child(_used_buy)
	_refresh_used_buy(entry)


func _refresh_used_buy(entry: Dictionary) -> void:
	if _used_buy == null or not is_instance_valid(_used_buy):
		return
	var price: float = entry["price"]
	_used_buy.disabled = price > _money
	_used_buy.text = "%s  Buy it" % UI.ic("shopping_cart") if price <= _money else "You are %s short" % UI.money(price - _money)
	_used_haggle.disabled = entry.get("haggled", true)
	_used_left.text = "Always in stock" if entry["left"] < 0.0 else "Gone in %s, or when someone else buys it" % UI.mmss(entry["left"])


func _purchase_used() -> void:
	var entry := _used_entry(_used_sel)
	if entry.is_empty():
		return
	if entry.get("staple", false):
		world.request_buy_used(0, entry["kind"])
	else:
		world.request_buy_used(int(entry["id"]))


func _haggle() -> void:
	var entry := _used_entry(_used_sel)
	if not entry.is_empty() and not entry.get("staple", false):
		world.request_haggle_used(int(entry["id"]))
		_used_haggle.disabled = true


# --- what to say about a part ---------------------------------------------------------------

func _cat(kind: String) -> Dictionary:
	for cat: Dictionary in Catalog.CATEGORIES:
		if cat["key"] == Catalog.SHOP_INFO[kind][0]:
			return cat
	return Catalog.CATEGORIES[-1]


## "1 CPU, 4 RAM, 2 GPU" for a machine, "4 servers" for a rack.
func _slot_summary(def: Dictionary) -> String:
	var counts := {}
	for slot: Dictionary in def["slots"]:
		counts[slot["accepts"]] = counts.get(slot["accepts"], 0) + 1
	var bits: Array[String] = []
	for group: String in counts:
		var word: String = Catalog.GROUP_NAMES.get(group, group)
		bits.append("%d %s%s" % [counts[group], word, "s" if group == "server" and counts[group] != 1 else ""])
	return ", ".join(bits)


## 2.0 -> "2", 2.6 -> "2.6".
func _fmt(v: float) -> String:
	return ("%.1f" % v).trim_suffix(".0")


## The one line under a part's name on its card: the number that matters most.
func _gist(def: Dictionary) -> String:
	if def.has("gen"):
		return "Makes %s W" % UI.num(def["gen"]["watts"])
	if def.has("tokens"):
		return "%s tok/s  ·  %d W%s" % [_fmt(def["tokens"]), def.get("watts", 0.0), "  ·  tier %d" % def["tier"] if def.has("tier") else ""]
	if def.has("radiator"):
		return "Sheds %d W per degree" % def["radiator"]
	if def.has("cool"):
		return "Cools the room  ·  %d W" % def["watts"]
	if def.has("sockets"):
		return "%d %s sockets" % [def["sockets"], {"power": "power", "net": "network", "coolant": "hose"}[def["provides"]]]
	if def.has("psu"):
		return "%s  ·  %d W supply" % [_slot_summary(def), def["psu"]]
	if def.has("gb"):
		return "%d GB" % def["gb"]
	if def.has("slots"):
		return "Holds %s" % _slot_summary(def)
	if def.has("sensor"):
		return {"room": "Shows a room's temperature", "power": "Shows a power source's load", "coolant": "Shows a coolant loop"}[def["sensor"]]
	if def.has("watts"):
		return "Uses %d W" % def["watts"]
	return ""


## Label and value rows for the detail panel.
func _facts(def: Dictionary) -> Array:
	var rows := []
	if def.has("tokens"):
		rows.append(["Makes", "%s tokens a second" % _fmt(def["tokens"])])
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
		rows.append(["Slots", _slot_summary(def)])
	if def.has("psu"):
		rows.append(["Power supply", "%s W" % UI.num(def["psu"])])
		rows.append(["Takes parts up to", "tier %d" % def["max_tier"]])
	if def.has("tier"):
		rows.append(["Tier", str(def["tier"])])
	if def.has("needs_ram"):
		rows.append(["Needs", "%d GB of RAM" % def["needs_ram"]])
	if def.has("gb"):
		rows.append(["Memory", "%d GB" % def["gb"]])
	if def.get("group", "") == "cpu":
		rows.append(["Feeds GPUs up to", "tier %d at full speed" % (def["tier"] + 1)])
	if def.get("group", "") in ["cpu", "ram", "gpu"]:
		rows.append(["Goes in", "a machine with its lid off"])
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
	if def.get("lid", false):
		out.append(["Needs a screwdriver to open", UI.ACCENT])
	if def.has("psu") and not def.get("coolant_port", false):
		out.append(["No coolant fittings", UI.DIM])
	if def.get("group", "") == "pc":
		out.append(["Does not fit in a rack", UI.DIM])
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
