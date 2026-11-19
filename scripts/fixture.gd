extends StaticBody3D
## Something bolted to the building that players interact with: wall outlets, the internet
## uplink, breaker boxes, the shop laptop, front doors, neighbours. Ids are negative so they never clash with items.
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
		[Vector3(0.22, 0.012, 0.01), Vector3(-0.03, 0.06, 0.062), Color(0.2, 1.0, 0.5), 2.5, "lamp"],
		[Vector3(0.24, 0.04, 0.01), Vector3(0, -0.05, 0.062), Color(0.12, 0.12, 0.14), 0.0],
	]},
	"breaker": {"label": "Breaker box", "provides": "", "sockets": 0, "size": Vector3(0.36, 0.5, 0.1), "parts": [
		[Vector3(0.36, 0.5, 0.09), Vector3(0, 0, 0.045), Color(0.5, 0.52, 0.55), 0.0],
		[Vector3(0.28, 0.2, 0.01), Vector3(0, 0.08, 0.092), Color(0.2, 0.21, 0.24), 0.0],
		[Vector3(0.05, 0.1, 0.03), Vector3(0, 0.08, 0.105), Color(0.2, 1.0, 0.5), 3.0, "lamp"],
	]},
	"door": {"label": "Garage door button", "provides": "", "sockets": 0, "size": Vector3(0.14, 0.2, 0.06), "parts": [
		[Vector3(0.14, 0.2, 0.05), Vector3(0, 0, 0.025), Color(0.85, 0.75, 0.15), 0.0],
		[Vector3(0.07, 0.07, 0.02), Vector3(0, 0.03, 0.055), Color(0.2, 1.0, 0.5), 2.5],
	]},
	"hdoor": {"label": "Front door", "provides": "", "sockets": 0,
		"size": Vector3(1.2, 2.1, 0.1), "center": Vector3(0.6, 1.05, 0), "parts": [
			[Vector3(1.2, 2.1, 0.07), Vector3(0.6, 1.05, 0), Color(0.5, 0.22, 0.16), 0.0],
			[Vector3(0.06, 0.16, 0.14), Vector3(1.05, 1.0, 0), Color(0.9, 0.8, 0.3), 0.0],
			[Vector3(0.5, 0.5, 0.08), Vector3(0.6, 1.5, 0), Color(0.6, 0.3, 0.22), 0.0],
		]},
	"neighbour": {"label": "Neighbour", "provides": "", "sockets": 0,
		"size": Vector3(0.9, 1.7, 0.9), "center": Vector3(0, 0.85, 0), "parts": []},
	"deed": {"label": "Deed to the house", "provides": "", "sockets": 0, "size": Vector3(0.4, 0.5, 0.05), "parts": [
		[Vector3(0.4, 0.5, 0.03), Vector3(0, 0, 0.015), Color(0.45, 0.3, 0.18), 0.0],
		[Vector3(0.32, 0.42, 0.01), Vector3(0, 0, 0.032), Color(0.96, 0.94, 0.85), 0.0],
		[Vector3(0.08, 0.08, 0.01), Vector3(0.09, -0.13, 0.038), Color(0.85, 0.15, 0.12), 0.0],
	]},
	"bin": {"label": "Dumpster button", "provides": "", "sockets": 0, "size": Vector3(0.22, 0.22, 0.09), "parts": [
		[Vector3(0.22, 0.22, 0.04), Vector3(0, 0, 0.02), Color(0.75, 0.76, 0.78), 0.0],
		[Vector3(0.12, 0.12, 0.05), Vector3(0, 0, 0.055), Color(1.0, 0.15, 0.1), 2.0],
	]},
	"shop": {"label": "Shop laptop", "provides": "", "sockets": 0,
		"size": Vector3(0.42, 0.3, 0.3), "center": Vector3(0, 0.15, 0), "parts": [
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
var house := -1         # id of the house this belongs to, -1 for the garage's own fixtures
var circuit := -1       # outlets and breakers: which breaker circuit they are on

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
	shape.position = def.get("center", Vector3(0, 0, size.z * 0.5))
	add_child(shape)
	for tagged: Array in Catalog.build_parts(self, def["parts"]):
		_lamp = tagged[1]


## The fixture's indicator lamp, if it has one: 0 off, 1 orange (warning), 2 its own colour.
func set_lamp(level: int) -> void:
	if _lamp:
		Catalog.set_light(_lamp, level)
