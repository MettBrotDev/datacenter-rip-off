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
	"tap": {"label": "Garden tap", "provides": "coolant", "sockets": 2, "size": Vector3(0.2, 0.24, 0.16), "parts": [
		[Vector3(0.06, 0.06, 0.12), Vector3(0, 0, 0.06), Color(0.7, 0.55, 0.25), 0.0],
		[Vector3(0.05, 0.12, 0.05), Vector3(0, -0.06, 0.12), Color(0.7, 0.55, 0.25), 0.0],
		[Vector3(0.14, 0.03, 0.03), Vector3(0, 0.06, 0.1), Color(0.2, 0.45, 0.9), 0.0],
	]},
	"bin": {"label": "Dumpster button", "provides": "", "sockets": 0, "size": Vector3(0.22, 0.22, 0.09), "parts": [
		[Vector3(0.22, 0.22, 0.04), Vector3(0, 0, 0.02), Color(0.75, 0.76, 0.78), 0.0],
		[Vector3(0.12, 0.12, 0.05), Vector3(0, 0, 0.055), Color(1.0, 0.15, 0.1), 2.0],
	]},
	"console": {"label": "Company console", "provides": "", "sockets": 0, "size": Vector3(1.1, 0.16, 0.42), "parts": [
		[Vector3(1.1, 0.04, 0.4), Vector3(0, -0.02, 0.2), Color(0.16, 0.17, 0.2), 0.0],
		[Vector3(0.05, 0.22, 0.3), Vector3(-0.45, -0.13, 0.15), Color(0.12, 0.13, 0.15), 0.0],
		[Vector3(0.05, 0.22, 0.3), Vector3(0.45, -0.13, 0.15), Color(0.12, 0.13, 0.15), 0.0],
		[Vector3(0.52, 0.025, 0.17), Vector3(-0.08, 0.012, 0.22), Color(0.07, 0.08, 0.1), 0.0],
		[Vector3(0.48, 0.006, 0.13), Vector3(-0.08, 0.027, 0.22), Color(0.3, 0.75, 1.0), 1.2],
		[Vector3(0.07, 0.03, 0.11), Vector3(0.32, 0.015, 0.22), Color(0.85, 0.86, 0.9), 0.0],
		[Vector3(1.1, 0.012, 0.012), Vector3(0, 0.0, 0.4), Color(0.2, 1.0, 0.5), 2.0],
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
	for tagged: Array in Catalog.build_parts(self, _look(kind, def["parts"])):
		_lamp = tagged[1]


## The fixture's indicator lamp, if it has one: 0 off, 1 orange (warning), 2 its own colour.
func set_lamp(level: int) -> void:
	if _lamp:
		Catalog.set_light(_lamp, level)


## What each fixture looks like (the `parts` in KINDS are the plain fallback). Local frame: wall at z = 0, front +Z.
static func _look(what: String, plain: Array) -> Array:
	var white := Color(0.93, 0.93, 0.95)
	var steel := Color(0.74, 0.76, 0.8)
	var black := Color(0.08, 0.08, 0.1)
	match what:
		"outlet":
			return Catalog._xf(Catalog.socket_plate_parts(false), Basis(Vector3.UP, PI), Vector3(0, 0, 0.02))
		"router":
			var parts := [
				Catalog._p(Vector3(0.34, 0.22, 0.05), Vector3(0, 0, 0.025), white, "plastic", 0.02),
				Catalog._p(Vector3(0.3, 0.17, 0.004), Vector3(0, -0.005, 0.0505), white.darkened(0.06), "plastic", 0.0),
				Catalog._led(Vector3(0.22, 0.012, 0.01), Vector3(-0.03, 0.082, 0.054), Color(0.2, 1.0, 0.5), 2.5, 0.003),
				Catalog._p(Vector3(0.05, 0.012, 0.006), Vector3(0.12, 0.082, 0.053), Color(0.25, 0.45, 0.8), "plastic", 0.002),
			]
			parts.append_array(Catalog._row(6, Vector3(-0.11, 0.025, 0.052), Vector3(0.11, 0.025, 0.052), Vector3(0.035, 0.005, 0.004), black, "matte", 0.0))
			for i in 4:
				parts.append(Catalog._p(Vector3(0.034, 0.024, 0.012), Vector3(-0.105 + i * 0.07, -0.065, 0.054), black, "matte", 0.002))
				parts.append(Catalog._p(Vector3(0.022, 0.004, 0.012), Vector3(-0.105 + i * 0.07, -0.074, 0.055), Color(0.9, 0.72, 0.22), "gold", 0.0))
			return parts
		"breaker":
			var parts := [
				Catalog._p(Vector3(0.36, 0.5, 0.09), Vector3(0, 0, 0.045), Color(0.5, 0.52, 0.55), "metal", 0.012),
				Catalog._p(Vector3(0.31, 0.44, 0.01), Vector3(0, 0, 0.093), Color(0.62, 0.64, 0.68), "metal", 0.006),
				Catalog._p(Vector3(0.28, 0.2, 0.008), Vector3(0, 0.08, 0.1), Color(0.14, 0.15, 0.17), "plastic", 0.004),
				Catalog._led(Vector3(0.05, 0.1, 0.03), Vector3(0, 0.08, 0.108), Color(0.2, 1.0, 0.5), 3.0, 0.006),
				Catalog._cyl(0.012, 0.01, Vector3(-0.145, 0.2, 0.1), steel, "z", "chrome"),
				Catalog._cyl(0.012, 0.01, Vector3(0.145, 0.2, 0.1), steel, "z", "chrome"),
				Catalog._cyl(0.012, 0.01, Vector3(-0.145, -0.2, 0.1), steel, "z", "chrome"),
				Catalog._cyl(0.012, 0.01, Vector3(0.145, -0.2, 0.1), steel, "z", "chrome"),
				Catalog._p(Vector3(0.2, 0.05, 0.004), Vector3(0, -0.2, 0.099), Color(0.95, 0.85, 0.2), "matte", 0.0),
			]
			for c in 2:
				for r in 3:
					var y := -0.03 - r * 0.045
					parts.append(Catalog._p(Vector3(0.08, 0.026, 0.012), Vector3(-0.075 + c * 0.15, y, 0.1), Color(0.1, 0.1, 0.12), "plastic", 0.004))
					parts.append(Catalog._p(Vector3(0.03, 0.012, 0.016), Vector3(-0.075 + c * 0.15, y + (0.005 if (r + c) % 2 == 0 else -0.005), 0.108), Color(0.9, 0.9, 0.88), "plastic", 0.002))
			return parts
		"door":
			return [
				Catalog._p(Vector3(0.14, 0.2, 0.04), Vector3(0, 0, 0.02), Color(0.85, 0.75, 0.15), "plastic", 0.014),
				Catalog._cyl(0.09, 0.012, Vector3(0, 0.025, 0.043), Color(0.1, 0.1, 0.12), "z", "plastic", 0.004),
				Catalog._cyl(0.07, 0.014, Vector3(0, 0.025, 0.05), Color(0.2, 1.0, 0.5), "z", "plastic", 0.005),
				Catalog._e(Vector3(0.05, 0.05, 0.004), Vector3(0, 0.025, 0.0585), Color(0.2, 1.0, 0.5), 2.5, 0.0),
				Catalog._p(Vector3(0.05, 0.012, 0.004), Vector3(0, -0.065, 0.041), Color(0.1, 0.1, 0.12), "matte", 0.0),
				Catalog._p(Vector3(0.012, 0.03, 0.004), Vector3(0, -0.065, 0.042), Color(0.1, 0.1, 0.12), "matte", 0.0),
			]
		"hdoor":
			var door := Color(0.5, 0.22, 0.16)
			var gold := Color(0.92, 0.8, 0.32)
			return [
				Catalog._p(Vector3(1.2, 2.1, 0.07), Vector3(0.6, 1.05, 0), door, "plastic", 0.012),
				Catalog._p(Vector3(0.44, 0.7, 0.014), Vector3(0.3, 0.5, 0.04), door.lightened(0.06), "plastic", 0.01),
				Catalog._p(Vector3(0.44, 0.7, 0.014), Vector3(0.9, 0.5, 0.04), door.lightened(0.06), "plastic", 0.01),
				Catalog._p(Vector3(0.5, 0.5, 0.02), Vector3(0.6, 1.5, 0.04), Color(0.9, 0.9, 0.88), "plastic", 0.012),
				Catalog._p(Vector3(0.42, 0.42, 0.01), Vector3(0.6, 1.5, 0.046), Color(0.6, 0.78, 0.9, 0.6), "glass", 0.0),
				Catalog._p(Vector3(0.02, 0.42, 0.006), Vector3(0.6, 1.5, 0.052), Color(0.9, 0.9, 0.88), "plastic", 0.0),
				Catalog._p(Vector3(0.42, 0.02, 0.006), Vector3(0.6, 1.5, 0.052), Color(0.9, 0.9, 0.88), "plastic", 0.0),
				Catalog._p(Vector3(0.05, 0.2, 0.014), Vector3(1.05, 1.0, 0.04), gold, "gold", 0.008),
				Catalog._cyl(0.04, 0.05, Vector3(1.05, 1.0, 0.07), gold, "z", "gold", 0.008),
				Catalog._p(Vector3(0.12, 0.03, 0.03), Vector3(1.0, 1.0, 0.08), gold, "gold", 0.01),
				Catalog._cyl(0.045, 0.02, Vector3(0.6, 1.88, 0.04), gold, "z", "gold", 0.004),
				Catalog._cyl(0.03, 0.12, Vector3(0.02, 0.4, 0.0), Color(0.3, 0.2, 0.15), "y", "metal"),
				Catalog._cyl(0.03, 0.12, Vector3(0.02, 1.0, 0.0), Color(0.3, 0.2, 0.15), "y", "metal"),
				Catalog._cyl(0.03, 0.12, Vector3(0.02, 1.7, 0.0), Color(0.3, 0.2, 0.15), "y", "metal"),
			]
		"deed":
			return [
				Catalog._p(Vector3(0.4, 0.5, 0.03), Vector3(0, 0, 0.015), Color(0.45, 0.3, 0.18), "plastic", 0.01),
				Catalog._p(Vector3(0.34, 0.44, 0.008), Vector3(0, 0, 0.032), Color(0.96, 0.94, 0.85), "matte", 0.004),
				Catalog._p(Vector3(0.24, 0.012, 0.002), Vector3(0, 0.14, 0.037), Color(0.25, 0.2, 0.15), "", 0.0),
				Catalog._p(Vector3(0.2, 0.01, 0.002), Vector3(0, 0.1, 0.037), Color(0.35, 0.3, 0.25), "", 0.0),
				Catalog._p(Vector3(0.2, 0.01, 0.002), Vector3(0, 0.06, 0.037), Color(0.35, 0.3, 0.25), "", 0.0),
				Catalog._cyl(0.09, 0.012, Vector3(0.09, -0.13, 0.04), Color(0.85, 0.15, 0.12), "z", "plastic", 0.004),
				Catalog._p(Vector3(0.03, 0.1, 0.006), Vector3(0.05, -0.2, 0.038), Color(0.85, 0.15, 0.12), "matte", 0.0),
			]
		"tap":
			var brass := Color(0.78, 0.6, 0.25)
			return [
				Catalog._cyl(0.09, 0.012, Vector3(0, 0, 0.006), steel, "z", "chrome", 0.003),
				Catalog._cyl(0.045, 0.1, Vector3(0, 0, 0.06), brass, "z", "gold", 0.004),
				Catalog._cyl(0.055, 0.02, Vector3(0, 0, 0.105), brass.darkened(0.15), "z", "gold", 0.004),
				Catalog._cyl(0.04, 0.09, Vector3(0, -0.04, 0.12), brass, "y", "gold", 0.004),
				Catalog._cyl(0.026, 0.03, Vector3(0, -0.09, 0.12), brass.lightened(0.1), "y", "gold", 0.003),
				Catalog._cyl(0.012, 0.06, Vector3(0, 0.07, 0.1), brass, "y", "gold"),
				Catalog._cyl(0.07, 0.014, Vector3(0, 0.1, 0.1), Color(0.2, 0.45, 0.9), "y", "plastic", 0.004),
				Catalog._p(Vector3(0.015, 0.012, 0.075), Vector3(0, 0.108, 0.1), Color(0.2, 0.45, 0.9), "plastic", 0.003),
			]
		"bin":
			return [
				Catalog._p(Vector3(0.22, 0.22, 0.04), Vector3(0, 0, 0.02), Color(0.75, 0.76, 0.78), "metal", 0.014),
				Catalog._cyl(0.15, 0.016, Vector3(0, 0, 0.048), Color(0.95, 0.85, 0.15), "z", "plastic", 0.004),
				Catalog._cyl(0.11, 0.03, Vector3(0, 0, 0.06), Color(0.8, 0.08, 0.06), "z", "plastic", 0.01),
				Catalog._e(Vector3(0.1, 0.1, 0.004), Vector3(0, 0, 0.0765), Color(1.0, 0.15, 0.1), 2.0, 0.0),
			]
		"console":
			return [
				Catalog._p(Vector3(1.1, 0.04, 0.4), Vector3(0, -0.02, 0.2), Color(0.16, 0.17, 0.2), "metal", 0.012),
				Catalog._p(Vector3(0.05, 0.22, 0.3), Vector3(-0.45, -0.13, 0.15), Color(0.12, 0.13, 0.15), "metal", 0.01),
				Catalog._p(Vector3(0.05, 0.22, 0.3), Vector3(0.45, -0.13, 0.15), Color(0.12, 0.13, 0.15), "metal", 0.01),
				Catalog._p(Vector3(0.54, 0.02, 0.19), Vector3(-0.08, 0.01, 0.22), Color(0.07, 0.08, 0.1), "plastic", 0.01),
				Catalog._e(Vector3(0.48, 0.006, 0.13), Vector3(-0.08, 0.023, 0.22), Color(0.3, 0.75, 1.0), 1.2, 0.0),
				Catalog._p(Vector3(0.08, 0.02, 0.12), Vector3(0.32, 0.01, 0.22), Color(0.85, 0.86, 0.9), "plastic", 0.006),
				Catalog._e(Vector3(1.1, 0.012, 0.012), Vector3(0, 0.0, 0.4), Color(0.2, 1.0, 0.5), 2.0, 0.0),
			]
		"shop":
			var parts := [
				Catalog._p(Vector3(0.36, 0.02, 0.25), Vector3(0, 0.01, 0.02), Color(0.2, 0.21, 0.24), "metal", 0.008),
				Catalog._p(Vector3(0.34, 0.006, 0.11), Vector3(0, 0.0215, 0.0), black, "matte", 0.002),
				Catalog._p(Vector3(0.1, 0.004, 0.06), Vector3(0, 0.022, 0.085), Color(0.28, 0.29, 0.33), "metal", 0.004),
				Catalog._cyl(0.012, 0.3, Vector3(0, 0.022, -0.1), Color(0.15, 0.16, 0.18), "x", "metal"),
				Catalog._p(Vector3(0.36, 0.24, 0.012), Vector3(0, 0.14, -0.105), Color(0.2, 0.21, 0.24), "metal", 0.01),
				Catalog._p(Vector3(0.34, 0.22, 0.004), Vector3(0, 0.14, -0.0985), black, "plastic", 0.004),
				Catalog._e(Vector3(0.325, 0.195, 0.003), Vector3(0, 0.14, -0.096), Color(0.25, 0.6, 1.0), 1.4, 0.0),
			]
			parts.append_array(Catalog._row(4, Vector3(0.0, 0.0255, -0.035), Vector3(0.0, 0.0255, 0.025), Vector3(0.32, 0.003, 0.012), Color(0.3, 0.31, 0.35), "plastic", 0.001))
			return parts
	return plain
