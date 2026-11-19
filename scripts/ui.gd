extends RefCounted
## Shared UI design system: colour tokens, fonts, text styles, cards, buttons, badges, bars, tiles.
## Deep navy translucent cards, thin blue borders, Inter text, Material icon glyphs.
##
## Call `setup()` once at startup (main.gd does): it loads the fonts and restyles Godot's default
## theme, so even plain widgets (scrollbars, sliders, tooltips, popups) match.
## Icons are glyphs of the Material Icons font, which is a fallback of the text font:
## `UI.ic("bolt")` returns the character, so "icon + text" works inside any Label or Button.

# --- colour tokens ------------------------------------------------------------------------
const BG_PAGE := Color(0.035, 0.055, 0.11)
const BG := Color(0.065, 0.1, 0.19, 0.93)          # cards
const BG_DARK := Color(0.03, 0.05, 0.1)            # inset areas, fields, bar troughs
const BG_RAISED := Color(0.09, 0.14, 0.26)         # buttons, rows
const BORDER := Color(0.16, 0.25, 0.44)
const ACCENT := Color(0.12, 0.5, 1.0)              # blue: primary
const TEXT := Color(0.92, 0.95, 1.0)
const DIM := Color(0.6, 0.68, 0.82)
const FAINT := Color(0.4, 0.48, 0.64)
const GREEN := Color(0.2, 0.9, 0.55)               # money
const RED := Color(1.0, 0.35, 0.4)
const AMBER := Color(1.0, 0.72, 0.25)
const PURPLE := Color(0.66, 0.5, 1.0)              # tokens
const CYAN := Color(0.3, 0.82, 0.95)

const FONT_DIR := "res://fonts/"

static var _font: Font
static var _bold: Font
static var _icons: Font
static var _codes: Dictionary = {}
static var _switch: Dictionary = {}
static var _ready_done := false


# --- setup --------------------------------------------------------------------------------

## Loads the fonts and restyles the default theme. Safe to call twice.
static func setup() -> void:
	if _ready_done:
		return
	_ready_done = true
	var base := _load_font("Inter.ttf")
	_icons = _load_font("MaterialIcons-Regular.ttf")
	if base != null:
		if _icons != null:
			base.fallbacks = [_icons]
		_font = base
		var bold := FontVariation.new()
		bold.base_font = base
		bold.variation_opentype = {2003265652: 650}   # the 'wght' axis tag
		if _icons != null:
			bold.fallbacks = [_icons]
		_bold = bold
		ThemeDB.fallback_font = base
	ThemeDB.fallback_font_size = 16
	_restyle_default_theme()


static func _load_font(file: String) -> FontFile:
	if not FileAccess.file_exists(FONT_DIR + file):
		return null
	var f := FontFile.new()
	var bytes := FileAccess.get_file_as_bytes(FONT_DIR + file)
	if bytes.is_empty():
		return null
	f.data = bytes
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	if file.begins_with("Inter"):
		f.hinting = TextServer.HINTING_NONE
		f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
		f.generate_mipmaps = true
	return f


## The glyph of a Material icon, as a one-character string ("" if the name is unknown).
static func ic(name: String) -> String:
	if _codes.is_empty():
		var file := FileAccess.open(FONT_DIR + "MaterialIcons-Regular.codepoints", FileAccess.READ)
		if file == null:
			_codes["_"] = ""
		else:
			while not file.eof_reached():
				var parts := file.get_line().split(" ")
				if parts.size() == 2:
					_codes[parts[0]] = String.chr(("0x" + parts[1]).hex_to_int())
	return _codes.get(name, "")


static func bold_font() -> Font:
	return _bold


# --- formatting ---------------------------------------------------------------------------

## 1234567.8 -> "$1,234,568"
static func money(value: float) -> String:
	return ("-$" if value < 0.0 and roundf(absf(value)) > 0.0 else "$") + num(absf(value))


## 1234567.8 -> "1,234,568"
static func num(value: float) -> String:
	var digits := str(int(round(absf(value))))
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += ","
		out += digits[i]
	return ("-" if value < 0.0 and out != "0" else "") + out


## Compact numbers: 9,500 / 12.5k / 120k / 1.2M / 35M / 1.5B. Exact below 10,000.
static func short(value: float) -> String:
	var a := absf(value)
	if a < 1e4:
		return num(value)
	var unit := "k"
	var scaled := a / 1e3
	if a >= 1e9:
		unit = "B"
		scaled = a / 1e9
	elif a >= 1e6:
		unit = "M"
		scaled = a / 1e6
	var text := ("%.0f" if scaled >= 100.0 else "%.1f") % scaled
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return ("-" if value < 0.0 else "") + text + unit


## Compact money: $9,500 / $12.5k / $1.2M.
static func cash(value: float) -> String:
	return ("-$" if value < 0.0 and roundf(absf(value)) > 0.0 else "$") + short(absf(value))


## Seconds -> "m:ss".
static func mmss(seconds: float) -> String:
	var s := maxi(0, int(ceil(seconds)))
	return "%d:%02d" % [s / 60, s % 60]


# --- boxes --------------------------------------------------------------------------------

static func box(bg := BG, radius := 10, border := BORDER, margin := 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_corner_radius_all(radius)
	s.set_border_width_all(1)
	s.set_content_margin_all(margin)
	s.anti_aliasing_size = 0.8
	return s


## A translucent navy card with a thin blue border.
static func panel(margin := 12) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(BG, 12, BORDER, margin))
	return p


## Same as `panel` under the design-system name.
static func card(margin := 16) -> PanelContainer:
	return panel(margin)


## A darker inset area inside a card (rows, bubbles).
static func inset(margin := 12, radius := 9) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(BG_DARK, radius, BORDER.darkened(0.3), margin))
	return p


## A light, see-through panel for the in-game HUD: it sits on top of the 3D view.
static func hud_panel(margin := 10) -> PanelContainer:
	var p := PanelContainer.new()
	var s := box(Color(0.035, 0.06, 0.12, 0.72), 10, Color(0.3, 0.45, 0.75, 0.35), margin)
	p.add_theme_stylebox_override("panel", s)
	return p


# --- text ---------------------------------------------------------------------------------

static func label(text: String, size := 18, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## A bold label.
static func bold(text: String, size := 18, color := TEXT) -> Label:
	var l := label(text, size, color)
	if _bold != null:
		l.add_theme_font_override("font", _bold)
	return l


static func title(text: String, color := TEXT) -> Label:
	return bold(text, 30, color)


static func heading(text: String, color := TEXT) -> Label:
	return bold(text, 20, color)


static func body(text: String, color := TEXT) -> Label:
	return label(text, 16, color)


static func caption(text: String, color := DIM) -> Label:
	return label(text, 13, color)


static func big(text: String, color := TEXT, size := 32) -> Label:
	return bold(text, size, color)


## A label that wraps. Give it a width through its container (or `custom_minimum_size.x`).
static func wrap(l: Label) -> Label:
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


## A bare icon glyph as a label.
static func icon(name: String, size := 20, color := TEXT) -> Label:
	var l := label(ic(name), size, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


## A coloured rounded square with an icon in it.
static func chip(icon_name: String, color := ACCENT, size := 40) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var s := box(Color(color.r, color.g, color.b, 0.2), int(size * 0.28), Color(color.r, color.g, color.b, 0.45), 0)
	p.add_theme_stylebox_override("panel", s)
	var l := icon(icon_name, int(size * 0.56), color.lightened(0.25))
	l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(l)
	return p


## Change the icon and colour of a chip made by `chip`.
static func chip_set(p: PanelContainer, icon_name: String, color: Color) -> void:
	var size := p.custom_minimum_size.x
	p.add_theme_stylebox_override("panel", box(Color(color.r, color.g, color.b, 0.2), int(size * 0.28), Color(color.r, color.g, color.b, 0.45), 0))
	var l := p.get_child(0) as Label
	l.text = ic(icon_name)
	l.add_theme_color_override("font_color", color.lightened(0.25))


## A small rounded badge ("LIVE", "Locked", "x1.5").
static func pill(text: String, color := ACCENT) -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var l := bold(text, 12, color.lightened(0.3))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	pill_set(p, text, color)
	return p


static func pill_set(p: PanelContainer, text: String, color: Color) -> void:
	var s := box(Color(color.r, color.g, color.b, 0.18), 20, Color(color.r, color.g, color.b, 0.4), 3)
	s.content_margin_left = 9
	s.content_margin_right = 9
	p.add_theme_stylebox_override("panel", s)
	var l := p.get_child(0) as Label
	l.text = text
	l.add_theme_color_override("font_color", color.lightened(0.3))


## A slim progress bar, 0..1.
static func bar(value := 0.0, color := ACCENT, height := 8) -> ProgressBar:
	var b := ProgressBar.new()
	b.min_value = 0.0
	b.max_value = 1.0
	b.step = 0.0
	b.value = value
	b.show_percentage = false
	b.custom_minimum_size.y = height
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_stylebox_override("background", box(BG_DARK, height / 2, BORDER.darkened(0.35), 0))
	bar_color(b, color)
	return b


static func bar_color(b: ProgressBar, color: Color) -> void:
	var s := box(color, int(b.custom_minimum_size.y / 2), color.lightened(0.2), 0)
	s.set_border_width_all(0)
	b.add_theme_stylebox_override("fill", s)


## "Title / big value / sub text" with a chip on the left. Returns {root, value, sub, chip}.
static func tile(title_text: String, icon_name: String, color := ACCENT, margin := 14) -> Dictionary:
	var root := card(margin)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	root.add_child(row)
	var c := chip(icon_name, color, 38)
	c.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(c)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 0)
	row.add_child(col)
	col.add_child(bold(title_text.to_upper(), 12, DIM))
	var value := big("-", TEXT, 24)
	col.add_child(value)
	var sub := caption("")
	col.add_child(sub)
	return {"root": root, "value": value, "sub": sub, "chip": c, "col": col}


## A section header: optional chip, bold title, small dim subtitle.
static func section(title_text: String, subtitle := "", icon_name := "", color := ACCENT) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	if icon_name != "":
		row.add_child(chip(icon_name, color, 34))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(col)
	col.add_child(heading(title_text))
	if subtitle != "":
		col.add_child(caption(subtitle))
	return row


## A thin horizontal rule.
static func rule() -> HSeparator:
	var h := HSeparator.new()
	var s := StyleBoxLine.new()
	s.color = BORDER.darkened(0.2)
	s.thickness = 1
	h.add_theme_stylebox_override("separator", s)
	return h


static func tip(c: Control, text: String) -> void:
	c.tooltip_text = text


## A vertical scroll area without the horizontal bar.
static func scroll() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	return s


# --- buttons ------------------------------------------------------------------------------

static func button(text: String, primary := false) -> Button:
	return btn(text, "primary" if primary else "secondary")


## kind: "primary" (blue), "secondary", "success" (green), "purple", "danger" (red), "ghost" (no fill).
static func btn(text: String, kind := "secondary", size := 16) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_size_override("font_size", size)
	if _bold != null:
		b.add_theme_font_override("font", _bold)
	style_button(b, kind)
	return b


static func style_button(b: Button, kind: String) -> void:
	var base: Color
	var border: Color
	var text := TEXT
	match kind:
		"primary":
			base = ACCENT
			border = ACCENT.lightened(0.25)
		"success":
			base = Color(0.1, 0.6, 0.36)
			border = GREEN.darkened(0.1)
		"purple":
			base = Color(0.42, 0.28, 0.82)
			border = PURPLE
		"danger":
			base = Color(0.55, 0.14, 0.2)
			border = RED.darkened(0.2)
		"ghost":
			base = Color(1, 1, 1, 0.0)
			border = Color(1, 1, 1, 0.0)
			text = DIM
		_:
			base = BG_RAISED
			border = BORDER.lightened(0.1)
	var ghost := kind == "ghost"
	var hover := base.lightened(0.14) if not ghost else Color(1, 1, 1, 0.07)
	var pressed := base.darkened(0.18) if not ghost else Color(1, 1, 1, 0.12)
	b.add_theme_stylebox_override("normal", box(base, 9, border, 10))
	b.add_theme_stylebox_override("hover", box(hover, 9, border.lightened(0.2), 10))
	b.add_theme_stylebox_override("pressed", box(pressed, 9, border, 10))
	b.add_theme_stylebox_override("hover_pressed", box(pressed.lightened(0.05), 9, border.lightened(0.2), 10))
	b.add_theme_stylebox_override("disabled", box(Color(0.07, 0.1, 0.17, 0.0 if ghost else 0.9), 9, Color(0.14, 0.2, 0.33, 0.0 if ghost else 1.0), 10))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", text)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", FAINT)


## A tab: a toggle button, lit up while pressed.
static func tab_button(text: String) -> Button:
	var b := btn(text, "ghost", 15)
	b.toggle_mode = true
	var lit := Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.95)
	b.add_theme_stylebox_override("pressed", box(lit, 9, ACCENT.lightened(0.3), 10))
	b.add_theme_stylebox_override("hover_pressed", box(lit.lightened(0.08), 9, ACCENT.lightened(0.4), 10))
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_color", DIM)
	return b


## A selectable option card (one of a group): lit while pressed.
static func choice_button(text: String, group: ButtonGroup) -> Button:
	var b := btn(text, "secondary", 15)
	b.toggle_mode = true
	b.button_group = group
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var sel := Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.22)
	b.add_theme_stylebox_override("pressed", box(sel, 9, ACCENT, 10))
	b.add_theme_stylebox_override("hover_pressed", box(sel.lightened(0.05), 9, ACCENT.lightened(0.2), 10))
	return b


## Puts an invisible full-size button over a card so the whole card is clickable.
static func click_card(c: PanelContainer, action: Callable) -> void:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var empty := StyleBoxEmpty.new()
	b.add_theme_stylebox_override("normal", empty)
	b.add_theme_stylebox_override("pressed", empty)
	b.add_theme_stylebox_override("focus", empty)
	b.add_theme_stylebox_override("hover", box(Color(1, 1, 1, 0.045), 12, Color(0.4, 0.6, 1.0, 0.6), 0))
	b.pressed.connect(action)
	c.add_child(b)


static func field(placeholder: String, text := "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.add_theme_font_size_override("font_size", 18)
	e.add_theme_stylebox_override("normal", box(BG_DARK, 9, BORDER, 11))
	e.add_theme_stylebox_override("focus", box(BG_DARK, 9, ACCENT, 11))
	e.add_theme_color_override("font_placeholder_color", FAINT)
	e.add_theme_color_override("caret_color", ACCENT)
	e.add_theme_color_override("selection_color", Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.4))
	return e


# --- stock widgets (for places that need them directly) --------------------------------------

static func style_slider(s: HSlider) -> void:
	s.focus_mode = Control.FOCUS_NONE
	s.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	s.add_theme_stylebox_override("slider", _track(BG_DARK, BORDER.darkened(0.2)))
	s.add_theme_stylebox_override("grabber_area", _track(ACCENT, ACCENT))
	s.add_theme_stylebox_override("grabber_area_highlight", _track(ACCENT.lightened(0.15), ACCENT))
	var knob := _knob(Color.WHITE)
	s.add_theme_icon_override("grabber", knob)
	s.add_theme_icon_override("grabber_highlight", _knob(Color(0.75, 0.88, 1.0)))
	s.add_theme_icon_override("grabber_disabled", _knob(FAINT))


static func style_check(c: CheckButton) -> void:
	c.focus_mode = Control.FOCUS_NONE
	c.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var on := _switch_icon(true)
	var off := _switch_icon(false)
	for n in ["checked", "checked_mirrored", "checked_disabled", "checked_disabled_mirrored"]:
		c.add_theme_icon_override(n, on)
	for n in ["unchecked", "unchecked_mirrored", "unchecked_disabled", "unchecked_disabled_mirrored"]:
		c.add_theme_icon_override(n, off)
	var empty := StyleBoxEmpty.new()
	for n in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		c.add_theme_stylebox_override(n, empty)


static func style_option(o: OptionButton) -> void:
	o.focus_mode = Control.FOCUS_NONE
	o.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	style_button(o, "secondary")
	o.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_style_popup(o.get_popup())


static func _style_popup(popup: PopupMenu) -> void:
	popup.add_theme_stylebox_override("panel", box(Color(0.045, 0.07, 0.14), 10, BORDER, 6))
	popup.add_theme_stylebox_override("hover", box(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.35), 7, Color(0, 0, 0, 0), 4))
	popup.add_theme_stylebox_override("separator", StyleBoxEmpty.new())
	popup.add_theme_constant_override("v_separation", 6)
	popup.add_theme_font_size_override("font_size", 16)


static func _track(fill: Color, border: Color) -> StyleBoxFlat:
	var s := box(fill, 4, border, 3)
	s.set_border_width_all(0)
	return s


static func _knob(color: Color) -> ImageTexture:
	var d := 22
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var r := d / 2.0
	for y in d:
		for x in d:
			var dist := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			var a := clampf(r - 1.0 - dist + 0.5, 0.0, 1.0)
			var ring := clampf(dist - (r - 4.5), 0.0, 1.0) * 0.0
			img.set_pixel(x, y, Color(color.r - ring, color.g, color.b, a))
	return ImageTexture.create_from_image(img)


static func _switch_icon(on: bool) -> ImageTexture:
	if _switch.has(on):
		return _switch[on]
	var w := 48
	var h := 26
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var track := ACCENT if on else Color(0.2, 0.27, 0.42)
	var knob_x := w - h / 2.0 if on else h / 2.0
	var kr := h / 2.0 - 4.0
	for y in h:
		for x in w:
			var p := Vector2(x + 0.5, y + 0.5)
			# rounded track: distance to the segment between the two end circles
			var cx := clampf(p.x, h / 2.0, w - h / 2.0)
			var td := p.distance_to(Vector2(cx, h / 2.0))
			var ta := clampf(h / 2.0 - td + 0.5, 0.0, 1.0)
			var kd := p.distance_to(Vector2(knob_x, h / 2.0))
			var ka := clampf(kr - kd + 0.5, 0.0, 1.0)
			var col := track.lerp(Color(0.97, 0.98, 1.0), ka)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, ta))
	var tex := ImageTexture.create_from_image(img)
	_switch[on] = tex
	return tex


# --- the default theme ----------------------------------------------------------------------

static func _restyle_default_theme() -> void:
	var t := ThemeDB.get_default_theme()
	if t == null:
		return
	if _font != null:
		t.default_font = _font
	t.default_font_size = 16
	t.set_color("font_color", "Label", TEXT)
	for kind in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", kind, box(Color(1, 1, 1, 0.03), 5, Color(0, 0, 0, 0), 3))
		t.set_stylebox("scroll_focus", kind, box(Color(1, 1, 1, 0.03), 5, Color(0, 0, 0, 0), 3))
		t.set_stylebox("grabber", kind, box(Color(0.35, 0.5, 0.8, 0.55), 5, Color(0, 0, 0, 0), 3))
		t.set_stylebox("grabber_highlight", kind, box(Color(0.45, 0.62, 0.95, 0.8), 5, Color(0, 0, 0, 0), 3))
		t.set_stylebox("grabber_pressed", kind, box(ACCENT, 5, Color(0, 0, 0, 0), 3))
	t.set_stylebox("panel", "TooltipPanel", box(Color(0.04, 0.065, 0.13, 0.98), 8, BORDER.lightened(0.2), 9))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font_size("font_size", "TooltipLabel", 14)
	t.set_stylebox("normal", "LineEdit", box(BG_DARK, 9, BORDER, 11))
	t.set_stylebox("focus", "LineEdit", box(BG_DARK, 9, ACCENT, 11))
	t.set_color("font_color", "LineEdit", TEXT)
	var popup_panel := box(Color(0.045, 0.07, 0.14), 10, BORDER, 6)
	t.set_stylebox("panel", "PopupMenu", popup_panel)
	t.set_stylebox("hover", "PopupMenu", box(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.35), 7, Color(0, 0, 0, 0), 4))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
