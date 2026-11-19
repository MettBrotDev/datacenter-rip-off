extends RefCounted
## Game data: every item kind, the shop list and the economy constants.
##
## Item fields (all optional except label/size/mass/parts):
##   group       what kind of slot it fits into ("gpu", "server")
##   slots       {"accepts": group, "at": [Vector3...], "yaw": degrees} — things that mount on it
##   power_port  has a power cable        net_port  has a network cable
##   provides    "power" | "net" — other cables can plug into it, up to `sockets`
##   feeds       a power inlet: cabled to a generator, it energises the wiring of the building it is in
##   bus         a wall socket: delivers power from the wiring of the building it is in
##   wall        can be mounted on walls as well as put on floors
##   light       shines while powered
##   liquid      a GPU with no fans: the server it sits on must be on a running coolant loop
##   coolant_port  has a coolant hose (servers, manifolds, radiators, pumps, reservoirs)
##   pump        drives a coolant loop; its own hose goes to a reservoir (or straight to a tap)
##   tank        a coolant reservoir; its own hose can go to a tap, which keeps it full
##   radiator    watts it sheds per degree its coolant is above the surrounding air
##   wear        Q puts it on
##   sensor      "room" | "power" | "coolant": its reading shows up on every ops screen
##   screen      shows the company dashboard while powered
##   used        second-hand: may turn out to be dead when unpacked
##   max_watts   power strips: more than this through them for 1.5 s and they catch fire
##   cool        {"vent": extra W per degree the room loses} or {"remove": W of heat taken out}; needs power
##   flammable   fire spreads to it (everything fragile is flammable too)
##   fragile     electronics: ruined for good by a few seconds of rain (unless still in its parcel)
##   watts, tokens   power draw and compute output while running
##   gen         {"kind": "pedal" | "fuel" | "solar", "watts": output, "burn": seconds per full tank}
##               a power source of its own. pedal = someone rides it, solar = outdoors only
##   solid       players cannot walk through it (small items are walk-through on purpose)
##   shapes      [[size, offset]...] collision boxes (default: one box of `size`)
##   parts       [[size, offset, colour, emission, tag]...] visual boxes; tag "led" = status light

const Shapes = preload("res://scripts/shapes.gd")

const START_MONEY := 1500.0
const BREAKER_WATTS := 3600.0    # what the garage's wiring can carry before its breaker trips
const MAX_CABLE := 7.0           # metres before a cable gets yanked out
const RAIN_GRACE := 5.0          # seconds of rain a fragile item survives
const SHOP: Array[String] = ["server", "gpu_1080", "gpu_4070", "gpu_4090", "gpu_a100", "gpu_h100",
	"powerstrip", "switch", "rack", "pump", "reservoir", "radiator", "manifold", "bucket", "suit",
	"thermometer", "sensor_power", "sensor_coolant", "screen",
	"gen_bike", "gen_mower", "gen_solar", "gen_diesel", "fuel", "inlet", "outlet", "lamp",
	"fan", "aircon", "extinguisher", "crate"]

## Weather states. `solar` scales what a solar panel can deliver.
const WEATHER: Array[Dictionary] = [
	{"name": "Sunny", "solar": 1.0, "temp": 26.0, "cooling": 0.8, "news": "The sun is out: solar panels at full power"},
	{"name": "Cloudy", "solar": 0.4, "temp": 20.0, "cooling": 1.0, "news": "Clouds are rolling in: solar panels down to 40%"},
	{"name": "Rain", "solar": 0.0, "rain": true, "temp": 14.0, "cooling": 1.3,
		"news": "It's raining: solar panels produce nothing, and electronics left outside will be ruined"},
]

static var ITEMS: Dictionary = _build()


static func _gpu(label: String, price: int, tokens: float, watts: float, glow: Color) -> Dictionary:
	return {"label": label, "group": "gpu", "price": price, "tokens": tokens, "watts": watts, "fragile": true,
		"used": label.contains("used"),
		"size": Vector3(0.3, 0.05, 0.13), "mass": 1.0, "parts": [
			[Vector3(0.3, 0.05, 0.13), Vector3.ZERO, Color(0.11, 0.11, 0.13), 0.0],
			[Vector3(0.3, 0.012, 0.012), Vector3(0, 0.026, 0.06), glow, 2.5, "led"],
			[Vector3(0.09, 0.006, 0.09), Vector3(-0.08, 0.027, -0.005), Color(0.4, 0.42, 0.46), 0.0],
			[Vector3(0.09, 0.006, 0.09), Vector3(0.06, 0.027, -0.005), Color(0.4, 0.42, 0.46), 0.0],
		]}


## Datacenter cards: no fans of their own, a copper cold plate instead.
static func _liquid(gpu: Dictionary) -> Dictionary:
	gpu["liquid"] = true
	gpu["parts"] = [
		[Vector3(0.3, 0.05, 0.13), Vector3.ZERO, Color(0.16, 0.16, 0.19), 0.0],
		[Vector3(0.22, 0.014, 0.1), Vector3(-0.02, 0.028, 0), Color(0.8, 0.5, 0.25), 0.0],
		[Vector3(0.3, 0.012, 0.012), Vector3(0, 0.026, 0.06), gpu["parts"][1][2], 2.5, "led"],
		[Vector3(0.03, 0.03, 0.03), Vector3(0.13, 0.03, -0.03), Color(0.2, 0.45, 0.9), 0.0],
		[Vector3(0.03, 0.03, 0.03), Vector3(0.13, 0.03, 0.02), Color(0.2, 0.45, 0.9), 0.0],
	]
	return gpu


static func _build() -> Dictionary:
	var dark := Color(0.1, 0.1, 0.13)
	var socket := Color(0.15, 0.15, 0.17)
	var purple := Color(0.7, 0.4, 1.0)
	return {
		"crate": {"label": "Empty box", "price": 1, "flammable": true, "size": Vector3(0.45, 0.35, 0.4), "mass": 1.5, "parts": [
			[Vector3(0.45, 0.35, 0.4), Vector3.ZERO, Color(0.72, 0.55, 0.36), 0.0],
			[Vector3(0.46, 0.01, 0.07), Vector3(0, 0.172, 0), Color(0.86, 0.79, 0.62), 0.0],
		]},
		"server": {"label": "Used server", "group": "server", "price": 300, "tokens": 1.0, "watts": 80.0, "fragile": true,
			"used": true, "coolant_port": true,
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
		"gpu_a100": _liquid(_gpu("A100 80GB", 9000, 30.0, 400.0, Color(0.6, 1.0, 0.2))),
		"gpu_h100": _liquid(_gpu("H100", 25000, 70.0, 700.0, Color(1.0, 0.8, 0.1))),
		"powerstrip": {"label": "Power strip", "price": 25, "power_port": true, "provides": "power", "sockets": 4, "fragile": true,
			"max_watts": 2000.0,
			"size": Vector3(0.4, 0.045, 0.07), "mass": 0.6, "parts": [
				[Vector3(0.4, 0.045, 0.07), Vector3.ZERO, Color(0.9, 0.9, 0.87), 0.0],
				[Vector3(0.03, 0.02, 0.04), Vector3(-0.17, 0.025, 0), Color(1.0, 0.15, 0.1), 2.0, "led"],
				[Vector3(0.04, 0.004, 0.04), Vector3(-0.08, 0.023, 0), socket, 0.0],
				[Vector3(0.04, 0.004, 0.04), Vector3(0.0, 0.023, 0), socket, 0.0],
				[Vector3(0.04, 0.004, 0.04), Vector3(0.08, 0.023, 0), socket, 0.0],
				[Vector3(0.04, 0.004, 0.04), Vector3(0.16, 0.023, 0), socket, 0.0],
			]},
		"switch": {"label": "Network switch", "price": 60, "watts": 5.0, "power_port": true, "net_port": true, "fragile": true,
			"provides": "net", "sockets": 4,
			"size": Vector3(0.28, 0.045, 0.16), "mass": 0.8, "parts": [
				[Vector3(0.28, 0.045, 0.16), Vector3.ZERO, Color(0.13, 0.18, 0.3), 0.0],
				[Vector3(0.2, 0.01, 0.01), Vector3(-0.02, 0.01, -0.081), Color(0.2, 1.0, 0.5), 2.5, "led"],
			]},
		# --- power generation, from scuffed to serious ---
		"gen_bike": {"label": "Exercise bike generator", "price": 150, "provides": "power", "sockets": 1,
			"gen": {"kind": "pedal", "watts": 300.0},
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
		# --- building wiring: nothing is powered unless you bring the power in yourself ---
		"inlet": {"label": "Power inlet", "price": 40, "wall": true, "power_port": true, "feeds": true,
			"size": Vector3(0.24, 0.24, 0.09), "mass": 1.0, "parts": [
				[Vector3(0.24, 0.24, 0.07), Vector3(0, 0, 0.01), Color(0.15, 0.35, 0.8), 0.0],
				[Vector3(0.14, 0.14, 0.03), Vector3(0, 0, -0.035), Color(0.1, 0.1, 0.12), 0.0],
				[Vector3(0.04, 0.04, 0.02), Vector3(0.08, 0.08, -0.03), Color(0.2, 1.0, 0.5), 3.0, "led"],
			]},
		"outlet": {"label": "Wall socket", "price": 15, "wall": true, "provides": "power", "sockets": 2, "bus": true,
			"size": Vector3(0.2, 0.12, 0.05), "mass": 0.3, "parts": [
				[Vector3(0.2, 0.12, 0.04), Vector3(0, 0, 0.005), Color(0.92, 0.92, 0.9), 0.0],
				[Vector3(0.06, 0.06, 0.012), Vector3(-0.045, 0, -0.02), Color(0.12, 0.12, 0.14), 0.0],
				[Vector3(0.06, 0.06, 0.012), Vector3(0.045, 0, -0.02), Color(0.12, 0.12, 0.14), 0.0],
				[Vector3(0.02, 0.02, 0.012), Vector3(0, 0.045, -0.02), Color(0.2, 1.0, 0.5), 3.0, "led"],
			]},
		"lamp": {"label": "Floor lamp", "price": 60, "watts": 5.0, "power_port": true, "light": true, "fragile": true,
			"size": Vector3(0.36, 1.6, 0.36), "mass": 4.0, "parts": [
				[Vector3(0.32, 0.04, 0.32), Vector3(0, -0.78, 0), Color(0.15, 0.15, 0.17), 0.0],
				[Vector3(0.04, 1.3, 0.04), Vector3(0, -0.13, 0), Color(0.6, 0.62, 0.66), 0.0],
				[Vector3(0.36, 0.3, 0.36), Vector3(0, 0.65, 0), Color(1.0, 0.9, 0.7), 2.5, "led"],
			]},
		# --- liquid cooling: reservoir -> pump -> manifold -> servers, plus a radiator outdoors ---
		"pump": {"label": "Coolant pump", "price": 350, "watts": 150.0, "power_port": true, "coolant_port": true,
			"provides": "coolant", "sockets": 3, "pump": true,
			"size": Vector3(0.4, 0.35, 0.3), "mass": 9.0, "parts": [
				[Vector3(0.4, 0.1, 0.3), Vector3(0, -0.125, 0), Color(0.2, 0.2, 0.23), 0.0],
				[Vector3(0.22, 0.24, 0.24), Vector3(-0.07, 0.04, 0), Color(0.15, 0.4, 0.85), 0.0],
				[Vector3(0.14, 0.16, 0.16), Vector3(0.12, 0.0, 0), Color(0.6, 0.62, 0.66), 0.0],
				[Vector3(0.05, 0.03, 0.02), Vector3(-0.07, 0.1, -0.125), Color(0.2, 1.0, 0.5), 3.0, "led"],
			]},
		"reservoir": {"label": "Coolant reservoir", "price": 150, "coolant_port": true, "provides": "coolant",
			"sockets": 1, "tank": true,
			"size": Vector3(0.45, 0.7, 0.45), "mass": 6.0, "parts": [
				[Vector3(0.45, 0.06, 0.45), Vector3(0, -0.32, 0), Color(0.2, 0.2, 0.23), 0.0],
				[Vector3(0.4, 0.56, 0.4), Vector3(0, -0.01, 0), Color(0.55, 0.75, 0.95), 0.0],
				[Vector3(0.45, 0.06, 0.45), Vector3(0, 0.32, 0), Color(0.2, 0.2, 0.23), 0.0],
				[Vector3(0.12, 0.05, 0.12), Vector3(0.1, 0.37, 0.1), Color(0.9, 0.2, 0.15), 0.0],
			]},
		"radiator": {"label": "Radiator", "price": 500, "coolant_port": true, "radiator": 250.0, "solid": true,
			"size": Vector3(1.2, 1.0, 0.3), "mass": 30.0, "parts": [
				[Vector3(1.2, 0.08, 0.3), Vector3(0, -0.46, 0), Color(0.2, 0.2, 0.23), 0.0],
				[Vector3(1.1, 0.84, 0.12), Vector3(0, 0.0, 0), Color(0.55, 0.57, 0.6), 0.0],
				[Vector3(0.4, 0.4, 0.14), Vector3(-0.28, 0.0, 0), Color(0.12, 0.12, 0.14), 0.0],
				[Vector3(0.4, 0.4, 0.14), Vector3(0.28, 0.0, 0), Color(0.12, 0.12, 0.14), 0.0],
				[Vector3(1.2, 0.08, 0.3), Vector3(0, 0.46, 0), Color(0.2, 0.2, 0.23), 0.0],
			]},
		"manifold": {"label": "Coolant manifold", "price": 120, "coolant_port": true, "provides": "coolant", "sockets": 6,
			"size": Vector3(0.6, 0.1, 0.12), "mass": 2.0, "parts": [
				[Vector3(0.6, 0.08, 0.1), Vector3.ZERO, Color(0.75, 0.5, 0.25), 0.0],
				[Vector3(0.04, 0.05, 0.04), Vector3(-0.22, 0.06, 0), Color(0.2, 0.45, 0.9), 0.0],
				[Vector3(0.04, 0.05, 0.04), Vector3(-0.11, 0.06, 0), Color(0.2, 0.45, 0.9), 0.0],
				[Vector3(0.04, 0.05, 0.04), Vector3(0.0, 0.06, 0), Color(0.2, 0.45, 0.9), 0.0],
				[Vector3(0.04, 0.05, 0.04), Vector3(0.11, 0.06, 0), Color(0.2, 0.45, 0.9), 0.0],
				[Vector3(0.04, 0.05, 0.04), Vector3(0.22, 0.06, 0), Color(0.2, 0.45, 0.9), 0.0],
			]},
		"bucket": {"label": "Bucket", "price": 15, "size": Vector3(0.3, 0.32, 0.3), "mass": 1.0, "parts": [
			[Vector3(0.3, 0.3, 0.3), Vector3(0, -0.01, 0), Color(0.9, 0.5, 0.1), 0.0],
			[Vector3(0.24, 0.02, 0.24), Vector3(0, 0.145, 0), Color(0.2, 0.5, 0.95), 0.4, "led"],   # the water
		]},
		"suit": {"label": "Heat suit", "price": 400, "wear": true, "size": Vector3(0.5, 0.25, 0.4), "mass": 3.0, "parts": [
			[Vector3(0.5, 0.2, 0.4), Vector3(0, -0.02, 0), Color(0.8, 0.82, 0.85), 0.0],
			[Vector3(0.3, 0.06, 0.2), Vector3(0, 0.1, 0), Color(0.95, 0.75, 0.2), 0.0],
		]},
		# --- knowing what is going on: sensors feed the big ops screen ---
		"thermometer": {"label": "Thermometer", "price": 20, "wall": true, "sensor": "room",
			"size": Vector3(0.1, 0.3, 0.04), "mass": 0.2, "parts": [
				[Vector3(0.1, 0.3, 0.03), Vector3.ZERO, Color(0.95, 0.95, 0.92), 0.0],
				[Vector3(0.02, 0.2, 0.012), Vector3(0, 0.02, -0.018), Color(0.9, 0.15, 0.1), 0.6],
				[Vector3(0.05, 0.05, 0.02), Vector3(0, -0.11, -0.018), Color(0.9, 0.15, 0.1), 0.6],
			]},
		"sensor_power": {"label": "Power meter", "price": 60, "power_port": true, "sensor": "power", "fragile": true,
			"size": Vector3(0.16, 0.1, 0.1), "mass": 0.4, "parts": [
				[Vector3(0.16, 0.1, 0.1), Vector3.ZERO, Color(0.95, 0.8, 0.15), 0.0],
				[Vector3(0.11, 0.05, 0.01), Vector3(0, 0.01, -0.051), Color(0.2, 1.0, 0.5), 1.5, "led"],
			]},
		"sensor_coolant": {"label": "Coolant sensor", "price": 80, "coolant_port": true, "sensor": "coolant",
			"size": Vector3(0.16, 0.12, 0.12), "mass": 0.5, "parts": [
				[Vector3(0.16, 0.12, 0.12), Vector3.ZERO, Color(0.2, 0.45, 0.9), 0.0],
				[Vector3(0.1, 0.1, 0.01), Vector3(0, 0, -0.061), Color(0.95, 0.95, 0.95), 0.0],
				[Vector3(0.01, 0.05, 0.012), Vector3(0.015, 0.015, -0.064), Color(0.9, 0.15, 0.1), 0.0],
			]},
		"screen": {"label": "Ops screen", "price": 250, "watts": 60.0, "power_port": true, "wall": true,
			"fragile": true, "screen": true,
			"size": Vector3(1.6, 0.94, 0.06), "mass": 8.0, "parts": [
				[Vector3(1.6, 0.94, 0.05), Vector3(0, 0, 0.005), Color(0.08, 0.09, 0.12), 0.0],
			]},
		# --- keeping it from burning down ---
		"fan": {"label": "Box fan", "price": 45, "watts": 30.0, "power_port": true, "fragile": true,
			"cool": {"vent": 45.0},
			"size": Vector3(0.5, 0.55, 0.18), "mass": 3.0, "parts": [
				[Vector3(0.5, 0.55, 0.16), Vector3.ZERO, Color(0.85, 0.87, 0.9), 0.0],
				[Vector3(0.4, 0.4, 0.17), Vector3(0, 0.03, 0), Color(0.2, 0.22, 0.26), 0.0],
				[Vector3(0.32, 0.06, 0.18), Vector3(0, 0.03, 0), Color(0.3, 0.6, 0.95), 0.0],
				[Vector3(0.06, 0.32, 0.18), Vector3(0, 0.03, 0), Color(0.3, 0.6, 0.95), 0.0],
				[Vector3(0.04, 0.03, 0.02), Vector3(0.2, -0.24, -0.08), Color(0.2, 1.0, 0.5), 3.0, "led"],
			]},
		"aircon": {"label": "Portable air conditioner", "price": 900, "watts": 700.0, "power_port": true,
			"fragile": true, "solid": true, "cool": {"remove": 2500.0},
			"size": Vector3(0.45, 0.8, 0.4), "mass": 28.0, "parts": [
				[Vector3(0.45, 0.8, 0.4), Vector3.ZERO, Color(0.93, 0.94, 0.95), 0.0],
				[Vector3(0.38, 0.2, 0.02), Vector3(0, 0.22, -0.2), Color(0.25, 0.27, 0.3), 0.0],
				[Vector3(0.38, 0.03, 0.02), Vector3(0, 0.05, -0.2), Color(0.25, 0.27, 0.3), 0.0],
				[Vector3(0.38, 0.03, 0.02), Vector3(0, -0.02, -0.2), Color(0.25, 0.27, 0.3), 0.0],
				[Vector3(0.1, 0.02, 0.02), Vector3(0.12, 0.36, -0.2), Color(0.3, 0.7, 1.0), 3.0, "led"],
			]},
		"extinguisher": {"label": "Fire extinguisher", "price": 60, "size": Vector3(0.18, 0.55, 0.18), "mass": 4.0, "parts": [
			[Vector3(0.16, 0.42, 0.16), Vector3(0, -0.06, 0), Color(0.85, 0.1, 0.08), 0.0],
			[Vector3(0.07, 0.08, 0.07), Vector3(0, 0.19, 0), Color(0.15, 0.15, 0.17), 0.0],
			[Vector3(0.05, 0.03, 0.16), Vector3(0, 0.25, -0.05), Color(0.15, 0.15, 0.17), 0.0],
			[Vector3(0.1, 0.12, 0.165), Vector3(0, -0.02, 0), Color(0.95, 0.95, 0.9), 0.0],
		]},
		"fuel": {"label": "Jerry can", "price": 40, "size": Vector3(0.3, 0.4, 0.16), "mass": 4.0, "parts": [
			[Vector3(0.3, 0.36, 0.16), Vector3(0, -0.02, 0), Color(0.75, 0.1, 0.08), 0.0],
			[Vector3(0.08, 0.06, 0.08), Vector3(0.08, 0.18, 0), Color(0.1, 0.1, 0.1), 0.0],
			[Vector3(0.14, 0.03, 0.04), Vector3(-0.05, 0.19, 0), Color(0.75, 0.1, 0.08), 0.0],
		]},
		# --- what the neighbours leave behind ---
		"sofa": {"label": "Sofa", "solid": true, "flammable": true, "size": Vector3(2.0, 0.8, 0.9), "mass": 40.0, "parts": [
			[Vector3(2.0, 0.4, 0.9), Vector3(0, -0.2, 0), Color(0.35, 0.5, 0.65), 0.0],
			[Vector3(2.0, 0.5, 0.25), Vector3(0, 0.15, 0.325), Color(0.32, 0.46, 0.6), 0.0],
			[Vector3(0.25, 0.3, 0.9), Vector3(-0.875, 0.1, 0), Color(0.32, 0.46, 0.6), 0.0],
			[Vector3(0.25, 0.3, 0.9), Vector3(0.875, 0.1, 0), Color(0.32, 0.46, 0.6), 0.0],
			[Vector3(0.7, 0.12, 0.55), Vector3(-0.4, 0.05, -0.1), Color(0.42, 0.58, 0.72), 0.0],
			[Vector3(0.7, 0.12, 0.55), Vector3(0.4, 0.05, -0.1), Color(0.42, 0.58, 0.72), 0.0],
		]},
		"tv": {"label": "Television", "fragile": true, "size": Vector3(1.3, 0.9, 0.35), "mass": 14.0, "parts": [
			[Vector3(1.3, 0.4, 0.35), Vector3(0, -0.25, 0), Color(0.45, 0.3, 0.18), 0.0],
			[Vector3(1.2, 0.5, 0.06), Vector3(0, 0.2, 0), Color(0.05, 0.05, 0.06), 0.0],
			[Vector3(1.1, 0.42, 0.01), Vector3(0, 0.2, -0.033), Color(0.3, 0.5, 0.9), 0.7],
		]},
		"table": {"label": "Coffee table", "flammable": true, "size": Vector3(1.0, 0.45, 0.6), "mass": 9.0, "parts": [
			[Vector3(1.0, 0.06, 0.6), Vector3(0, 0.195, 0), Color(0.55, 0.38, 0.24), 0.0],
			[Vector3(0.06, 0.39, 0.06), Vector3(-0.44, -0.03, -0.24), Color(0.4, 0.27, 0.17), 0.0],
			[Vector3(0.06, 0.39, 0.06), Vector3(0.44, -0.03, -0.24), Color(0.4, 0.27, 0.17), 0.0],
			[Vector3(0.06, 0.39, 0.06), Vector3(-0.44, -0.03, 0.24), Color(0.4, 0.27, 0.17), 0.0],
			[Vector3(0.06, 0.39, 0.06), Vector3(0.44, -0.03, 0.24), Color(0.4, 0.27, 0.17), 0.0],
		]},
		"bed": {"label": "Bed", "solid": true, "flammable": true, "size": Vector3(1.6, 0.55, 2.1), "mass": 45.0, "parts": [
			[Vector3(1.6, 0.3, 2.1), Vector3(0, -0.125, 0), Color(0.5, 0.34, 0.2), 0.0],
			[Vector3(1.5, 0.2, 2.0), Vector3(0, 0.12, 0), Color(0.95, 0.95, 0.93), 0.0],
			[Vector3(1.54, 0.08, 1.25), Vector3(0, 0.22, 0.38), Color(0.75, 0.3, 0.3), 0.0],
			[Vector3(0.6, 0.1, 0.38), Vector3(-0.37, 0.25, -0.75), Color(1.0, 1.0, 1.0), 0.0],
			[Vector3(0.6, 0.1, 0.38), Vector3(0.37, 0.25, -0.75), Color(1.0, 1.0, 1.0), 0.0],
			[Vector3(1.6, 0.6, 0.08), Vector3(0, 0.15, -1.05), Color(0.45, 0.3, 0.18), 0.0],
		]},
		"fridge": {"label": "Fridge", "solid": true, "size": Vector3(0.7, 1.8, 0.7), "mass": 60.0, "parts": [
			[Vector3(0.7, 1.8, 0.7), Vector3.ZERO, Color(0.9, 0.92, 0.94), 0.0],
			[Vector3(0.66, 0.02, 0.02), Vector3(0, 0.3, -0.35), Color(0.6, 0.62, 0.66), 0.0],
			[Vector3(0.04, 0.4, 0.05), Vector3(0.26, 0.6, -0.37), Color(0.6, 0.62, 0.66), 0.0],
			[Vector3(0.04, 0.5, 0.05), Vector3(0.26, -0.1, -0.37), Color(0.6, 0.62, 0.66), 0.0],
		]},
		"plant": {"label": "Pot plant", "size": Vector3(0.4, 0.9, 0.4), "mass": 5.0, "parts": [
			[Vector3(0.3, 0.3, 0.3), Vector3(0, -0.3, 0), Color(0.75, 0.42, 0.28), 0.0],
			[Vector3(0.06, 0.3, 0.06), Vector3(0, -0.05, 0), Color(0.35, 0.25, 0.15), 0.0],
			[Vector3(0.4, 0.4, 0.4), Vector3(0, 0.22, 0), Color(0.25, 0.6, 0.3), 0.0],
			[Vector3(0.26, 0.26, 0.26), Vector3(0.1, 0.38, 0.06), Color(0.3, 0.68, 0.34), 0.0],
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


## The cardboard box a purchase arrives in: sized to fit, labelled, and rainproof.
static func parcel(kind: String) -> Dictionary:
	var inside: Dictionary = ITEMS[kind]
	var fit: Vector3 = inside["size"]
	var size := Vector3(maxf(fit.x + 0.08, 0.3), maxf(fit.y + 0.08, 0.2), maxf(fit.z + 0.08, 0.3))
	var tape := Color(0.86, 0.79, 0.62)
	return {"label": "Parcel: %s" % inside["label"], "size": size, "mass": inside["mass"] + 0.5,
		"solid": inside.get("solid", false), "flammable": true, "parts": [
			[size, Vector3.ZERO, Color(0.72, 0.55, 0.36), 0.0],
			[Vector3(size.x + 0.006, 0.006, minf(0.07, size.z * 0.3)), Vector3(0, size.y * 0.5, 0), tape, 0.0],
			[Vector3(minf(0.07, size.x * 0.3), size.y + 0.006, size.z + 0.006), Vector3.ZERO, tape, 0.0],
		]}


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
		var size: Vector3 = part[0]
		var soft := clampf(minf(size.x, minf(size.y, size.z)) * 0.3, 0.003, 0.03)
		node.add_child(Shapes.instance(Shapes.rounded_box(size, soft, 2), mat, part[1]))
	return tagged


## Lights a tagged material: 0 = off, 1 = warning (orange), 2 = on (its own colour).
static func set_light(mat: StandardMaterial3D, level: int) -> void:
	var c: Color = mat.get_meta("color")
	if level == 1:
		c = Color(1.0, 0.45, 0.05)
	mat.albedo_color = c if level > 0 else c.darkened(0.85)
	mat.emission = c
	mat.emission_energy_multiplier = mat.get_meta("energy") if level > 0 else 0.0
