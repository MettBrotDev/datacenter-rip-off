extends Control
## The company menu (Tab): everything the company can do with its tokens.
## Each tab is built once; `refresh()` (twice a second) only updates texts, values and bars in place.
## Rows for jobs and live things are added and removed only when the set of ids changes.
## All actions go through world.request_company(action, args).

const UI = preload("res://scripts/ui.gd")
const Data = preload("res://scripts/company_data.gd")
const Company = preload("res://scripts/company.gd")

signal closed

var world: Node3D

const TABS: Array = [
	["overview", "Overview", "dashboard"], ["slop", "Slop", "auto_awesome"], ["products", "Products", "widgets"],
	["lab", "Model Lab", "science"], ["platform", "Platform", "dns"], ["market", "Market", "show_chart"],
]
const SLOP_ICONS := {"seo": "article", "linkedin": "work", "recipes": "restaurant", "hands": "back_hand",
	"ebooks": "menu_book", "lofi": "headphones", "reviews": "star", "podcast": "podcasts", "news": "newspaper"}
const PRODUCT_ICONS := {"wrapper": "memory", "resume": "description", "horoscope": "stars", "girlfriend": "favorite",
	"copilot": "code", "legal": "gavel", "crypto": "currency_bitcoin", "agi": "psychology"}
const FAIL_CHANCE := 15

var _tab := "overview"
var _tab_buttons: Dictionary = {}
var _pages: Dictionary = {}
var _scroll: ScrollContainer
var _alert: PanelContainer
var _strip: Dictionary = {}
var _rows: Dictionary = {}      # list key -> {id -> row dictionary}
var _ov: Dictionary = {}
var _sl: Dictionary = {}
var _pr: Dictionary = {}
var _lb: Dictionary = {}
var _pf: Dictionary = {}
var _mk: Dictionary = {}
var _attn_sig := ""
var _attn_rows: Array = []
var _p_what := "wrapper"
var _p_size := 0
var _p_risk := 0
var _share_hold := 0
var _dragging := false


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0.01, 0.02, 0.05, 0.72)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 60)
	margin.add_theme_constant_override("margin_right", 60)
	margin.add_theme_constant_override("margin_top", 34)
	margin.add_theme_constant_override("margin_bottom", 34)
	add_child(margin)
	var shell := PanelContainer.new()
	shell.add_theme_stylebox_override("panel", UI.box(Color(0.04, 0.065, 0.135, 0.97), 18, UI.BORDER, 22))
	margin.add_child(shell)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	shell.add_child(v)

	v.add_child(_build_header())
	v.add_child(_build_strip())
	_alert = UI.panel(12)
	_alert.add_theme_stylebox_override("panel", UI.box(Color(0.5, 0.1, 0.16, 0.9), 10, UI.RED, 12))
	var ar := _hbox(12)
	_alert.add_child(ar)
	ar.add_child(UI.chip("warning", UI.RED, 34))
	ar.add_child(_grow(UI.wrap(UI.bold("Your account is below zero. The landlady has cut the garage internet until you pay up. Sell tokens or retire things that cost money.", 16))))
	_alert.hide()
	v.add_child(_alert)
	_scroll = UI.scroll()
	_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(_scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_right", 10)
	_scroll.add_child(pad)
	var holder := VBoxContainer.new()
	holder.size_flags_horizontal = SIZE_EXPAND_FILL
	pad.add_child(holder)
	_pages["overview"] = _build_overview()
	_pages["slop"] = _build_slop()
	_pages["products"] = _build_products()
	_pages["lab"] = _build_lab()
	_pages["platform"] = _build_platform()
	_pages["market"] = _build_market()
	for t: String in _pages:
		holder.add_child(_pages[t])
	_show_tab("overview")


# --- public ---------------------------------------------------------------------------------

func open(tab: String) -> void:
	_show_tab(tab if _pages.has(tab) else "overview")
	show()
	refresh()


func refresh() -> void:
	if world == null or world.co.is_empty():
		return
	_upd_strip()
	match _tab:
		"overview": _upd_overview()
		"slop": _upd_slop()
		"products": _upd_products()
		"lab": _upd_lab()
		"platform": _upd_platform()
		"market": _upd_market()


# --- small helpers --------------------------------------------------------------------------

func _co() -> Dictionary:
	return world.co


func _go(tab: String) -> void:
	_show_tab(tab)
	refresh()


func _show_tab(tab: String) -> void:
	_tab = tab
	for t: String in _pages:
		_pages[t].visible = t == tab
		(_tab_buttons[t] as Button).set_pressed_no_signal(t == tab)
	_scroll.scroll_vertical = 0


func _page() -> VBoxContainer:
	var p := VBoxContainer.new()
	p.add_theme_constant_override("separation", 14)
	p.size_flags_horizontal = SIZE_EXPAND_FILL
	return p


func _hbox(sep := 14) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.size_flags_horizontal = SIZE_EXPAND_FILL
	return h


func _vbox(sep := 8) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.size_flags_horizontal = SIZE_EXPAND_FILL
	return v


func _grow(c: Control, ratio := 1.0) -> Control:
	c.size_flags_horizontal = SIZE_EXPAND_FILL
	c.size_flags_stretch_ratio = ratio
	return c


## "Key ......... value" row. Returns the value label.
func _kv(parent: Control, key: String, value := "", color := UI.TEXT) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var k := UI.caption(key)
	k.size_flags_horizontal = SIZE_EXPAND_FILL
	k.add_theme_font_size_override("font_size", 14)
	row.add_child(k)
	var val := UI.bold(value, 15, color)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	return val


func _name_label(size := 17) -> Label:
	var l := UI.bold("", size)
	l.size_flags_horizontal = SIZE_EXPAND_FILL
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.clip_text = true
	return l


func _hint(text: String) -> Label:
	var l := UI.wrap(UI.caption(text, UI.FAINT))
	l.add_theme_font_size_override("font_size", 14)
	return l


func _stage_name(level: int) -> String:
	return Data.STAGES[clampi(level, 0, Data.STAGES.size() - 1)]["name"]


func _free_slots() -> int:
	var co := _co()
	return int(co["slots"]) - (co["jobs"] as Array).size() - (co["live"] as Array).size()


func _hype_color(hype: float) -> Color:
	return UI.GREEN if hype >= 0.6 else (UI.AMBER if hype >= 0.35 else UI.RED)


func _set_enabled(b: Button, reason: String, label: String) -> void:
	b.disabled = reason != ""
	b.text = reason if reason != "" else label
	b.tooltip_text = reason


## Add or remove rows only when the set of ids changed, then update every row in place.
func _sync(key: String, holder: Container, items: Array, make: Callable, upd: Callable, empty: Control) -> void:
	var rows: Dictionary = _rows.get(key, {})
	_rows[key] = rows
	var seen := {}
	for it: Dictionary in items:
		seen[it["id"]] = true
	for id: Variant in rows.keys():
		if not seen.has(id):
			var root: Control = rows[id]["root"]
			holder.remove_child(root)
			root.queue_free()
			rows.erase(id)
	var idx := 0
	for it: Dictionary in items:
		var id: int = it["id"]
		if not rows.has(id):
			rows[id] = make.call(id)
			holder.add_child(rows[id]["root"])
		if (rows[id]["root"] as Control).get_index() != idx:
			holder.move_child(rows[id]["root"], idx)
		idx += 1
		upd.call(rows[id], it)
	empty.visible = items.is_empty()


# --- header and stats strip --------------------------------------------------------------------

func _build_header() -> Control:
	var h := _hbox(16)
	h.add_child(UI.chip("bolt", UI.ACCENT, 48))
	var t := VBoxContainer.new()
	t.add_theme_constant_override("separation", -2)
	t.size_flags_vertical = SIZE_SHRINK_CENTER
	h.add_child(t)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	t.add_child(name_row)
	name_row.add_child(UI.bold("RIP OFF", 28))
	name_row.add_child(UI.bold("OPS", 28, UI.ACCENT))
	t.add_child(UI.caption("What your datacenter is doing right now"))
	var gap := Control.new()
	gap.size_flags_horizontal = SIZE_EXPAND_FILL
	h.add_child(gap)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	h.add_child(tabs)
	for entry: Array in TABS:
		var b := UI.tab_button(UI.ic(entry[2]) + "  " + entry[1])
		b.custom_minimum_size.y = 42
		var key: String = entry[0]
		b.pressed.connect(func() -> void: _go(key))
		tabs.add_child(b)
		_tab_buttons[key] = b
	var close := UI.btn(UI.ic("close") + "  Close", "secondary", 15)
	close.custom_minimum_size.y = 42
	close.tooltip_text = "Esc or Tab"
	close.pressed.connect(func() -> void: closed.emit())
	h.add_child(close)
	return h


func _build_strip() -> Control:
	var row := _hbox(12)
	_strip["tokens"] = UI.tile("Tokens stored", "memory", UI.PURPLE, 12)
	_strip["money"] = UI.tile("Balance", "payments", UI.GREEN, 12)
	_strip["income"] = UI.tile("Net per minute", "trending_up", UI.GREEN, 12)
	_strip["stage"] = UI.tile("Funding stage", "emoji_events", UI.AMBER, 12)
	_strip["slots"] = UI.tile("Free slots", "view_in_ar", UI.CYAN, 12)
	for k: String in ["tokens", "money", "income", "stage", "slots"]:
		row.add_child(_strip[k]["root"])
	_strip["tokens_bar"] = UI.bar(0.0, UI.PURPLE, 6)
	_strip["tokens"]["col"].add_child(_strip["tokens_bar"])
	_strip["stage_bar"] = UI.bar(0.0, UI.AMBER, 6)
	_strip["stage"]["col"].add_child(_strip["stage_bar"])
	_grow(_strip["stage"]["root"], 1.25)
	_grow(_strip["tokens"]["root"], 1.25)
	return row


func _upd_strip() -> void:
	var co := _co()
	var tokens: float = co["tokens"]
	var storage: float = co["storage"]
	var fill := tokens / maxf(storage, 1.0)
	_strip["tokens"]["value"].text = "%s / %s" % [UI.short(tokens), UI.short(storage)]
	_strip["tokens"]["sub"].text = "+%s tok/s from the servers" % UI.short(co["rate"])
	(_strip["tokens_bar"] as ProgressBar).value = fill
	UI.bar_color(_strip["tokens_bar"], UI.RED if fill >= 0.98 else (UI.AMBER if fill >= 0.85 else UI.PURPLE))
	_strip["money"]["value"].text = UI.cash(world.money)
	_strip["money"]["value"].add_theme_color_override("font_color", UI.GREEN if world.money >= 0.0 else UI.RED)
	_strip["money"]["sub"].text = "cash on hand"
	var net: float = co["net"]
	_strip["income"]["value"].text = "%s%s/min" % ["+" if net >= 0.0 else "", UI.cash(net)]
	_strip["income"]["value"].add_theme_color_override("font_color", UI.GREEN if net >= 0.0 else UI.RED)
	_strip["income"]["sub"].text = "%s in, %s upkeep" % [UI.cash(co["income"]), UI.cash(co["upkeep"])]
	UI.chip_set(_strip["income"]["chip"], "trending_up" if net >= 0.0 else "trending_down", UI.GREEN if net >= 0.0 else UI.RED)
	_alert.visible = bool(co["overdue"])
	var level: int = co["level"]
	_strip["stage"]["value"].text = co["stage"]
	var floor_at: float = Data.STAGES[level]["at"]
	var next_at: float = co["next_at"]
	var maxed := level >= Data.STAGES.size() - 1
	(_strip["stage_bar"] as ProgressBar).value = 1.0 if maxed else clampf((float(co["earned"]) - floor_at) / maxf(next_at - floor_at, 1.0), 0.0, 1.0)
	_strip["stage"]["sub"].text = "Top of the ladder" if maxed else "%s of %s earned" % [UI.cash(co["earned"]), UI.cash(next_at)]
	var free := _free_slots()
	_strip["slots"]["value"].text = "%d of %d" % [free, co["slots"]]
	_strip["slots"]["sub"].text = "%d building, %d live" % [(co["jobs"] as Array).size(), (co["live"] as Array).size()]


# --- rows shared by several tabs ----------------------------------------------------------------

func _make_job_row(id: int, full: bool) -> Dictionary:
	var root := UI.inset(12)
	var v := _vbox(7)
	root.add_child(v)
	var top := _hbox(8)
	v.add_child(top)
	var row := {"root": root, "name": _name_label(), "eta": UI.bold("", 15, UI.AMBER)}
	top.add_child(row["name"])
	row["tag"] = UI.pill("", UI.DIM)
	top.add_child(row["tag"])
	top.add_child(row["eta"])
	row["bar"] = UI.bar(0.0, UI.AMBER, 8)
	v.add_child(row["bar"])
	if full:
		var bottom := _hbox(8)
		v.add_child(bottom)
		row["info"] = UI.caption("")
		row["info"].size_flags_horizontal = SIZE_EXPAND_FILL
		bottom.add_child(row["info"])
		row["rush"] = UI.btn("Rush", "success", 14)
		row["rush"].pressed.connect(func() -> void: world.request_company("rush", [id]))
		bottom.add_child(row["rush"])
		row["cancel"] = UI.btn("Cancel", "ghost", 14)
		row["cancel"].pressed.connect(func() -> void: world.request_company("cancel", [id]))
		bottom.add_child(row["cancel"])
	return row


func _upd_job_row(row: Dictionary, job: Dictionary) -> void:
	row["name"].text = job["name"]
	var left: float = job["left"]
	var total: float = job["total"]
	(row["bar"] as ProgressBar).value = 1.0 - left / maxf(total, 0.001)
	row["eta"].text = "%s left" % UI.mmss(left)
	var tag: String = "Slop" if job["kind"] == "slop" else "%s, %s" % [Data.SIZES[job["size"]]["name"], Data.RISKS[job["risk"]]["name"]]
	UI.pill_set(row["tag"], tag, UI.AMBER if job["kind"] == "slop" else UI.CYAN)
	if row.has("rush"):
		var price: float = Company.rush_price(job)
		row["rush"].text = "Rush  %s" % UI.cash(price)
		row["rush"].disabled = price > world.money
		row["rush"].tooltip_text = "Pay cash to finish right now" if price <= world.money else "You need %s" % UI.cash(price)
		row["cancel"].text = "Cancel  (+%s tokens)" % UI.short(Company.cancel_refund(job))
		row["info"].text = "Uses %s tokens" % UI.short(job["tokens"])


func _make_live_row(id: int, full: bool) -> Dictionary:
	var root := UI.inset(12)
	var v := _vbox(7)
	root.add_child(v)
	var top := _hbox(8)
	v.add_child(top)
	var row := {"root": root, "name": _name_label(), "income": UI.bold("", 16, UI.GREEN), "hype": UI.bold("", 14)}
	top.add_child(row["name"])
	row["tag"] = UI.pill("", UI.DIM)
	top.add_child(row["tag"])
	top.add_child(row["income"])
	row["bar"] = UI.bar(0.0, UI.GREEN, 8)
	var mid := _hbox(8)
	v.add_child(mid)
	mid.add_child(row["bar"])
	row["bar"].size_flags_horizontal = SIZE_EXPAND_FILL
	mid.add_child(row["hype"])
	if full:
		var bottom := _hbox(8)
		v.add_child(bottom)
		row["info"] = UI.caption("")
		row["info"].size_flags_horizontal = SIZE_EXPAND_FILL
		bottom.add_child(row["info"])
		row["update"] = UI.btn("Update", "primary", 14)
		row["update"].pressed.connect(func() -> void: world.request_company("update", [id]))
		bottom.add_child(row["update"])
		row["retire"] = UI.btn("Retire", "ghost", 14)
		row["retire"].pressed.connect(func() -> void: world.request_company("retire", [id]))
		bottom.add_child(row["retire"])
	return row


func _upd_live_row(row: Dictionary, item: Dictionary) -> void:
	var hype: float = item["hype"]
	row["name"].text = item["name"]
	row["income"].text = "%s/min" % UI.cash(float(item["peak"]) * hype)
	(row["bar"] as ProgressBar).value = hype
	UI.bar_color(row["bar"], _hype_color(hype))
	row["hype"].text = "hype %d%%" % roundi(hype * 100.0)
	row["hype"].add_theme_color_override("font_color", _hype_color(hype))
	var product: bool = item["kind"] == "product"
	UI.pill_set(row["tag"], "Product" if product else "Slop", UI.CYAN if product else UI.AMBER)
	if row.has("info"):
		row["info"].text = "Earned so far %s  ·  hype halves every %s" % [UI.cash(item["earned"]), UI.mmss(item["half_life"])]
		var upd: Button = row["update"]
		upd.visible = product
		var cost: float = float(item["tokens"]) * Data.UPDATE_COST
		var short: bool = cost > float(_co()["tokens"])
		upd.disabled = short
		upd.text = "%s  Update  %s tokens" % [UI.ic("update"), UI.short(cost)]
		upd.tooltip_text = "Hype back to full. Each update excites people a little less." if not short else "Not enough tokens"


# --- overview ------------------------------------------------------------------------------------

func _summary(parent: Control, title: String, icon: String, color: Color, tab: String) -> Dictionary:
	var t := UI.tile(title, icon, color, 16)
	t["value"].add_theme_font_size_override("font_size", 28)
	UI.click_card(t["root"], func() -> void: _go(tab))
	parent.add_child(t["root"])
	return t


func _build_overview() -> Control:
	var page := _page()
	var top := _hbox(14)
	page.add_child(top)
	_ov["dev"] = _summary(top, "In development", "build", UI.AMBER, "products")
	_ov["live"] = _summary(top, "Live now", "payments", UI.GREEN, "products")
	_ov["model"] = _summary(top, "Model in use", "psychology", UI.PURPLE, "lab")
	_ov["plat"] = _summary(top, "API platform", "dns", UI.CYAN, "platform")

	var mid := _hbox(14)
	page.add_child(mid)
	var todo := UI.card(18)
	_grow(todo, 2.0)
	mid.add_child(todo)
	var tv := _vbox(14)
	todo.add_child(tv)
	tv.add_child(UI.section("What do you want to do?", "Each card opens the right tab", "bolt", UI.ACCENT))
	var cards := _hbox(12)
	cards.size_flags_vertical = SIZE_EXPAND_FILL
	tv.add_child(cards)
	_ov["act_slop"] = _action_card(cards, "auto_awesome", UI.ACCENT, "Make some slop", "Cheap, fast and shameless. Quick money from spare tokens.", "Start slop", "primary", "slop")
	_ov["act_prod"] = _action_card(cards, "widgets", UI.GREEN, "Build a product", "", "New product", "success", "products")
	_ov["act_model"] = _action_card(cards, "science", UI.PURPLE, "Models and training", "Smarter models unlock bigger things. Have one write the code for your own.", "Model Lab", "purple", "lab")
	_ov["act_sell"] = _action_card(cards, "sell", UI.AMBER, "Sell tokens", "Storage full? Dump tokens on the raw market, at a poor price.", "Market", "secondary", "market")

	var attn := UI.card(18)
	_grow(attn, 1.0)
	mid.add_child(attn)
	var av := _vbox(10)
	attn.add_child(av)
	var ah := UI.section("Needs your attention", "Most important first", "notifications_active", UI.AMBER)
	_ov["attn_count"] = UI.pill("0", UI.AMBER)
	ah.add_child(_grow(Control.new()))
	ah.add_child(_ov["attn_count"])
	av.add_child(ah)
	_ov["attn"] = _vbox(8)
	av.add_child(_ov["attn"])

	var low := _hbox(14)
	page.add_child(low)
	for k: String in ["dev", "live"]:
		var c := UI.card(18)
		_grow(c, 1.0)
		low.add_child(c)
		var cv := _vbox(10)
		c.add_child(cv)
		if k == "dev":
			cv.add_child(UI.section("In development", "Being built right now", "build", UI.AMBER))
		else:
			cv.add_child(UI.section("Live", "Earning money while the hype lasts", "payments", UI.GREEN))
		_ov[k + "_empty"] = _hint("Nothing here yet." if k == "live" else "Nothing is being built. Start something in Slop or Products.")
		cv.add_child(_ov[k + "_empty"])
		_ov[k + "_list"] = _vbox(8)
		cv.add_child(_ov[k + "_list"])
	var cost := UI.card(18)
	_grow(cost, 0.8)
	low.add_child(cost)
	var kv := _vbox(8)
	cost.add_child(kv)
	kv.add_child(UI.section("Running costs", "They never stop. Per minute.", "account_balance", UI.RED))
	_ov["cost_list"] = _vbox(6)
	kv.add_child(_ov["cost_list"])
	_ov["cost_rows"] = {}
	kv.add_child(UI.rule())
	_ov["cost_in"] = _kv(kv, "Income", "", UI.GREEN)
	_ov["cost_out"] = _kv(kv, "Upkeep", "", UI.RED)
	_ov["cost_net"] = _kv(kv, "Net", "")
	return page


## Cost rows are added or removed only when the set of reasons changes.
func _upd_costs() -> void:
	var co := _co()
	var costs: Dictionary = co["costs"]
	var rows: Dictionary = _ov["cost_rows"]
	for reason: Variant in rows.keys():
		if not costs.has(reason):
			var root: Control = rows[reason]["root"]
			_ov["cost_list"].remove_child(root)
			root.queue_free()
			rows.erase(reason)
	for reason: String in costs:
		if not rows.has(reason):
			var row := HBoxContainer.new()
			var k := UI.body(reason, UI.DIM)
			k.size_flags_horizontal = SIZE_EXPAND_FILL
			k.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			k.clip_text = true
			row.add_child(k)
			var v := UI.bold("", 16, UI.RED.lightened(0.15))
			row.add_child(v)
			_ov["cost_list"].add_child(row)
			rows[reason] = {"root": row, "value": v}
		rows[reason]["value"].text = "-%s" % UI.cash(costs[reason])
	(_ov["cost_list"] as Control).visible = not costs.is_empty()
	_ov["cost_in"].text = "+%s" % UI.cash(co["income"])
	_ov["cost_out"].text = "-%s" % UI.cash(co["upkeep"])
	var net: float = co["net"]
	_ov["cost_net"].text = "%s%s" % ["+" if net >= 0.0 else "", UI.cash(net)]
	_ov["cost_net"].add_theme_color_override("font_color", UI.GREEN if net >= 0.0 else UI.RED)


func _action_card(parent: Control, icon: String, color: Color, title: String, text: String, button: String, kind: String, tab: String) -> Dictionary:
	var c := UI.inset(16, 12)
	_grow(c, 1.0)
	c.custom_minimum_size.y = 200
	parent.add_child(c)
	var v := _vbox(8)
	c.add_child(v)
	v.add_child(UI.chip(icon, color, 40))
	v.add_child(UI.bold(title, 17))
	var body := UI.wrap(UI.caption(text))
	body.add_theme_font_size_override("font_size", 14)
	body.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(body)
	var b := UI.btn(button, kind, 15)
	b.pressed.connect(func() -> void: _go(tab))
	v.add_child(b)
	return {"body": body}


func _upd_overview() -> void:
	var co := _co()
	var jobs: Array = co["jobs"]
	var live: Array = co["live"]
	var model: Dictionary = co["model"]
	var plat: Dictionary = co["platform"]
	var free := _free_slots()

	var soonest := ""
	var best := INF
	for j: Dictionary in jobs:
		if float(j["left"]) < best:
			best = j["left"]
			soonest = "%s, %s left" % [j["name"], UI.mmss(j["left"])]
	_ov["dev"]["value"].text = "%d of %d slots" % [jobs.size(), co["slots"]]
	_ov["dev"]["sub"].text = soonest if soonest != "" else "Nothing is being built"
	_upd_costs()
	_ov["live"]["value"].text = "%s/min" % UI.cash(co["income"])
	_ov["live"]["sub"].text = "%d live, %d slots free" % [live.size(), free]
	_ov["model"]["value"].text = model["name"]
	_ov["model"]["value"].add_theme_font_size_override("font_size", 22)
	var training: Dictionary = co["training"]
	if not training.is_empty():
		_ov["model"]["sub"].text = "Training your own: %s left" % UI.mmss(training["left"])
	else:
		_ov["model"]["sub"].text = "smartness %d, %s" % [model["smart"], ("rented, %s/min" % UI.cash(model["rent"])) if model["rented"] else "yours for good"]
	if bool(plat["open"]):
		_ov["plat"]["value"].text = "%s users" % UI.short(plat["users"])
		_ov["plat"]["sub"].text = "%d%% of production reserved" % roundi(float(plat["share"]) * 100.0)
	else:
		_ov["plat"]["value"].text = "Locked"
		_ov["plat"]["sub"].text = "Needs a smartness %d model" % Data.PLATFORM_TIER
	_ov["act_prod"]["body"].text = "Pick a type, a size and a launch style. %d of %d slots are free." % [free, co["slots"]]

	_sync("ov_jobs", _ov["dev_list"], jobs, func(id: int) -> Dictionary: return _make_job_row(id, false), _upd_job_row, _ov["dev_empty"])
	_sync("ov_live", _ov["live_list"], live, func(id: int) -> Dictionary: return _make_live_row(id, false), _upd_live_row, _ov["live_empty"])
	_upd_attention()


func _has_own(co: Dictionary) -> bool:
	for key: String in co["models"]:
		if co["models"][key].get("own", false):
			return true
	return false


## The name of a product we have the funding for but the model in use cannot make ("" if none).
func _best_unlocked_blocked(co: Dictionary) -> String:
	var m: Dictionary = co["models"][co["active"]]
	var found := ""
	for key: String in Data.PRODUCTS:
		var def: Dictionary = Data.PRODUCTS[key]
		if int(def["level"]) <= int(co["level"]) and Data.can_make(m, "product", key) != "":
			found = def["name"]
	return found


func _upd_attention() -> void:
	var co := _co()
	var items: Array = []
	var tokens: float = co["tokens"]
	var storage: float = co["storage"]
	var model: Dictionary = co["model"]
	if bool(co["overdue"]):
		items.append({"icon": "warning", "color": UI.RED, "title": "Your account is below zero",
			"detail": "The landlady has cut the internet and a rented model bounces. Sell tokens to get back above zero.", "tab": "market"})
	elif float(co["net"]) < 0.0 and float(co["upkeep"]) > 0.0:
		items.append({"icon": "trending_down", "color": UI.RED, "title": "You are losing money",
			"detail": "Upkeep is %s a minute and income only %s. Launch something or drop a model you rent." % [UI.cash(co["upkeep"]), UI.cash(co["income"])], "tab": "overview"})
	if bool(model["rented"]):
		var owned_model: Dictionary = co["models"][model["key"]]
		if world.money >= float(owned_model["price"]) and float(owned_model["price"]) > 0.0:
			items.append({"icon": "savings", "color": UI.GREEN, "title": "Buy %s instead of renting" % model["name"],
				"detail": "You can afford the %s price, and you pay %s every minute in licence fees." % [UI.cash(owned_model["price"]), UI.cash(model["rent"])], "tab": "lab"})
	var plan: Dictionary = co["plan"]
	if bool(plan["ready"]) and (co["training"] as Dictionary).is_empty() and not _has_own(co):
		items.append({"icon": "science", "color": UI.PURPLE, "title": "Your training stack is ready",
			"detail": "Train your own model: no licence fees, ever.", "tab": "lab"})
	var best_new := _best_unlocked_blocked(co)
	if best_new != "":
		items.append({"icon": "psychology", "color": UI.PURPLE, "title": "%s is too weak for %s" % [model["name"], best_new],
			"detail": "You have the funding for it, but the model in use is not smart enough. Switch models in the Lab.", "tab": "lab"})
	if tokens >= storage * 0.9:
		items.append({"icon": "storage", "color": UI.RED, "title": "Storage is nearly full",
			"detail": "%s of %s tokens. Whatever the servers make beyond that is wasted: spend it or sell it." % [UI.short(tokens), UI.short(storage)], "tab": "market"})
	for item: Dictionary in co["live"]:
		if float(item["hype"]) < 0.35:
			if item["kind"] == "product":
				items.append({"icon": "update", "color": UI.AMBER, "title": "%s lost its hype" % item["name"],
					"detail": "Hype is at %d%%. An update costs %s tokens and brings it back." % [roundi(float(item["hype"]) * 100.0), UI.short(float(item["tokens"]) * Data.UPDATE_COST)], "tab": "products"})
			else:
				items.append({"icon": "trending_down", "color": UI.AMBER, "title": "%s is fading" % item["name"],
					"detail": "Hype is at %d%%. Retire it and start fresh slop." % roundi(float(item["hype"]) * 100.0), "tab": "slop"})
	var plat: Dictionary = co["platform"]
	if bool(plat["open"]) and float(plat["users"]) > 0.0 and float(plat["served"]) < float(plat["want"]) * 0.8:
		items.append({"icon": "error", "color": UI.RED, "title": "Platform users are not being served",
			"detail": "They want %.1f tok/s and get %.1f. Unhappy users leave: reserve more production." % [plat["want"], plat["served"]], "tab": "platform"})
	var free := _free_slots()
	if free > 0 and tokens >= 400.0:
		items.append({"icon": "view_in_ar", "color": UI.CYAN, "title": "%d free %s" % [free, "slot" if free == 1 else "slots"],
			"detail": "Tokens sitting in storage earn nothing. Start something.", "tab": "slop"})
	var sig := ""
	for it: Dictionary in items:
		sig += it["title"] + "|"
	if sig != _attn_sig:
		_attn_sig = sig
		_attn_rows.clear()
		for c in _ov["attn"].get_children():
			_ov["attn"].remove_child(c)
			c.queue_free()
		if items.is_empty():
			var ok := UI.inset(12)
			var r := _hbox(10)
			ok.add_child(r)
			r.add_child(UI.chip("check_circle", UI.GREEN, 32))
			r.add_child(_grow(UI.wrap(UI.body("All quiet. Nothing needs you right now.", UI.DIM))))
			_ov["attn"].add_child(ok)
		for it: Dictionary in items:
			var root := UI.inset(12)
			var r := _hbox(10)
			root.add_child(r)
			var chip := UI.chip(it["icon"], it["color"], 32)
			chip.size_flags_vertical = SIZE_SHRINK_BEGIN
			r.add_child(chip)
			var col := _vbox(1)
			r.add_child(col)
			col.add_child(UI.bold(it["title"], 15))
			var detail := UI.wrap(UI.caption(""))
			detail.add_theme_font_size_override("font_size", 13)
			col.add_child(detail)
			var look := UI.btn("Look", "ghost", 14)
			var tab: String = it["tab"]
			look.pressed.connect(func() -> void: _go(tab))
			look.size_flags_vertical = SIZE_SHRINK_CENTER
			r.add_child(look)
			_ov["attn"].add_child(root)
			_attn_rows.append(detail)
	for i in mini(items.size(), _attn_rows.size()):
		(_attn_rows[i] as Label).text = items[i]["detail"]
	_ov["attn_count"].get_child(0).text = str(items.size())
	UI.pill_set(_ov["attn_count"], str(items.size()), UI.AMBER if not items.is_empty() else UI.GREEN)


# --- slop ------------------------------------------------------------------------------------------

func _build_slop() -> Control:
	var page := _page()
	var head := UI.section("Slop", "Cheap, fast, shameless. Short-lived income, so keep feeding it.", "auto_awesome", UI.ACCENT)
	page.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	grid.size_flags_horizontal = SIZE_EXPAND_FILL
	page.add_child(grid)
	_sl["cards"] = {}
	for key: String in Data.SLOP:
		var def: Dictionary = Data.SLOP[key]
		var c := UI.card(16)
		c.size_flags_horizontal = SIZE_EXPAND_FILL
		grid.add_child(c)
		var v := _vbox(8)
		c.add_child(v)
		var top := _hbox(10)
		v.add_child(top)
		top.add_child(UI.chip(SLOP_ICONS.get(key, "auto_awesome"), UI.ACCENT, 38))
		var nm := _name_label(17)
		nm.text = def["name"]
		nm.size_flags_vertical = SIZE_SHRINK_CENTER
		top.add_child(nm)
		var lock := UI.pill("", UI.AMBER)
		top.add_child(lock)
		var blurb := UI.wrap(UI.caption(def["blurb"]))
		blurb.add_theme_font_size_override("font_size", 14)
		blurb.custom_minimum_size.y = 40
		v.add_child(blurb)
		var grid2 := VBoxContainer.new()
		grid2.add_theme_constant_override("separation", 2)
		v.add_child(grid2)
		_kv(grid2, "Cost", "%s tokens" % UI.short(def["tokens"]), UI.PURPLE.lightened(0.3))
		var time := _kv(grid2, "Build time")
		var income := _kv(grid2, "Income at launch", "", UI.GREEN)
		_kv(grid2, "Lasts", "hype halves every %s" % UI.mmss(def["half_life"]))
		var b := UI.btn("Start", "primary", 15)
		b.pressed.connect(func() -> void: world.request_company("start", ["slop", key, 0, 0]))
		v.add_child(b)
		_sl["cards"][key] = {"root": c, "btn": b, "lock": lock, "time": time, "income": income}
	var live := UI.card(18)
	page.add_child(live)
	var lv := _vbox(10)
	live.add_child(lv)
	lv.add_child(UI.section("Live slop", "Earning right now. Retire it to free the slot.", "payments", UI.GREEN))
	_sl["empty"] = _hint("No slop is live. Start something above.")
	lv.add_child(_sl["empty"])
	_sl["list"] = _vbox(8)
	lv.add_child(_sl["list"])
	return page


func _upd_slop() -> void:
	var co := _co()
	var model: Dictionary = co["models"][co["active"]]
	var speed: float = model["speed"]
	var quality: float = model["productivity"]
	var level: int = co["level"]
	var tokens: float = co["tokens"]
	var free := _free_slots()
	for key: String in _sl["cards"]:
		var def: Dictionary = Data.SLOP[key]
		var card: Dictionary = _sl["cards"][key]
		var stage_locked: bool = int(def["level"]) > level
		var model_block := Data.can_make(model, "slop", key)
		var locked := stage_locked or model_block != ""
		card["root"].modulate = Color(1, 1, 1, 0.5 if locked else 1.0)
		card["lock"].visible = locked
		if stage_locked:
			UI.pill_set(card["lock"], "%s  %s" % [UI.ic("lock"), _stage_name(def["level"])], UI.AMBER)
		elif model_block != "":
			UI.pill_set(card["lock"], "%s  Smartness %d" % [UI.ic("lock"), def["smart"]], UI.PURPLE)
		card["time"].text = UI.mmss(float(def["time"]) / speed)
		card["income"].text = "%s/min" % UI.cash(float(def["income"]) * quality)
		var reason := ""
		if stage_locked:
			reason = "Needs %s" % _stage_name(def["level"])
		elif model_block != "":
			reason = "Needs smartness %d" % def["smart"]
		elif free <= 0:
			reason = "No free slot"
		elif float(def["tokens"]) > tokens:
			reason = "Needs %s tokens" % UI.short(def["tokens"])
		_set_enabled(card["btn"], reason, "Start")
	var items: Array = []
	for item: Dictionary in co["live"]:
		if item["kind"] == "slop":
			items.append(item)
	_sync("sl_live", _sl["list"], items, func(id: int) -> Dictionary: return _make_live_row(id, true), _upd_live_row, _sl["empty"])


# --- products ----------------------------------------------------------------------------------------

func _build_products() -> Control:
	var page := _page()
	page.add_child(UI.section("Products", "Real software, allegedly. Slower and pricier than slop, but it lasts and can be updated.", "widgets", UI.GREEN))
	var top := _hbox(14)
	page.add_child(top)

	var left := UI.card(18)
	_grow(left, 2.0)
	top.add_child(left)
	var lv := _vbox(10)
	left.add_child(lv)
	lv.add_child(UI.bold("1   What are you building?", 16))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	lv.add_child(grid)
	var group := ButtonGroup.new()
	_pr["types"] = {}
	for key: String in Data.PRODUCTS:
		var b := UI.choice_button("", group)
		b.custom_minimum_size.y = 58
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.button_pressed = key == _p_what
		b.pressed.connect(func() -> void: _p_what = key; _upd_products())
		grid.add_child(b)
		_pr["types"][key] = b
	lv.add_child(UI.bold("2   How big?", 16))
	var sizes := _hbox(10)
	lv.add_child(sizes)
	group = ButtonGroup.new()
	for i in Data.SIZES.size():
		var s: Dictionary = Data.SIZES[i]
		var b := UI.choice_button("%s\nx%s cost, x%s time, x%s income" % [s["name"], _x(s["cost"]), _x(s["time"]), _x(s["income"])], group)
		b.custom_minimum_size.y = 58
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.button_pressed = i == _p_size
		b.pressed.connect(func() -> void: _p_size = i; _upd_products())
		sizes.add_child(b)
	lv.add_child(UI.bold("3   How do you launch it?", 16))
	var risks := _hbox(10)
	lv.add_child(risks)
	group = ButtonGroup.new()
	for i in Data.RISKS.size():
		var r: Dictionary = Data.RISKS[i]
		var b := UI.choice_button("%s\nluck x%s to x%s, time x%s" % [r["name"], _x(r["low"]), _x(r["high"]), _x(r["time"])], group)
		b.custom_minimum_size.y = 58
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.button_pressed = i == _p_risk
		b.pressed.connect(func() -> void: _p_risk = i; _upd_products())
		risks.add_child(b)

	var sum := UI.card(18)
	sum.custom_minimum_size.x = 400
	top.add_child(sum)
	var sv := _vbox(8)
	sum.add_child(sv)
	var sh := _hbox(10)
	sv.add_child(sh)
	_pr["chip"] = UI.chip("widgets", UI.GREEN, 40)
	sh.add_child(_pr["chip"])
	var tcol := _vbox(0)
	sh.add_child(tcol)
	tcol.add_child(UI.caption("YOU WILL BUILD"))
	_pr["name"] = _name_label(19)
	tcol.add_child(_pr["name"])
	_pr["blurb"] = UI.wrap(UI.caption(""))
	_pr["blurb"].add_theme_font_size_override("font_size", 14)
	_pr["blurb"].custom_minimum_size.y = 40
	sv.add_child(_pr["blurb"])
	sv.add_child(UI.rule())
	_pr["cost"] = _kv(sv, "Cost", "", UI.PURPLE.lightened(0.3))
	_pr["time"] = _kv(sv, "Build time")
	_pr["income"] = _kv(sv, "Income at launch", "", UI.GREEN)
	_pr["lasts"] = _kv(sv, "Lasts")
	_pr["update"] = _kv(sv, "An update costs")
	_pr["risk"] = UI.wrap(UI.caption(""))
	_pr["risk"].add_theme_font_size_override("font_size", 14)
	sv.add_child(_pr["risk"])
	var gap := Control.new()
	gap.size_flags_vertical = SIZE_EXPAND_FILL
	sv.add_child(gap)
	_pr["build"] = UI.btn("Build", "success", 17)
	_pr["build"].custom_minimum_size.y = 46
	_pr["build"].pressed.connect(func() -> void: world.request_company("start", ["product", _p_what, _p_size, _p_risk]))
	sv.add_child(_pr["build"])

	var low := _hbox(14)
	page.add_child(low)
	for k: String in ["dev", "live"]:
		var c := UI.card(18)
		_grow(c, 1.0)
		low.add_child(c)
		var cv := _vbox(10)
		c.add_child(cv)
		if k == "dev":
			cv.add_child(UI.section("In development", "Rush it with cash or cancel for most of your tokens back", "build", UI.AMBER))
		else:
			cv.add_child(UI.section("Live products", "Update before the hype runs out", "payments", UI.GREEN))
		_pr[k + "_empty"] = _hint("Nothing is being built." if k == "dev" else "No products are live yet.")
		cv.add_child(_pr[k + "_empty"])
		_pr[k + "_list"] = _vbox(8)
		cv.add_child(_pr[k + "_list"])
	return page


func _x(v: float) -> String:
	return ("%.2f" % v).rstrip("0").rstrip(".")


func _upd_products() -> void:
	var co := _co()
	var level: int = co["level"]
	var model: Dictionary = co["models"][co["active"]]
	var speed: float = model["speed"]
	var quality: float = model["productivity"]
	for key: String in _pr["types"]:
		var def: Dictionary = Data.PRODUCTS[key]
		var b: Button = _pr["types"][key]
		var stage_locked: bool = int(def["level"]) > level
		var model_block := Data.can_make(model, "product", key)
		var second := "from %s tokens" % UI.short(def["tokens"])
		if stage_locked:
			second = "%s  %s" % [UI.ic("lock"), _stage_name(def["level"])]
		elif model_block != "":
			second = "%s  Smartness %d" % [UI.ic("lock"), def["smart"]] if model.get("only", "") != "slop" else "%s  Slop-only model" % UI.ic("lock")
		b.text = "%s\n%s" % [def["name"], second]
		b.modulate = Color(1, 1, 1, 0.6 if (stage_locked or model_block != "") else 1.0)
	var def: Dictionary = Data.PRODUCTS[_p_what]
	var size: Dictionary = Data.SIZES[_p_size]
	var risk: Dictionary = Data.RISKS[_p_risk]
	var cost: float = float(def["tokens"]) * float(size["cost"])
	var seconds: float = float(def["time"]) * float(size["time"]) * float(risk["time"]) / speed
	var base_income: float = float(def["income"]) * float(size["income"]) * quality
	_pr["name"].text = def["name"]
	_pr["blurb"].text = def["blurb"]
	UI.chip_set(_pr["chip"], PRODUCT_ICONS.get(_p_what, "widgets"), UI.GREEN)
	_pr["cost"].text = "%s tokens" % UI.short(cost)
	_pr["time"].text = UI.mmss(seconds) + ("" if speed <= 1.0 else "  (model x%.2f)" % speed)
	_pr["income"].text = "%s to %s /min" % [UI.cash(base_income * float(risk["low"])), UI.cash(base_income * float(risk["high"]))]
	_pr["lasts"].text = "hype halves every %s" % UI.mmss(def["half_life"])
	_pr["update"].text = "%s tokens" % UI.short(cost * Data.UPDATE_COST)
	_pr["risk"].text = "%s: %s  Model reliability %d%%: that is the chance the launch is not half hallucinated." % [risk["name"], risk["blurb"], roundi(float(model["reliability"]) * 100.0)]
	var reason := ""
	var blocked := Data.can_make(model, "product", _p_what)
	if int(def["level"]) > level:
		reason = "Needs %s" % _stage_name(def["level"])
	elif blocked != "":
		reason = "Model too weak" if model.get("only", "") != "slop" else "Slop-only model"
		_pr["risk"].text = blocked
	elif _free_slots() <= 0:
		reason = "No free slot"
	elif cost > float(co["tokens"]):
		reason = "Needs %s tokens" % UI.short(cost)
	_set_enabled(_pr["build"], reason, "%s  Build" % UI.ic("rocket_launch"))

	if _tab != "products":
		return
	_sync("pr_jobs", _pr["dev_list"], co["jobs"], func(id: int) -> Dictionary: return _make_job_row(id, true), _upd_job_row, _pr["dev_empty"])
	var items: Array = []
	for item: Dictionary in co["live"]:
		if item["kind"] == "product":
			items.append(item)
	_sync("pr_live", _pr["live_list"], items, func(id: int) -> Dictionary: return _make_live_row(id, true), _upd_live_row, _pr["live_empty"])


# --- model lab ----------------------------------------------------------------------------------------

func _pips(n: int, total := 5) -> String:
	return "●".repeat(clampi(n, 0, total)) + "○".repeat(total - clampi(n, 0, total))


func _build_lab() -> Control:
	var page := _page()
	page.add_child(UI.section("Model Lab", "Choose the model that does your work, then have it write the code for your own.", "science", UI.PURPLE))
	var note := UI.inset(16)
	page.add_child(note)
	var nr := _hbox(12)
	note.add_child(nr)
	nr.add_child(UI.chip("psychology", UI.PURPLE, 36))
	nr.add_child(_grow(UI.wrap(UI.body("The loop: code written at level N trains a model of smartness N + 1. A rented model writes the code for your own model, which then writes better code for its successor. Renting costs money every minute; buying costs once; your own models are free forever.", UI.DIM))))

	var mc := UI.card(18)
	page.add_child(mc)
	var mv := _vbox(12)
	mc.add_child(mv)
	mv.add_child(UI.section("Models", "Four stats each. Names changed to protect the lawyers.", "memory", UI.PURPLE))
	_lb["groups"] = {}
	_lb["cards"] = {}
	for g in range(0, 6):
		var head := UI.bold("Your own models" if g == 0 else "Smartness %d  %s" % [g, _pips(g)], 15, UI.PURPLE.lightened(0.3) if g == 0 else UI.DIM)
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 12)
		grid.size_flags_horizontal = SIZE_EXPAND_FILL
		mv.add_child(head)
		mv.add_child(grid)
		_lb["groups"][g] = {"head": head, "grid": grid}

	var sc := UI.card(18)
	page.add_child(sc)
	var sv := _vbox(12)
	sc.add_child(sv)
	sv.add_child(UI.section("Training stack", "Five pieces of code, level 0 to %d, all written by the model in use." % Data.MAX_CODE, "code", UI.CYAN))
	_lb["code_box"] = UI.inset(14)
	sv.add_child(_lb["code_box"])
	var cv := _vbox(8)
	_lb["code_box"].add_child(cv)
	var ch := _hbox(8)
	cv.add_child(ch)
	_lb["code_name"] = _name_label(16)
	ch.add_child(_lb["code_name"])
	_lb["code_eta"] = UI.bold("", 15, UI.CYAN)
	ch.add_child(_lb["code_eta"])
	_lb["code_bar"] = UI.bar(0.0, UI.CYAN, 10)
	cv.add_child(_lb["code_bar"])
	_lb["code_info"] = UI.caption("")
	cv.add_child(_lb["code_info"])
	_lb["parts"] = {}
	for key: String in Data.COMPONENTS:
		var def: Dictionary = Data.COMPONENTS[key]
		var root := UI.inset(12)
		sv.add_child(root)
		var row := _hbox(14)
		root.add_child(row)
		var text := _vbox(1)
		text.size_flags_stretch_ratio = 2.0
		row.add_child(text)
		text.add_child(UI.bold(def["name"], 16))
		var blurb := UI.wrap(UI.caption(def["blurb"]))
		text.add_child(blurb)
		var gives := UI.caption("Gives: %s" % def["gives"], UI.CYAN.darkened(0.1))
		text.add_child(gives)
		var mid := _vbox(4)
		mid.size_flags_stretch_ratio = 1.4
		mid.size_flags_vertical = SIZE_SHRINK_CENTER
		row.add_child(mid)
		var pips := UI.bold("", 18, UI.CYAN)
		mid.add_child(pips)
		var info := UI.caption("")
		info.add_theme_font_size_override("font_size", 13)
		mid.add_child(info)
		var b := UI.btn("Write", "primary", 14)
		b.custom_minimum_size.x = 170
		b.size_flags_vertical = SIZE_SHRINK_CENTER
		b.pressed.connect(func() -> void: world.request_company("code", [key]))
		row.add_child(b)
		_lb["parts"][key] = {"pips": pips, "info": info, "btn": b}

	var pc := UI.card(18)
	page.add_child(pc)
	var pv := _vbox(10)
	pc.add_child(pv)
	pv.add_child(UI.section("Train your own model", "What your stack would produce right now.", "rocket_launch", UI.PURPLE))
	var pr := _hbox(24)
	pv.add_child(pr)
	var left := _vbox(4)
	pr.add_child(left)
	_lb["p_smart"] = _kv(left, "Smartness", "", UI.PURPLE.lightened(0.3))
	_lb["p_prod"] = _kv(left, "Productivity", "", UI.GREEN)
	_lb["p_rel"] = _kv(left, "Reliability", "", UI.CYAN)
	_lb["p_speed"] = _kv(left, "Speed", "", UI.AMBER)
	var right := _vbox(4)
	pr.add_child(right)
	_lb["p_cost"] = _kv(right, "Training cost", "", UI.PURPLE.lightened(0.3))
	_lb["p_time"] = _kv(right, "Training time")
	_lb["p_fail"] = _kv(right, "Chance the run fails", "", UI.AMBER)
	_lb["p_note"] = UI.wrap(UI.caption("A failed run (loss goes to NaN) returns half the tokens."))
	right.add_child(_lb["p_note"])
	_lb["train"] = UI.btn("Train", "purple", 17)
	_lb["train"].custom_minimum_size.y = 46
	_lb["train"].pressed.connect(func() -> void: world.request_company("train", []))
	pv.add_child(_lb["train"])
	_lb["train_box"] = _vbox(6)
	pv.add_child(_lb["train_box"])
	var tl := _hbox(8)
	_lb["train_box"].add_child(tl)
	_lb["train_name"] = _name_label(16)
	tl.add_child(_lb["train_name"])
	_lb["train_eta"] = UI.bold("", 15, UI.PURPLE.lightened(0.3))
	tl.add_child(_lb["train_eta"])
	_lb["train_bar"] = UI.bar(0.0, UI.PURPLE, 12)
	_lb["train_box"].add_child(_lb["train_bar"])
	return page


func _make_model_card(key: String) -> Dictionary:
	var m: Dictionary = _co()["models"][key]
	var c := UI.inset(14, 12)
	_grow(c, 1.0)
	var v := _vbox(6)
	c.add_child(v)
	var top := _hbox(8)
	v.add_child(top)
	var nm := _name_label(16)
	nm.text = m["name"]
	top.add_child(nm)
	var pill := UI.pill("", UI.DIM)
	top.add_child(pill)
	var blurb := UI.wrap(UI.caption(m["blurb"]))
	blurb.add_theme_font_size_override("font_size", 13)
	blurb.custom_minimum_size.y = 40
	v.add_child(blurb)
	if m.get("only", "") == "slop":
		v.add_child(UI.pill("slop only", UI.AMBER))
	_kv(v, "Smartness", "%s" % _pips(int(m["smart"])), UI.PURPLE.lightened(0.3))
	_kv(v, "Productivity", "x%s" % _x(m["productivity"]), UI.GREEN)
	_kv(v, "Reliability", "%d%%" % roundi(float(m["reliability"]) * 100.0), UI.CYAN)
	_kv(v, "Speed", "x%s" % _x(m["speed"]), UI.AMBER)
	var unlocks := UI.wrap(UI.caption(_unlocks(m)))
	unlocks.add_theme_font_size_override("font_size", 13)
	unlocks.custom_minimum_size.y = 34
	v.add_child(unlocks)
	var btns := _hbox(6)
	v.add_child(btns)
	var use := UI.btn("Use", "primary", 14)
	use.size_flags_horizontal = SIZE_EXPAND_FILL
	use.pressed.connect(func() -> void: world.request_company("use", [key]))
	btns.add_child(use)
	var buy := UI.btn("Buy", "success", 14)
	buy.size_flags_horizontal = SIZE_EXPAND_FILL
	buy.pressed.connect(func() -> void: world.request_company("buy", [key]))
	btns.add_child(buy)
	return {"root": c, "pill": pill, "use": use, "buy": buy}


func _unlocks(m: Dictionary) -> String:
	var slop := 0
	for k: String in Data.SLOP:
		if Data.can_make(m, "slop", k) == "":
			slop += 1
	var prod := 0
	for k: String in Data.PRODUCTS:
		if Data.can_make(m, "product", k) == "":
			prod += 1
	var text := "Makes %d of %d slop, %d of %d products. Writes code up to level %d." % [slop, Data.SLOP.size(), prod, Data.PRODUCTS.size(), Data.code_cap(m)]
	if int(m["smart"]) >= Data.PLATFORM_TIER:
		text += " Opens the API platform."
	return text


func _upd_lab() -> void:
	var co := _co()
	var models: Dictionary = co["models"]
	var active: String = co["active"]
	for key: String in models:
		if not _lb["cards"].has(key):
			_lb["cards"][key] = _make_model_card(key)
			var g: int = 0 if bool(models[key].get("own", false)) else int(models[key]["smart"])
			_lb["groups"][g]["grid"].add_child(_lb["cards"][key]["root"])
		var card: Dictionary = _lb["cards"][key]
		var m: Dictionary = models[key]
		var is_active := key == active
		var owned: bool = m["owned"]
		var bg := Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.16) if is_active else (Color(0.05, 0.13, 0.12) if owned else UI.BG_DARK)
		var edge := UI.ACCENT if is_active else (UI.GREEN.darkened(0.45) if owned else UI.BORDER.darkened(0.3))
		card["root"].add_theme_stylebox_override("panel", UI.box(bg, 12, edge, 12))
		var rent: float = m["rent"]
		var price: float = m["price"]
		if is_active:
			UI.pill_set(card["pill"], "IN USE" if owned else "RENTED, %s/min" % UI.cash(rent), UI.GREEN if owned else UI.AMBER)
		elif bool(m.get("own", false)):
			UI.pill_set(card["pill"], "YOURS", UI.PURPLE)
		elif owned:
			UI.pill_set(card["pill"], "OWNED", UI.GREEN)
		elif rent < 0.0:
			UI.pill_set(card["pill"], "BUY ONLY", UI.CYAN)
		elif price < 0.0:
			UI.pill_set(card["pill"], "SUBSCRIPTION", UI.AMBER)
		else:
			UI.pill_set(card["pill"], "%s/min" % UI.cash(rent), UI.AMBER)
		var use: Button = card["use"]
		var buy: Button = card["buy"]
		buy.visible = not owned and price >= 0.0
		use.visible = owned or rent >= 0.0
		if is_active:
			use.disabled = true
			use.text = "In use" if owned else "Renting  %s/min" % UI.cash(rent)
		elif owned:
			use.disabled = false
			use.text = "Use"
		else:
			use.disabled = world.money <= 0.0
			use.text = "Rent  %s/min" % UI.cash(rent)
			use.tooltip_text = "Pay by the minute, stop any time" if not use.disabled else "No money, no licence"
		buy.disabled = price > world.money
		buy.text = "Buy  %s" % UI.cash(price)
		buy.tooltip_text = "Own it for good: no more licence fees" if not buy.disabled else "You need %s" % UI.cash(price)

	for g: int in _lb["groups"]:
		var has: bool = (_lb["groups"][g]["grid"] as Control).get_child_count() > 0
		_lb["groups"][g]["head"].visible = has
		_lb["groups"][g]["grid"].visible = has
	var model: Dictionary = models[active]
	var stack: Dictionary = co["stack"]
	var coding: Dictionary = co["coding"]
	var cap := Data.code_cap(model)
	var tokens: float = co["tokens"]
	_lb["code_box"].visible = not coding.is_empty()
	if not coding.is_empty():
		_lb["code_name"].text = "Writing %s, level %d" % [Data.COMPONENTS[coding["part"]]["name"], coding["level"]]
		_lb["code_eta"].text = "%s left" % UI.mmss(coding["left"])
		(_lb["code_bar"] as ProgressBar).value = 1.0 - float(coding["left"]) / maxf(float(coding["total"]), 0.001)
		_lb["code_info"].text = "%d%% chance it does not even run (it imports a library that does not exist)." % roundi(float(coding["fail"]) * 100.0)
	for key: String in _lb["parts"]:
		var part: Dictionary = _lb["parts"][key]
		var level: int = stack[key]
		var next := level + 1
		part["pips"].text = _pips(level, Data.MAX_CODE)
		var reason := ""
		if next > Data.MAX_CODE:
			reason = "Maxed out"
			part["info"].text = "Level %d: as good as code gets." % level
		else:
			part["info"].text = "Level %d: %s tokens, %s, %d%% it fails" % [next, UI.short(Data.code_cost(next)), UI.mmss(Data.code_time(next) / float(model["speed"])), roundi(Data.code_fail(model) * 100.0)]
			if not coding.is_empty():
				reason = "Busy writing"
			elif next > cap:
				reason = "Model too weak"
				part["info"].text = "%s can only write up to level %d." % [model["name"], cap]
			elif Data.code_cost(next) > tokens:
				reason = "Needs %s tokens" % UI.short(Data.code_cost(next))
		_set_enabled(part["btn"], reason, "Write level %d" % next)

	var plan: Dictionary = co["plan"]
	var training: Dictionary = co["training"]
	var p: Dictionary = plan if training.is_empty() else training["plan"]
	_lb["p_smart"].text = "%s  %d" % [_pips(int(p["smart"])), p["smart"]]
	_lb["p_prod"].text = "x%s" % _x(p["productivity"])
	_lb["p_rel"].text = "%d%%" % roundi(float(p["reliability"]) * 100.0)
	_lb["p_speed"].text = "x%s" % _x(p["speed"])
	_lb["p_cost"].text = "%s tokens" % UI.short(p["tokens"])
	_lb["p_cost"].add_theme_color_override("font_color", UI.RED if float(p["tokens"]) > tokens and training.is_empty() else UI.PURPLE.lightened(0.3))
	_lb["p_time"].text = UI.mmss(p["time"])
	_lb["p_fail"].text = "%d%%" % roundi(float(p["fail"]) * 100.0)
	var reason := ""
	if not training.is_empty():
		reason = "Already training"
	elif not bool(plan["ready"]):
		reason = "Every part needs level 1 first"
	elif float(plan["tokens"]) > float(co["storage"]):
		reason = "Needs more storage: next funding stage"
	elif float(plan["tokens"]) > tokens:
		reason = "Needs %s tokens" % UI.short(plan["tokens"])
	_set_enabled(_lb["train"], reason, "%s  Train a smartness %d model" % [UI.ic("science"), plan["smart"]])
	_lb["train_box"].visible = not training.is_empty()
	if not training.is_empty():
		_lb["train_name"].text = "Training a smartness %d model" % p["smart"]
		_lb["train_eta"].text = "%s left" % UI.mmss(training["left"])
		(_lb["train_bar"] as ProgressBar).value = 1.0 - float(training["left"]) / maxf(float(training["total"]), 0.001)


# --- platform -----------------------------------------------------------------------------------------

func _build_platform() -> Control:
	var page := _page()
	page.add_child(UI.section("API platform", "Sell tokens to other people's apps, one request at a time.", "dns", UI.CYAN))
	_pf["locked"] = UI.card(28)
	page.add_child(_pf["locked"])
	var lv := _vbox(12)
	_pf["locked"].add_child(lv)
	var lh := _hbox(14)
	lv.add_child(lh)
	lh.add_child(UI.chip("lock", UI.AMBER, 52))
	var lt := _vbox(2)
	lh.add_child(lt)
	lt.add_child(UI.bold("The platform is locked", 20))
	lt.add_child(UI.wrap(UI.caption("Nobody pays for tokens from a toy model. Use a model of smartness %d or better (rented, bought or your own), then come back to find users." % Data.PLATFORM_TIER)))
	var go := UI.btn("Open the Model Lab", "purple", 16)
	go.size_flags_horizontal = SIZE_SHRINK_BEGIN
	go.pressed.connect(func() -> void: _go("lab"))
	lv.add_child(go)

	_pf["open"] = _vbox(14)
	page.add_child(_pf["open"])
	var open: VBoxContainer = _pf["open"]
	var tiles := _hbox(12)
	open.add_child(tiles)
	_pf["users"] = UI.tile("Users", "group", UI.CYAN, 14)
	_pf["want"] = UI.tile("They want", "speed", UI.PURPLE, 14)
	_pf["served"] = UI.tile("You serve", "bolt", UI.GREEN, 14)
	_pf["price"] = UI.tile("Price per token", "sell", UI.AMBER, 14)
	_pf["rev"] = UI.tile("Revenue now", "payments", UI.GREEN, 14)
	for k: String in ["users", "want", "served", "price", "rev"]:
		tiles.add_child(_pf[k]["root"])

	var share := UI.card(18)
	open.add_child(share)
	var sv := _vbox(10)
	share.add_child(sv)
	sv.add_child(UI.section("Reserve production", "Share of the tokens your servers make that goes to platform users first. The rest is stored.", "tune", UI.CYAN))
	var sr := _hbox(16)
	sv.add_child(sr)
	_pf["slider"] = HSlider.new()
	_pf["slider"].min_value = 0.0
	_pf["slider"].max_value = 1.0
	_pf["slider"].step = 0.05
	_pf["slider"].custom_minimum_size = Vector2(300, 28)
	_pf["slider"].size_flags_horizontal = SIZE_EXPAND_FILL
	_pf["slider"].size_flags_vertical = SIZE_SHRINK_CENTER
	UI.style_slider(_pf["slider"])
	_pf["slider"].drag_started.connect(func() -> void: _dragging = true)
	_pf["slider"].drag_ended.connect(func(_changed: bool) -> void:
		_dragging = false
		_share_hold = Time.get_ticks_msec() + 1200
		world.request_company("share", [snappedf(_pf["slider"].value, 0.05)]))
	_pf["slider"].value_changed.connect(func(value: float) -> void: _share_text(value))
	sr.add_child(_pf["slider"])
	_pf["share_val"] = UI.big("0%", UI.CYAN, 26)
	_pf["share_val"].custom_minimum_size.x = 90
	_pf["share_val"].horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sr.add_child(_pf["share_val"])
	_pf["share_note"] = UI.wrap(UI.caption(""))
	_pf["share_note"].add_theme_font_size_override("font_size", 14)
	sv.add_child(_pf["share_note"])

	var camp := UI.card(18)
	open.add_child(camp)
	var cv := _vbox(12)
	camp.add_child(cv)
	cv.add_child(UI.section("Marketing campaigns", "Cost real money, bring users. One at a time. Results depend on luck.", "campaign", UI.PURPLE))
	_pf["run_box"] = UI.inset(14)
	cv.add_child(_pf["run_box"])
	var rv := _vbox(8)
	_pf["run_box"].add_child(rv)
	var rh := _hbox(8)
	rv.add_child(rh)
	_pf["run_name"] = _name_label(16)
	rh.add_child(_pf["run_name"])
	_pf["run_eta"] = UI.bold("", 15, UI.PURPLE.lightened(0.3))
	rh.add_child(_pf["run_eta"])
	_pf["run_bar"] = UI.bar(0.0, UI.PURPLE, 10)
	rv.add_child(_pf["run_bar"])
	_pf["run_info"] = UI.caption("")
	rv.add_child(_pf["run_info"])
	var crow := _hbox(14)
	cv.add_child(crow)
	_pf["camps"] = {}
	for key: String in Data.CAMPAIGNS:
		var def: Dictionary = Data.CAMPAIGNS[key]
		var c := UI.inset(16, 12)
		_grow(c, 1.0)
		crow.add_child(c)
		var v := _vbox(8)
		c.add_child(v)
		var h := _hbox(8)
		v.add_child(h)
		var nm := _name_label(17)
		nm.text = def["name"]
		h.add_child(nm)
		h.add_child(UI.pill("Gamble" if float(def["luck"]) > 0.5 else "Steady", UI.AMBER if float(def["luck"]) > 0.5 else UI.GREEN))
		var bl := UI.wrap(UI.caption(def["blurb"]))
		v.add_child(bl)
		_kv(v, "Price", UI.cash(def["price"]), UI.GREEN)
		_kv(v, "Reaches", "%s people" % UI.short(def["reach"]))
		_kv(v, "Expect", "about %s new users" % UI.short(float(def["reach"]) * float(def["stay"])), UI.CYAN)
		_kv(v, "Runs for", UI.mmss(def["time"]))
		var b := UI.btn("Launch", "primary", 15)
		b.pressed.connect(func() -> void: world.request_company("advertise", [key]))
		v.add_child(b)
		_pf["camps"][key] = b
	return page


func _share_text(value: float) -> void:
	var co := _co()
	_pf["share_val"].text = "%d%%" % roundi(value * 100.0)
	var rate: float = co.get("rate", 0.0)
	_pf["share_note"].text = "Up to %.1f tok/s of your %.1f tok/s production is held back for the platform." % [rate * value, rate]


func _upd_platform() -> void:
	var co := _co()
	var plat: Dictionary = co["platform"]
	var open: bool = plat["open"]
	_pf["locked"].visible = not open
	_pf["open"].visible = open
	if not open:
		return
	var served: float = plat["served"]
	var want: float = plat["want"]
	_pf["users"]["value"].text = UI.short(plat["users"])
	_pf["users"]["sub"].text = "using the platform"
	_pf["want"]["value"].text = "%.1f tok/s" % want
	_pf["want"]["sub"].text = "what they would like"
	_pf["served"]["value"].text = "%.1f tok/s" % served
	var short: bool = want > 0.0 and served < want * 0.8
	_pf["served"]["value"].add_theme_color_override("font_color", UI.RED if short else UI.GREEN)
	_pf["served"]["sub"].text = "users are leaving: reserve more" if short else ("everybody is served" if want > 0.0 else "no users yet")
	_pf["price"]["value"].text = "$%.2f" % plat["price"]
	_pf["price"]["sub"].text = "per token, model x%.2f" % co["model"]["productivity"]
	_pf["rev"]["value"].text = "%s/min" % UI.cash(served * float(plat["price"]) * 60.0)
	_pf["rev"]["sub"].text = "from the platform alone"
	var slider: HSlider = _pf["slider"]
	if not _dragging and Time.get_ticks_msec() > _share_hold:
		slider.set_value_no_signal(float(plat["share"]))
		_share_text(float(plat["share"]))
	var camp: Dictionary = plat["campaign"]
	var running := not camp.is_empty()
	_pf["run_box"].visible = running
	if running:
		var def: Dictionary = Data.CAMPAIGNS[camp["kind"]]
		_pf["run_name"].text = "Running: %s" % def["name"]
		_pf["run_eta"].text = "%s left" % UI.mmss(camp["left"])
		(_pf["run_bar"] as ProgressBar).value = 1.0 - float(camp["left"]) / maxf(float(camp["total"]), 0.001)
		_pf["run_info"].text = "Expected to bring about %s users in total." % UI.short(camp["gain"])
	for key: String in _pf["camps"]:
		var price: float = Data.CAMPAIGNS[key]["price"]
		var reason := ""
		if running:
			reason = "A campaign is running"
		elif price > world.money:
			reason = "Needs %s" % UI.cash(price)
		_set_enabled(_pf["camps"][key], reason, "%s  Launch  %s" % [UI.ic("campaign"), UI.cash(price)])


# --- market -------------------------------------------------------------------------------------------

func _build_market() -> Control:
	var page := _page()
	page.add_child(UI.section("Token market", "The raw price is bad on purpose. Slop and products pay far better.", "show_chart", UI.AMBER))
	var row := _hbox(14)
	page.add_child(row)
	var spot := UI.card(20)
	_grow(spot, 1.0)
	row.add_child(spot)
	var sv := _vbox(8)
	spot.add_child(sv)
	sv.add_child(UI.caption("RAW TOKEN PRICE"))
	var sh := _hbox(12)
	sv.add_child(sh)
	_mk["spot"] = UI.big("", UI.TEXT, 44)
	sh.add_child(_mk["spot"])
	_mk["trend"] = UI.pill("", UI.DIM)
	sh.add_child(_mk["trend"])
	_mk["range"] = UI.bar(0.0, UI.AMBER, 10)
	sv.add_child(_mk["range"])
	var rr := _hbox(8)
	sv.add_child(rr)
	rr.add_child(_grow(UI.caption("$%.2f low" % Data.SPOT_MIN)))
	rr.add_child(UI.caption("$%.2f high" % Data.SPOT_MAX))
	sv.add_child(UI.caption("The price drifts every 10 seconds."))

	var stock := UI.card(20)
	_grow(stock, 1.0)
	row.add_child(stock)
	var kv := _vbox(8)
	stock.add_child(kv)
	kv.add_child(UI.caption("YOUR STORED TOKENS"))
	_mk["tokens"] = UI.big("", UI.PURPLE.lightened(0.2), 44)
	kv.add_child(_mk["tokens"])
	_mk["worth"] = UI.body("", UI.GREEN)
	kv.add_child(_mk["worth"])
	_mk["fill"] = UI.bar(0.0, UI.PURPLE, 10)
	kv.add_child(_mk["fill"])
	_mk["cap"] = UI.caption("")
	kv.add_child(_mk["cap"])

	var sell := UI.card(20)
	page.add_child(sell)
	var cv := _vbox(12)
	sell.add_child(cv)
	cv.add_child(UI.section("Sell raw tokens", "Instant cash, no slot needed.", "sell", UI.AMBER))
	var br := _hbox(12)
	cv.add_child(br)
	_mk["sell"] = []
	for entry: Array in [[0.25, "Sell 25%"], [0.5, "Sell 50%"], [0.0, "Sell everything"]]:
		var frac: float = entry[0]
		var b := UI.btn("", "secondary", 16)
		b.custom_minimum_size.y = 64
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void:
			var have: float = _co()["tokens"]
			world.request_company("sell", [0.0 if frac <= 0.0 else floorf(have * frac)]))
		br.add_child(b)
		_mk["sell"].append([b, frac, entry[1]])

	var cmp := UI.inset(18)
	page.add_child(cmp)
	var ch := _hbox(14)
	cmp.add_child(ch)
	_mk["cmp_chip"] = UI.chip("trending_up", UI.GREEN, 40)
	_mk["cmp_chip"].size_flags_vertical = SIZE_SHRINK_BEGIN
	ch.add_child(_mk["cmp_chip"])
	var ct := _vbox(2)
	ch.add_child(ct)
	ct.add_child(UI.bold("Is selling worth it?", 17))
	_mk["cmp"] = UI.wrap(UI.body("", UI.DIM))
	ct.add_child(_mk["cmp"])
	return page


func _upd_market() -> void:
	var co := _co()
	var tokens: float = co["tokens"]
	var spot: float = co["spot"]
	var trend: int = co["spot_trend"]
	_mk["spot"].text = "$%.3f" % spot
	var trend_icon := "trending_up" if trend > 0 else ("trending_down" if trend < 0 else "trending_flat")
	var trend_color := UI.GREEN if trend > 0 else (UI.RED if trend < 0 else UI.DIM)
	UI.pill_set(_mk["trend"], "%s  %s" % [UI.ic(trend_icon), "rising" if trend > 0 else ("falling" if trend < 0 else "steady")], trend_color)
	(_mk["range"] as ProgressBar).value = clampf((spot - Data.SPOT_MIN) / (Data.SPOT_MAX - Data.SPOT_MIN), 0.0, 1.0)
	_mk["tokens"].text = "%s tokens" % UI.short(tokens)
	_mk["worth"].text = "Worth %s at today's price" % UI.cash(tokens * spot)
	(_mk["fill"] as ProgressBar).value = tokens / maxf(float(co["storage"]), 1.0)
	_mk["cap"].text = "of %s storage" % UI.short(co["storage"])
	for entry: Array in _mk["sell"]:
		var b: Button = entry[0]
		var frac: float = entry[1]
		var amount := tokens if frac <= 0.0 else floorf(tokens * frac)
		b.disabled = amount < 1.0
		b.text = "%s\n%s tokens for %s" % [entry[2], UI.short(amount), UI.cash(amount * spot)]

	# the honest comparison: the same tokens as the best slop we can afford right now
	var quality: float = co["model"]["productivity"]
	var best_key := ""
	var best_ratio := 0.0
	for key: String in Data.SLOP:
		var def: Dictionary = Data.SLOP[key]
		if int(def["level"]) > int(co["level"]) or float(def["tokens"]) > tokens or Data.can_make(co["models"][co["active"]], "slop", key) != "":
			continue
		var ratio := _slop_lifetime(def, quality) / float(def["tokens"])
		if ratio > best_ratio:
			best_ratio = ratio
			best_key = key
	if best_key == "":
		_mk["cmp"].text = "You cannot afford any slop yet (the cheapest takes %s tokens). Selling is all you can do, but waiting for more tokens pays better." % UI.short(Data.SLOP["seo"]["tokens"])
		UI.chip_set(_mk["cmp_chip"], "info", UI.DIM)
	else:
		var def: Dictionary = Data.SLOP[best_key]
		var cost: float = def["tokens"]
		var as_slop := _slop_lifetime(def, quality)
		var as_cash := cost * spot
		var extra := "" if _free_slots() > 0 else " (all your slots are busy right now)"
		_mk["cmp"].text = "Put %s tokens into %s and it earns about %s over its life. Sold raw, the same tokens fetch %s. That is %.1fx more%s." % [
			UI.short(cost), def["name"], UI.cash(as_slop), UI.cash(as_cash), as_slop / maxf(as_cash, 0.01), extra]
		UI.chip_set(_mk["cmp_chip"], "trending_up", UI.GREEN)


## Everything a slop entry earns before its hype is gone: the area under peak * 0.5^(t/half_life).
func _slop_lifetime(def: Dictionary, quality: float) -> float:
	return float(def["income"]) * quality * float(def["half_life"]) / (60.0 * log(2.0))
