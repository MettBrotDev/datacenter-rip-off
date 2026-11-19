extends Control
## The haggling overlay: make a neighbour an offer for their house.
## They never say what they want; you find out by trying (and by annoying them).

const UI = preload("res://scripts/ui.gd")
const STEP := 500

signal closed

var world: Node3D

var _house := -1
var _amount := 0
var _title: Label
var _line: Label
var _value: Label
var _offer: Label
var _slider: HSlider
var _send: Button


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
	card.custom_minimum_size.x = 560
	center.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	card.add_child(v)

	_title = UI.label("", 26)
	v.add_child(_title)
	var bubble := PanelContainer.new()
	bubble.add_theme_stylebox_override("panel", UI.box(UI.BG_DARK, 10, UI.BORDER, 14))
	v.add_child(bubble)
	_line = UI.label("", 19)
	_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_line.custom_minimum_size.y = 56
	bubble.add_child(_line)
	_value = UI.label("", 15, UI.DIM)
	v.add_child(_value)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	v.add_child(row)
	var less := UI.button("  -  ")
	less.pressed.connect(func(): _set_amount(_amount - STEP))
	row.add_child(less)
	_slider = HSlider.new()
	_slider.step = STEP
	_slider.size_flags_horizontal = SIZE_EXPAND_FILL
	_slider.size_flags_vertical = SIZE_SHRINK_CENTER
	_slider.value_changed.connect(func(value: float): _set_amount(int(value)))
	row.add_child(_slider)
	var more := UI.button("  +  ")
	more.pressed.connect(func(): _set_amount(_amount + STEP))
	row.add_child(more)
	_offer = UI.label("", 24, UI.GREEN)
	_offer.custom_minimum_size.x = 130
	_offer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_offer)

	_send = UI.button("Make this offer", true)
	_send.pressed.connect(func(): world.request_offer(_house, _amount))
	v.add_child(_send)
	var leave := UI.button("Walk away  [Esc]")
	leave.pressed.connect(func(): closed.emit())
	v.add_child(leave)


func open(house_id: int) -> void:
	_house = house_id
	var lot: Dictionary = world.houses[house_id].lot
	_title.text = "The house of %s" % lot["name"]
	_line.text = "You want to buy my house? Hm. Make me an offer."
	_value.text = "Houses like this go for around %s. What they would actually take is anyone's guess." % UI.money(lot["value"])
	_slider.min_value = STEP
	_slider.max_value = lot["value"] * 3
	_send.show()
	_set_amount(lot["value"])
	show()


func reply(house_id: int, text: String, accepted: bool) -> void:
	if house_id != _house:
		return
	_line.text = text
	if accepted:
		_send.hide()
		_value.text = "It is yours. The door is unlocked and the wiring is live."


## Call when the company balance changes.
func refresh() -> void:
	if visible:
		_set_amount(_amount)


func _set_amount(amount: int) -> void:
	_amount = clampi(amount, int(_slider.min_value), int(_slider.max_value))
	_slider.set_value_no_signal(_amount)
	_offer.text = UI.money(_amount)
	var short: float = _amount - world.money
	_send.disabled = short > 0.0
	_send.text = "Make this offer" if short <= 0.0 else "You are %s short" % UI.money(short)
