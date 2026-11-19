extends RefCounted
## Game data: every item kind, the shop list and the economy constants.
##
## Item fields (all optional except label/size/mass/parts):
##   group       what kind of slot it fits into ("cpu", "ram", "gpu", "server")
##   slots       [{"accepts": group, "xf": Transform3D}...] — the places things mount on it
##   lid         has a screwed-on lid: parts go in and out only while it is open (needs a screwdriver)
##   psu         a machine: watts its power supply delivers; more than that inside and it will not boot
##   max_tier    a machine: the highest tier of CPU and GPU that fits
##   tier        a CPU or GPU: 1 (consumer) to 5 (frontier)
##   needs_ram   a GPU: gigabytes of RAM the machine must have spare for it
##   gb          a RAM stick: gigabytes
##   tool        "screwdriver"
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
##   parts       [[size, offset, colour, emission, tag, options]...] visual parts (tag and options optional;
##               tag "led" = status light; options: shape, r, mat, basis, hole, top, seg: see "Part builders" below)

const Shapes = preload("res://scripts/shapes.gd")
const Materials = preload("res://scripts/materials.gd")

const START_MONEY := 1500.0
const BREAKER_WATTS := 3600.0    # what the garage's wiring can carry before its breaker trips
const MAX_CABLE := 7.0           # metres a loose stretch of cable reaches before it gets yanked out
const MAX_ROUTED := 40.0         # metres of cable in total when it is pinned along the way
const MAX_PINS := 24
# Loose CPUs, RAM sticks and GPUs are delicate. A hit takes speed off them: below HIT_SAFE m/s nothing happens
# (letting go at chest height is about 5), from HIT_SURE up it is certain (a throw lands at 8 to 10).
const HIT_SAFE := 6.5
const HIT_SURE := 10.0
const HIT_INSIDE := 0.25         # chance for each part inside a machine that takes such a hit
const STEP_WALK := 0.15          # chance that walking over a part on the floor breaks it; sprinting always does
const RAIN_GRACE := 5.0          # seconds of rain a fragile item survives
const SHOP: Array[String] = ["mini_pc", "server_frame", "server_ws", "server_2u", "server_wslc", "server_4u", "server_pod",
	"cpu_pentum", "cpu_celery", "cpu_ryzer", "cpu_ryzer7", "cpu_thread", "cpu_corei9", "cpu_xenon", "cpu_xenonp", "cpu_epycc", "cpu_bergamo",
	"ram_4", "ram_16", "ram_32", "ram_64", "ram_128", "ram_256", "ram_512",
	"gpu_580", "gpu_1650", "gpu_4060", "gpu_4070", "gpu_4070ti", "gpu_4080", "gpu_4090", "gpu_6000",
	"gpu_l40s", "gpu_5090", "gpu_a100", "gpu_mi300", "gpu_h100", "gpu_b200", "screwdriver",
	"powerstrip", "switch", "rack_half", "rack", "rack_tall", "pump", "reservoir", "radiator", "manifold", "bucket", "suit",
	"thermometer", "sensor_power", "sensor_coolant", "screen",
	"gen_bike", "gen_mower", "gen_solar", "gen_diesel", "fuel", "inlet", "outlet", "lamp",
	"fan", "aircon", "extinguisher", "crate"]

## The parts market's shelves. `color` is a name the shop maps to its palette.
## A category with more than a handful of parts lists its `subs` ([{key, name}]); every SHOP_INFO entry of such a
## category names its sub-category as the third element.
const CATEGORIES: Array[Dictionary] = [
	{"key": "compute", "name": "Compute", "icon": "memory", "color": "purple", "subs": [
		{"key": "rigs", "name": "Machines"}, {"key": "gpu", "name": "GPUs"}, {"key": "cpu", "name": "CPUs"},
		{"key": "memory", "name": "Memory"}, {"key": "racks", "name": "Racks"}]},
	{"key": "power", "name": "Power", "icon": "bolt", "color": "amber"},
	{"key": "cooling", "name": "Cooling", "icon": "water_drop", "color": "cyan", "subs": [
		{"key": "air", "name": "Air"}, {"key": "liquid", "name": "Liquid loop"}]},
	{"key": "wiring", "name": "Wiring and network", "icon": "cable", "color": "blue"},
	{"key": "sensors", "name": "Sensors and screens", "icon": "speed", "color": "green"},
	{"key": "workshop", "name": "Workshop", "icon": "build", "color": "grey"},
]

## For every part in SHOP (and the used market's staples): [category key, what the shop says about it].
const GROUP_NAMES := {"cpu": "CPU", "ram": "RAM", "gpu": "GPU", "server": "server"}

const SHOP_INFO: Dictionary = {
	"pc_office": ["compute", "Beige. Came out of an accountant's office. Takes one small GPU and judges you.", "rigs"],
	"server": ["compute", "Second-hand tower server: two GPU slots, four for RAM, and a past nobody talks about.", "rigs"],
	"server_ws": ["compute", "A proper workstation. The first chassis whose power supply can feed a 4090.", "rigs"],
	"server_4u": ["compute", "Four GPU slots, two CPU sockets and coolant fittings. This is where it gets serious.", "rigs"],
	"server_pod": ["compute", "Eight GPUs in one box. Needs a loop, a forklift and a second mortgage.", "rigs"],
	"cpu_celery": ["compute", "Two cores, both tired. Enough to boot and to hold back anything good.", "cpu"],
	"cpu_ryzer": ["compute", "Six honest cores. The sensible choice, so nobody brags about it.", "cpu"],
	"cpu_thread": ["compute", "More cores than you have friends. Runs hot, runs fast.", "cpu"],
	"cpu_xenon": ["compute", "Server silicon. The box says Gold; the price agrees.", "cpu"],
	"cpu_epycc": ["compute", "Ninety-six cores. Feeds a rack of H100s without blinking.", "cpu"],
	"ram_8": ["compute", "One used stick. Somebody else's browser tabs are probably still in it.", "memory"],
	"ram_16": ["compute", "Sixteen gigabytes. Enough for a 4070 to stretch its legs.", "memory"],
	"ram_32": ["compute", "Thirty-two gigabytes, which is what a 4090 asks for.", "memory"],
	"ram_64": ["compute", "Sixty-four gigabytes. Datacenter cards will not start for less.", "memory"],
	"ram_256": ["compute", "A quarter of a terabyte on one stick. Server boards only want the best.", "memory"],
	"screwdriver": ["workshop", "Opens server lids. Without it your parts are decorations."],
	"gpu_1080": ["compute", "Somebody mined on this for six years. It still works. Usually.", "gpu"],
	"gpu_4070": ["compute", "New, sensible, boring. Does what it says on the box.", "gpu"],
	"gpu_4090": ["compute", "Draws 450 W and looks good doing it. The last card that cools itself.", "gpu"],
	"gpu_a100": ["compute", "A datacenter card. It has no fans: the server it sits on needs a coolant loop.", "gpu"],
	"gpu_h100": ["compute", "The one everybody is fighting over. Seventy tokens a second, zero fans.", "gpu"],
	"rack": ["compute", "Holds four servers upright and makes the garage look like you meant it.", "racks"],
	"gen_bike": ["power", "An exercise bike with a dynamo. Makes power for as long as a friend keeps pedalling."],
	"gen_mower": ["power", "A lawnmower engine bolted to an alternator. Loud, thirsty, surprisingly reliable."],
	"gen_solar": ["power", "Free power from the sky, when the sky feels like it."],
	"gen_diesel": ["power", "A real generator with four sockets. Weighs as much as a neighbour."],
	"fuel": ["power", "A full jerry can. Pour it into a generator."],
	"powerstrip": ["wiring", "Four sockets on a cable. You can plug it into another one. You should not."],
	"inlet": ["wiring", "Mount it in a building and cable it to a generator: the building's wiring goes live."],
	"outlet": ["wiring", "Delivers whatever power the building's inlets bring in. Two plugs."],
	"switch": ["wiring", "Four more network ports. Needs power itself."],
	"pump": ["cooling", "The heart of a coolant loop. Its own hose goes to a reservoir; everything else plugs into it.", "liquid"],
	"reservoir": ["cooling", "Holds the water. Fill it by bucket, or hose it to the garden tap and forget about it.", "liquid"],
	"radiator": ["cooling", "Gets rid of the heat your coolant picked up. Works best outside in the rain.", "liquid"],
	"manifold": ["cooling", "Six hose sockets, so one pump can serve a whole rack.", "liquid"],
	"bucket": ["cooling", "For carrying water from the garden tap to a reservoir, three trips at a time.", "liquid"],
	"fan": ["cooling", "Pushes warm air out of the room a little faster.", "air"],
	"aircon": ["cooling", "Takes 2,500 W of heat out of a room, for 700 W of your precious power.", "air"],
	"thermometer": ["sensors", "Without one you do not know how hot a room is. You will find out anyway."],
	"sensor_power": ["sensors", "Plug it into a generator or a wall socket and its load shows up on the ops screen."],
	"sensor_coolant": ["sensors", "Hose it into a loop to see water temperature, flow and reservoir level."],
	"screen": ["sensors", "Another ops screen for another room. Goes dark without power."],
	"lamp": ["workshop", "Five watts of cosy light. Goes out in a power cut, which is the funny part."],
	"extinguisher": ["workshop", "Hold it, look at the fire, click. Buy it before you need it."],
	"suit": ["workshop", "For working in rooms that would otherwise cook you. Walks like it looks."],
	"crate": ["workshop", "An empty box. One dollar. Do not ask what it is for."],
	"mini_pc": ["compute", "A lunchbox with one GPU slot and a power supply for a laptop. Does not fit a 4070, nor any dreams.", "rigs"],
	"server_frame": ["compute", "Six cards on a bare frame, no lid, no walls. Cheap, loud, and anything above tier 2 will not fit.", "rigs"],
	"server_2u": ["compute", "A pizza box with two flat GPU slots, two sockets and a lid that is not that hard to lose.", "rigs"],
	"server_wslc": ["compute", "A workstation that came with coolant fittings, so a tier 4 card can finally live in an office.", "rigs"],
	"cpu_pentum": ["compute", "Two cores and a gold sticker. Marginally less tired than the Celery.", "cpu"],
	"cpu_ryzer7": ["compute", "Eight cores for people who found the Ryzer 5 too modest.", "cpu"],
	"cpu_corei9": ["compute", "Feeds a 4090 and heats the room. Pick one.", "cpu"],
	"cpu_xenonp": ["compute", "The box says Platinum. The invoice says more.", "cpu"],
	"cpu_bergamo": ["compute", "A hundred and twenty-eight small cores that think they are one large one.", "cpu"],
	"ram_4": ["compute", "Four gigabytes. It is a start, and technically a stick.", "memory"],
	"ram_128": ["compute", "A hundred and twenty-eight gigabytes with a heat spreader and opinions.", "memory"],
	"ram_512": ["compute", "Half a terabyte on one stick, with a heat shield. Do not drop it.", "memory"],
	"gpu_580": ["compute", "Cheap per token and loud in every other respect. Eats 220 W to do the work of a modest card.", "gpu"],
	"gpu_1650": ["compute", "Seventy-five watts, no power connector, no excitement. Slow, thrifty and everywhere.", "gpu"],
	"gpu_4060": ["compute", "The sensible little sibling of the 4070. Barely sips power.", "gpu"],
	"gpu_4070ti": ["compute", "A 4070 that went to the gym. Still air cooled, still a tier 2.", "gpu"],
	"gpu_4080": ["compute", "A 4090 for people who stopped at the second price tag. Needs a little less of everything.", "gpu"],
	"gpu_6000": ["compute", "A workstation card with a blower and a huge memory pool. Asks for 96 GB of RAM before it gets out of bed.", "gpu"],
	"gpu_l40s": ["compute", "Datacenter silicon with a modest appetite. Needs a coolant loop, like all of its friends.", "gpu"],
	"gpu_5090": ["compute", "A tier 4 card that still has fans. 600 W of it. Your room will notice.", "gpu"],
	"gpu_mi300": ["compute", "Almost an H100, for slightly less money and slightly more RAM. A different logo on the bill.", "gpu"],
	"gpu_b200": ["compute", "Two dies, two cold plates and 1100 W. It is faster than anything and it knows it.", "gpu"],
	"rack_half": ["compute", "Two servers and a polite amount of garage.", "racks"],
	"rack_tall": ["compute", "Six servers, floor to ceiling, and a lot of purple light.", "racks"],
}

## Weather states. `solar` scales what a solar panel can deliver.
const WEATHER: Array[Dictionary] = [
	{"name": "Sunny", "solar": 1.0, "temp": 26.0, "cooling": 0.8, "news": "The sun is out: solar panels at full power"},
	{"name": "Cloudy", "solar": 0.4, "temp": 20.0, "cooling": 1.0, "news": "Clouds are rolling in: solar panels down to 40%"},
	{"name": "Rain", "solar": 0.0, "rain": true, "temp": 14.0, "cooling": 1.3,
		"news": "It's raining: solar panels produce nothing, and electronics left outside will be ruined"},
]

static var ITEMS: Dictionary = _build()




# =====================================================================================
# Part builders. A part is  [size, position, colour, emission, (tag), (options)]  where the
# tag (String, "led" = status light) and the options (Dictionary) are both optional:
#   shape  "box" (default), "cyl" (size = diameter, length, diameter), "ring" (a tube: `hole` is the
#          inner diameter as a fraction), "sphere" (an ellipsoid), "wedge" (tall at -Z, sloping to +Z)
#   r      bevel radius (0 = a flat box with hard edges); default depends on the size
#   mat    finish: "metal" "brushed" "chrome" "gold" "plastic" "matte" "rubber" "pcb" "glass"
#          (or empty: picked from the colour)
#   basis  a Basis that rotates the part around its own centre (cylinders point along Y until rotated)
#   top    "cyl" only: top diameter as a fraction of the bottom one (0.6 = a cone-ish frustum)
#   seg    segments around a round shape (default 14)
# Helpers below return ready-made parts; `_xf` moves a whole list of parts.
# =====================================================================================

static func _o(o: Dictionary, fin: String, r: float) -> Dictionary:
	if fin != "":
		o["mat"] = fin
	if r >= 0.0:
		o["r"] = r
	return o


## A box. `r` < 0 picks a bevel from the size; 0 makes it flat.
static func _p(size: Vector3, pos: Vector3, col: Color, fin := "", r := -1.0) -> Array:
	return [size, pos, col, 0.0, _o({}, fin, r)]


## An always-glowing box (no status behaviour).
static func _e(size: Vector3, pos: Vector3, col: Color, energy := 2.0, r := 0.0) -> Array:
	return [size, pos, col, energy, _o({}, "", r)]


## A status light: goes dark when the item is off, orange on a warning.
static func _led(size: Vector3, pos: Vector3, col: Color, energy := 2.5, r := 0.0) -> Array:
	return [size, pos, col, energy, "led", _o({}, "", r)]


static func _axis(axis: String) -> Basis:
	match axis:
		"x":
			return Basis(Vector3.BACK, -PI / 2.0)
		"z":
			return Basis(Vector3.RIGHT, PI / 2.0)
	return Basis.IDENTITY


## A cylinder `length` long along `axis` ("x", "y" or "z").
static func _cyl(dia: float, length: float, pos: Vector3, col: Color, axis := "y", fin := "", r := -1.0) -> Array:
	var o := _o({"shape": "cyl", "basis": _axis(axis)}, fin, r)
	return [Vector3(dia, length, dia), pos, col, 0.0, o]


## A tube (cylinder with a hole; `hole` = inner diameter / outer diameter).
static func _tube(dia: float, hole: float, length: float, pos: Vector3, col: Color, axis := "y", fin := "") -> Array:
	var o := _o({"shape": "ring", "hole": hole, "basis": _axis(axis)}, fin, -1.0)
	return [Vector3(dia, length, dia), pos, col, 0.0, o]


## A frustum along `axis`: `dia` at the bottom, dia * top at the top (axis +Y / +X / +Z end).
static func _cone(dia: float, top: float, length: float, pos: Vector3, col: Color, axis := "y", fin := "") -> Array:
	var o := _o({"shape": "cyl", "top": top, "basis": _axis(axis)}, fin, -1.0)
	return [Vector3(dia, length, dia), pos, col, 0.0, o]


static func _ball(size: Vector3, pos: Vector3, col: Color, fin := "") -> Array:
	return [size, pos, col, 0.0, _o({"shape": "sphere"}, fin, -1.0)]


static func _wedge(size: Vector3, pos: Vector3, col: Color, basis := Basis.IDENTITY, fin := "") -> Array:
	return [size, pos, col, 0.0, _o({"shape": "wedge", "basis": basis}, fin, -1.0)]


## A round rod from point `a` to point `b`.
static func _rod(a: Vector3, b: Vector3, dia: float, col: Color, fin := "") -> Array:
	var y := (b - a).normalized()
	var ref := Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.FORWARD
	var x := ref.cross(y).normalized()
	var z := x.cross(y)
	var o := _o({"shape": "cyl", "basis": Basis(x, y, z)}, fin, -1.0)
	return [Vector3(dia, a.distance_to(b), dia), (a + b) * 0.5, col, 0.0, o]


## Moves and turns a list of parts as one: `basis` first, then `offset`.
static func _xf(parts: Array, basis: Basis, offset := Vector3.ZERO) -> Array:
	var out := []
	for part: Array in parts:
		var q := part.duplicate()
		q[1] = basis * (part[1] as Vector3) + offset
		var found := false
		for i in range(4, q.size()):
			if q[i] is Dictionary:
				var o: Dictionary = (q[i] as Dictionary).duplicate()
				o["basis"] = basis * (o.get("basis", Basis.IDENTITY) as Basis)
				q[i] = o
				found = true
		if not found:
			q.append({"basis": basis})
		out.append(q)
	return out


## `n` copies of one box spread evenly from `a` to `b`: vent slats, ribs, drive bays, keys.
static func _row(n: int, a: Vector3, b: Vector3, size: Vector3, col: Color, fin := "", r := 0.0) -> Array:
	var out := []
	for i in n:
		var t := 0.5 if n == 1 else float(i) / (n - 1)
		out.append(_p(size, a.lerp(b, t), col, fin, r))
	return out


## A round fan facing +Y, resting on y = 0: a frame ring, a dark well, a hub and tilted blades.
static func _fan(dia: float, frame: Color, blade: Color, blades := 7) -> Array:
	var out := [
		_cyl(dia, 0.0015, Vector3(0, 0.0003, 0), Color(0.015, 0.015, 0.02), "y", "matte", 0.0),
		_tube(dia, 0.88, 0.007, Vector3(0, 0.0015, 0), frame, "y", "plastic"),
		_cyl(dia * 0.3, 0.007, Vector3(0, 0.0035, 0), frame.darkened(0.2), "y", "plastic"),
	]
	for k in blades:
		var a := TAU * k / blades
		var spin := Basis(Vector3.UP, a)
		out.append([Vector3(dia * 0.3, 0.0012, dia * 0.2), spin * Vector3(dia * 0.28, 0.002, 0), blade, 0.0,
				{"r": 0.0, "mat": "plastic", "basis": spin * Basis(Vector3.RIGHT, deg_to_rad(28.0))}])
	return out


## A round wire grille facing +Y: rings and a cross.
static func _grille(dia: float, col: Color) -> Array:
	return [
		_tube(dia, 0.94, 0.004, Vector3(0, 0.002, 0), col, "y", "metal"),
		_tube(dia * 0.66, 0.93, 0.0025, Vector3(0, 0.0015, 0), col, "y", "metal"),
		_tube(dia * 0.33, 0.9, 0.0025, Vector3(0, 0.0015, 0), col, "y", "metal"),
		_p(Vector3(dia * 0.96, 0.0025, 0.0025), Vector3(0, 0.0015, 0), col, "metal", 0.0),
		_p(Vector3(0.0025, 0.0025, dia * 0.96), Vector3(0, 0.0015, 0), col, "metal", 0.0),
	]


static func _screw(pos: Vector3, axis := "y", dia := 0.008) -> Array:
	return _cyl(dia, 0.003, pos, Color(0.7, 0.72, 0.76), axis, "chrome", 0.0006)


# =====================================================================================
# Compute parts
# =====================================================================================

## The processor package: green substrate, gold contact field underneath, nickel heat spreader.
static func _cpu(label: String, price: int, tier: int, tokens: float, watts: float, look := "") -> Dictionary:
	var accent: Color = [Color(0.6, 0.62, 0.66), Color(0.9, 0.25, 0.2), Color(0.25, 0.5, 1.0), Color(0.95, 0.75, 0.2), Color(0.8, 0.35, 1.0)][tier - 1]
	var lid_col: Color = [Color(0.62, 0.64, 0.68), Color(0.7, 0.72, 0.76), Color(0.74, 0.76, 0.8), Color(0.78, 0.8, 0.84), Color(0.8, 0.82, 0.86)][tier - 1]
	match look:   # sidegrades of a tier look different: black, gold or oversized spreaders
		"dark":
			lid_col = Color(0.16, 0.16, 0.18)
			accent = Color(1.0, 0.45, 0.1)
		"gold":
			lid_col = Color(0.9, 0.72, 0.25)
			accent = Color(0.15, 0.15, 0.17)
		"blue":
			lid_col = Color(0.35, 0.45, 0.7)
	var big := tier >= 4 or look == "wide"
	var s := 0.056 if big else 0.05   # heat spreader width
	var parts := [
		_p(Vector3(0.064, 0.0012, 0.064), Vector3(0, -0.0119, 0), Color(0.9, 0.7, 0.22), "gold", 0.0),   # contact pads, underneath
		_p(Vector3(0.07, 0.004, 0.07), Vector3(0, -0.0092, 0), Color(0.07, 0.3, 0.17), "pcb", 0.001),
		_p(Vector3(s, 0.013, s), Vector3(0, -0.0005, 0), lid_col, "metal", 0.003),
		_p(Vector3(s - 0.012, 0.0015, s - 0.012), Vector3(0, 0.0065, 0), lid_col.lightened(0.12), "chrome", 0.0),
		_led(Vector3(0.009, 0.0016, 0.009), Vector3(s * 0.5 - 0.008, 0.0075, -s * 0.5 + 0.008), accent, 1.8),
		_p(Vector3(0.03, 0.0016, 0.007), Vector3(0, 0.0072, s * 0.5 - 0.012), accent, "plastic", 0.0),
	]
	for c: Vector2 in [Vector2(-0.03, -0.012), Vector2(-0.03, 0.012), Vector2(0.03, -0.012), Vector2(0.03, 0.012),
			Vector2(-0.012, 0.031), Vector2(0.012, 0.031), Vector2(-0.012, -0.031), Vector2(0.012, -0.031)]:
		parts.append(_p(Vector3(0.006, 0.0025, 0.004), Vector3(c.x, -0.0055, c.y), Color(0.12, 0.12, 0.13), "", 0.0))
	if big:   # server parts: a second, ribbed spreader plate
		parts.append_array(_row(4, Vector3(-0.015, 0.0075, 0), Vector3(0.015, 0.0075, 0), Vector3(0.003, 0.001, s - 0.02), Color(0.5, 0.52, 0.56), "metal", 0.0))
	return {"label": label, "group": "cpu", "price": price, "tier": tier, "tokens": tokens, "watts": watts, "fragile": true,
		"size": Vector3(0.07, 0.025, 0.07), "mass": 0.1, "parts": parts}


## A memory stick: PCB with chips on both sides, gold edge connector, heat spreaders on the bigger ones.
static func _ram(label: String, price: int, gb: int) -> Dictionary:
	var pcb := Color(0.08, 0.34, 0.2) if gb < 256 else Color(0.1, 0.3, 0.18)
	var parts := [
		_p(Vector3(0.14, 0.035, 0.0016), Vector3.ZERO, pcb, "pcb", 0.0),
		_p(Vector3(0.062, 0.003, 0.0018), Vector3(-0.037, -0.0165, 0), Color(0.9, 0.72, 0.22), "gold", 0.0),
		_p(Vector3(0.062, 0.003, 0.0018), Vector3(0.039, -0.0165, 0), Color(0.9, 0.72, 0.22), "gold", 0.0),
	]
	var chips := 4 if gb < 16 else 6
	if gb >= 256:
		chips = 9
	var spreader := gb >= 32 and gb < 256
	for side: float in [-1.0, 1.0]:
		if not spreader:
			for i in chips:
				var x := lerpf(-0.056, 0.056, float(i) / (chips - 1)) if chips > 1 else 0.0
				parts.append(_p(Vector3(0.0105 if chips > 6 else 0.014, 0.012, 0.0022), Vector3(x, 0.002, side * 0.0019), Color(0.05, 0.05, 0.06), "plastic", 0.0))
		else:
			var plate := Color(0.14, 0.14, 0.16) if gb == 32 else (Color(0.86, 0.66, 0.26) if gb == 128 else Color(0.72, 0.74, 0.78))
			parts.append(_p(Vector3(0.132, 0.03, 0.0032), Vector3(0, 0.0015, side * 0.0024), plate, "metal", 0.0015))
			parts.append_array(_row(6, Vector3(-0.045, 0.0165, side * 0.0024), Vector3(0.045, 0.0165, side * 0.0024), Vector3(0.007, 0.004, 0.0034), plate, "metal", 0.0))
			parts.append(_p(Vector3(0.05, 0.012, 0.0005), Vector3(0.0, -0.004, side * 0.0042), Color(0.9, 0.2, 0.15) if gb == 32 else (Color(0.2, 0.8, 0.4) if gb == 128 else Color(0.2, 0.5, 0.95)), "", 0.0))
	if spreader:
		parts.append(_led(Vector3(0.1, 0.0035, 0.0045), Vector3(0, 0.0185, 0), Color(0.3, 0.9, 1.0) if gb == 64 else (Color(1.0, 0.7, 0.15) if gb == 128 else Color(1.0, 0.3, 0.6)), 2.2))
	else:
		parts.append(_p(Vector3(0.05, 0.01, 0.0004), Vector3(0.0, 0.0085, 0.0026), Color(0.92, 0.92, 0.9), "matte", 0.0))   # label sticker
	if gb >= 256:   # RDIMM: ejector latches and a register chip; the 512 has a heat shield too
		if gb >= 512:
			parts.append(_p(Vector3(0.12, 0.024, 0.0022), Vector3(0, -0.002, 0.0034), Color(0.8, 0.82, 0.86), "metal", 0.0))
			parts.append(_p(Vector3(0.12, 0.024, 0.0022), Vector3(0, -0.002, -0.0034), Color(0.8, 0.82, 0.86), "metal", 0.0))
		parts.append(_p(Vector3(0.012, 0.012, 0.0024), Vector3(0.0, 0.013, 0.0019), Color(0.04, 0.04, 0.05), "plastic", 0.0))
		var latch := Color(0.2, 0.45, 0.95) if gb == 256 else Color(1.0, 0.5, 0.1)
		parts.append(_p(Vector3(0.006, 0.03, 0.006), Vector3(-0.0715, 0.0, 0), latch, "plastic", 0.0015))
		parts.append(_p(Vector3(0.006, 0.03, 0.006), Vector3(0.0715, 0.0, 0), latch, "plastic", 0.0015))
	return {"label": label, "group": "ram", "price": price, "gb": gb, "watts": 3.0, "fragile": true, "used": label.contains("used"),
		"size": Vector3(0.14, 0.035, 0.012), "mass": 0.05, "parts": parts}


## The look of a graphics card, flat on its back (fans up, +Y), long side along X. Tier 1-3 are air cooled with
## a shroud and fans, 4 and 5 are bare datacentre cards with a coolant cold plate and two fittings.
## `v` overrides the tier's look: body, blade, trim, plate, stripe (Colors), fans (1-3), d (fan diameter), thick,
## blower (bool: one intake window and a rear grille instead of fans), plates (1 or 2 cold plates).
static func _gpu_parts(tier: int, glow: Color, liquid: bool, v := {}) -> Array:
	var th: float = v.get("thick", [0.034, 0.04, 0.045, 0.036, 0.04][tier - 1])   # body thickness, from y = -0.02 upwards
	var top := -0.02 + th
	var mid := -0.02 + th * 0.5
	var body: Color = v.get("body", [Color(0.13, 0.13, 0.15), Color(0.15, 0.15, 0.18), Color(0.19, 0.19, 0.22), Color(0.1, 0.1, 0.12), Color(0.09, 0.09, 0.1)][tier - 1])
	var silver: Color = v.get("trim", Color(0.72, 0.74, 0.78))
	var blower: bool = v.get("blower", false)
	var parts := [
		_p(Vector3(0.29, 0.005, 0.122), Vector3(0, -0.0225, 0), silver if (tier == 3 or v.has("trim")) else Color(0.2, 0.21, 0.24), "brushed", 0.002),   # backplate
		_p(Vector3(0.003, 0.05, 0.126), Vector3(-0.1485, 0, 0), Color(0.8, 0.82, 0.85), "metal", 0.0),   # I/O bracket
		_p(Vector3(0.075, 0.003, 0.006), Vector3(-0.04, -0.0165, -0.0625), Color(0.92, 0.74, 0.24), "gold", 0.0),   # PCIe fingers
		_p(Vector3(0.292, th, 0.124), Vector3(0, mid, 0), body, "plastic", 0.007),
		_led(Vector3(0.22, 0.005, 0.004), Vector3(0.0, mid, 0.0615), glow, 2.6),
	]
	for k in 3:
		parts.append(_p(Vector3(0.0036, 0.011, 0.016), Vector3(-0.1488, -0.004, -0.034 + k * 0.034), Color(0.03, 0.03, 0.04), "matte", 0.0))
	if not liquid:
		var fans: int = v.get("fans", [2, 2, 3][tier - 1] if tier <= 3 else 3)
		var d: float = v.get("d", [0.088, 0.098, 0.092][tier - 1] if tier <= 3 else 0.092)
		var xs: Array = [[0.012], [-0.045, 0.06], [-0.095, 0.0, 0.095]][fans - 1]
		var blade: Color = v.get("blade", Color(0.4, 0.42, 0.46) if tier < 3 else Color(0.82, 0.84, 0.88))
		if blower:   # one intake window, a rear exhaust grille
			parts.append(_p(Vector3(0.11, 0.0012, 0.1), Vector3(0.01, top + 0.0003, 0), Color(0.02, 0.02, 0.03), "matte", 0.0))
			parts.append_array(_xf(_fan(0.09, Color(0.05, 0.05, 0.06), blade, 11), Basis.IDENTITY, Vector3(0.01, top, 0)))
			parts.append_array(_xf(_grille(0.098, silver), Basis.IDENTITY, Vector3(0.01, top + 0.002, 0)))
			parts.append_array(_row(5, Vector3(0.09, top + 0.0003, 0), Vector3(0.14, top + 0.0003, 0), Vector3(0.006, 0.001, 0.1), Color(0.02, 0.02, 0.03), "matte", 0.0))
			parts.append(_p(Vector3(0.05, 0.002, 0.012), Vector3(-0.1, top + 0.0005, 0.04), v.get("stripe", Color(0.45, 0.8, 0.2)), "plastic", 0.0))
		else:
			for x: float in xs:
				parts.append_array(_xf(_fan(d, Color(0.07, 0.07, 0.08), blade, 7 if tier < 3 else 9), Basis.IDENTITY, Vector3(x, top, 0)))
				if tier >= 3:   # lit fan hub
					parts.append(_led(Vector3(0.016, 0.0015, 0.016), Vector3(x, top + 0.0072, 0), glow, 3.0, 0.0))
			if tier < 3:   # tail vents
				parts.append_array(_row(4, Vector3(0.121, top + 0.0003, 0), Vector3(0.14, top + 0.0003, 0), Vector3(0.005, 0.001, 0.09), Color(0.02, 0.02, 0.03), "matte", 0.0))
				parts.append(_p(Vector3(0.06, 0.0014, 0.007), Vector3(-0.115 if tier == 1 else -0.117, top + 0.0004, 0.03), Color(0.7, 0.72, 0.76), "chrome", 0.0))
			if tier >= 2:   # accent stripe
				parts.append(_p(Vector3(0.1, 0.0016, 0.007), Vector3(0.012, top + 0.0005, -0.054), silver, "metal", 0.0))
			if v.has("stripe"):
				parts.append(_p(Vector3(0.12, 0.0016, 0.012), Vector3(-0.02, top + 0.0006, 0.052), v["stripe"], "plastic", 0.0))
		if tier >= 3:   # the big ones: side fins
			parts.append(_p(Vector3(0.292, 0.006, 0.006), Vector3(0, top - 0.002, -0.058), silver, "metal", 0.0025))
			parts.append(_wedge(Vector3(0.04, 0.01, 0.02), Vector3(0.13, top + 0.003, 0.045), silver, Basis(Vector3.UP, PI * 0.5), "metal"))
			parts.append(_wedge(Vector3(0.04, 0.01, 0.02), Vector3(-0.13, top + 0.003, 0.045), silver, Basis(Vector3.UP, PI * 0.5), "metal"))
		if tier == 4:   # an air-cooled monster: heat pipes and fin stack at the end
			for i in 4:
				parts.append(_cyl(0.007, 0.03, Vector3(0.152, -0.012 + i * 0.011, 0.0), Color(0.85, 0.5, 0.26), "x", "metal"))
			parts.append_array(_row(7, Vector3(0.12, top + 0.004, 0), Vector3(0.146, top + 0.004, 0), Vector3(0.0025, 0.007, 0.115), Color(0.55, 0.57, 0.6), "metal", 0.0))
	else:
		var gold := tier == 5
		var trim: Color = v.get("trim", Color(0.95, 0.72, 0.2) if gold else Color(0.55, 0.58, 0.62))
		var plate: Color = v.get("plate", Color(0.86, 0.5, 0.26))
		var two: bool = v.get("plates", 1) == 2
		parts.append(_p(Vector3(0.286, 0.004, 0.006), Vector3(0, mid, -0.06), trim, "gold" if gold else "metal", 0.0))
		if two:   # two dies, two cold plates
			for px: float in [-0.065, 0.045]:
				parts.append(_p(Vector3(0.1, 0.007, 0.108), Vector3(px, top + 0.0025, 0), Color(0.06, 0.06, 0.07), "metal", 0.002))
				parts.append(_p(Vector3(0.08, 0.007, 0.082), Vector3(px, top + 0.008, 0), plate, "metal", 0.002))
				parts.append_array(_row(3, Vector3(px - 0.025, top + 0.0125, 0), Vector3(px + 0.025, top + 0.0125, 0), Vector3(0.004, 0.0015, 0.07), plate.darkened(0.15), "metal", 0.0))
		else:
			parts.append(_p(Vector3(0.208, 0.007, 0.108), Vector3(-0.02, top + 0.0025, 0), Color(0.06, 0.06, 0.07), "metal", 0.002))
			parts.append(_p(Vector3(0.17, 0.007, 0.082), Vector3(-0.02, top + 0.008, 0), plate, "metal", 0.002))   # cold plate
			parts.append_array(_row(5, Vector3(-0.085, top + 0.0125, 0), Vector3(0.045, top + 0.0125, 0), Vector3(0.004, 0.0015, 0.07), plate.darkened(0.15), "metal", 0.0))
		parts.append(_p(Vector3(0.06, 0.003, 0.02), Vector3(-0.1, top + 0.0015, 0.03), trim, "gold" if gold else "metal", 0.001))
		parts.append(_led(Vector3(0.05, 0.002, 0.006), Vector3(-0.1, top + 0.0035, 0.03), glow, 2.6))
		var fit_x: Array = [0.12, 0.09] if two else [0.115]
		for fx: float in fit_x:
			for side: float in [-1.0, 1.0]:   # inlet and outlet: blue and red collars
				var at := Vector3(fx, top, side * 0.027)
				var band := Color(0.2, 0.5, 0.95) if (side < 0.0) == (fx > 0.1) else Color(0.95, 0.3, 0.2)
				parts.append(_cyl(0.026, 0.012, at + Vector3(0, 0.006, 0), Color(0.08, 0.08, 0.09), "y", "metal"))
				parts.append(_cyl(0.019, 0.005, at + Vector3(0, 0.0125, 0), band, "y", "plastic"))
				parts.append(_cyl(0.015, 0.012, at + Vector3(0, 0.02, 0), Color(0.78, 0.8, 0.84), "y", "chrome"))
	return parts


static func _gpu(label: String, price: int, tier: int, tokens: float, watts: float, needs_ram: int, glow: Color, v := {}) -> Dictionary:
	return {"label": label, "group": "gpu", "price": price, "tier": tier, "tokens": tokens, "watts": watts,
		"needs_ram": needs_ram, "fragile": true, "used": label.contains("used"),
		"size": Vector3(0.3, 0.05, 0.13), "mass": 1.0, "parts": _gpu_parts(tier, glow, tier >= 4 and not v.get("air", false), v)}


## Datacenter cards: no fans of their own, a copper cold plate instead.
static func _liquid(gpu: Dictionary, v := {}) -> Dictionary:
	gpu["liquid"] = true
	var glow := Color.WHITE
	for part: Array in gpu["parts"]:
		if part.size() > 4 and part[4] is String and part[4] == "led":
			glow = part[2]
	gpu["parts"] = _gpu_parts(gpu["tier"], glow, true, v)
	return gpu


# =====================================================================================
# Machines
# =====================================================================================

## A machine: an open metal tray with a mainboard in it and a lid screwed on top.
## Slots, front to back: CPU sockets front left, a bank of RAM front right, GPUs standing on
## edge behind them in rows of four. `idle` = watts the bare machine draws.
## The look follows `max_tier` unless `o["look"]` says otherwise: 1 office PC, 2 tower server, 3 workstation,
## 4 GPU server, 5 AI pod, 6 2U server, 7 mini PC, 8 liquid-ready workstation. Other options in `o`: board (Color),
## compact (skip the extras that do not fit a small case), psu_h, couplers, ram_x, ram_z0, gpu_slots (Vector3 x, -, z
## per card), gpu_basis, gpu_y.
static func _chassis(label: String, price: int, size: Vector3, cpus: int, rams: int, gpus: int, psu: float,
		max_tier: int, idle: float, paint: Color, extra: Dictionary, o := {}) -> Dictionary:
	var w := size.x
	var h := size.y
	var d := size.z
	var wall := 0.015
	var floor_y := -h * 0.5 + wall
	var boxes := [   # bottom, two sides, front, back: the tray is open on top
		[Vector3(w, wall, d), Vector3(0, -h * 0.5 + wall * 0.5, 0)],
		[Vector3(wall, h, d), Vector3(-w * 0.5 + wall * 0.5, 0, 0)],
		[Vector3(wall, h, d), Vector3(w * 0.5 - wall * 0.5, 0, 0)],
		[Vector3(w, h, wall), Vector3(0, 0, -d * 0.5 + wall * 0.5)],
		[Vector3(w, h, wall), Vector3(0, 0, d * 0.5 - wall * 0.5)],
	]
	var slots := []
	for i in cpus:
		slots.append({"accepts": "cpu", "xf": Transform3D(Basis(), Vector3(-w * 0.5 + 0.085 + i * 0.1, floor_y + 0.018, -d * 0.5 + 0.1))})
	for j in rams:
		slots.append({"accepts": "ram", "xf": Transform3D(Basis(), Vector3(o.get("ram_x", w * 0.5 - 0.105), floor_y + 0.024, o.get("ram_z0", -d * 0.5 + 0.045) + j * 0.02))})
	var on_edge := Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0))   # card length along Z, fans facing +X
	for k in gpus:
		if o.has("gpu_slots"):
			var g: Vector3 = o["gpu_slots"][k]
			slots.append({"accepts": "gpu", "xf": Transform3D(o.get("gpu_basis", on_edge), Vector3(g.x, floor_y + o.get("gpu_y", 0.072), g.z))})
			continue
		var row := k / 4
		var in_row := mini(gpus - row * 4, 4)
		var x := (k % 4 - (in_row - 1) * 0.5) * 0.085 + 0.04
		slots.append({"accepts": "gpu", "xf": Transform3D(on_edge, Vector3(x, floor_y + 0.072, -d * 0.5 + 0.37 + row * 0.31))})
	var def := {"label": label, "group": "server", "price": price, "watts": idle, "psu": psu, "max_tier": max_tier,
		"power_port": true, "net_port": true, "fragile": true, "lid": true, "slots": slots,
		"size": size, "mass": 4.0 + size.z * 8.0, "shapes": boxes,
		"parts": _chassis_parts(o.get("look", max_tier), size, boxes, slots, paint, cpus, rams, gpus, o),
		"look": o.get("look", max_tier),
		"lid_box": [Vector3(w, wall, d), Vector3(0, h * 0.5 - wall * 0.5, 0), paint.lightened(0.06)]}
	def.merge(extra, true)
	return def


static func _chassis_parts(style: int, size: Vector3, boxes: Array, slots: Array, paint: Color, cpus: int, rams: int, gpus: int, o := {}) -> Array:
	var w := size.x
	var h := size.y
	var d := size.z
	var floor_y := -h * 0.5 + 0.015
	var fin := "plastic" if style == 1 else ""
	var parts := []
	for box: Array in boxes:
		parts.append(_p(box[0], box[1], paint, fin, 0.003))
	# --- the inside -------------------------------------------------------------------
	var board: Color = o.get("board", [Color(0.06, 0.3, 0.16), Color(0.05, 0.05, 0.07), Color(0.05, 0.12, 0.3), Color(0.07, 0.07, 0.09), Color(0.22, 0.1, 0.35)][mini(style, 5) - 1])
	var compact: bool = o.get("compact", false)
	var psu_h: float = o.get("psu_h", 0.075)
	var ram_i := 0
	parts.append(_p(Vector3(w - 0.05, 0.004, d - 0.05), Vector3(0, floor_y + 0.002, 0), board, "pcb", 0.0))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			parts.append(_screw(Vector3(sx * (w * 0.5 - 0.034), floor_y + 0.0055, sz * (d * 0.5 - 0.034)), "y", 0.009))
	var dark := Color(0.07, 0.07, 0.08)
	for s: Dictionary in slots:
		var at: Vector3 = (s["xf"] as Transform3D).origin
		match s["accepts"]:
			"cpu":
				parts.append(_p(Vector3(0.09, 0.0035, 0.09), Vector3(at.x, floor_y + 0.0057, at.z), Color(0.5, 0.52, 0.56), "metal", 0.002))
				parts.append(_p(Vector3(0.062, 0.0016, 0.062), Vector3(at.x, floor_y + 0.0078, at.z), Color(0.1, 0.1, 0.12), "matte", 0.0))
				parts.append(_cyl(0.0035, 0.07, Vector3(at.x, floor_y + 0.0095, at.z + 0.044), Color(0.75, 0.77, 0.8), "x", "chrome", 0.0))
				parts.append(_p(Vector3(0.082, 0.02, 0.012), Vector3(at.x, floor_y + 0.014, at.z - 0.062), dark.lightened(0.05), "metal", 0.002))   # VRM heatsink
			"ram":
				var idx := ram_i
				ram_i += 1
				parts.append(_p(Vector3(0.148, 0.0065, 0.0125), Vector3(at.x, floor_y + 0.0072, at.z), Color(0.06, 0.06, 0.07) if idx % 2 == 0 else Color(0.33, 0.34, 0.37), "plastic", 0.001))
				if idx == 0 or idx == rams - 1:
					for lx: float in [-1.0, 1.0]:
						parts.append(_p(Vector3(0.006, 0.014, 0.013), Vector3(at.x + lx * 0.0765, floor_y + 0.011, at.z), Color(0.9, 0.9, 0.88), "plastic", 0.001))
			"gpu":
				if (s["xf"] as Transform3D).basis.y.y < 0.5:   # standing on edge: a slot under it
					parts.append(_p(Vector3(0.012, 0.0075, 0.1), Vector3(at.x, floor_y + 0.0079, at.z - 0.04), dark, "plastic", 0.001))
					parts.append(_p(Vector3(0.012, 0.0085, 0.012), Vector3(at.x, floor_y + 0.0084, at.z - 0.095), Color(0.8, 0.8, 0.78), "plastic", 0.001))
	if not compact:
		# left strip: chipset heatsink, VRM caps, M.2 stick
		var lx := -w * 0.5 + 0.06
		parts.append(_p(Vector3(0.05, 0.014, 0.05), Vector3(lx + 0.015, floor_y + 0.011, -0.03), Color(0.14, 0.14, 0.16), "metal", 0.002))
		parts.append_array(_row(5, Vector3(lx - 0.005, floor_y + 0.0195, -0.03), Vector3(lx + 0.035, floor_y + 0.0195, -0.03), Vector3(0.004, 0.003, 0.046), Color(0.3, 0.32, 0.36), "metal", 0.0))
		for i in 6:
			parts.append(_cyl(0.011, 0.016, Vector3(-w * 0.5 + 0.034, floor_y + 0.012, 0.03 + i * 0.016), Color(0.07, 0.07, 0.09) if style != 1 else Color(0.2, 0.2, 0.3), "y", "plastic", 0.001))
		parts.append(_p(Vector3(0.022, 0.003, 0.08), Vector3(-0.03 if style > 1 else -0.0, floor_y + 0.0055, -d * 0.5 + 0.12), Color(0.3, 0.32, 0.36), "metal", 0.0))
	# power supply with a fan grille on top
	var psu_pos := Vector3(-w * 0.5 + 0.075, floor_y + 0.004 + psu_h * 0.5, d * 0.5 - 0.095)
	parts.append(_p(Vector3(0.09, psu_h, 0.15), psu_pos, Color(0.5, 0.52, 0.56), "brushed", 0.003))
	parts.append_array(_xf(_fan(0.07, Color(0.1, 0.1, 0.12), Color(0.2, 0.2, 0.23), 5), Basis.IDENTITY, psu_pos + Vector3(0, psu_h * 0.5, 0.0)))
	parts.append_array(_xf(_grille(0.07, Color(0.55, 0.57, 0.6)), Basis.IDENTITY, psu_pos + Vector3(0, psu_h * 0.5 + 0.006, 0.0)))
	parts.append(_p(Vector3(0.05, 0.001, 0.034), psu_pos + Vector3(0, psu_h * 0.5, 0.055), Color(0.92, 0.92, 0.9), "matte", 0.0))
	if not compact:   # a drive cage: three 2.5 inch drives in sleds
		var cage := Vector3(w * 0.5 - 0.065, floor_y + 0.03, d * 0.5 - 0.07) if gpus <= 2 else Vector3(0.03, floor_y + 0.03, -d * 0.5 + 0.075)
		for i in 3:
			parts.append(_p(Vector3(0.056 if gpus <= 2 else 0.044, 0.012, 0.09), cage + Vector3(0, -0.012 + i * 0.014, 0), Color(0.55, 0.57, 0.6) if i != 1 else Color(0.2, 0.2, 0.24), "brushed", 0.0015))
		parts.append(_p(Vector3(0.06 if gpus <= 2 else 0.048, 0.003, 0.09), cage + Vector3(0, -0.0205, 0), Color(0.1, 0.1, 0.12), "metal", 0.0))
	# --- the outside: front (-Z), back (+Z), feet ---------------------------------------
	var fz := -d * 0.5 - 0.004
	parts.append(_p(Vector3(w - 0.006, h - 0.006, 0.012), Vector3(0, 0, -d * 0.5 + 0.002), paint.lightened(0.05), fin, 0.003))
	var led := Color(0.7, 0.4, 1.0)
	match style:
		1:   # office PC: beige, optical drive, power button, vent grille
			var beige := paint.darkened(0.08)
			parts.append(_p(Vector3(w * 0.78, 0.034, 0.004), Vector3(0, h * 0.27, fz - 0.0014), beige, "plastic", 0.002))
			parts.append(_p(Vector3(w * 0.62, 0.0035, 0.003), Vector3(-0.02, h * 0.27 + 0.004, fz - 0.003), Color(0.04, 0.04, 0.05), "matte", 0.0))
			parts.append(_p(Vector3(0.022, 0.009, 0.004), Vector3(w * 0.3, h * 0.27 - 0.008, fz - 0.003), Color(0.9, 0.9, 0.86), "plastic", 0.002))
			parts.append(_p(Vector3(0.09, 0.026, 0.004), Vector3(-w * 0.24, h * 0.0, fz - 0.0014), beige, "plastic", 0.002))
			parts.append(_p(Vector3(0.07, 0.003, 0.003), Vector3(-w * 0.24, h * 0.0, fz - 0.003), Color(0.04, 0.04, 0.05), "matte", 0.0))
			parts.append(_cyl(0.026, 0.006, Vector3(w * 0.3, -h * 0.24, fz - 0.002), Color(0.8, 0.8, 0.78), "z", "plastic", 0.002))
			parts.append(_tube(0.034, 0.78, 0.003, Vector3(w * 0.3, -h * 0.24, fz - 0.0012), Color(0.9, 0.9, 0.88), "z", "plastic"))
			parts.append(_led(Vector3(0.007, 0.007, 0.003), Vector3(w * 0.3 - 0.04, -h * 0.24, fz - 0.0014), Color(0.3, 1.0, 0.4), 2.5))
			parts.append_array(_row(6, Vector3(-w * 0.4, -h * 0.34, fz - 0.002), Vector3(-w * 0.1, -h * 0.34, fz - 0.002), Vector3(0.004, 0.032, 0.003), beige.darkened(0.45), "matte", 0.0))
			parts.append(_p(Vector3(0.045, 0.012, 0.002), Vector3(w * 0.12, -h * 0.34, fz - 0.002), Color(0.25, 0.45, 0.8), "plastic", 0.0))
		2:   # tower server: perforated bezel and three drive bays
			parts.append_array(_row(14, Vector3(-w * 0.45, -0.005, fz - 0.0014), Vector3(-w * 0.02, -0.005, fz - 0.0014), Vector3(0.007, h * 0.7, 0.003), Color(0.3, 0.32, 0.36), "metal", 0.0))
			for i in 3:
				var by := h * 0.28 - i * 0.056
				parts.append(_p(Vector3(w * 0.38, 0.044, 0.004), Vector3(w * 0.25, by, fz - 0.0012), Color(0.04, 0.04, 0.05), "matte", 0.002))
				parts.append(_p(Vector3(w * 0.3, 0.007, 0.004), Vector3(w * 0.25, by - 0.012, fz - 0.003), Color(0.5, 0.52, 0.56), "metal", 0.0015))
				parts.append(_p(Vector3(0.006, 0.006, 0.003), Vector3(w * 0.4, by + 0.012, fz - 0.003), Color(0.25, 0.9, 0.4), "", 0.0))
			parts.append(_cyl(0.02, 0.006, Vector3(-w * 0.38, h * 0.38, fz - 0.002), Color(0.75, 0.77, 0.8), "z", "chrome", 0.002))
			parts.append(_led(Vector3(w * 0.9, 0.006, 0.003), Vector3(0, h * 0.5 - 0.012, fz - 0.002), led, 3.0))
		6:   # 2U server: rack ears, two grilles, a row of bays
			for sx: float in [-1.0, 1.0]:
				parts.append(_p(Vector3(0.036, h, 0.014), Vector3(sx * (w * 0.5 - 0.018), 0, -d * 0.5 + 0.001), Color(0.62, 0.64, 0.68), "metal", 0.002))
				parts.append(_cyl(0.012, 0.006, Vector3(sx * (w * 0.5 - 0.018), h * 0.28, fz - 0.003), Color(0.9, 0.92, 0.95), "z", "chrome", 0.0015))
				parts.append(_p(Vector3(0.008, h * 0.4, 0.012), Vector3(sx * (w * 0.5 - 0.018), -h * 0.12, fz - 0.006), Color(0.1, 0.1, 0.12), "plastic", 0.003))
			for fx: float in [-0.13, -0.035]:
				var fb := Basis(Vector3.RIGHT, -PI / 2.0)
				parts.append_array(_xf(_fan(0.075, Color(0.08, 0.08, 0.1), Color(0.3, 0.32, 0.36), 7), fb, Vector3(fx, -0.005, fz)))
				parts.append_array(_xf(_grille(0.08, Color(0.5, 0.52, 0.56)), fb, Vector3(fx, -0.005, fz)))
			for c in 4:
				parts.append(_p(Vector3(0.05, 0.05, 0.004), Vector3(0.06 + c * 0.055, -0.005, fz - 0.0012), Color(0.04, 0.04, 0.05), "matte", 0.002))
				parts.append(_p(Vector3(0.04, 0.006, 0.004), Vector3(0.06 + c * 0.055, -0.022, fz - 0.003), Color(0.5, 0.52, 0.56), "metal", 0.0))
			parts.append(_led(Vector3(w * 0.6, 0.005, 0.003), Vector3(0, h * 0.5 - 0.012, fz - 0.002), led, 3.0))
		7:   # mini PC: a smooth little box, vents down one side, one button
			parts.append_array(_row(9, Vector3(-w * 0.4, 0.0, fz - 0.0014), Vector3(-w * 0.02, 0.0, fz - 0.0014), Vector3(0.006, h * 0.6, 0.003), Color(0.3, 0.32, 0.36), "metal", 0.0))
			parts.append(_cyl(0.026, 0.006, Vector3(w * 0.26, h * 0.2, fz - 0.002), Color(0.85, 0.87, 0.9), "z", "chrome", 0.002))
			parts.append(_p(Vector3(0.05, 0.012, 0.004), Vector3(w * 0.26, -h * 0.2, fz - 0.002), Color(0.05, 0.05, 0.06), "plastic", 0.003))
			parts.append(_led(Vector3(w * 0.8, 0.005, 0.003), Vector3(0, -h * 0.5 + 0.014, fz - 0.002), led, 3.0))
		3, 8:   # workstation: fine mesh, a flap and a vertical light bar
			parts.append_array(_row(10, Vector3(-w * 0.05, h * 0.4, fz - 0.0014), Vector3(-w * 0.05, h * 0.0, fz - 0.0014), Vector3(w * 0.78, 0.004, 0.003), Color(0.32, 0.34, 0.38), "metal", 0.0))
			parts.append(_p(Vector3(w * 0.86, 0.034, 0.004), Vector3(0, -h * 0.32, fz - 0.0012), Color(0.09, 0.09, 0.1), "metal", 0.002))
			parts.append(_p(Vector3(0.07, 0.01, 0.003), Vector3(-w * 0.3, -h * 0.32, fz - 0.003), Color(0.7, 0.72, 0.76), "chrome", 0.0))
			parts.append(_cyl(0.022, 0.006, Vector3(w * 0.34, -h * 0.32, fz - 0.002), Color(0.8, 0.82, 0.86), "z", "chrome", 0.002))
			parts.append(_led(Vector3(0.006, h * 0.84, 0.003), Vector3(w * 0.5 - 0.016, 0, fz - 0.002), led, 3.0))
			parts.append(_led(Vector3(0.006, h * 0.84, 0.003), Vector3(-w * 0.5 + 0.016, 0, fz - 0.002), led, 3.0))
		4:   # GPU server: rack ears, two big fans and a bay grid
			for sx: float in [-1.0, 1.0]:
				parts.append(_p(Vector3(0.036, h, 0.014), Vector3(sx * (w * 0.5 - 0.018), 0, -d * 0.5 + 0.001), Color(0.62, 0.64, 0.68), "metal", 0.002))
				parts.append(_cyl(0.014, 0.006, Vector3(sx * (w * 0.5 - 0.018), h * 0.3, fz - 0.003), Color(0.9, 0.92, 0.95), "z", "chrome", 0.0015))
				parts.append(_cyl(0.014, 0.006, Vector3(sx * (w * 0.5 - 0.018), -h * 0.3, fz - 0.003), Color(0.9, 0.92, 0.95), "z", "chrome", 0.0015))
				parts.append(_p(Vector3(0.008, h * 0.4, 0.012), Vector3(sx * (w * 0.5 - 0.018), 0, fz - 0.006), Color(0.1, 0.1, 0.12), "plastic", 0.003))
			for fx: float in [-0.14, -0.005]:
				var fb := Basis(Vector3.RIGHT, -PI / 2.0)
				parts.append_array(_xf(_fan(0.13, Color(0.08, 0.08, 0.1), Color(0.3, 0.32, 0.36), 9), fb, Vector3(fx, -0.012, fz)))
				parts.append_array(_xf(_grille(0.136, Color(0.5, 0.52, 0.56)), fb, Vector3(fx, -0.012, fz)))
			for c in 2:
				for r in 3:
					parts.append(_p(Vector3(0.048, 0.03, 0.004), Vector3(0.095 + c * 0.052, -0.012 + (1 - r) * 0.04, fz - 0.0012), Color(0.04, 0.04, 0.05), "matte", 0.002))
					parts.append(_p(Vector3(0.036, 0.005, 0.004), Vector3(0.095 + c * 0.052, -0.012 + (1 - r) * 0.04 - 0.009, fz - 0.003), Color(0.5, 0.52, 0.56), "metal", 0.0))
			parts.append(_led(Vector3(w * 0.7, 0.006, 0.003), Vector3(0, h * 0.5 - 0.016, fz - 0.002), led, 3.0))
			parts.append(_cyl(0.016, 0.006, Vector3(-0.17, h * 0.5 - 0.016, fz - 0.002), Color(0.8, 0.82, 0.86), "z", "chrome", 0.002))
		5:   # AI pod: a fan for every GPU, a status display and the liquid couplers
			parts.append(_p(Vector3(w - 0.006, h - 0.006, 0.004), Vector3(0, 0, fz - 0.0004), Color(0.28, 0.17, 0.42), "plastic", 0.003))
			for r in 2:
				for c in 4:
					var fb := Basis(Vector3.RIGHT, -PI / 2.0)
					var at := Vector3(-0.15 + c * 0.1, -0.032 - r * 0.0 + (0.026 if r == 0 else -0.058) - 0.0, fz)
					at.y = 0.035 - r * 0.075
					parts.append_array(_xf(_fan(0.07, Color(0.05, 0.05, 0.07), Color(0.6, 0.45, 0.9), 7), fb, at))
					parts.append_array(_xf(_grille(0.074, Color(0.5, 0.5, 0.56)), fb, at))
			parts.append(_p(Vector3(0.22, 0.026, 0.004), Vector3(0, h * 0.5 - 0.02, fz - 0.0012), Color(0.03, 0.03, 0.05), "plastic", 0.002))
			parts.append(_e(Vector3(0.2, 0.018, 0.0016), Vector3(0, h * 0.5 - 0.02, fz - 0.0032), Color(0.3, 0.9, 1.0), 1.4, 0.0))
			parts.append(_cyl(0.028, 0.014, Vector3(-w * 0.5 + 0.03, -h * 0.5 + 0.026, fz - 0.007), Color(0.2, 0.5, 0.95), "z", "plastic", 0.003))
			parts.append(_cyl(0.028, 0.014, Vector3(w * 0.5 - 0.03, -h * 0.5 + 0.026, fz - 0.007), Color(0.95, 0.3, 0.2), "z", "plastic", 0.003))
			parts.append(_cyl(0.016, 0.016, Vector3(-w * 0.5 + 0.03, -h * 0.5 + 0.026, fz - 0.015), Color(0.8, 0.82, 0.86), "z", "chrome", 0.002))
			parts.append(_cyl(0.016, 0.016, Vector3(w * 0.5 - 0.03, -h * 0.5 + 0.026, fz - 0.015), Color(0.8, 0.82, 0.86), "z", "chrome", 0.002))
			parts.append(_led(Vector3(w * 0.5, 0.005, 0.003), Vector3(0, -h * 0.5 + 0.014, fz - 0.002), led, 3.0))
			for sx: float in [-1.0, 1.0]:
				parts.append(_p(Vector3(0.012, h * 0.5, 0.016), Vector3(sx * (w * 0.5 - 0.0), 0.0, fz - 0.003), Color(0.75, 0.77, 0.8), "chrome", 0.004))
	if o.get("couplers", false):   # liquid-ready: two quick couplers under the light bar
		parts.append(_cyl(0.026, 0.014, Vector3(-w * 0.5 + 0.045, -h * 0.5 + 0.04, fz - 0.007), Color(0.2, 0.5, 0.95), "z", "plastic", 0.003))
		parts.append(_cyl(0.026, 0.014, Vector3(w * 0.5 - 0.045, -h * 0.5 + 0.04, fz - 0.007), Color(0.95, 0.3, 0.2), "z", "plastic", 0.003))
		parts.append(_cyl(0.015, 0.016, Vector3(-w * 0.5 + 0.045, -h * 0.5 + 0.04, fz - 0.015), Color(0.8, 0.82, 0.86), "z", "chrome", 0.002))
		parts.append(_cyl(0.015, 0.016, Vector3(w * 0.5 - 0.045, -h * 0.5 + 0.04, fz - 0.015), Color(0.8, 0.82, 0.86), "z", "chrome", 0.002))
	# back: power supply exhaust, mains inlet, I/O shield and a rear fan
	var bz := d * 0.5 + 0.0
	var rows_top := minf(0.07, h - 0.05)
	parts.append_array(_row(6, Vector3(-w * 0.5 + 0.075, floor_y + 0.012, bz), Vector3(-w * 0.5 + 0.075, floor_y + rows_top, bz), Vector3(0.07, 0.004, 0.003), Color(0.04, 0.04, 0.05), "matte", 0.0))
	parts.append(_p(Vector3(0.03, 0.022, 0.003), Vector3(-w * 0.5 + 0.12, floor_y + minf(0.062, rows_top - 0.008), bz), Color(0.03, 0.03, 0.04), "matte", 0.001))
	parts.append(_p(Vector3(0.12, 0.03, 0.003), Vector3(0.04, floor_y + minf(0.05, rows_top - 0.02), bz), Color(0.5, 0.52, 0.56), "metal", 0.0))
	parts.append_array(_row(4, Vector3(0.0, floor_y + minf(0.05, rows_top - 0.02), bz + 0.001), Vector3(0.08, floor_y + minf(0.05, rows_top - 0.02), bz + 0.001), Vector3(0.012, 0.012, 0.003), Color(0.04, 0.04, 0.05), "matte", 0.0))
	parts.append_array(_xf(_fan(0.06, Color(0.1, 0.1, 0.12), Color(0.25, 0.25, 0.3), 7), Basis(Vector3.RIGHT, PI / 2.0), Vector3(w * 0.5 - 0.06, h * 0.5 - minf(0.055, h * 0.4), bz)))
	# feet
	if style <= 3 or style == 7 or style == 8:
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				parts.append(_cyl(0.03, 0.012, Vector3(sx * (w * 0.5 - 0.035), -h * 0.5 - 0.0, sz * (d * 0.5 - 0.04)), Color(0.05, 0.05, 0.06), "y", "rubber", 0.003))
	return parts


## What sits on top of a machine: the lid (looks only; its collider is `lid_box`). Origin = lid centre.
static func lid_parts(def: Dictionary) -> Array:
	var lid: Array = def["lid_box"]
	var s: Vector3 = lid[0]
	var col: Color = lid[2]
	var style: int = def.get("look", def.get("max_tier", 1))
	style = {6: 3, 7: 2, 8: 3}.get(style, style)
	var t := s.y * 0.5
	var parts := []
	var screw := Color(0.7, 0.72, 0.76)
	var slot := Color(0.015, 0.015, 0.02)
	if style >= 4:   # a window in a frame, so you can see what you installed
		var fb := 0.05
		var bar := 0.07
		parts.append(_p(Vector3(s.x, s.y, bar), Vector3(0, 0, -s.z * 0.5 + bar * 0.5), col, "", 0.003))
		parts.append(_p(Vector3(s.x, s.y, bar), Vector3(0, 0, s.z * 0.5 - bar * 0.5), col, "", 0.003))
		for sx: float in [-1.0, 1.0]:
			parts.append(_p(Vector3(fb, s.y, s.z - bar * 2.0 + 0.004), Vector3(sx * (s.x * 0.5 - fb * 0.5), 0, 0), col, "", 0.003))
		var win := Vector3(s.x - fb * 2.0, 0.003, s.z - bar * 2.0)
		parts.append(_p(win, Vector3(0, 0.001, 0), Color(0.5, 0.65, 0.8, 0.16), "glass", 0.0))
		parts.append(_e(Vector3(win.x + 0.004, 0.0016, 0.003), Vector3(0, t + 0.0003, -win.z * 0.5), Color(0.7, 0.4, 1.0), 1.6))
		parts.append(_e(Vector3(win.x + 0.004, 0.0016, 0.003), Vector3(0, t + 0.0003, win.z * 0.5), Color(0.7, 0.4, 1.0), 1.6))
		parts.append(_p(Vector3(0.09, 0.0016, 0.022), Vector3(0, t + 0.0003, -s.z * 0.5 + 0.035), Color(0.78, 0.8, 0.84), "chrome", 0.0))
		parts.append_array(_row(4, Vector3(-s.x * 0.5 + 0.03, t, s.z * 0.5 - 0.035), Vector3(s.x * 0.5 - 0.03, t, s.z * 0.5 - 0.035), Vector3(0.008, 0.003, 0.008), screw, "chrome", 0.0))
		return parts
	parts.append(_p(s, Vector3.ZERO, col, "plastic" if style == 1 else "", 0.004))
	match style:
		1:   # office PC: two grooves and screws along the back
			parts.append(_p(Vector3(s.x - 0.04, 0.001, 0.0035), Vector3(0, t + 0.0003, -s.z * 0.2), col.darkened(0.3), "matte", 0.0))
			parts.append(_p(Vector3(s.x - 0.04, 0.001, 0.0035), Vector3(0, t + 0.0003, s.z * 0.05), col.darkened(0.3), "matte", 0.0))
			parts.append_array(_row(3, Vector3(-s.x * 0.35, t, s.z * 0.43), Vector3(s.x * 0.35, t, s.z * 0.43), Vector3(0.008, 0.003, 0.008), screw, "chrome", 0.0))
		2:   # tower server: vent slots, a service label, two screws
			parts.append_array(_row(10, Vector3(-s.x * 0.36, t + 0.0003, s.z * 0.28), Vector3(s.x * 0.36, t + 0.0003, s.z * 0.28), Vector3(0.012, 0.0012, 0.14), slot, "matte", 0.0))
			parts.append(_p(Vector3(0.1, 0.0012, 0.06), Vector3(s.x * 0.12, t + 0.0003, -s.z * 0.25), Color(0.85, 0.85, 0.82), "matte", 0.0))
			parts.append_array(_row(5, Vector3(s.x * 0.06, t + 0.0013, -s.z * 0.25), Vector3(s.x * 0.18, t + 0.0013, -s.z * 0.25), Vector3(0.004, 0.0005, 0.04), Color(0.1, 0.1, 0.12), "", 0.0))
			parts.append_array(_row(2, Vector3(-s.x * 0.42, t, -s.z * 0.45), Vector3(s.x * 0.42, t, -s.z * 0.45), Vector3(0.009, 0.003, 0.009), screw, "chrome", 0.0))
		3:   # workstation: grille panel and a low carry handle
			for c in 2:
				parts.append_array(_row(9, Vector3(-s.x * 0.34, t + 0.0003, s.z * (0.1 + c * 0.2)), Vector3(s.x * 0.34, t + 0.0003, s.z * (0.1 + c * 0.2)), Vector3(0.012, 0.0012, 0.12), slot, "matte", 0.0))
			parts.append(_p(Vector3(0.2, 0.011, 0.024), Vector3(0, t + 0.0055, -s.z * 0.3), Color(0.08, 0.08, 0.09), "metal", 0.004))
			parts.append(_p(Vector3(0.008, 0.004, 0.024), Vector3(-0.1, t + 0.002, -s.z * 0.3), Color(0.7, 0.72, 0.76), "chrome", 0.0))
			parts.append(_p(Vector3(0.008, 0.004, 0.024), Vector3(0.1, t + 0.002, -s.z * 0.3), Color(0.7, 0.72, 0.76), "chrome", 0.0))
	return parts


# =====================================================================================
# Rack
# =====================================================================================

static func _rack_parts(h := 1.8, ys := [-0.62, -0.22, 0.18, 0.58]) -> Array:
	var steel := Color(0.13, 0.13, 0.16)
	var trim := Color(0.7, 0.4, 1.0)
	var ty := h * 0.5 - 0.025   # centre of the top plate
	var parts := [
		_p(Vector3(0.6, 0.05, 0.75), Vector3(0, -ty, 0), Color(0.1, 0.1, 0.13), "metal", 0.01),
		_p(Vector3(0.6, 0.05, 0.75), Vector3(0, ty, 0), Color(0.1, 0.1, 0.13), "metal", 0.01),
		_p(Vector3(0.54, 0.02, 0.7), Vector3(0, -ty + 0.035, 0), steel, "metal", 0.004),
	]
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			parts.append(_p(Vector3(0.036, h - 0.1, 0.036), Vector3(sx * 0.27, 0.0, sz * 0.34), steel, "metal", 0.006))
	for sx: float in [-1.0, 1.0]:   # side lattice, so you can see in
		parts.append(_p(Vector3(0.026, 0.03, 0.68), Vector3(sx * 0.285, ty - 0.075, 0), steel, "metal", 0.005))
		parts.append(_p(Vector3(0.026, 0.03, 0.68), Vector3(sx * 0.285, -ty + 0.075, 0), steel, "metal", 0.005))
		parts.append_array(_row(11, Vector3(sx * 0.285, 0.0, -0.31), Vector3(sx * 0.285, 0.0, 0.31), Vector3(0.016, h - 0.2, 0.014), Color(0.18, 0.18, 0.22), "metal", 0.0))
		parts.append(_e(Vector3(0.008, h - 0.1, 0.012), Vector3(sx * 0.289, 0.0, -0.372), trim, 2.2, 0.0))
	parts.append(_e(Vector3(0.6, 0.012, 0.014), Vector3(0, ty + 0.029, -0.372), trim, 2.2, 0.0))
	for y: float in ys:   # a shelf rail per server and the rail holes beside it
		for sx: float in [-1.0, 1.0]:
			parts.append(_p(Vector3(0.022, 0.012, 0.66), Vector3(sx * 0.2535, y - 0.1, 0), Color(0.55, 0.57, 0.6), "metal", 0.002))
			for k in 3:
				parts.append(_p(Vector3(0.012, 0.012, 0.004), Vector3(sx * 0.27, y - 0.05 + k * 0.05, -0.358), Color(0.02, 0.02, 0.03), "matte", 0.0))
	parts.append_array(_xf(_fan(0.13, Color(0.06, 0.06, 0.08), Color(0.3, 0.32, 0.36), 7), Basis.IDENTITY, Vector3(-0.13, ty + 0.025, 0.0)))
	parts.append_array(_xf(_fan(0.13, Color(0.06, 0.06, 0.08), Color(0.3, 0.32, 0.36), 7), Basis.IDENTITY, Vector3(0.13, ty + 0.025, 0.0)))
	return parts


## A rack of any height with a server slot at each height in `ys`.
static func _rack(label: String, price: int, h: float, ys: Array, mass: float) -> Dictionary:
	var slots := []
	for y: float in ys:
		slots.append({"accepts": "server", "xf": Transform3D(Basis(), Vector3(0, y, 0))})
	var ty := h * 0.5 - 0.025
	return {"label": label, "price": price, "solid": true, "slots": slots, "size": Vector3(0.6, h, 0.75), "mass": mass,
		"shapes": [
			[Vector3(0.6, 0.05, 0.75), Vector3(0, -ty, 0)], [Vector3(0.6, 0.05, 0.75), Vector3(0, ty, 0)],
			[Vector3(0.03, h, 0.75), Vector3(-0.285, 0, 0)], [Vector3(0.03, h, 0.75), Vector3(0.285, 0, 0)]],
		"parts": _rack_parts(h, ys)}


## An open-air mining frame: no walls and no lid, just a plate, rails, a power supply and a row of cards.
static func _frame(label: String, price: int, size: Vector3, cpus: int, rams: int, gpus: int, psu: float,
		max_tier: int, idle: float) -> Dictionary:
	var w := size.x
	var h := size.y
	var d := size.z
	var base_y := -h * 0.5 + 0.015
	var floor_y := base_y + 0.015
	var slots := []
	for i in cpus:
		slots.append({"accepts": "cpu", "xf": Transform3D(Basis(), Vector3(-w * 0.5 + 0.1 + i * 0.1, floor_y + 0.018, -d * 0.5 + 0.1))})
	for j in rams:
		slots.append({"accepts": "ram", "xf": Transform3D(Basis(), Vector3(w * 0.5 - 0.105, floor_y + 0.024, -d * 0.5 + 0.045 + j * 0.02))})
	var on_edge := Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0))
	for k in gpus:
		slots.append({"accepts": "gpu", "xf": Transform3D(on_edge, Vector3((k - (gpus - 1) * 0.5) * 0.085, floor_y + 0.072, 0.07))})
	var alu := Color(0.7, 0.72, 0.76)
	var parts := [
		_p(Vector3(w, 0.03, d), Vector3(0, base_y, 0), Color(0.14, 0.14, 0.16), "metal", 0.006),
		_p(Vector3(w - 0.05, 0.004, d - 0.05), Vector3(0, floor_y + 0.002, 0), Color(0.05, 0.05, 0.07), "pcb", 0.0),
	]
	for sx: float in [-1.0, 1.0]:   # rails and uprights
		parts.append(_p(Vector3(0.025, 0.025, d), Vector3(sx * (w * 0.5 - 0.0125), base_y + 0.027, 0), alu, "brushed", 0.004))
		parts.append(_p(Vector3(0.025, 0.14, 0.025), Vector3(sx * (w * 0.5 - 0.0125), base_y + 0.09, -d * 0.5 + 0.0125), alu, "brushed", 0.004))
		parts.append(_p(Vector3(0.025, 0.14, 0.025), Vector3(sx * (w * 0.5 - 0.0125), base_y + 0.09, d * 0.5 - 0.0125), alu, "brushed", 0.004))
	parts.append(_p(Vector3(w, 0.022, 0.022), Vector3(0, base_y + 0.16, d * 0.5 - 0.011), alu, "brushed", 0.004))   # a bar behind the cards
	parts.append(_p(Vector3(w, 0.022, 0.022), Vector3(0, base_y + 0.16, -d * 0.5 + 0.011), alu, "brushed", 0.004))
	for s: Dictionary in slots:
		var at: Vector3 = (s["xf"] as Transform3D).origin
		match s["accepts"]:
			"cpu":
				parts.append(_p(Vector3(0.09, 0.0035, 0.09), Vector3(at.x, floor_y + 0.0057, at.z), Color(0.5, 0.52, 0.56), "metal", 0.002))
				parts.append(_p(Vector3(0.062, 0.0016, 0.062), Vector3(at.x, floor_y + 0.0078, at.z), Color(0.1, 0.1, 0.12), "matte", 0.0))
			"ram":
				parts.append(_p(Vector3(0.148, 0.0065, 0.0125), Vector3(at.x, floor_y + 0.0072, at.z), Color(0.06, 0.06, 0.07), "plastic", 0.001))
			"gpu":   # a riser board under each card
				parts.append(_p(Vector3(0.012, 0.0075, 0.06), Vector3(at.x, floor_y + 0.0079, at.z - 0.06), Color(0.07, 0.07, 0.08), "plastic", 0.001))
				parts.append(_p(Vector3(0.026, 0.004, 0.026), Vector3(at.x, floor_y + 0.006, at.z - 0.11), Color(0.1, 0.3, 0.18), "pcb", 0.0))
	parts.append(_p(Vector3(0.15, 0.085, 0.09), Vector3(0, floor_y + 0.0465, -d * 0.5 + 0.07), Color(0.5, 0.52, 0.56), "brushed", 0.004))   # the power supply
	parts.append_array(_xf(_fan(0.07, Color(0.1, 0.1, 0.12), Color(0.2, 0.2, 0.23), 5), Basis.IDENTITY, Vector3(0, floor_y + 0.089, -d * 0.5 + 0.07)))
	parts.append_array(_xf(_grille(0.07, Color(0.55, 0.57, 0.6)), Basis.IDENTITY, Vector3(0, floor_y + 0.095, -d * 0.5 + 0.07)))
	parts.append(_led(Vector3(0.02, 0.006, 0.004), Vector3(-0.05, floor_y + 0.07, -d * 0.5 + 0.0235), Color(0.3, 1.0, 0.4), 2.5, 0.002))
	for sx: float in [-1.0, 1.0]:
		parts.append(_cyl(0.026, 0.01, Vector3(sx * (w * 0.5 - 0.0125), base_y - 0.015, -d * 0.5 + 0.03), Color(0.05, 0.05, 0.06), "y", "rubber", 0.003))
		parts.append(_cyl(0.026, 0.01, Vector3(sx * (w * 0.5 - 0.0125), base_y - 0.015, d * 0.5 - 0.03), Color(0.05, 0.05, 0.06), "y", "rubber", 0.003))
	return {"label": label, "group": "server", "price": price, "watts": idle, "psu": psu, "max_tier": max_tier,
		"power_port": true, "net_port": true, "fragile": true, "slots": slots, "size": size, "mass": 4.0 + gpus * 0.8,
		"shapes": [[Vector3(w, 0.03, d), Vector3(0, base_y, 0)], [Vector3(w, 0.03, 0.03), Vector3(0, base_y + 0.16, d * 0.5 - 0.015)]],
		"parts": parts}


static func _build() -> Dictionary:
	return {
		"crate": {"label": "Empty box", "price": 1, "flammable": true, "size": Vector3(0.45, 0.35, 0.4), "mass": 1.5, "parts": _box_parts(Vector3(0.45, 0.35, 0.4))},
		# --- machines: a chassis with slots; what it does depends on what you screw into it ---
		"pc_office": _chassis("Office PC (used)", 120, Vector3(0.42, 0.18, 0.45), 1, 2, 1, 350.0, 1, 30.0,
			Color(0.82, 0.78, 0.68), {"group": "pc", "used": true}),
		"server": _chassis("Tower server (used)", 300, Vector3(0.48, 0.18, 0.6), 1, 4, 2, 750.0, 2, 40.0,
			Color(0.1, 0.1, 0.13), {"used": true}),
		"server_ws": _chassis("Workstation", 1400, Vector3(0.48, 0.19, 0.6), 1, 4, 2, 1300.0, 3, 60.0,
			Color(0.16, 0.17, 0.2), {}),
		"server_4u": _chassis("GPU server 4U", 6000, Vector3(0.48, 0.2, 0.6), 2, 8, 4, 3200.0, 4, 100.0,
			Color(0.12, 0.13, 0.17), {"coolant_port": true}),
		"server_pod": _chassis("AI pod", 28000, Vector3(0.48, 0.22, 0.86), 2, 8, 8, 7000.0, 5, 150.0,
			Color(0.2, 0.12, 0.3), {"coolant_port": true}),
		"mini_pc": _chassis("Mini PC", 350, Vector3(0.3, 0.2, 0.46), 1, 2, 1, 180.0, 2, 15.0,
			Color(0.82, 0.83, 0.86), {}, {"look": 7, "compact": true, "board": Color(0.05, 0.05, 0.07), "ram_x": 0.05, "ram_z0": 0.18,
			"gpu_slots": [Vector3(0.04, 0.0, 0.0)]}),
		"server_frame": _frame("Mining frame", 650, Vector3(0.62, 0.2, 0.5), 1, 2, 6, 1600.0, 2, 40.0),
		"server_2u": _chassis("Server 2U", 2600, Vector3(0.48, 0.1, 0.6), 2, 8, 2, 1800.0, 3, 80.0,
			Color(0.3, 0.32, 0.36), {}, {"look": 6, "compact": true, "psu_h": 0.05, "gpu_basis": Basis.IDENTITY, "gpu_y": 0.032,
			"gpu_slots": [Vector3(0.07, 0.0, 0.0), Vector3(0.07, 0.0, 0.14)], "board": Color(0.05, 0.07, 0.07)}),
		"server_wslc": _chassis("Workstation (liquid ready)", 3600, Vector3(0.48, 0.19, 0.6), 1, 4, 2, 2000.0, 4, 70.0,
			Color(0.13, 0.22, 0.28), {"coolant_port": true}, {"look": 8, "couplers": true, "board": Color(0.04, 0.14, 0.2)}),
		"cpu_pentum": _cpu("Pentum G7", 95, 1, 0.7, 46.0, "gold"),
		"cpu_celery": _cpu("Celery G4", 60, 1, 0.5, 35.0),
		"cpu_ryzer": _cpu("Ryzer 5", 220, 2, 1.0, 65.0),
		"cpu_ryzer7": _cpu("Ryzer 7", 420, 2, 1.4, 105.0, "dark"),
		"cpu_thread": _cpu("Threadsmasher", 900, 3, 2.0, 180.0),
		"cpu_corei9": _cpu("Coree i9", 1500, 3, 2.8, 250.0, "blue"),
		"cpu_xenon": _cpu("Xenon Gold", 3500, 4, 3.0, 270.0),
		"cpu_xenonp": _cpu("Xenon Platinum", 6000, 4, 4.2, 350.0, "gold"),
		"cpu_epycc": _cpu("EPYCC 9965", 12000, 5, 5.0, 400.0),
		"cpu_bergamo": _cpu("EPYCC Bergamo", 19000, 5, 7.2, 520.0, "dark"),
		"ram_8": _ram("8 GB stick (used)", 20, 8),
		"ram_4": _ram("4 GB stick", 15, 4),
		"ram_16": _ram("16 GB stick", 60, 16),
		"ram_32": _ram("32 GB stick", 150, 32),
		"ram_64": _ram("64 GB stick", 400, 64),
		"ram_128": _ram("128 GB kit", 900, 128),
		"ram_256": _ram("256 GB RDIMM", 2000, 256),
		"ram_512": _ram("512 GB LRDIMM", 4600, 512),
		# GPU balance: tier / price / tokens per second / watts / RAM it needs / dollars per token-per-second.
		# Within a tier more money buys more tokens, at a worse price per token; the sidegrades trade watts, RAM or cooling.
		#   card                tier   price   tok/s    W    RAM   $ per tok/s
		#   RX 580 8GB            1     $240     2.6   220     8       92   cheap, power hungry
		#   GTX 1080 (used)       1     $400     3.0   180     8      133   staple of the second-hand market
		#   GTX 1650              1     $330     2.2    75     4      150   frugal: no power cable to speak of
		#   RTX 4060              2     $750     4.0   100     8      188   efficient
		#   RTX 4070              2   $1,200     6.0   200    16      200
		#   RTX 4070 Ti Super     2   $1,900     8.5   285    16      224
		#   RTX 4080              3   $2,300     9.5   320    24      242
		#   RTX 4090              3   $3,500    14.0   450    32      250
		#   RTX 6000 Ada          3   $6,000    17.0   300    96      353   blower, wants a huge pile of RAM
		#   L40S                  4   $5,200    18.0   250    48      289   liquid, modest watts
		#   RTX 5090              4   $7,000    24.0   600    48      292   air cooled tier 4: no loop, all heat
		#   A100 80GB             4   $9,000    30.0   400    64      300   liquid
		#   H100                  5  $25,000    70.0   700   128      357   liquid
		#   MI300X                5  $19,000    52.0   750   192      365   liquid, cheaper entry, RAM hungry
		#   B200                  5  $48,000   130.0  1100   192      369   liquid, two dies, the monster
		"gpu_580": _gpu("RX 580 8GB", 240, 1, 2.6, 220.0, 8, Color(1.0, 0.15, 0.1),
			{"body": Color(0.5, 0.07, 0.07), "blade": Color(0.18, 0.18, 0.2), "stripe": Color(0.95, 0.12, 0.1)}),
		"gpu_1080": _gpu("GTX 1080 (used)", 400, 1, 3.0, 180.0, 8, Color(0.2, 1.0, 0.5)),
		"gpu_1650": _gpu("GTX 1650", 330, 1, 2.2, 75.0, 4, Color(0.5, 1.0, 0.4),
			{"fans": 1, "d": 0.105, "body": Color(0.22, 0.22, 0.25), "blade": Color(0.6, 0.62, 0.66)}),
		"gpu_4060": _gpu("RTX 4060", 750, 2, 4.0, 100.0, 8, Color(0.4, 1.0, 0.85),
			{"body": Color(0.84, 0.85, 0.88), "blade": Color(0.25, 0.27, 0.3), "trim": Color(0.3, 0.33, 0.38)}),
		"gpu_4070": _gpu("RTX 4070", 1200, 2, 6.0, 200.0, 16, Color(0.2, 0.8, 1.0)),
		"gpu_4070ti": _gpu("RTX 4070 Ti Super", 1900, 2, 8.5, 285.0, 16, Color(1.0, 0.8, 0.2),
			{"body": Color(0.1, 0.13, 0.22), "fans": 3, "d": 0.082, "trim": Color(0.88, 0.72, 0.3), "blade": Color(0.55, 0.56, 0.6)}),
		"gpu_4080": _gpu("RTX 4080", 2300, 3, 9.5, 320.0, 24, Color(1.0, 0.5, 0.2),
			{"body": Color(0.22, 0.17, 0.14), "trim": Color(0.85, 0.55, 0.3), "blade": Color(0.2, 0.2, 0.22)}),
		"gpu_4090": _gpu("RTX 4090", 3500, 3, 14.0, 450.0, 32, Color(1.0, 0.3, 0.6)),
		"gpu_6000": _gpu("RTX 6000 Ada", 6000, 3, 17.0, 300.0, 96, Color(0.3, 1.0, 0.7),
			{"blower": true, "body": Color(0.06, 0.06, 0.07), "trim": Color(0.78, 0.8, 0.84), "stripe": Color(0.45, 0.85, 0.2), "blade": Color(0.3, 0.32, 0.36), "thick": 0.04}),
		"gpu_l40s": _liquid(_gpu("L40S", 5200, 4, 18.0, 250.0, 48, Color(0.8, 1.0, 0.9),
			{"plate": Color(0.76, 0.79, 0.84), "trim": Color(0.3, 0.9, 0.6)}), {"plate": Color(0.76, 0.79, 0.84), "trim": Color(0.3, 0.9, 0.6)}),
		"gpu_5090": _gpu("RTX 5090", 7000, 4, 24.0, 600.0, 48, Color(1.0, 0.55, 0.2),
			{"air": true, "thick": 0.048, "body": Color(0.13, 0.12, 0.13), "trim": Color(0.75, 0.2, 0.15), "blade": Color(0.85, 0.86, 0.9)}),
		"gpu_a100": _liquid(_gpu("A100 80GB", 9000, 4, 30.0, 400.0, 64, Color(0.6, 1.0, 0.2))),
		"gpu_mi300": _liquid(_gpu("MI300X", 19000, 5, 52.0, 750.0, 192, Color(1.0, 0.15, 0.2),
			{"plate": Color(0.16, 0.16, 0.18), "trim": Color(0.85, 0.12, 0.12), "body": Color(0.16, 0.05, 0.06)}),
			{"plate": Color(0.16, 0.16, 0.18), "trim": Color(0.85, 0.12, 0.12), "body": Color(0.16, 0.05, 0.06)}),
		"gpu_h100": _liquid(_gpu("H100", 25000, 5, 70.0, 700.0, 128, Color(1.0, 0.8, 0.1))),
		"gpu_b200": _liquid(_gpu("B200", 48000, 5, 130.0, 1100.0, 192, Color(0.4, 1.0, 0.3),
			{"plates": 2, "plate": Color(0.9, 0.62, 0.3), "trim": Color(0.35, 0.9, 0.4), "body": Color(0.05, 0.07, 0.05), "thick": 0.045}),
			{"plates": 2, "plate": Color(0.9, 0.62, 0.3), "trim": Color(0.35, 0.9, 0.4), "body": Color(0.05, 0.07, 0.05), "thick": 0.045}),
		"screwdriver": {"label": "Screwdriver", "price": 10, "tool": "screwdriver", "size": Vector3(0.04, 0.04, 0.24), "mass": 0.2, "parts": [
			_cyl(0.038, 0.1, Vector3(0, 0, 0.07), Color(0.9, 0.2, 0.15), "z", "plastic", 0.01),
			_cyl(0.04, 0.012, Vector3(0, 0, 0.035), Color(0.1, 0.1, 0.12), "z", "rubber", 0.003),
			_cyl(0.041, 0.012, Vector3(0, 0, 0.1), Color(0.1, 0.1, 0.12), "z", "rubber", 0.003),
			_cyl(0.034, 0.016, Vector3(0, 0, 0.125), Color(0.1, 0.1, 0.12), "z", "rubber", 0.005),
			_cyl(0.012, 0.09, Vector3(0, 0, -0.04), Color(0.74, 0.76, 0.8), "z", "chrome", 0.002),
			_cyl(0.016, 0.03, Vector3(0, 0, 0.0), Color(0.15, 0.15, 0.17), "z", "metal", 0.003),
			_p(Vector3(0.012, 0.002, 0.016), Vector3(0, 0, -0.1), Color(0.74, 0.76, 0.8), "chrome", 0.0),
		]},
		"powerstrip": {"label": "Power strip", "price": 25, "power_port": true, "provides": "power", "sockets": 4, "fragile": true,
			"max_watts": 2000.0,
			"size": Vector3(0.4, 0.045, 0.07), "mass": 0.6, "parts": _strip_parts()},
		"switch": {"label": "Network switch", "price": 60, "watts": 5.0, "power_port": true, "net_port": true, "fragile": true,
			"provides": "net", "sockets": 4,
			"size": Vector3(0.28, 0.045, 0.16), "mass": 0.8, "parts": _switch_parts()},
		# --- power generation, from scuffed to serious ---
		"gen_bike": {"label": "Exercise bike generator", "price": 150, "provides": "power", "sockets": 1,
			"gen": {"kind": "pedal", "watts": 300.0},
			"size": Vector3(0.5, 1.0, 1.1), "mass": 18.0, "parts": _bike_parts()},
		"gen_mower": {"label": "Lawnmower generator", "price": 450, "provides": "power", "sockets": 2,
			"gen": {"kind": "fuel", "watts": 1200.0, "burn": 600.0},
			"size": Vector3(0.6, 0.5, 0.85), "mass": 30.0, "parts": _mower_parts()},
		"gen_solar": {"label": "Solar panel", "price": 900, "provides": "power", "sockets": 1,
			"gen": {"kind": "solar", "watts": 400.0},
			"size": Vector3(1.6, 0.08, 1.0), "mass": 12.0, "parts": _solar_parts()},
		"gen_diesel": {"label": "Diesel generator", "price": 2800, "provides": "power", "sockets": 4, "solid": true,
			"gen": {"kind": "fuel", "watts": 5000.0, "burn": 900.0},
			"size": Vector3(0.8, 0.9, 1.4), "mass": 90.0, "parts": _diesel_parts()},
		# --- building wiring: nothing is powered unless you bring the power in yourself ---
		"inlet": {"label": "Power inlet", "price": 40, "wall": true, "power_port": true, "feeds": true,
			"size": Vector3(0.24, 0.24, 0.09), "mass": 1.0, "parts": _inlet_parts()},
		"outlet": {"label": "Wall socket", "price": 15, "wall": true, "provides": "power", "sockets": 2, "bus": true,
			"size": Vector3(0.2, 0.12, 0.05), "mass": 0.3, "parts": _xf(socket_plate_parts(true), Basis(Vector3.UP, PI))},
		"lamp": {"label": "Floor lamp", "price": 60, "watts": 5.0, "power_port": true, "light": true, "fragile": true,
			"size": Vector3(0.36, 1.6, 0.36), "mass": 4.0, "parts": [
				_cyl(0.32, 0.03, Vector3(0, -0.785, 0), Color(0.12, 0.12, 0.14), "y", "metal", 0.008),
				_cyl(0.2, 0.012, Vector3(0, -0.762, 0), Color(0.75, 0.77, 0.8), "y", "chrome", 0.004),
				_cyl(0.022, 1.3, Vector3(0, -0.12, 0), Color(0.72, 0.74, 0.78), "y", "chrome"),
				_cyl(0.05, 0.05, Vector3(0, 0.55, 0), Color(0.72, 0.74, 0.78), "y", "chrome", 0.01),
				_cone(0.36, 0.7, 0.3, Vector3(0, 0.7, 0), Color(1.0, 0.9, 0.7), "y"),
				_cyl(0.012, 0.06, Vector3(0.05, 0.62, 0.03), Color(0.72, 0.74, 0.78), "y", "chrome"),
				_ball(Vector3(0.025, 0.025, 0.025), Vector3(0.05, 0.585, 0.03), Color(0.9, 0.7, 0.2), "gold"),
				_led(Vector3(0.1, 0.01, 0.1), Vector3(0, 0.84, 0), Color(1.0, 0.9, 0.7), 2.5, 0.0),
			]},
		# --- liquid cooling: reservoir -> pump -> manifold -> servers, plus a radiator outdoors ---
		"pump": {"label": "Coolant pump", "price": 350, "watts": 150.0, "power_port": true, "coolant_port": true,
			"provides": "coolant", "sockets": 3, "pump": true,
			"size": Vector3(0.4, 0.35, 0.3), "mass": 9.0, "parts": _pump_parts()},
		"reservoir": {"label": "Coolant reservoir", "price": 150, "coolant_port": true, "provides": "coolant",
			"sockets": 1, "tank": true,
			"size": Vector3(0.45, 0.7, 0.45), "mass": 6.0, "parts": _reservoir_parts()},
		"radiator": {"label": "Radiator", "price": 500, "coolant_port": true, "radiator": 250.0, "solid": true,
			"size": Vector3(1.2, 1.0, 0.3), "mass": 30.0, "parts": _radiator_parts()},
		"manifold": {"label": "Coolant manifold", "price": 120, "coolant_port": true, "provides": "coolant", "sockets": 6,
			"size": Vector3(0.6, 0.1, 0.12), "mass": 2.0, "parts": _manifold_parts()},
		"bucket": {"label": "Bucket", "price": 15, "size": Vector3(0.3, 0.32, 0.3), "mass": 1.0, "parts": [
			_cone(0.26, 1.15, 0.3, Vector3(0, -0.01, 0), Color(0.95, 0.5, 0.1), "y", "plastic"),
			_tube(0.31, 0.88, 0.025, Vector3(0, 0.14, 0), Color(0.95, 0.5, 0.1), "y", "plastic"),
			_cyl(0.2, 0.012, Vector3(0, -0.158, 0), Color(0.12, 0.12, 0.14), "y", "rubber", 0.004),
			_cyl(0.27, 0.008, Vector3(0, 0.126, 0), Color(0.25, 0.55, 0.95, 0.85), "y", "glass", 0.0),
			_p(Vector3(0.05, 0.1, 0.012), Vector3(0, -0.01, -0.145), Color(0.95, 0.9, 0.8), "matte", 0.002),
			_cyl(0.012, 0.05, Vector3(0.155, 0.12, 0), Color(0.72, 0.74, 0.78), "z", "chrome"),
			_cyl(0.012, 0.05, Vector3(-0.155, 0.12, 0), Color(0.72, 0.74, 0.78), "z", "chrome"),
		]},
		"suit": {"label": "Heat suit", "price": 400, "wear": true, "size": Vector3(0.5, 0.25, 0.4), "mass": 3.0, "parts": _suit_parts()},
		# --- knowing what is going on: sensors feed the big ops screen ---
		"thermometer": {"label": "Thermometer", "price": 20, "wall": true, "sensor": "room",
			"size": Vector3(0.1, 0.3, 0.04), "mass": 0.2, "parts": _thermometer_parts()},
		"sensor_power": {"label": "Power meter", "price": 60, "power_port": true, "sensor": "power", "fragile": true,
			"size": Vector3(0.16, 0.1, 0.1), "mass": 0.4, "parts": [
				_p(Vector3(0.16, 0.1, 0.1), Vector3.ZERO, Color(0.95, 0.8, 0.15), "plastic", 0.018),
				_p(Vector3(0.12, 0.062, 0.006), Vector3(0, 0.008, -0.0495), Color(0.08, 0.08, 0.09), "plastic", 0.006),
				_led(Vector3(0.1, 0.044, 0.003), Vector3(0, 0.008, -0.0535), Color(0.2, 1.0, 0.5), 1.5, 0.002),
				_p(Vector3(0.026, 0.012, 0.006), Vector3(-0.04, -0.034, -0.05), Color(0.12, 0.12, 0.14), "plastic", 0.003),
				_p(Vector3(0.026, 0.012, 0.006), Vector3(0.0, -0.034, -0.05), Color(0.12, 0.12, 0.14), "plastic", 0.003),
				_p(Vector3(0.026, 0.012, 0.006), Vector3(0.04, -0.034, -0.05), Color(0.12, 0.12, 0.14), "plastic", 0.003),
				_p(Vector3(0.05, 0.016, 0.012), Vector3(0, 0.0, 0.052), Color(0.1, 0.1, 0.12), "rubber", 0.004),
			] + _row(2, Vector3(-0.07, 0.0, 0.0), Vector3(0.07, 0.0, 0.0), Vector3(0.012, 0.1, 0.104), Color(0.12, 0.12, 0.14), "rubber", 0.004)},
		"sensor_coolant": {"label": "Coolant sensor", "price": 80, "coolant_port": true, "sensor": "coolant",
			"size": Vector3(0.16, 0.12, 0.12), "mass": 0.5, "parts": [
				_p(Vector3(0.16, 0.1, 0.12), Vector3(0, -0.01, 0), Color(0.2, 0.45, 0.9), "plastic", 0.02),
				_cyl(0.1, 0.012, Vector3(0, -0.005, -0.06), Color(0.95, 0.95, 0.95), "z", "plastic", 0.003),
				_tube(0.108, 0.86, 0.016, Vector3(0, -0.005, -0.062), Color(0.75, 0.77, 0.8), "z", "chrome"),
				_cyl(0.092, 0.003, Vector3(0, -0.005, -0.068), Color(0.6, 0.8, 1.0, 0.25), "z", "glass", 0.0),
				_p(Vector3(0.005, 0.034, 0.002), Vector3(0.012, 0.004, -0.0665), Color(0.9, 0.15, 0.1), "", 0.0),
				_p(Vector3(0.05, 0.004, 0.002), Vector3(0.0, -0.032, -0.0665), Color(0.2, 0.2, 0.25), "", 0.0),
				_cyl(0.026, 0.02, Vector3(-0.04, 0.056, 0), Color(0.78, 0.8, 0.84), "y", "chrome", 0.003),
				_cyl(0.026, 0.02, Vector3(0.04, 0.056, 0), Color(0.78, 0.8, 0.84), "y", "chrome", 0.003),
				_cyl(0.034, 0.008, Vector3(-0.04, 0.043, 0), Color(0.15, 0.15, 0.17), "y", "plastic", 0.002),
				_cyl(0.034, 0.008, Vector3(0.04, 0.043, 0), Color(0.15, 0.15, 0.17), "y", "plastic", 0.002),
			]},
		"screen": {"label": "Ops screen", "price": 250, "watts": 60.0, "power_port": true, "wall": true,
			"fragile": true, "screen": true,
			"size": Vector3(1.6, 0.94, 0.06), "mass": 8.0, "parts": [
				_p(Vector3(1.6, 0.94, 0.05), Vector3(0, 0, 0.005), Color(0.06, 0.07, 0.09), "plastic", 0.02),
				_p(Vector3(1.5, 0.84, 0.004), Vector3(0, 0, -0.021), Color(0.02, 0.03, 0.05), "glass", 0.0),
				_led(Vector3(0.03, 0.008, 0.004), Vector3(0.72, -0.43, -0.022), Color(0.2, 1.0, 0.5), 2.0),
			]},
		# --- keeping it from burning down ---
		"fan": {"label": "Box fan", "price": 45, "watts": 30.0, "power_port": true, "fragile": true,
			"cool": {"vent": 45.0},
			"size": Vector3(0.5, 0.55, 0.18), "mass": 3.0, "parts": _boxfan_parts()},
		"aircon": {"label": "Portable air conditioner", "price": 900, "watts": 700.0, "power_port": true,
			"fragile": true, "solid": true, "cool": {"remove": 2500.0},
			"size": Vector3(0.45, 0.8, 0.4), "mass": 28.0, "parts": _aircon_parts()},
		"extinguisher": {"label": "Fire extinguisher", "price": 60, "size": Vector3(0.18, 0.55, 0.18), "mass": 4.0, "parts": [
			_cyl(0.15, 0.36, Vector3(0, -0.07, 0), Color(0.85, 0.1, 0.08), "y", "plastic", 0.012),
			_ball(Vector3(0.15, 0.1, 0.15), Vector3(0, 0.125, 0), Color(0.85, 0.1, 0.08), "plastic"),
			_cyl(0.154, 0.1, Vector3(0, -0.04, 0), Color(0.95, 0.95, 0.9), "y", "matte", 0.002),
			_cyl(0.16, 0.025, Vector3(0, -0.255, 0), Color(0.1, 0.1, 0.12), "y", "rubber", 0.006),
			_cyl(0.05, 0.05, Vector3(0, 0.185, 0), Color(0.78, 0.8, 0.84), "y", "chrome", 0.004),
			_p(Vector3(0.05, 0.05, 0.075), Vector3(0, 0.225, 0.0), Color(0.12, 0.12, 0.14), "plastic", 0.012),
			_p(Vector3(0.026, 0.012, 0.13), Vector3(0, 0.26, 0.0), Color(0.12, 0.12, 0.14), "plastic", 0.004),
			_p(Vector3(0.026, 0.012, 0.1), Vector3(0, 0.222, 0.04), Color(0.12, 0.12, 0.14), "plastic", 0.004),
			_cyl(0.04, 0.012, Vector3(0.0, 0.2, -0.075), Color(0.95, 0.95, 0.9), "x", "plastic"),
			_rod(Vector3(0.055, 0.19, 0.0), Vector3(0.08, 0.05, 0.0), 0.014, Color(0.1, 0.1, 0.12), "rubber"),
			_cone(0.026, 2.2, 0.05, Vector3(0.08, 0.025, 0.0), Color(0.1, 0.1, 0.12), "y", "rubber"),
			_cyl(0.044, 0.008, Vector3(0, 0.145, -0.074), Color(0.15, 0.15, 0.17), "z", "metal", 0.002),
			_cyl(0.036, 0.003, Vector3(0, 0.145, -0.079), Color(0.95, 0.95, 0.9), "z", "plastic", 0.0),
			_p(Vector3(0.004, 0.026, 0.002), Vector3(0.006, 0.148, -0.081), Color(0.15, 0.7, 0.2), "", 0.0),
		]},
		"fuel": {"label": "Jerry can", "price": 40, "size": Vector3(0.3, 0.4, 0.16), "mass": 4.0, "parts": [
			_p(Vector3(0.3, 0.34, 0.16), Vector3(0, -0.03, 0), Color(0.75, 0.1, 0.08), "plastic", 0.012),
			_p(Vector3(0.3, 0.05, 0.14), Vector3(0, 0.15, 0), Color(0.75, 0.1, 0.08), "plastic", 0.016),
			_p(Vector3(0.1, 0.05, 0.14), Vector3(-0.1, 0.19, 0), Color(0.75, 0.1, 0.08), "plastic", 0.012),
			_p(Vector3(0.1, 0.035, 0.14), Vector3(0.0, 0.2, 0), Color(0.2, 0.02, 0.02), "plastic", 0.01),
			_cyl(0.05, 0.03, Vector3(0.095, 0.195, 0), Color(0.1, 0.1, 0.1), "y", "plastic", 0.005),
			_cyl(0.036, 0.012, Vector3(0.095, 0.215, 0), Color(0.95, 0.75, 0.1), "y", "plastic", 0.003),
			_rod(Vector3(-0.14, -0.1, -0.082), Vector3(0.14, 0.12, -0.082), 0.014, Color(0.62, 0.08, 0.06), "plastic"),
			_rod(Vector3(-0.14, 0.12, -0.082), Vector3(0.14, -0.1, -0.082), 0.014, Color(0.62, 0.08, 0.06), "plastic"),
			_rod(Vector3(-0.14, -0.1, 0.082), Vector3(0.14, 0.12, 0.082), 0.014, Color(0.62, 0.08, 0.06), "plastic"),
			_rod(Vector3(-0.14, 0.12, 0.082), Vector3(0.14, -0.1, 0.082), 0.014, Color(0.62, 0.08, 0.06), "plastic"),
			_p(Vector3(0.1, 0.1, 0.002), Vector3(0, -0.05, -0.0815), Color(0.95, 0.85, 0.2), "matte", 0.0),
		]},
		# --- what the neighbours leave behind ---
		"sofa": {"label": "Sofa", "solid": true, "flammable": true, "size": Vector3(2.0, 0.8, 0.9), "mass": 40.0, "parts": [
			_p(Vector3(2.0, 0.2, 0.9), Vector3(0, -0.3, 0), Color(0.25, 0.36, 0.48), "matte", 0.05),
			_p(Vector3(2.0, 0.55, 0.26), Vector3(0, 0.12, 0.32), Color(0.32, 0.46, 0.6), "matte", 0.1),
			_p(Vector3(0.26, 0.42, 0.9), Vector3(-0.87, -0.02, 0), Color(0.32, 0.46, 0.6), "matte", 0.1),
			_p(Vector3(0.26, 0.42, 0.9), Vector3(0.87, -0.02, 0), Color(0.32, 0.46, 0.6), "matte", 0.1),
			_p(Vector3(0.72, 0.16, 0.6), Vector3(-0.4, -0.12, -0.1), Color(0.42, 0.58, 0.72), "matte", 0.07),
			_p(Vector3(0.72, 0.16, 0.6), Vector3(0.4, -0.12, -0.1), Color(0.42, 0.58, 0.72), "matte", 0.07),
			_p(Vector3(0.5, 0.34, 0.12), Vector3(-0.55, 0.12, 0.17), Color(0.85, 0.7, 0.3), "matte", 0.05),
			_cyl(0.05, 0.12, Vector3(-0.9, -0.395, -0.38), Color(0.2, 0.14, 0.1), "y", "matte"),
			_cyl(0.05, 0.12, Vector3(0.9, -0.395, -0.38), Color(0.2, 0.14, 0.1), "y", "matte"),
			_cyl(0.05, 0.12, Vector3(-0.9, -0.395, 0.38), Color(0.2, 0.14, 0.1), "y", "matte"),
			_cyl(0.05, 0.12, Vector3(0.9, -0.395, 0.38), Color(0.2, 0.14, 0.1), "y", "matte"),
		]},
		"tv": {"label": "Television", "fragile": true, "size": Vector3(1.3, 0.9, 0.35), "mass": 14.0, "parts": [
			_p(Vector3(0.7, 0.03, 0.3), Vector3(0, -0.435, 0), Color(0.08, 0.08, 0.09), "metal", 0.012),
			_p(Vector3(0.1, 0.18, 0.06), Vector3(0, -0.34, 0.05), Color(0.1, 0.1, 0.11), "metal", 0.012),
			_p(Vector3(1.3, 0.76, 0.06), Vector3(0, 0.0, 0.0), Color(0.05, 0.05, 0.06), "plastic", 0.02),
			_p(Vector3(0.5, 0.2, 0.06), Vector3(0, -0.02, 0.06), Color(0.08, 0.08, 0.09), "plastic", 0.03),
			_e(Vector3(1.22, 0.68, 0.006), Vector3(0, 0.0, -0.032), Color(0.3, 0.5, 0.9), 0.7, 0.0),
			_p(Vector3(0.1, 0.012, 0.004), Vector3(0.0, -0.36, -0.03), Color(0.7, 0.72, 0.76), "chrome", 0.0),
		]},
		"table": {"label": "Coffee table", "flammable": true, "size": Vector3(1.0, 0.45, 0.6), "mass": 9.0, "parts": [
			_p(Vector3(1.0, 0.05, 0.6), Vector3(0, 0.2, 0), Color(0.58, 0.4, 0.26), "plastic", 0.02),
			_p(Vector3(0.9, 0.04, 0.5), Vector3(0, 0.155, 0), Color(0.4, 0.27, 0.17), "matte", 0.01),
			_cone(0.07, 0.6, 0.38, Vector3(-0.43, -0.015, -0.23), Color(0.4, 0.27, 0.17), "y", "matte"),
			_cone(0.07, 0.6, 0.38, Vector3(0.43, -0.015, -0.23), Color(0.4, 0.27, 0.17), "y", "matte"),
			_cone(0.07, 0.6, 0.38, Vector3(-0.43, -0.015, 0.23), Color(0.4, 0.27, 0.17), "y", "matte"),
			_cone(0.07, 0.6, 0.38, Vector3(0.43, -0.015, 0.23), Color(0.4, 0.27, 0.17), "y", "matte"),
		]},
		"bed": {"label": "Bed", "solid": true, "flammable": true, "size": Vector3(1.6, 0.55, 2.1), "mass": 45.0, "parts": [
			_p(Vector3(1.6, 0.3, 2.1), Vector3(0, -0.125, 0), Color(0.5, 0.34, 0.2), "plastic", 0.03),
			_p(Vector3(1.5, 0.2, 2.0), Vector3(0, 0.12, 0), Color(0.95, 0.95, 0.93), "matte", 0.07),
			_p(Vector3(1.54, 0.08, 1.25), Vector3(0, 0.22, 0.38), Color(0.75, 0.3, 0.3), "matte", 0.04),
			_p(Vector3(0.6, 0.12, 0.38), Vector3(-0.37, 0.26, -0.75), Color(1.0, 1.0, 1.0), "matte", 0.06),
			_p(Vector3(0.6, 0.12, 0.38), Vector3(0.37, 0.26, -0.75), Color(1.0, 1.0, 1.0), "matte", 0.06),
			_p(Vector3(1.6, 0.6, 0.08), Vector3(0, 0.15, -1.05), Color(0.45, 0.3, 0.18), "plastic", 0.03),
		]},
		"fridge": {"label": "Fridge", "solid": true, "size": Vector3(0.7, 1.8, 0.7), "mass": 60.0, "parts": [
			_p(Vector3(0.7, 1.76, 0.7), Vector3(0, 0.02, 0), Color(0.9, 0.92, 0.94), "plastic", 0.04),
			_p(Vector3(0.66, 0.012, 0.01), Vector3(0, 0.3, -0.354), Color(0.45, 0.47, 0.5), "", 0.0),
			_p(Vector3(0.03, 0.44, 0.045), Vector3(0.26, 0.6, -0.375), Color(0.72, 0.74, 0.78), "chrome", 0.012),
			_p(Vector3(0.03, 0.56, 0.045), Vector3(0.26, -0.1, -0.375), Color(0.72, 0.74, 0.78), "chrome", 0.012),
			_p(Vector3(0.62, 0.03, 0.01), Vector3(0, -0.88, -0.35), Color(0.25, 0.25, 0.28), "", 0.0),
			_p(Vector3(0.08, 0.02, 0.003), Vector3(-0.22, 0.75, -0.354), Color(0.3, 0.8, 0.5), "", 0.0),
		]},
		"plant": {"label": "Pot plant", "size": Vector3(0.4, 0.9, 0.4), "mass": 5.0, "parts": [
			_cone(0.3, 1.25, 0.3, Vector3(0, -0.3, 0), Color(0.75, 0.42, 0.28), "y", "matte"),
			_tube(0.38, 0.8, 0.04, Vector3(0, -0.14, 0), Color(0.78, 0.45, 0.3), "y", "matte"),
			_cyl(0.32, 0.01, Vector3(0, -0.15, 0), Color(0.25, 0.17, 0.1), "y", "matte", 0.0),
			_rod(Vector3(0, -0.15, 0), Vector3(0.04, 0.12, 0.0), 0.035, Color(0.35, 0.25, 0.15), "matte"),
			_rod(Vector3(0, -0.1, 0), Vector3(-0.1, 0.05, 0.08), 0.02, Color(0.35, 0.25, 0.15), "matte"),
			_ball(Vector3(0.38, 0.3, 0.38), Vector3(0.0, 0.22, 0), Color(0.25, 0.6, 0.3), "matte"),
			_ball(Vector3(0.26, 0.24, 0.26), Vector3(0.1, 0.38, 0.06), Color(0.32, 0.7, 0.36), "matte"),
			_ball(Vector3(0.22, 0.2, 0.22), Vector3(-0.1, 0.14, 0.1), Color(0.2, 0.52, 0.28), "matte"),
		]},
		"rack_half": _rack("Half rack", 140, 1.0, [-0.2, 0.2], 14.0),
		"rack": _rack("Open rack", 250, 1.8, [-0.62, -0.22, 0.18, 0.58], 25.0),
		"rack_tall": _rack("Server rack 42U", 520, 2.2, [-0.85, -0.51, -0.17, 0.17, 0.51, 0.85], 38.0),
	}


# =====================================================================================
# Items with a bit more to them
# =====================================================================================

static func _box_parts(s: Vector3) -> Array:
	var card := Color(0.72, 0.55, 0.36)
	var tape := Color(0.86, 0.79, 0.62)
	var parts := [
		_p(s, Vector3.ZERO, card, "matte", 0.012),
		_p(Vector3(s.x - 0.01, 0.006, s.z * 0.5 - 0.005), Vector3(0, s.y * 0.5 + 0.001, -s.z * 0.25), card.lightened(0.08), "matte", 0.002),
		_p(Vector3(s.x - 0.01, 0.006, s.z * 0.5 - 0.005), Vector3(0, s.y * 0.5 + 0.001, s.z * 0.25), card.lightened(0.08), "matte", 0.002),
		_p(Vector3(s.x + 0.006, 0.008, minf(0.07, s.z * 0.2)), Vector3(0, s.y * 0.5 + 0.002, 0), tape, "plastic", 0.002),
		_p(Vector3(minf(0.07, s.x * 0.2), s.y + 0.006, 0.008), Vector3(0, 0, -s.z * 0.5 - 0.001), tape, "plastic", 0.002),
		_p(Vector3(s.x * 0.28, s.y * 0.22, 0.003), Vector3(-s.x * 0.2, s.y * 0.05, -s.z * 0.5 - 0.002), Color(0.95, 0.95, 0.92), "matte", 0.0),
	]
	for i in 5:
		parts.append(_p(Vector3(0.003 + (i % 2) * 0.002, s.y * 0.1, 0.002), Vector3(-s.x * 0.2 - s.x * 0.1 + i * s.x * 0.05, s.y * 0.0, -s.z * 0.5 - 0.0035), Color(0.1, 0.1, 0.1), "", 0.0))
	return parts


static func socket_plate_parts(with_led: bool) -> Array:
	## A double wall socket facing -Z (wall at +Z): plate, two round sockets with pin holes, an optional light.
	var plate := Color(0.93, 0.93, 0.91)
	var parts := [_p(Vector3(0.2, 0.12, 0.016), Vector3(0, 0, 0.012), plate, "plastic", 0.012)]
	for sx: float in [-0.045, 0.045]:
		parts.append(_cyl(0.07, 0.01, Vector3(sx, 0, 0.0), Color(0.86, 0.86, 0.84), "z", "plastic", 0.003))
		parts.append(_cyl(0.052, 0.005, Vector3(sx, 0, -0.0045), Color(0.1, 0.1, 0.12), "z", "plastic", 0.0))
		parts.append(_cyl(0.008, 0.004, Vector3(sx - 0.0125, 0, -0.0085), Color(0.0, 0.0, 0.0), "z", "matte", 0.0))
		parts.append(_cyl(0.008, 0.004, Vector3(sx + 0.0125, 0, -0.0085), Color(0.0, 0.0, 0.0), "z", "matte", 0.0))
		parts.append(_p(Vector3(0.014, 0.003, 0.003), Vector3(sx, 0.02, -0.0075), Color(0.7, 0.72, 0.76), "metal", 0.0))
		parts.append(_p(Vector3(0.014, 0.003, 0.003), Vector3(sx, -0.02, -0.0075), Color(0.7, 0.72, 0.76), "metal", 0.0))
	for sx: float in [-0.09, 0.09]:
		parts.append(_screw(Vector3(sx, 0.045, 0.0), "z", 0.007))
	if with_led:
		parts.append(_led(Vector3(0.02, 0.012, 0.004), Vector3(0, 0.048, -0.0055), Color(0.2, 1.0, 0.5), 3.0, 0.002))
	return parts


static func _strip_parts() -> Array:
	var parts := [_p(Vector3(0.4, 0.045, 0.07), Vector3.ZERO, Color(0.9, 0.9, 0.87), "plastic", 0.014),
		_p(Vector3(0.05, 0.006, 0.054), Vector3(-0.17, 0.0225, 0), Color(0.12, 0.12, 0.14), "plastic", 0.003),
		_led(Vector3(0.03, 0.012, 0.04), Vector3(-0.17, 0.027, 0), Color(1.0, 0.15, 0.1), 2.0, 0.004)]
	for k in 4:
		var x := -0.085 + k * 0.077
		parts.append(_p(Vector3(0.056, 0.004, 0.054), Vector3(x, 0.0225, 0), Color(0.15, 0.15, 0.17), "plastic", 0.004))
		parts.append(_cyl(0.007, 0.002, Vector3(x - 0.0115, 0.0245, 0), Color(0.0, 0.0, 0.0), "y", "matte", 0.0))
		parts.append(_cyl(0.007, 0.002, Vector3(x + 0.0115, 0.0245, 0), Color(0.0, 0.0, 0.0), "y", "matte", 0.0))
		parts.append(_p(Vector3(0.014, 0.0016, 0.004), Vector3(x, 0.0245, 0.016), Color(0.7, 0.72, 0.76), "metal", 0.0))
		parts.append(_p(Vector3(0.014, 0.0016, 0.004), Vector3(x, 0.0245, -0.016), Color(0.7, 0.72, 0.76), "metal", 0.0))
	return parts


static func _switch_parts() -> Array:
	var parts := [
		_p(Vector3(0.28, 0.045, 0.16), Vector3.ZERO, Color(0.13, 0.18, 0.3), "metal", 0.008),
		_p(Vector3(0.264, 0.03, 0.006), Vector3(0, -0.002, -0.0795), Color(0.7, 0.72, 0.76), "brushed", 0.002),
		_led(Vector3(0.2, 0.008, 0.008), Vector3(-0.02, 0.017, -0.081), Color(0.2, 1.0, 0.5), 2.5, 0.002),
		_p(Vector3(0.2, 0.0012, 0.05), Vector3(0.0, 0.0226, 0.03), Color(0.9, 0.9, 0.88), "matte", 0.0),
	]
	for i in 6:
		var x := -0.105 + i * 0.037
		parts.append(_p(Vector3(0.028, 0.02, 0.012), Vector3(x, -0.002, -0.081), Color(0.03, 0.03, 0.04), "matte", 0.002))
		parts.append(_p(Vector3(0.018, 0.004, 0.012), Vector3(x, -0.008, -0.082), Color(0.9, 0.72, 0.22), "gold", 0.0))
		parts.append(_e(Vector3(0.005, 0.004, 0.004), Vector3(x - 0.008, 0.0105, -0.0815), Color(0.3, 1.0, 0.4) if i % 3 else Color(1.0, 0.7, 0.2), 2.0, 0.0))
	parts.append_array(_row(8, Vector3(-0.1, 0.0226, -0.02), Vector3(0.1, 0.0226, -0.02), Vector3(0.012, 0.0012, 0.03), Color(0.03, 0.04, 0.08), "matte", 0.0))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			parts.append(_cyl(0.02, 0.008, Vector3(sx * 0.12, -0.0245, sz * 0.06), Color(0.05, 0.05, 0.06), "y", "rubber", 0.002))
	return parts


static func _bike_parts() -> Array:
	var red := Color(0.85, 0.2, 0.2)
	var black := Color(0.1, 0.1, 0.12)
	var steel := Color(0.72, 0.74, 0.78)
	var parts := [
		_p(Vector3(0.06, 0.05, 1.1), Vector3(-0.2, -0.475, 0), black, "matte", 0.02),
		_p(Vector3(0.06, 0.05, 1.1), Vector3(0.2, -0.475, 0), black, "matte", 0.02),
		_p(Vector3(0.46, 0.04, 0.06), Vector3(0, -0.47, -0.45), black, "matte", 0.015),
		_p(Vector3(0.46, 0.04, 0.06), Vector3(0, -0.47, 0.45), black, "matte", 0.015),
		_rod(Vector3(0, -0.45, 0.4), Vector3(0, 0.12, 0.3), 0.06, red, "plastic"),
		_rod(Vector3(0, 0.1, 0.3), Vector3(0, 0.27, 0.27), 0.035, steel, "chrome"),
		_p(Vector3(0.19, 0.05, 0.14), Vector3(0, 0.3, 0.3), black, "rubber", 0.02),
		_p(Vector3(0.09, 0.04, 0.16), Vector3(0, 0.3, 0.16), black, "rubber", 0.018),
		_rod(Vector3(0, -0.43, 0.38), Vector3(0, -0.3, -0.3), 0.05, red, "plastic"),
		_rod(Vector3(0, 0.1, 0.3), Vector3(0, 0.2, -0.37), 0.05, red, "plastic"),
		_rod(Vector3(0, -0.44, -0.36), Vector3(0, 0.36, -0.4), 0.06, red, "plastic"),
		_rod(Vector3(-0.21, 0.38, -0.42), Vector3(0.21, 0.38, -0.42), 0.03, steel, "chrome"),
		_cyl(0.042, 0.1, Vector3(-0.2, 0.38, -0.42), black, "x", "rubber", 0.01),
		_cyl(0.042, 0.1, Vector3(0.2, 0.38, -0.42), black, "x", "rubber", 0.01),
		_p(Vector3(0.17, 0.09, 0.03), Vector3(0, 0.44, -0.4), black, "plastic", 0.01),
		_led(Vector3(0.13, 0.06, 0.004), Vector3(0, 0.44, -0.4165), Color(0.2, 1.0, 0.5), 2.5, 0.002),
		_cyl(0.4, 0.05, Vector3(0, -0.22, -0.2), Color(0.45, 0.47, 0.5), "x", "metal", 0.006),
		_cyl(0.43, 0.012, Vector3(0.034, -0.22, -0.2), red, "x", "plastic", 0.004),
		_cyl(0.43, 0.012, Vector3(-0.034, -0.22, -0.2), red, "x", "plastic", 0.004),
		_cyl(0.09, 0.1, Vector3(0, -0.22, -0.2), steel, "x", "chrome", 0.004),
		_cyl(0.05, 0.14, Vector3(0, -0.12, 0.08), steel, "x", "chrome", 0.004),
		_rod(Vector3(0.07, -0.12, 0.08), Vector3(0.07, -0.29, 0.1), 0.03, steel, "metal"),
		_rod(Vector3(-0.07, -0.12, 0.08), Vector3(-0.07, 0.04, 0.06), 0.03, steel, "metal"),
		_p(Vector3(0.1, 0.025, 0.11), Vector3(0.12, -0.3, 0.1), black, "rubber", 0.008),
		_p(Vector3(0.1, 0.025, 0.11), Vector3(-0.12, 0.05, 0.06), black, "rubber", 0.008),
		_p(Vector3(0.2, 0.14, 0.2), Vector3(0, -0.37, 0.42), Color(0.95, 0.75, 0.1), "plastic", 0.02),
		_cyl(0.12, 0.04, Vector3(0.11, -0.37, 0.42), steel, "x", "metal", 0.004),
		_cyl(0.12, 0.04, Vector3(-0.11, -0.37, 0.42), steel, "x", "metal", 0.004),
		_led(Vector3(0.04, 0.04, 0.02), Vector3(0, -0.34, 0.53), Color(0.2, 1.0, 0.5), 3.0, 0.003),
	]
	return parts


static func _mower_parts() -> Array:
	var red := Color(0.8, 0.15, 0.12)
	var black := Color(0.08, 0.08, 0.09)
	var steel := Color(0.72, 0.74, 0.78)
	var iron := Color(0.25, 0.25, 0.28)
	var parts := [
		_p(Vector3(0.56, 0.1, 0.82), Vector3(0, -0.15, 0), red, "plastic", 0.035),
		_p(Vector3(0.58, 0.03, 0.84), Vector3(0, -0.205, 0), black, "rubber", 0.01),
		_cyl(0.24, 0.16, Vector3(0, -0.02, -0.1), iron, "y", "metal", 0.006),
		_tube(0.27, 0.8, 0.012, Vector3(0, -0.065, -0.1), iron, "y", "metal"),
		_tube(0.27, 0.8, 0.012, Vector3(0, -0.035, -0.1), iron, "y", "metal"),
		_tube(0.27, 0.8, 0.012, Vector3(0, -0.005, -0.1), iron, "y", "metal"),
		_ball(Vector3(0.3, 0.14, 0.3), Vector3(0, 0.07, -0.1), red, "plastic"),
		_cyl(0.06, 0.03, Vector3(0, 0.145, -0.1), black, "y", "plastic", 0.005),
		_p(Vector3(0.12, 0.1, 0.1), Vector3(0.2, 0.03, -0.1), black, "plastic", 0.02),
		_p(Vector3(0.034, 0.03, 0.06), Vector3(0.265, 0.03, -0.17), Color(0.95, 0.75, 0.1), "plastic", 0.008),
		_rod(Vector3(0.26, 0.03, -0.1), Vector3(0.265, 0.03, -0.15), 0.006, Color(0.9, 0.9, 0.85), "matte"),
		_cyl(0.14, 0.3, Vector3(0, 0.16, 0.14), Color(0.92, 0.92, 0.88), "x", "plastic", 0.01),
		_cyl(0.05, 0.03, Vector3(0.1, 0.24, 0.14), black, "y", "plastic", 0.005),
		_cyl(0.07, 0.22, Vector3(0.2, 0.0, 0.22), iron, "z", "metal", 0.004),
		_cyl(0.045, 0.05, Vector3(0.2, 0.0, 0.34), Color(0.5, 0.5, 0.54), "z", "chrome", 0.004),
		_p(Vector3(0.26, 0.1, 0.03), Vector3(0, -0.07, -0.41), iron, "metal", 0.006),
		_tube(0.05, 0.6, 0.012, Vector3(-0.06, -0.07, -0.43), black, "z", "plastic"),
		_tube(0.05, 0.6, 0.012, Vector3(0.06, -0.07, -0.43), black, "z", "plastic"),
		_led(Vector3(0.06, 0.04, 0.02), Vector3(0, -0.02, -0.43), Color(0.2, 1.0, 0.5), 3.0, 0.003),
		_rod(Vector3(-0.2, -0.1, 0.36), Vector3(-0.2, 0.2, 0.42), 0.03, steel, "metal"),
		_rod(Vector3(0.2, -0.1, 0.36), Vector3(0.2, 0.2, 0.42), 0.03, steel, "metal"),
		_rod(Vector3(-0.22, 0.2, 0.42), Vector3(0.22, 0.2, 0.42), 0.032, steel, "metal"),
		_cyl(0.04, 0.1, Vector3(-0.2, 0.2, 0.42), black, "x", "rubber", 0.01),
		_cyl(0.04, 0.1, Vector3(0.2, 0.2, 0.42), black, "x", "rubber", 0.01),
	]
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			parts.append(_cyl(0.2, 0.05, Vector3(sx * 0.275, -0.15, sz * 0.3), black, "x", "rubber", 0.012))
			parts.append(_cyl(0.08, 0.056, Vector3(sx * 0.275, -0.15, sz * 0.3), steel, "x", "chrome", 0.004))
	return parts


static func _solar_parts() -> Array:
	var alu := Color(0.75, 0.77, 0.8)
	var parts := [
		_p(Vector3(1.6, 0.06, 0.04), Vector3(0, -0.01, -0.48), alu, "metal", 0.012),
		_p(Vector3(1.6, 0.06, 0.04), Vector3(0, -0.01, 0.48), alu, "metal", 0.012),
		_p(Vector3(0.04, 0.06, 0.92), Vector3(-0.78, -0.01, 0), alu, "metal", 0.012),
		_p(Vector3(0.04, 0.06, 0.92), Vector3(0.78, -0.01, 0), alu, "metal", 0.012),
		_p(Vector3(1.52, 0.012, 0.92), Vector3(0, 0.005, 0), Color(0.9, 0.92, 0.94), "matte", 0.0),
		_p(Vector3(1.52, 0.004, 0.92), Vector3(0, 0.022, 0), Color(0.72, 0.74, 0.78), "metal", 0.0),
	]
	for c in 6:
		for r in 4:
			parts.append(_p(Vector3(0.242, 0.004, 0.215), Vector3(-0.625 + c * 0.25, 0.026, -0.345 + r * 0.23), Color(0.06, 0.12, 0.42), "plastic", 0.0))
	for c in 6:
		parts.append(_p(Vector3(0.002, 0.0012, 0.9), Vector3(-0.625 + c * 0.25 - 0.04, 0.0285, 0), Color(0.8, 0.82, 0.86), "metal", 0.0))
		parts.append(_p(Vector3(0.002, 0.0012, 0.9), Vector3(-0.625 + c * 0.25 + 0.04, 0.0285, 0), Color(0.8, 0.82, 0.86), "metal", 0.0))
	parts.append(_led(Vector3(0.06, 0.03, 0.02), Vector3(0.7, -0.005, 0.5), Color(0.2, 1.0, 0.5), 3.0, 0.004))
	return parts


static func _diesel_parts() -> Array:
	var yellow := Color(0.95, 0.72, 0.1)
	var black := Color(0.1, 0.1, 0.12)
	var iron := Color(0.22, 0.23, 0.26)
	var steel := Color(0.72, 0.74, 0.78)
	var parts := [
		_p(Vector3(0.8, 0.07, 1.4), Vector3(0, -0.415, 0), black, "metal", 0.02),
		_p(Vector3(0.7, 0.05, 1.3), Vector3(0, -0.36, 0), yellow.darkened(0.15), "plastic", 0.02),
		_p(Vector3(0.6, 0.18, 0.9), Vector3(0, 0.34, 0.05), yellow, "plastic", 0.05),
		_cyl(0.07, 0.04, Vector3(0.2, 0.46, 0.2), black, "y", "plastic", 0.006),
		_cyl(0.05, 0.015, Vector3(0.2, 0.49, 0.2), yellow.darkened(0.4), "y", "plastic", 0.003),
		_p(Vector3(0.4, 0.34, 0.46), Vector3(0, -0.15, -0.1), iron, "metal", 0.03),
		_p(Vector3(0.44, 0.1, 0.2), Vector3(0, 0.05, -0.12), Color(0.8, 0.15, 0.12), "plastic", 0.025),
		_cyl(0.36, 0.4, Vector3(0, -0.12, 0.45), Color(0.45, 0.47, 0.5), "z", "metal", 0.01),
		_p(Vector3(0.2, 0.12, 0.1), Vector3(0, 0.12, 0.45), black, "plastic", 0.02),
		_rod(Vector3(0.31, -0.3, -0.45), Vector3(0.31, 0.48, -0.45), 0.09, iron, "metal"),
		_cyl(0.12, 0.025, Vector3(0.31, 0.5, -0.45), black, "y", "metal", 0.004),
		_cyl(0.13, 0.12, Vector3(0.31, 0.1, -0.45), Color(0.5, 0.5, 0.54), "y", "brushed", 0.006),
		_p(Vector3(0.5, 0.26, 0.05), Vector3(0, -0.1, -0.685), iron, "metal", 0.012),
		_led(Vector3(0.3, 0.03, 0.01), Vector3(0, 0.0, -0.715), Color(0.2, 1.0, 0.5), 3.0, 0.003),
		_cyl(0.07, 0.006, Vector3(-0.18, -0.07, -0.715), Color(0.95, 0.95, 0.95), "z", "plastic", 0.0),
		_cyl(0.07, 0.006, Vector3(-0.18, -0.07, -0.718), Color(0.6, 0.8, 1.0, 0.3), "z", "glass", 0.0),
		_cyl(0.045, 0.02, Vector3(0.18, -0.07, -0.72), Color(0.85, 0.1, 0.08), "z", "plastic", 0.006),
	]
	for k in 4:
		parts.append(_tube(0.06, 0.6, 0.014, Vector3(-0.15 + k * 0.1, -0.18, -0.715), black, "z", "plastic"))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			parts.append(_rod(Vector3(sx * 0.36, -0.38, sz * 0.66), Vector3(sx * 0.36, 0.26, sz * 0.66), 0.045, yellow, "metal"))
		parts.append(_rod(Vector3(sx * 0.36, 0.26, -0.66), Vector3(sx * 0.36, 0.26, 0.66), 0.045, yellow, "metal"))
	parts.append(_rod(Vector3(-0.36, 0.26, -0.66), Vector3(0.36, 0.26, -0.66), 0.045, yellow, "metal"))
	parts.append(_rod(Vector3(-0.36, 0.26, 0.66), Vector3(0.36, 0.26, 0.66), 0.045, yellow, "metal"))
	parts.append(_tube(0.16, 0.65, 0.03, Vector3(-0.2, 0.5, 0.2), steel, "x", "chrome"))
	return parts


static func _inlet_parts() -> Array:
	var blue := Color(0.15, 0.35, 0.8)
	var parts := [
		_p(Vector3(0.24, 0.24, 0.03), Vector3(0, 0, 0.03), Color(0.1, 0.1, 0.12), "metal", 0.01),
		_p(Vector3(0.2, 0.2, 0.04), Vector3(0, 0, 0.0), blue, "plastic", 0.02),
		_cyl(0.15, 0.02, Vector3(0, 0, -0.025), blue.darkened(0.25), "z", "plastic", 0.004),
		_tube(0.15, 0.72, 0.03, Vector3(0, 0, -0.03), Color(0.75, 0.77, 0.8), "z", "chrome"),
		_cyl(0.1, 0.012, Vector3(0, 0, -0.034), Color(0.05, 0.05, 0.06), "z", "matte", 0.0),
		_cyl(0.014, 0.012, Vector3(0.0, 0.03, -0.04), Color(0.9, 0.72, 0.22), "z", "gold", 0.0),
		_cyl(0.014, 0.012, Vector3(-0.026, -0.016, -0.04), Color(0.9, 0.72, 0.22), "z", "gold", 0.0),
		_cyl(0.014, 0.012, Vector3(0.026, -0.016, -0.04), Color(0.9, 0.72, 0.22), "z", "gold", 0.0),
		_led(Vector3(0.03, 0.016, 0.006), Vector3(0.07, 0.09, -0.022), Color(0.2, 1.0, 0.5), 3.0, 0.003),
		_p(Vector3(0.05, 0.016, 0.002), Vector3(-0.06, 0.09, -0.021), Color(0.95, 0.8, 0.1), "matte", 0.0),
	]
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			parts.append(_screw(Vector3(sx * 0.1, sy * 0.1, -0.02), "z", 0.012))
	return parts


static func _pump_parts() -> Array:
	var blue := Color(0.15, 0.4, 0.85)
	var steel := Color(0.74, 0.76, 0.8)
	var parts := [
		_p(Vector3(0.4, 0.06, 0.3), Vector3(0, -0.145, 0), Color(0.18, 0.18, 0.21), "metal", 0.015),
		_cyl(0.2, 0.2, Vector3(-0.1, -0.01, 0), blue, "x", "plastic", 0.01),
		_tube(0.21, 0.85, 0.012, Vector3(-0.15, -0.01, 0), Color(0.12, 0.3, 0.65), "x", "plastic"),
		_tube(0.21, 0.85, 0.012, Vector3(-0.1, -0.01, 0), Color(0.12, 0.3, 0.65), "x", "plastic"),
		_tube(0.21, 0.85, 0.012, Vector3(-0.05, -0.01, 0), Color(0.12, 0.3, 0.65), "x", "plastic"),
		_cyl(0.22, 0.09, Vector3(0.05, -0.01, 0), steel, "x", "chrome", 0.006),
		_cyl(0.07, 0.07, Vector3(0.14, -0.01, 0), steel, "x", "chrome", 0.004),
		_cyl(0.09, 0.012, Vector3(0.18, -0.01, 0), steel, "x", "chrome", 0.003),
		_cyl(0.05, 0.12, Vector3(0.05, 0.11, 0.0), steel, "y", "chrome", 0.004),
		_cyl(0.07, 0.012, Vector3(0.05, 0.165, 0.0), steel, "y", "chrome", 0.003),
		_p(Vector3(0.1, 0.05, 0.08), Vector3(-0.1, 0.12, 0), Color(0.1, 0.1, 0.12), "plastic", 0.01),
		_led(Vector3(0.05, 0.03, 0.004), Vector3(-0.1, 0.12, -0.0415), Color(0.2, 1.0, 0.5), 3.0, 0.002),
		_p(Vector3(0.05, 0.1, 0.05), Vector3(-0.1, 0.07, 0.0), Color(0.1, 0.1, 0.12), "plastic", 0.005),
	]
	for sx: float in [-1.0, 1.0]:
		parts.append(_p(Vector3(0.03, 0.05, 0.22), Vector3(sx * 0.12, -0.1, 0), Color(0.18, 0.18, 0.21), "metal", 0.005))
	return parts


static func _reservoir_parts() -> Array:
	var steel := Color(0.74, 0.76, 0.8)
	var parts := [
		_cyl(0.45, 0.06, Vector3(0, -0.32, 0), Color(0.15, 0.15, 0.18), "y", "metal", 0.012),
		_cyl(0.45, 0.06, Vector3(0, 0.32, 0), Color(0.15, 0.15, 0.18), "y", "metal", 0.012),
		_cyl(0.4, 0.58, Vector3(0, 0.0, 0), Color(0.55, 0.78, 0.98, 0.3), "y", "glass", 0.0),
		_cyl(0.36, 0.34, Vector3(0, -0.12, 0), Color(0.2, 0.5, 0.95, 0.5), "y", "glass", 0.0),
		_cyl(0.1, 0.05, Vector3(0.1, 0.37, 0.1), Color(0.9, 0.2, 0.15), "y", "plastic", 0.006),
		_cyl(0.09, 0.015, Vector3(0.1, 0.34, 0.1), Color(0.5, 0.1, 0.08), "y", "plastic", 0.003),
		_cyl(0.03, 0.06, Vector3(0, -0.30, -0.24), steel, "z", "chrome", 0.004),
		_cyl(0.04, 0.012, Vector3(0, -0.30, -0.275), steel, "z", "chrome", 0.003),
		_cyl(0.03, 0.06, Vector3(0.0, 0.26, -0.24), steel, "z", "chrome", 0.004),
	]
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			parts.append(_cyl(0.014, 0.58, Vector3(sx * 0.2, 0.0, sz * 0.2), steel, "y", "chrome"))
	for i in 7:
		parts.append(_p(Vector3(0.05 if i % 2 == 0 else 0.03, 0.004, 0.004), Vector3(0.0, -0.2 + i * 0.07, -0.205), Color(0.95, 0.95, 0.95), "matte", 0.0))
	return parts


static func _radiator_parts() -> Array:
	var alu := Color(0.62, 0.64, 0.68)
	var black := Color(0.12, 0.12, 0.14)
	var parts := [
		_p(Vector3(1.2, 0.08, 0.3), Vector3(0, -0.46, 0), Color(0.18, 0.18, 0.21), "metal", 0.01),
		_p(Vector3(1.2, 0.06, 0.3), Vector3(0, 0.47, 0), Color(0.18, 0.18, 0.21), "metal", 0.01),
		_p(Vector3(0.06, 0.84, 0.14), Vector3(-0.575, 0.0, 0.04), Color(0.2, 0.2, 0.24), "metal", 0.01),
		_p(Vector3(0.06, 0.84, 0.14), Vector3(0.575, 0.0, 0.04), Color(0.2, 0.2, 0.24), "metal", 0.01),
		_p(Vector3(1.1, 0.84, 0.03), Vector3(0, 0.0, 0.11), black, "metal", 0.0),
		_cyl(0.04, 0.12, Vector3(-0.575, 0.46, 0.04), Color(0.78, 0.8, 0.84), "z", "chrome", 0.004),
		_cyl(0.04, 0.12, Vector3(0.575, -0.46, 0.04), Color(0.78, 0.8, 0.84), "z", "chrome", 0.004),
		_cyl(0.05, 0.02, Vector3(-0.575, 0.46, 0.11), Color(0.2, 0.5, 0.95), "z", "plastic", 0.004),
		_cyl(0.05, 0.02, Vector3(0.575, -0.46, 0.11), Color(0.95, 0.3, 0.2), "z", "plastic", 0.004),
		_p(Vector3(0.5, 0.45, 0.04), Vector3(-0.28, 0.0, -0.1), Color(0.1, 0.1, 0.12), "plastic", 0.02),
		_p(Vector3(0.5, 0.45, 0.04), Vector3(0.28, 0.0, -0.1), Color(0.1, 0.1, 0.12), "plastic", 0.02),
	]
	parts.append_array(_row(32, Vector3(-0.53, 0.0, 0.03), Vector3(0.53, 0.0, 0.03), Vector3(0.008, 0.88, 0.16), alu, "metal", 0.0))
	parts.append_array(_row(8, Vector3(-0.53, 0.0, 0.03), Vector3(0.53, 0.0, 0.03), Vector3(0.006, 0.88, 0.17), Color(0.45, 0.47, 0.5), "metal", 0.0))
	var fb := Basis(Vector3.RIGHT, -PI / 2.0)
	for fx: float in [-0.28, 0.28]:
		parts.append_array(_xf(_fan(0.4, Color(0.06, 0.06, 0.08), Color(0.35, 0.38, 0.42), 9), fb, Vector3(fx, 0.0, -0.12)))
		parts.append_array(_xf(_grille(0.44, Color(0.6, 0.62, 0.66)), fb, Vector3(fx, 0.0, -0.12)))
	return parts


static func _manifold_parts() -> Array:
	var copper := Color(0.8, 0.5, 0.25)
	var steel := Color(0.78, 0.8, 0.84)
	var parts := [
		_cyl(0.06, 0.56, Vector3(0, -0.005, 0), copper, "x", "metal", 0.004),
		_cyl(0.07, 0.03, Vector3(-0.29, -0.005, 0), steel, "x", "chrome", 0.005),
		_cyl(0.07, 0.03, Vector3(0.29, -0.005, 0), steel, "x", "chrome", 0.005),
		_p(Vector3(0.04, 0.03, 0.12), Vector3(-0.2, -0.035, 0), Color(0.15, 0.15, 0.18), "metal", 0.004),
		_p(Vector3(0.04, 0.03, 0.12), Vector3(0.2, -0.035, 0), Color(0.15, 0.15, 0.18), "metal", 0.004),
	]
	for i in 6:
		var x := -0.25 + i * 0.1
		parts.append(_cyl(0.034, 0.03, Vector3(x, 0.04, 0), steel, "y", "chrome", 0.003))
		parts.append(_cyl(0.044, 0.01, Vector3(x, 0.025, 0), Color(0.2, 0.45, 0.9), "y", "plastic", 0.002))
	return parts


static func _suit_parts() -> Array:
	var foil := Color(0.8, 0.82, 0.86)
	return [
		_p(Vector3(0.5, 0.08, 0.4), Vector3(0, -0.085, 0), foil, "metal", 0.03),
		_p(Vector3(0.46, 0.07, 0.36), Vector3(0.0, -0.01, 0.01), foil.darkened(0.08), "metal", 0.03),
		_p(Vector3(0.48, 0.06, 0.34), Vector3(0.0, 0.05, -0.01), foil.lightened(0.05), "metal", 0.03),
		_p(Vector3(0.08, 0.2, 0.42), Vector3(-0.14, -0.02, 0), Color(0.95, 0.5, 0.1), "matte", 0.01),
		_p(Vector3(0.08, 0.2, 0.42), Vector3(0.18, -0.02, 0), Color(0.95, 0.5, 0.1), "matte", 0.01),
		_ball(Vector3(0.2, 0.17, 0.2), Vector3(0.0, 0.14, 0.0), Color(0.88, 0.9, 0.93), "metal"),
		_p(Vector3(0.15, 0.06, 0.04), Vector3(0.0, 0.14, -0.09), Color(0.9, 0.7, 0.15, 0.95), "gold", 0.02),
		_p(Vector3(0.12, 0.1, 0.1), Vector3(-0.19, 0.03, -0.1), Color(0.35, 0.35, 0.38), "rubber", 0.03),
	]


static func _thermometer_parts() -> Array:
	var parts := [
		_p(Vector3(0.1, 0.3, 0.02), Vector3(0, 0, 0.01), Color(0.95, 0.95, 0.92), "plastic", 0.01),
		_p(Vector3(0.03, 0.2, 0.01), Vector3(0, 0.03, -0.004), Color(0.75, 0.9, 0.98, 0.5), "glass", 0.004),
		_p(Vector3(0.014, 0.12, 0.008), Vector3(0, 0.0, -0.005), Color(0.9, 0.15, 0.1), "plastic", 0.004),
		_ball(Vector3(0.045, 0.045, 0.026), Vector3(0, -0.105, -0.002), Color(0.9, 0.15, 0.1), "plastic"),
		_screw(Vector3(0, 0.135, -0.0), "z", 0.01),
	]
	for i in 9:
		parts.append(_p(Vector3(0.022 if i % 2 == 0 else 0.014, 0.003, 0.003), Vector3(0.036, 0.08 - i * 0.02, -0.0015), Color(0.15, 0.15, 0.18), "", 0.0))
	return parts


static func _boxfan_parts() -> Array:
	var shell := Color(0.85, 0.87, 0.9)
	var fb := Basis(Vector3.RIGHT, -PI / 2.0)
	var parts := [
		_p(Vector3(0.5, 0.05, 0.16), Vector3(0, 0.25, 0), shell, "plastic", 0.016),
		_p(Vector3(0.5, 0.05, 0.16), Vector3(0, -0.25, 0), shell, "plastic", 0.016),
		_p(Vector3(0.05, 0.5, 0.16), Vector3(-0.225, 0, 0), shell, "plastic", 0.016),
		_p(Vector3(0.05, 0.5, 0.16), Vector3(0.225, 0, 0), shell, "plastic", 0.016),
		_p(Vector3(0.42, 0.07, 0.12), Vector3(0, -0.265, 0.0), Color(0.3, 0.32, 0.36), "plastic", 0.016),
		_p(Vector3(0.4, 0.4, 0.015), Vector3(0, 0.0, 0.06), Color(0.2, 0.22, 0.26), "metal", 0.0),
		_cyl(0.05, 0.05, Vector3(0, 0.0, 0.03), Color(0.2, 0.22, 0.26), "z", "plastic", 0.006),
		_led(Vector3(0.04, 0.03, 0.02), Vector3(0.18, -0.26, -0.082), Color(0.2, 1.0, 0.5), 3.0, 0.003),
		_cyl(0.05, 0.03, Vector3(0.1, -0.265, -0.082), Color(0.15, 0.17, 0.2), "z", "plastic", 0.006),
	]
	parts.append_array(_xf(_fan(0.38, shell.darkened(0.1), Color(0.3, 0.6, 0.95), 5), fb, Vector3(0, 0.0, 0.0)))
	parts.append_array(_xf(_grille(0.4, Color(0.7, 0.72, 0.76)), fb, Vector3(0, 0.0, -0.07)))
	parts.append(_tube(0.28, 0.96, 0.004, Vector3(0, 0, -0.072), Color(0.7, 0.72, 0.76), "z", "metal"))
	parts.append(_tube(0.16, 0.94, 0.004, Vector3(0, 0, -0.072), Color(0.7, 0.72, 0.76), "z", "metal"))
	for k in 8:
		var a := PI * k / 8.0
		parts.append(_p(Vector3(0.4, 0.003, 0.003), Vector3(0, 0, -0.0715), Color(0.7, 0.72, 0.76), "metal", 0.0))
		parts[parts.size() - 1][4] = {"r": 0.0, "mat": "metal", "basis": Basis(Vector3.BACK, a)}
	return parts


static func _aircon_parts() -> Array:
	var white := Color(0.93, 0.94, 0.95)
	var dark := Color(0.25, 0.27, 0.3)
	var parts := [
		_p(Vector3(0.45, 0.76, 0.4), Vector3(0, 0.02, 0), white, "plastic", 0.04),
		_p(Vector3(0.4, 0.05, 0.36), Vector3(0, -0.375, 0), Color(0.2, 0.2, 0.23), "rubber", 0.01),
		_p(Vector3(0.38, 0.12, 0.006), Vector3(0, 0.28, -0.2), Color(0.12, 0.13, 0.15), "glass", 0.004),
		_led(Vector3(0.1, 0.03, 0.004), Vector3(0.05, 0.28, -0.2035), Color(0.3, 0.7, 1.0), 3.0, 0.003),
		_cyl(0.04, 0.012, Vector3(-0.1, 0.28, -0.205), Color(0.75, 0.77, 0.8), "z", "chrome", 0.003),
		_p(Vector3(0.34, 0.02, 0.01), Vector3(0, 0.1, -0.2), dark, "plastic", 0.0),
		_cyl(0.1, 0.05, Vector3(0, -0.18, 0.2), dark, "z", "plastic", 0.01),
		_tube(0.12, 0.7, 0.02, Vector3(0, -0.18, 0.225), Color(0.7, 0.72, 0.76), "z", "chrome"),
	]
	parts.append_array(_row(7, Vector3(0, 0.0, -0.2), Vector3(0, -0.2, -0.2), Vector3(0.36, 0.014, 0.012), dark, "plastic", 0.0))
	parts.append_array(_row(7, Vector3(0, 0.395, -0.12), Vector3(0, 0.395, 0.12), Vector3(0.28, 0.003, 0.014), dark.darkened(0.3), "plastic", 0.0))
	for sx: float in [-1.0, 1.0]:
		parts.append(_cyl(0.06, 0.03, Vector3(sx * 0.2, -0.395, -0.15), Color(0.1, 0.1, 0.12), "x", "rubber", 0.006))
		parts.append(_cyl(0.06, 0.03, Vector3(sx * 0.2, -0.395, 0.15), Color(0.1, 0.1, 0.12), "x", "rubber", 0.006))
		parts.append(_p(Vector3(0.012, 0.1, 0.16), Vector3(sx * 0.226, 0.1, 0.0), white.darkened(0.12), "plastic", 0.005))
	return parts


## The cardboard box a purchase arrives in: sized to fit, labelled, and rainproof.
static func parcel(kind: String) -> Dictionary:
	var inside: Dictionary = ITEMS[kind]
	var fit: Vector3 = inside["size"]
	var size := Vector3(maxf(fit.x + 0.08, 0.3), maxf(fit.y + 0.08, 0.2), maxf(fit.z + 0.08, 0.3))
	return {"label": "Parcel: %s" % inside["label"], "size": size, "mass": inside["mass"] + 0.5,
		"solid": inside.get("solid", false), "flammable": true, "parts": _box_parts(size)}


# =====================================================================================
# Turning parts into meshes
# =====================================================================================

static var _baked: Dictionary = {}


## [mesh, transform] of one part. Rotated parts are baked with their own transform.
static func _part_mesh(part: Array, opts: Dictionary) -> Mesh:
	var size: Vector3 = part[0]
	var seg: int = opts.get("seg", 14)
	var r: float = opts.get("r", -1.0)
	match opts.get("shape", "box"):
		"cyl":
			var bev := r if r >= 0.0 else clampf(minf(size.x, size.y) * 0.1, 0.0, 0.006)
			return Shapes.cylinder(size, bev, seg, 0.0, opts.get("top", 1.0))
		"ring":
			var bev := r if r >= 0.0 else clampf(size.y * 0.15, 0.0, 0.003)
			return Shapes.cylinder(size, bev, seg, opts.get("hole", 0.6))
		"sphere":
			return Shapes.sphere(size, seg)
		"wedge":
			return Shapes.wedge(size)
	var smallest := minf(size.x, minf(size.y, size.z))
	if r == 0.0 or smallest < 0.005:
		return Shapes.box(size)
	var soft := r if r > 0.0 else clampf(smallest * 0.3, 0.003, 0.03)
	return Shapes.rounded_box(size, soft, 1 if (smallest < 0.03 or soft < 0.008) else 2)


static func _split(part: Array) -> Array:
	var tag := ""
	var opts := {}
	for i in range(4, part.size()):
		if part[i] is String:
			tag = part[i]
		elif part[i] is Dictionary:
			opts = part[i]
	return [tag, opts]


## All untagged parts of a list merged into one mesh with one surface per material. Cached: the same
## list of parts is baked once however many items use it. Returns null if there is nothing untagged.
static func baked_mesh(parts: Array) -> ArrayMesh:
	var key := parts.hash()
	if _baked.has(key):
		return _baked[key]
	var groups := {}   # material -> [vertices, normals]
	for part: Array in parts:
		var info := _split(part)
		if info[0] != "":
			continue
		var opts: Dictionary = info[1]
		var mat := Materials.part(part[2], opts.get("mat", ""), part[3] * 1.5)
		if not groups.has(mat):
			groups[mat] = [PackedVector3Array(), PackedVector3Array()]
		var basis: Basis = opts.get("basis", Basis.IDENTITY)
		var pos: Vector3 = part[1]
		var arrays := _part_mesh(part, opts).surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var out_v: PackedVector3Array = groups[mat][0]
		var out_n: PackedVector3Array = groups[mat][1]
		var base := out_v.size()
		out_v.resize(base + verts.size())
		out_n.resize(base + verts.size())
		for i in verts.size():
			out_v[base + i] = basis * verts[i] + pos
			out_n[base + i] = basis * norms[i]
		groups[mat] = [out_v, out_n]
	var mesh: ArrayMesh = null
	if not groups.is_empty():
		mesh = ArrayMesh.new()
		for mat: StandardMaterial3D in groups:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = groups[mat][0]
			arrays[Mesh.ARRAY_NORMAL] = groups[mat][1]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	_baked[key] = mesh
	return mesh


## Adds the look of `parts` to `node`: one MeshInstance3D for everything static (shared between all
## items with the same parts) and one per tagged part. Returns the tagged materials as [[tag, material]]
## (unique per call, so each item lights its own).
static func build_parts(node: Node3D, parts: Array) -> Array:
	var tagged := []
	var mesh := baked_mesh(parts)
	if mesh:
		var body := MeshInstance3D.new()
		body.mesh = mesh
		node.add_child(body)
	for part: Array in parts:
		var info := _split(part)
		if info[0] == "":
			continue
		var opts: Dictionary = info[1]
		var mat: StandardMaterial3D = Materials.part(part[2], opts.get("mat", ""), part[3] * 1.5).duplicate()
		mat.set_meta("color", part[2])
		mat.set_meta("energy", part[3])
		tagged.append([info[0], mat])
		var mi := Shapes.instance(_part_mesh(part, opts), mat, part[1])
		mi.basis = opts.get("basis", Basis.IDENTITY)
		node.add_child(mi)
	return tagged


## Lights a tagged material: 0 = off, 1 = warning (orange), 2 = on (its own colour).
static func set_light(mat: StandardMaterial3D, level: int) -> void:
	var c: Color = mat.get_meta("color")
	if level == 1:
		c = Color(1.0, 0.45, 0.05)
	mat.albedo_color = c if level > 0 else c.darkened(0.85)
	mat.emission = c
	mat.emission_energy_multiplier = float(mat.get_meta("energy")) * 1.5 if level > 0 else 0.0
