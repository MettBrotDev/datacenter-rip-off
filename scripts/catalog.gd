extends RefCounted
## Game data: every item kind, the shop list and the economy constants.
##
## Item fields (all optional except label/size/mass/parts):
##   group       what kind of slot it fits into ("gpu", "server")
##   slots       {"accepts": group, "at": [Vector3...], "yaw": degrees} — things that mount on it
##   power_port  has a power cable        net_port  has a network cable
##   provides    "power" | "net" — other cables can plug into it, up to `sockets`
##   watts, tokens   power draw and compute output while running
##   gen         {"kind": "pedal" | "fuel" | "solar", "watts": output, "burn": seconds per full tank}
##               a power source of its own. pedal = someone rides it, solar = outdoors only
##   solid       players cannot walk through it (small items are walk-through on purpose)
##   shapes      [[size, offset]...] collision boxes (default: one box of `size`)
##   parts       [[size, offset, colour, emission, tag]...] visual boxes; tag "led" = status light

const START_MONEY := 1500.0
const TOKEN_PRICE := 0.25        # $ earned per token
const POWER_PRICE := 0.0004      # $ paid per watt-second
const BREAKER_WATTS := 3600.0    # the garage's single circuit
const MAX_CABLE := 7.0           # metres before a cable gets yanked out
const SHOP: Array[String] = ["server", "gpu_1080", "gpu_4070", "gpu_4090", "powerstrip", "switch", "rack",
	"gen_bike", "gen_mower", "gen_solar", "gen_diesel", "fuel", "crate"]

## Land you can buy by walking up to its sale sign. `sign` and `pole` are world positions;
## the fibre pole on a plot only works once the plot is owned. No wall power out there.
const PLOTS := {
	"backyard": {"label": "Backyard pad", "price": 2500, "center": Vector3(0, 0, -15), "size": Vector2(10, 12),
		"sign": Vector3(4.2, 0, -8.6), "sign_yaw": 0.0, "pole": Vector3(-4.4, 0, -9.6)},
	"east": {"label": "East lot", "price": 12000, "center": Vector3(21, 0, 0), "size": Vector2(16, 14),
		"sign": Vector3(12.6, 0, 5.5), "sign_yaw": -90.0, "pole": Vector3(13.6, 0, -6.2)},
	"field": {"label": "Field across the street", "price": 50000, "center": Vector3(0, 0, 41), "size": Vector2(26, 16),
		"sign": Vector3(5.0, 0, 32.6), "sign_yaw": 180.0, "pole": Vector3(-12.2, 0, 33.6)},
}

static var ITEMS: Dictionary = _build()


static func _gpu(label: String, price: int, tokens: float, watts: float, glow: Color) -> Dictionary:
	return {"label": label, "group": "gpu", "price": price, "tokens": tokens, "watts": watts,
		"size": Vector3(0.3, 0.05, 0.13), "mass": 1.0, "parts": [
			[Vector3(0.3, 0.05, 0.13), Vector3.ZERO, Color(0.11, 0.11, 0.13), 0.0],
			[Vector3(0.3, 0.012, 0.012), Vector3(0, 0.026, 0.06), glow, 2.5, "led"],
			[Vector3(0.09, 0.006, 0.09), Vector3(-0.08, 0.027, -0.005), Color(0.4, 0.42, 0.46), 0.0],
			[Vector3(0.09, 0.006, 0.09), Vector3(0.06, 0.027, -0.005), Color(0.4, 0.42, 0.46), 0.0],
		]}


static func _build() -> Dictionary:
	var dark := Color(0.1, 0.1, 0.13)
	var socket := Color(0.15, 0.15, 0.17)
	var purple := Color(0.7, 0.4, 1.0)
	return {
		"crate": {"label": "Empty box", "price": 1, "size": Vector3(0.45, 0.35, 0.4), "mass": 1.5, "parts": [
			[Vector3(0.45, 0.35, 0.4), Vector3.ZERO, Color(0.72, 0.55, 0.36), 0.0],
			[Vector3(0.46, 0.01, 0.07), Vector3(0, 0.172, 0), Color(0.86, 0.79, 0.62), 0.0],
		]},
		"server": {"label": "Used server", "group": "server", "price": 300, "tokens": 1.0, "watts": 80.0,
			"power_port": true, "net_port": true,
			"slots": {"accepts": "gpu", "yaw": 90.0, "at": [Vector3(-0.12, 0.086, 0), Vector3(0.12, 0.086, 0)]},
			"size": Vector3(0.48, 0.12, 0.6), "mass": 6.0, "parts": [
				[Vector3(0.48, 0.12, 0.6), Vector3.ZERO, dark, 0.0],
				[Vector3(0.42, 0.014, 0.01), Vector3(0, 0.03, -0.301), purple, 3.0, "led"],
				[Vector3(0.42, 0.03, 0.01), Vector3(0, -0.02, -0.301), Color(0.2, 0.2, 0.24), 0.0],
			]},
		"gpu_1080": _gpu("GTX 1080 (used)", 400, 3.0, 180.0, Color(0.2, 1.0, 0.5)),
		"gpu_4070": _gpu("RTX 4070", 1200, 6.0, 200.0, Color(0.2, 0.8, 1.0)),
		"gpu_4090": _gpu("RTX 4090", 3500, 14.0, 450.0, Color(1.0, 0.3, 0.6)),
		"powerstrip": {"label": "Power strip", "price": 25, "power_port": true, "provides": "power", "sockets": 4,
			"size": Vector3(0.4, 0.045, 0.07), "mass": 0.6, "parts": [
				[Vector3(0.4, 0.045, 0.07), Vector3.ZERO, Color(0.9, 0.9, 0.87), 0.0],
				[Vector3(0.03, 0.02, 0.04), Vector3(-0.17, 0.025, 0), Color(1.0, 0.15, 0.1), 2.0, "led"],
				[Vector3(0.04, 0.004, 0.04), Vector3(-0.08, 0.023, 0), socket, 0.0],
				[Vector3(0.04, 0.004, 0.04), Vector3(0.0, 0.023, 0), socket, 0.0],
				[Vector3(0.04, 0.004, 0.04), Vector3(0.08, 0.023, 0), socket, 0.0],
				[Vector3(0.04, 0.004, 0.04), Vector3(0.16, 0.023, 0), socket, 0.0],
			]},
		"switch": {"label": "Network switch", "price": 60, "watts": 5.0, "power_port": true, "net_port": true,
			"provides": "net", "sockets": 4,
			"size": Vector3(0.28, 0.045, 0.16), "mass": 0.8, "parts": [
				[Vector3(0.28, 0.045, 0.16), Vector3.ZERO, Color(0.13, 0.18, 0.3), 0.0],
				[Vector3(0.2, 0.01, 0.01), Vector3(-0.02, 0.01, -0.081), Color(0.2, 1.0, 0.5), 2.5, "led"],
			]},
		# --- power generation, from scuffed to serious ---
		"gen_bike": {"label": "Exercise bike generator", "price": 150, "provides": "power", "sockets": 1,
			"gen": {"kind": "pedal", "watts": 250.0},
			"size": Vector3(0.5, 1.0, 1.1), "mass": 18.0, "parts": [
				[Vector3(0.5, 0.06, 1.1), Vector3(0, -0.47, 0), Color(0.2, 0.2, 0.23), 0.0],
				[Vector3(0.08, 0.7, 0.08), Vector3(0, -0.1, 0.25), Color(0.85, 0.2, 0.2), 0.0],
				[Vector3(0.26, 0.06, 0.3), Vector3(0, 0.28, 0.25), Color(0.1, 0.1, 0.12), 0.0],
				[Vector3(0.08, 0.9, 0.08), Vector3(0, 0.0, -0.35), Color(0.85, 0.2, 0.2), 0.0],
				[Vector3(0.5, 0.05, 0.05), Vector3(0, 0.45, -0.35), Color(0.1, 0.1, 0.12), 0.0],
				[Vector3(0.06, 0.5, 0.5), Vector3(0, -0.2, -0.1), Color(0.6, 0.62, 0.66), 0.0],
				[Vector3(0.2, 0.14, 0.2), Vector3(0, -0.37, 0.42), Color(0.95, 0.75, 0.1), 0.0],
				[Vector3(0.04, 0.04, 0.02), Vector3(0, -0.34, 0.53), Color(0.2, 1.0, 0.5), 3.0, "led"],
			]},
		"gen_mower": {"label": "Lawnmower generator", "price": 450, "provides": "power", "sockets": 2,
			"gen": {"kind": "fuel", "watts": 1200.0, "burn": 600.0},
			"size": Vector3(0.6, 0.5, 0.85), "mass": 30.0, "parts": [
				[Vector3(0.6, 0.16, 0.85), Vector3(0, -0.14, 0), Color(0.8, 0.15, 0.12), 0.0],
				[Vector3(0.3, 0.26, 0.3), Vector3(0, 0.07, -0.1), Color(0.2, 0.2, 0.23), 0.0],
				[Vector3(0.12, 0.1, 0.12), Vector3(0.18, 0.0, 0.25), Color(0.9, 0.9, 0.88), 0.0],
				[Vector3(0.05, 0.5, 0.05), Vector3(-0.2, 0.25, 0.4), Color(0.6, 0.62, 0.66), 0.0],
				[Vector3(0.05, 0.5, 0.05), Vector3(0.2, 0.25, 0.4), Color(0.6, 0.62, 0.66), 0.0],
				[Vector3(0.14, 0.14, 0.06), Vector3(-0.3, -0.2, 0.3), Color(0.08, 0.08, 0.08), 0.0],
				[Vector3(0.14, 0.14, 0.06), Vector3(0.3, -0.2, 0.3), Color(0.08, 0.08, 0.08), 0.0],
				[Vector3(0.14, 0.14, 0.06), Vector3(-0.3, -0.2, -0.3), Color(0.08, 0.08, 0.08), 0.0],
				[Vector3(0.14, 0.14, 0.06), Vector3(0.3, -0.2, -0.3), Color(0.08, 0.08, 0.08), 0.0],
				[Vector3(0.06, 0.04, 0.02), Vector3(0, 0.1, -0.26), Color(0.2, 1.0, 0.5), 3.0, "led"],
			]},
		"gen_solar": {"label": "Solar panel", "price": 900, "provides": "power", "sockets": 1,
			"gen": {"kind": "solar", "watts": 400.0},
			"size": Vector3(1.6, 0.08, 1.0), "mass": 12.0, "parts": [
				[Vector3(1.6, 0.06, 1.0), Vector3(0, -0.01, 0), Color(0.75, 0.77, 0.8), 0.0],
				[Vector3(1.5, 0.02, 0.9), Vector3(0, 0.03, 0), Color(0.06, 0.12, 0.35), 0.0],
				[Vector3(0.02, 0.022, 0.9), Vector3(-0.375, 0.031, 0), Color(0.75, 0.77, 0.8), 0.0],
				[Vector3(0.02, 0.022, 0.9), Vector3(0, 0.031, 0), Color(0.75, 0.77, 0.8), 0.0],
				[Vector3(0.02, 0.022, 0.9), Vector3(0.375, 0.031, 0), Color(0.75, 0.77, 0.8), 0.0],
				[Vector3(0.06, 0.03, 0.02), Vector3(0.7, 0.0, 0.5), Color(0.2, 1.0, 0.5), 3.0, "led"],
			]},
		"gen_diesel": {"label": "Diesel generator", "price": 2800, "provides": "power", "sockets": 4, "solid": true,
			"gen": {"kind": "fuel", "watts": 5000.0, "burn": 900.0},
			"size": Vector3(0.8, 0.9, 1.4), "mass": 90.0, "parts": [
				[Vector3(0.8, 0.9, 1.4), Vector3.ZERO, Color(0.95, 0.72, 0.1), 0.0],
				[Vector3(0.82, 0.3, 0.9), Vector3(0, -0.1, 0), Color(0.15, 0.15, 0.17), 0.0],
				[Vector3(0.1, 0.4, 0.1), Vector3(0.25, 0.6, -0.5), Color(0.3, 0.3, 0.33), 0.0],
				[Vector3(0.5, 0.25, 0.02), Vector3(0, 0.2, -0.705), Color(0.1, 0.1, 0.12), 0.0],
				[Vector3(0.3, 0.03, 0.01), Vector3(0, 0.25, -0.72), Color(0.2, 1.0, 0.5), 3.0, "led"],
			]},
		"fuel": {"label": "Jerry can", "price": 40, "size": Vector3(0.3, 0.4, 0.16), "mass": 4.0, "parts": [
			[Vector3(0.3, 0.36, 0.16), Vector3(0, -0.02, 0), Color(0.75, 0.1, 0.08), 0.0],
			[Vector3(0.08, 0.06, 0.08), Vector3(0.08, 0.18, 0), Color(0.1, 0.1, 0.1), 0.0],
			[Vector3(0.14, 0.03, 0.04), Vector3(-0.05, 0.19, 0), Color(0.75, 0.1, 0.08), 0.0],
		]},
		"rack": {"label": "Open rack", "price": 250, "solid": true,
			"slots": {"accepts": "server", "yaw": 0.0, "at": [
				Vector3(0, -0.62, 0), Vector3(0, -0.22, 0), Vector3(0, 0.18, 0), Vector3(0, 0.58, 0)]},
			"size": Vector3(0.6, 1.8, 0.75), "mass": 25.0,
			"shapes": [
				[Vector3(0.6, 0.05, 0.75), Vector3(0, -0.875, 0)], [Vector3(0.6, 0.05, 0.75), Vector3(0, 0.875, 0)],
				[Vector3(0.03, 1.8, 0.75), Vector3(-0.285, 0, 0)], [Vector3(0.03, 1.8, 0.75), Vector3(0.285, 0, 0)]],
			"parts": [
				[Vector3(0.6, 0.05, 0.75), Vector3(0, -0.875, 0), dark, 0.0],
				[Vector3(0.6, 0.05, 0.75), Vector3(0, 0.875, 0), dark, 0.0],
				[Vector3(0.03, 1.8, 0.75), Vector3(-0.285, 0, 0), Color(0.26, 0.23, 0.38), 0.0],
				[Vector3(0.03, 1.8, 0.75), Vector3(0.285, 0, 0), Color(0.26, 0.23, 0.38), 0.0],
				[Vector3(0.6, 0.02, 0.02), Vector3(0, 0.89, -0.37), purple, 3.0],
				[Vector3(0.02, 1.7, 0.02), Vector3(-0.29, 0, -0.37), purple, 2.0],
				[Vector3(0.02, 1.7, 0.02), Vector3(0.29, 0, -0.37), purple, 2.0],
			]},
	}


## Adds one MeshInstance3D per part to `node`. Returns the materials of tagged parts as [[tag, material]].
static func build_parts(node: Node3D, parts: Array) -> Array:
	var tagged := []
	for part: Array in parts:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = part[2]
		mat.roughness = 0.6
		if part[3] > 0.0:
			mat.emission_enabled = true
			mat.emission = part[2]
			mat.emission_energy_multiplier = part[3]
		if part.size() > 4:
			mat.set_meta("color", part[2])
			mat.set_meta("energy", part[3])
			tagged.append([part[4], mat])
		var mesh := BoxMesh.new()
		mesh.size = part[0]
		mesh.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = part[1]
		node.add_child(mi)
	return tagged


## Lights a tagged material: 0 = off, 1 = warning (orange), 2 = on (its own colour).
static func set_light(mat: StandardMaterial3D, level: int) -> void:
	var c: Color = mat.get_meta("color")
	if level == 1:
		c = Color(1.0, 0.45, 0.05)
	mat.albedo_color = c if level > 0 else c.darkened(0.85)
	mat.emission = c
	mat.emission_energy_multiplier = mat.get_meta("energy") if level > 0 else 0.0
