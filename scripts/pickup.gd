extends Node3D
## The pick-up point: a pallet beside the driveway. Put things on it and press the button: a courier
## buys the lot (see World._h_sell). Local frame: centred on the pallet, button on the +Z side.

const Shapes = preload("res://scripts/shapes.gd")
const Fixture = preload("res://scripts/fixture.gd")
const BUTTON_ID := -10
const HALF := Vector2(0.7, 1.0)    # half width (x) and half depth (z) of the pallet
const DECK := 0.16                 # height of its top above the ground

var fixtures: Dictionary = {}


func _ready() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.62, 0.46, 0.28)
	wood.roughness = 0.9
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.4, 0.28, 0.17)
	dark.roughness = 0.9
	var yellow := StandardMaterial3D.new()
	yellow.albedo_color = Color(0.95, 0.78, 0.15)
	yellow.roughness = 0.6
	var body := StaticBody3D.new()
	add_child(body)
	var boxes := []
	for i in 5:   # deck slats
		boxes.append([Vector3(HALF.x * 2.0, 0.03, 0.3), Vector3(0, DECK - 0.015, -HALF.y + 0.15 + i * 0.425), wood])
	for x: float in [-HALF.x + 0.08, 0.0, HALF.x - 0.08]:   # runners
		boxes.append([Vector3(0.14, DECK - 0.03, HALF.y * 2.0), Vector3(x, (DECK - 0.03) * 0.5, 0), dark])
	for z: float in [-HALF.y, HALF.y]:   # corner posts in hazard yellow
		for x: float in [-HALF.x, HALF.x]:
			boxes.append([Vector3(0.08, 0.5, 0.08), Vector3(x, DECK + 0.25, z), yellow])
	for box: Array in boxes:
		add_child(Shapes.instance(Shapes.rounded_box(box[0], 0.012, 1), box[2], box[1]))
		var shape := BoxShape3D.new()
		shape.size = box[0]
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = box[1]
		body.add_child(col)
	# a post at the front with the button and a sign
	add_child(Shapes.instance(Shapes.rounded_box(Vector3(0.1, 1.1, 0.1), 0.02, 1), dark, Vector3(HALF.x - 0.2, 0.55, HALF.y + 0.15)))
	var board := Shapes.instance(Shapes.rounded_box(Vector3(0.7, 0.3, 0.05), 0.02, 1), yellow, Vector3(HALF.x - 0.2, 1.3, HALF.y + 0.15))
	add_child(board)
	var tag := Label3D.new()
	tag.text = "PICK-UP"
	tag.font_size = 48
	tag.pixel_size = 0.0035
	tag.modulate = Color(0.1, 0.1, 0.12)
	tag.outline_size = 0
	tag.position = Vector3(HALF.x - 0.2, 1.3, HALF.y + 0.18)
	add_child(tag)
	var button := Fixture.new()
	button.setup(BUTTON_ID, "sell")
	button.position = Vector3(HALF.x - 0.2, 0.85, HALF.y + 0.2)
	add_child(button)
	fixtures[BUTTON_ID] = button


## Is this world position on the pallet (or stacked above it)?
func holds(pos: Vector3) -> bool:
	var local := to_local(pos)
	return absf(local.x) < HALF.x + 0.15 and absf(local.z) < HALF.y + 0.15 and local.y > 0.0 and local.y < DECK + 1.8
