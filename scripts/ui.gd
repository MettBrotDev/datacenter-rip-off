extends RefCounted
## Shared UI look: dark navy cards, rounded corners, blue accent.

const BG := Color(0.055, 0.085, 0.16, 0.93)
const BG_DARK := Color(0.03, 0.045, 0.09)
const BORDER := Color(0.16, 0.24, 0.42)
const ACCENT := Color(0.1, 0.55, 1.0)
const TEXT := Color(0.92, 0.95, 1.0)
const DIM := Color(0.6, 0.68, 0.82)
const GREEN := Color(0.2, 0.9, 0.55)
const RED := Color(1.0, 0.35, 0.4)


static func box(bg := BG, radius := 10, border := BORDER, margin := 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_corner_radius_all(radius)
	s.set_border_width_all(1)
	s.set_content_margin_all(margin)
	return s


static func panel(margin := 12) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(BG, 10, BORDER, margin))
	return p


static func label(text: String, size := 18, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func button(text: String, primary := false) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 18)
	var base := ACCENT if primary else Color(0.09, 0.14, 0.26)
	b.add_theme_stylebox_override("normal", box(base, 8, base.lightened(0.15), 10))
	b.add_theme_stylebox_override("hover", box(base.lightened(0.12), 8, base.lightened(0.3), 10))
	b.add_theme_stylebox_override("pressed", box(base.darkened(0.15), 8, base, 10))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


static func field(placeholder: String, text := "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.add_theme_font_size_override("font_size", 18)
	e.add_theme_stylebox_override("normal", box(BG_DARK, 8, BORDER, 10))
	e.add_theme_stylebox_override("focus", box(BG_DARK, 8, ACCENT, 10))
	return e


## 1234567.8 -> "$1,234,568"
static func money(value: float) -> String:
	var digits := str(int(round(absf(value))))
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += ","
		out += digits[i]
	return ("-$" if value < 0.0 else "$") + out
