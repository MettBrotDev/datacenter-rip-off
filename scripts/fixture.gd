extends StaticBody3D
## Something bolted to the building that players interact with: wall outlets, the internet
## uplink, the breaker box, the shop laptop. Ids are negative so they never clash with items.
## Local frame: origin on the wall (or table) surface, front facing +Z.

const Catalog = preload("res://scripts/catalog.gd")

const KINDS := {
	"outlet": {"label": "Wall outlet", "provides": "power", "sockets": 2, "size": Vector3(0.2, 0.12, 0.04), "parts": [
		[Vector3(0.2, 0.12, 0.03), Vector3(0, 0, 0.015), Color(0.92, 0.92, 0.9), 0.0],
		[Vector3(0.06, 0.06, 0.01), Vector3(-0.045, 0, 0.032), Color(0.12, 0.12, 0.14), 0.0],
		[Vector3(0.06, 0.06, 0.01), Vector3(0.045, 0, 0.032), Color(0.12, 0.12, 0.14), 0.0],
	]},
	"router": {"label": "Internet uplink", "provides": "net", "sockets": 4, "size": Vector3(0.34, 0.22, 0.07), "parts": [
		[Vector3(0.34, 0.22, 0.06), Vector3(0, 0, 0.03), Color(0.93, 0.93, 0.95), 0.0],
		[Vector3(0.22, 0.012, 0.01), Vector3(-0.03, 0.06, 0.062), Color(0.2, 1.0, 0.5), 2.5],
		[Vector3(0.24, 0.04, 0.01), Vector3(0, -0.05, 0.062), Color(0.12, 0.12, 0.14), 0.0],
	]},
	"breaker": {"label": "Breaker box", "provides": "", "sockets": 0, "size": Vector3(0.36, 0.5, 0.1), "parts": [
		[Vector3(0.36, 0.5, 0.09), Vector3(0, 0, 0.045), Color(0.5, 0.52, 0.55), 0.0],
		[Vector3(0.28, 0.2, 0.01), Vector3(0, 0.08, 0.092), Color(0.2, 0.21, 0.24), 0.0],
		[Vector3(0.05, 0.1, 0.03), Vector3(0, 0.08, 0.105), Color(0.2, 1.0, 0.5), 3.0, "lamp"],
	]},
	"shop": {"label": "Shop laptop", "provides": "", "sockets": 0, "size": Vector3(0.42, 0.3, 0.3), "parts": [
		[Vector3(0.36, 0.02, 0.25), Vector3(0, 0.01, 0.02), Color(0.2, 0.21, 0.24), 0.0],
		[Vector3(0.36, 0.24, 0.012), Vector3(0, 0.14, -0.105), Color(0.2, 0.21, 0.24), 0.0],
		[Vector3(0.33, 0.2, 0.004), Vector3(0, 0.14, -0.097), Color(0.25, 0.6, 1.0), 1.4],
	]},
}

var id := 0
var kind := ""
var label := ""
var provides := ""
var sockets := 0

var _lamp: StandardMaterial3D


func setup(p_id: int, p_kind: String) -> void:
	id = p_id
	kind = p_kind
	var def: Dictionary = KINDS[kind]
	label = def["label"]
	provides = def["provides"]
	sockets = def["sockets"]
	var size: Vector3 = def["size"]
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = Vector3(0, size.y * 0.5, 0) if kind == "shop" else Vector3(0, 0, size.z * 0.5)
	add_child(shape)
	for tagged: Array in Catalog.build_parts(self, def["parts"]):
		_lamp = tagged[1]


## Breaker box lamp: green when fine, orange when tripped.
func set_tripped(on: bool) -> void:
	if _lamp:
		Catalog.set_light(_lamp, 1 if on else 2)
