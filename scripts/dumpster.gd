extends Node3D
## A big open-top skip beside the driveway. Throw or place things into it; the red button on its
## front empties it for good. Local frame: centred on its footprint, long side along X, front +Z.

const Shapes = preload("res://scripts/shapes.gd")
const Fixture = preload("res://scripts/fixture.gd")
const BUTTON_ID := -8
const INNER := Vector3(2.0, 1.0, 1.0)   # inside width, wall height, inside depth
const WALL := 0.08
const FLOOR := 0.14                     # height of its floor above the ground

var fixtures: Dictionary = {}


func _ready() -> void:
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.13, 0.36, 0.24)
	paint.roughness = 0.6
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.08, 0.2, 0.14)
	dark.roughness = 0.8
	var body := StaticBody3D.new()
	add_child(body)
	var hx := INNER.x * 0.5 + WALL * 0.5
	var hz := INNER.z * 0.5 + WALL * 0.5
	var mid := FLOOR + INNER.y * 0.5
	var boxes := [
		[Vector3(INNER.x + WALL * 2, FLOOR, INNER.z + WALL * 2), Vector3(0, FLOOR * 0.5, 0), dark],
		[Vector3(INNER.x + WALL * 2, INNER.y, WALL), Vector3(0, mid, hz), paint],
		[Vector3(INNER.x + WALL * 2, INNER.y, WALL), Vector3(0, mid, -hz), paint],
		[Vector3(WALL, INNER.y, INNER.z), Vector3(hx, mid, 0), paint],
		[Vector3(WALL, INNER.y, INNER.z), Vector3(-hx, mid, 0), paint],
	]
	for box: Array in boxes:
		add_child(Shapes.instance(Shapes.rounded_box(box[0], 0.03, 2), box[2], box[1]))
		var shape := BoxShape3D.new()
		shape.size = box[0]
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = box[1]
		body.add_child(col)
	# rim and ribs, just for looks
	for z: float in [hz, -hz]:
		add_child(Shapes.instance(Shapes.rounded_box(Vector3(INNER.x + 0.3, 0.07, 0.14), 0.03, 2), dark,
				Vector3(0, FLOOR + INNER.y, z)))
	for x: float in [-0.6, 0.0, 0.6]:
		add_child(Shapes.instance(Shapes.rounded_box(Vector3(0.07, INNER.y * 0.8, 0.05), 0.02, 1), dark,
				Vector3(x, mid, hz + WALL * 0.5 + 0.02)))
	var button := Fixture.new()
	button.setup(BUTTON_ID, "bin")
	button.position = Vector3(0.75, FLOOR + INNER.y * 0.72, hz + WALL * 0.5)
	add_child(button)
	fixtures[BUTTON_ID] = button


## Is this world position inside the skip?
func holds(pos: Vector3) -> bool:
	var local := to_local(pos)
	return absf(local.x) < INNER.x * 0.5 and absf(local.z) < INNER.z * 0.5 \
			and local.y > 0.0 and local.y < FLOOR + INNER.y + 0.6
