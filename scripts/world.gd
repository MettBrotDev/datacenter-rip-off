extends Node3D
## The running game: level, players, items, cables and the company's numbers.
## The host owns all state; clients send requests and receive replicated results.
##
## Naming: request_*  = called locally by gameplay code
##         _h_*       = runs on the host (validates a request)
##         _r_*       = replicated result, runs on every peer

const Player = preload("res://scripts/player.gd")
const Item = preload("res://scripts/item.gd")
const Garage = preload("res://scripts/garage.gd")
const Hud = preload("res://scripts/hud.gd")
const Cables = preload("res://scripts/cables.gd")
const Sim = preload("res://scripts/sim.gd")
const Catalog = preload("res://scripts/catalog.gd")
const UI = preload("res://scripts/ui.gd")
const SPAWNS: Array[Vector3] = [Vector3(-1.5, 0, 2), Vector3(0, 0, 2.4), Vector3(1.5, 0, 2), Vector3(0, 0, 1)]
const SIM_STEP := 0.5
const Weather = preload("res://scripts/weather.gd")
const House = preload("res://scripts/house.gd")
const Dumpster = preload("res://scripts/dumpster.gd")
const Pickup = preload("res://scripts/pickup.gd")
const UsedMarket = preload("res://scripts/used_market.gd")
const OpsBoard = preload("res://scripts/ops_board.gd")
const Company = preload("res://scripts/company.gd")
const OpsScreen = preload("res://scripts/ops_screen.gd")
const Town = preload("res://scripts/town.gd")
const OUTSIDE := "res://scripts/outside.gd"   # scenery: the town around the garage
const LINKS := {"power": "power cable", "net": "network cable", "coolant": "coolant hose"}   # link type -> its name
const GARAGE_CIRCUIT := 1000                  # houses use their own id as circuit id
# What a neighbour says to an offer, by how close it was to the price they have in mind.
const HAGGLE := {
	"insult": ["Is that a joke? Get off my lawn.", "My garden gnome is worth more than that.",
		"I have had better offers from the raccoons."],
	"low": ["No. Come back with a real number.", "For that money you can have the mailbox.",
		"My sister says the market is hot. No."],
	"close": ["Tempting... but no. A little more and we might talk.", "You are close. Add a bit and I start packing.",
		"Hm. Almost. I do like this kitchen though."],
	"deal": ["Sold! I always hated this street anyway.", "Deal. The fridge stays, I cannot lift it.",
		"Done. Do not ask about the smell in the bedroom."],
	"done": ["I am done talking to you for now. Come back later."],
}

var items: Dictionary = {}      # item id (> 0) -> Item
var fixtures: Dictionary = {}   # fixture id (< 0) -> Fixture
var hud: CanvasLayer
var ready_peers: Array = []     # host only: clients that have loaded the world
var preview: Dictionary = {}    # cable end the local player is carrying: {"id", "type", "pins"}
var money := 0.0
var tokens := 0.0
var watts := 0.0
var tripped := false             # any breaker off
var tripped_circuits: Array = [] # which ones
var houses: Dictionary = {}      # house id -> House (0 is the landlady's, next door)
var temps: Dictionary = {}       # circuit id -> degrees C inside that building
var outside_temp := 20.0
var cables: Cables
var board: OpsBoard              # the dashboard every ops screen shows
var co: Dictionary = {}          # the company as every peer sees it: see Company.state()
var used: Dictionary = {}        # the second-hand market as every peer sees it: see UsedMarket.state()
var profit := 0.0                # $ per second
var wiring: Dictionary = {}      # circuit id -> watts drawn through that building's wiring
var puddles: Array = []          # [{"pos", "radius", "left"}] water on the floor
var doa_chance := 0.12           # host: odds that a used part turns out dead when unpacked
var hot_swap_chance := 0.25      # host: odds that swapping a part in a powered machine kills the part
var door_open := false
var capacity := 0.0             # watts available right now (grid + running generators)

var weather := 0                # index into Catalog.WEATHER

var _garage: Garage
var _dumpster: Dumpster
var _pickup: Pickup
var _market: UsedMarket         # host only
var _parcel_cond: Dictionary = {}   # host only: parcel id -> {"cond", "actual"}: what is really in the box
var _weather: Weather
var _players: Node3D
var _items: Node3D
var _sim: Sim                   # host only
var _company: Company           # host only
var _at_console: Dictionary = {}   # host only: peers who have the company console open
var _haggle: Dictionary = {}    # host only: house id -> {"reserve", "mood", "until"}
var _demolish_asked: Dictionary = {}   # host only: house id -> time of the first press
var _next_id := 1
var _deliveries := 0            # host only: purchases so far, picks the drop-off slot
var _tick := 0
var _sim_t := 0.0


func _ready() -> void:
	_garage = Garage.new()
	add_child(_garage)
	fixtures = _garage.fixtures
	if ResourceLoader.exists(OUTSIDE):
		add_child(load(OUTSIDE).new())
	for f: Node3D in fixtures.values():
		f.circuit = GARAGE_CIRCUIT
	board = OpsBoard.new()
	add_child(board)
	var wall_screen := OpsScreen.new()   # the big one on the garage's back wall; needs no power
	wall_screen.setup(board, 3.0, true)
	wall_screen.position = Vector3(-0.4, 1.85, -3.42)
	wall_screen.rotation.y = PI
	add_child(wall_screen)
	_build_houses()
	_dumpster = Dumpster.new()
	_dumpster.position = Vector3(4.9, 0, 8.2)   # on the grass beside the driveway
	_dumpster.rotation.y = -PI / 2   # button towards the driveway
	add_child(_dumpster)
	fixtures.merge(_dumpster.fixtures)
	_pickup = Pickup.new()
	_pickup.position = Vector3(-4.6, 0, 8.2)   # across the driveway from the dumpster
	_pickup.rotation.y = PI / 2   # button towards the driveway
	add_child(_pickup)
	fixtures.merge(_pickup.fixtures)
	_weather = Weather.new()
	_weather.setup(_garage.env, _garage.sky_mat, _garage.sun)
	add_child(_weather)
	_players = Node3D.new()
	_players.name = "Players"
	add_child(_players)
	_items = Node3D.new()
	_items.name = "Items"
	add_child(_items)
	cables = Cables.new()
	cables.world = self
	add_child(cables)
	hud = Hud.new()
	add_child(hud)
	Net.players_changed.connect(_reconcile_players)
	_reconcile_players()
	if multiplayer.is_server():
		_sim = Sim.new()
		_company = Company.new()
		_market = UsedMarket.new()
		_market.fill(0)
		used = _market.state()
		_spawn_starting_items()
		_spawn_furniture()
		_sim_step(0.0)
	else:
		_h_snapshot.rpc_id(1)


# --- queries (valid on every peer) -------------------------------------------

func player(id: int) -> Player:
	return _players.get_node_or_null(str(id))


func held_by(peer: int) -> Item:
	for it: Item in items.values():
		if it.holder == peer:
			return it
	return null


## Test aid (host): two opened machines full of parts on the driveway, to look at.
func debug_bench() -> void:
	var builds := [["server", Vector3(-0.45, 0.3, 6.0), ["cpu_ryzer", "ram_16", "ram_16", "gpu_4070", "gpu_1080"]],
		["server_4u", Vector3(0.45, 0.3, 6.0), ["cpu_xenon", "cpu_xenon", "ram_64", "ram_64", "ram_64", "gpu_a100", "gpu_a100", "gpu_4090"]]]
	for build: Array in builds:
		var machine_id := _next_id
		_cast(&"_r_spawn", [machine_id, build[0], Transform3D(Basis(), build[1]), [0, 0, 0, 0, 0, false, "", 0, 0, true]])
		_next_id += 1
		for kind: String in build[2]:
			var slot := free_slot(items[machine_id], Catalog.ITEMS[kind]["group"])
			_cast(&"_r_spawn", [_next_id, kind, Transform3D(Basis(), build[1]), [0, machine_id, slot, 0, 0, false, "", 0, 0, false]])
			_next_id += 1
	for kind: String in ["cpu_celery", "ram_8", "gpu_h100", "screwdriver"]:   # loose parts beside them
		_spawn(kind, Transform3D(Basis(), Vector3(-0.3 + _next_id % 4 * 0.2, 0.3, 6.7)))


## Test aid: cable up the garage both ways. Three machines dragged to the router with loose cables,
## one with its network cable pinned neatly along the floor edge and up the wall.
func debug_cables() -> void:
	var by_kind := {}
	for it: Item in items.values():
		by_kind[it.kind] = it
	request_link(by_kind["powerstrip"].id, "power", by_kind["gen_bike"].id)
	request_link(by_kind["server"].id, "power", by_kind["powerstrip"].id)
	request_link(by_kind["server"].id, "net", -3)
	for spot: Vector3 in [Vector3(-0.6, 0.3, 0.6), Vector3(0.7, 0.3, 0.2)]:
		var id := _next_id
		_spawn("server", Transform3D(Basis(), spot))
		request_link(id, "power", by_kind["powerstrip"].id)
		request_link(id, "net", -3)
	var neat := _next_id
	_spawn("server", Transform3D(Basis(), Vector3(2.3, 0.3, 1.6)))
	request_link(neat, "net", -3, [Vector3(2.3, 0.02, 1.0), Vector3(3.35, 0.02, 1.0), Vector3(3.35, 0.02, -3.3),
		Vector3(1.7, 0.02, -3.44), Vector3(1.7, 1.3, -3.47)])


## Whatever a cable can be plugged into: an item (id > 0) or a fixture (id < 0).
func provider(id: int) -> Node3D:
	return items.get(id) if id > 0 else fixtures.get(id)


func sockets_used(provider_id: int, type: String) -> int:
	var n := 0
	for it: Item in items.values():
		if it.link(type) == provider_id:
			n += 1
	return n


## The heat suit this player has on, if any.
func worn_by(peer: int) -> Item:
	for it: Item in items.values():
		if it.worn == peer:
			return it
	return null


## Is this item standing in water?
func in_puddle(it: Item) -> bool:
	var pos := it.global_position
	for puddle: Dictionary in puddles:
		var at: Vector3 = puddle["pos"]
		if absf(pos.y - at.y) < 0.4 and Vector2(pos.x - at.x, pos.z - at.z).length() < puddle["radius"]:
			return true
	return false


## The bike generator this player is pedalling, if any.
func ridden_by(peer: int) -> Item:
	for it: Item in items.values():
		if it.rider == peer:
			return it
	return null


## Anywhere without a roof overhead. Solar panels only work out there.
func is_outdoors(pos: Vector3) -> bool:
	if absf(pos.x) < 5.5 and absf(pos.z) < 4.5:
		return false   # the garage
	for h: House in houses.values():
		if h.state != House.GONE:
			var local := h.to_local(pos)
			var half: Vector2 = Town.FOOTPRINTS[h.lot["size"]] * 0.5
			if absf(local.x) < half.x and absf(local.z) < half.y:
				return false
	return true


## The wiring of every building we own: circuit id -> [limit in watts, where it is].
func circuits() -> Dictionary:
	var out := {GARAGE_CIRCUIT: [Catalog.BREAKER_WATTS, "the garage"]}
	for h: House in houses.values():
		if h.state != House.NEIGHBOUR:
			out[h.id] = [Town.CIRCUIT_WATTS[h.lot["size"]], "the old house of %s" % h.lot["name"]]
	return out


## How much faster than a sealed room this building loses heat (open doors, no walls at all).
func vent_factor(circuit: int) -> float:
	if circuit == GARAGE_CIRCUIT:
		return 2.5 if door_open else 1.0
	var h: House = houses.get(circuit)
	if h == null:
		return 1.0
	return 25.0 if h.state == House.GONE else (2.0 if h.door_open else 1.0)


## Is there a thermometer where this player stands? Outdoors you can always tell.
func temp_known_at(pos: Vector3) -> bool:
	var c := circuit_at(pos)
	if c < 0:
		return true
	for it: Item in items.values():
		if it.def.get("sensor", "") == "room" and it.holder == 0 and circuit_at(it.global_position) == c:
			return true
	return false


## Does this pump's loop have a coolant sensor on it?
func loop_measured(pump_id: int) -> bool:
	for it: Item in items.values():
		if it.def.get("sensor", "") == "coolant" and it.holder == 0 and Sim.pump_id(it, items) == pump_id:
			return true
	return false


## The temperature a player standing here feels: the building they are in, or the weather.
func temp_at(pos: Vector3) -> float:
	return temps.get(circuit_at(pos), outside_temp)


## Which building's wiring a power inlet or wall socket at this spot belongs to; -1 for none.
func circuit_at(pos: Vector3) -> int:
	if absf(pos.x) < 5.5 and absf(pos.z) < 4.5:
		return GARAGE_CIRCUIT
	for h: House in houses.values():
		if h.state == House.NEIGHBOUR:
			continue
		var local := h.to_local(pos)
		var half: Vector2 = (Town.CLEAR_SIZE if h.state == House.GONE else Town.FOOTPRINTS[h.lot["size"]]) * 0.5
		if absf(local.x) < half.x and absf(local.z) < half.y:
			return h.id
	return -1


func can_attach(child: Item, par: Item) -> bool:
	return attach_problem(child, par) == ""


## Why `child` cannot be mounted on `par` right now, or "" if it can.
func attach_problem(child: Item, par: Item) -> String:
	if par == child or not par.def.has("slots"):
		return "That does not go there"
	var group: String = child.def.get("group", "")
	var fits := false
	for slot: Dictionary in par.def["slots"]:
		fits = fits or slot["accepts"] == group
	if not fits:
		return "A %s has no place for that" % par.label.to_lower()
	if child.def.get("tier", 0) > par.def.get("max_tier", 99):
		return "Too advanced for this chassis: it takes parts up to tier %d, this is tier %d" % [par.def["max_tier"], child.def["tier"]]
	if par.def.get("lid", false) and not par.opened:
		return "The lid is screwed on. Open it with a screwdriver."
	if free_slot(par, group) < 0:
		return "Every %s slot is taken" % Catalog.GROUP_NAMES.get(group, group)
	return ""


## The first empty slot of `par` that takes this group, or the empty one nearest to the world
## position `near` if that is given and within `reach` metres. -1 if there is none.
func free_slot(par: Item, group: String, near: Variant = null, reach := 0.2) -> int:
	var used := {}
	for it: Item in items.values():
		if it.parent == par.id:
			used[it.slot] = true
	var best := -1
	var best_dist := reach
	var slots: Array = par.def["slots"]
	for s in slots.size():
		if used.has(s) or slots[s]["accepts"] != group:
			continue
		if near == null:
			return s
		var dist: float = (par.global_transform * slots[s]["xf"].origin).distance_to(near)
		if dist < best_dist:
			best = s
			best_dist = dist
	return best


func debug_dump() -> String:
	var out := "PROBE peer=%d players=%s money=%.0f tokens=%.1f watts=%.0f/%.0f tripped=%s door=%s owned=%s weather=%s" % [
		multiplayer.get_unique_id(), Net.players.keys(), money, tokens, watts, capacity, tripped_circuits, door_open, _owned_ids(),
		Catalog.WEATHER[weather]["name"]]
	for p: Player in _players.get_children():
		out += "\n  player %d at %.1v" % [p.peer_id, p.position]
	out += "\n  used=[%s]" % ",".join((used.get("listings", []) as Array).map(
			func(l: Dictionary) -> String: return "%d:%s:%d" % [l["id"], l["kind"], l["price"]]))
	for it: Item in items.values():
		out += "\n  item %d %s at %.1v holder=%d parent=%d/%d power=%d net=%d status=%d speed=%.3f asleep=%s pinned=%s" % [
			it.id, it.kind, it.global_position, it.holder, it.parent, it.slot, it.power_to, it.net_to, it.status,
			it.linear_velocity.length() + it.angular_velocity.length(), it.sleeping, it.pinned]
		if it.def.has("gen"):
			out += " running=%s fuel=%.2f rider=%d load=%.0f" % [it.running, it.fuel, it.rider, it.load]
	return out


# --- requests ---------------------------------------------------------------

func request_grab(id: int) -> void:
	_to_host(&"_h_grab", [id])


func request_release(throw: bool) -> void:
	_to_host(&"_h_release", [throw])


## Put the held item down exactly at xf, at rest.
func request_place(xf: Transform3D) -> void:
	_to_host(&"_h_place", [xf])


## Mount the held item on `parent_id`. `slot` -1 = the first free slot that takes it.
func request_attach(parent_id: int, slot := -1) -> void:
	_to_host(&"_h_attach", [parent_id, slot])


## With a screwdriver in hand: open or close a machine's lid.
func request_lid(id: int) -> void:
	_to_host(&"_h_lid", [id])


## provider_id 0 = unplug.
## `pins`: points in the world the cable is clipped to on its way from the item to the provider.
func request_link(id: int, type: String, provider_id: int, pins: Array = []) -> void:
	_to_host(&"_h_link", [id, type, provider_id, pins])


## Why a cable cannot run from `from` through `pins` to `to` ("" if it can). A loose stretch reaches
## MAX_CABLE; pinned along the way the whole run can be MAX_ROUTED long.
static func route_problem(from: Vector3, pins: Array, to: Vector3) -> String:
	if pins.is_empty():
		return "" if from.distance_to(to) <= Catalog.MAX_CABLE else "Too far for a loose cable (%d m). Pin it along the way." % Catalog.MAX_CABLE
	if pins.size() > Catalog.MAX_PINS:
		return "That is enough pins for one cable"
	if from.distance_to(pins[0]) > Catalog.MAX_CABLE or (pins[-1] as Vector3).distance_to(to) > Catalog.MAX_CABLE:
		return "Too far from the last pin (%d m of slack at most)" % Catalog.MAX_CABLE
	var total := from.distance_to(pins[0]) + (pins[-1] as Vector3).distance_to(to)
	for i in pins.size() - 1:
		total += (pins[i] as Vector3).distance_to(pins[i + 1])
	return "" if total <= Catalog.MAX_ROUTED else "This cable is only %d m long" % Catalog.MAX_ROUTED


func request_buy(kind: String) -> void:
	_to_host(&"_h_buy", [kind])


## Second-hand market: a listing id, or 0 and the kind of one of the always-in-stock staples.
func request_buy_used(listing: int, staple := "") -> void:
	_to_host(&"_h_buy_used", [listing, staple])


## Second-hand market: ask a seller for a lower price (once per offer).
func request_haggle_used(listing: int) -> void:
	_to_host(&"_h_haggle_used", [listing])


## Sell everything on the pick-up pallet.
func request_sell() -> void:
	_to_host(&"_h_sell", [])


## Open a delivered parcel: the box is gone, the thing inside stands in its place.
func request_unpack(id: int) -> void:
	_to_host(&"_h_unpack", [id])


func request_breaker(circuit: int) -> void:
	_to_host(&"_h_breaker", [circuit])


func request_door() -> void:
	_to_host(&"_h_door", [])


## Pump: suck the water out of every hose on its loop, back into the reservoir.
func request_drain(id: int) -> void:
	_to_host(&"_h_drain", [id])


## Bucket in hand: fill it at a tap, or pour it into a reservoir.
func request_bucket(target_id: int) -> void:
	_to_host(&"_h_bucket", [target_id])


func request_unwear() -> void:
	_to_host(&"_h_unwear", [])


## The local player passed out from the heat.
func request_fainted() -> void:
	_to_host(&"_h_fainted", [])


## Ask the company to do something. Actions and their arguments:
##   "start" [kind "slop"|"product", key, size 0-2, risk 0-2]     "rent" [true|false]: rent out spare compute
##   "update" [live id]   "retire" [live id]   "cancel" [job id]   "rush" [job id]
##   "priority" [job id]: feed this one first (again to undo; the code being written and the training run have ids too)
##   "train" []           "advertise" [campaign key]
##   "use" [model key]    "buy" [model key]    "code" [training stack component key]
## A refusal comes back to the asker as a notice (hud.toast).
func request_company(action: String, args: Array = []) -> void:
	_to_host(&"_h_company", [action, args])


## Tell everyone that we sat down at (or left) the company console: the ops board shows who is typing.
func request_console(on: bool) -> void:
	_to_host(&"_h_console", [on])


func request_empty_bin() -> void:
	_to_host(&"_h_empty_bin", [])


## The local player ran into a cable.
func request_trip(id: int, type: String) -> void:
	_to_host(&"_h_trip", [id, type])


## Spray the held extinguisher at a burning item.
func request_extinguish(id: int) -> void:
	_to_host(&"_h_extinguish", [id])


## Switch a generator on/off, or hop on/off the bike.
func request_use(id: int) -> void:
	_to_host(&"_h_use", [id])


## Pour the held jerry can into a generator.
func request_refuel(id: int) -> void:
	_to_host(&"_h_refuel", [id])


## Offer a neighbour money for their house. The answer comes back through hud.offer_reply().
func request_offer(house_id: int, amount: int) -> void:
	_to_host(&"_h_offer", [house_id, amount])


func request_house_door(house_id: int) -> void:
	_to_host(&"_h_house_door", [house_id])


## Has to be asked twice within a few seconds before anything happens.
func request_demolish(house_id: int) -> void:
	_to_host(&"_h_demolish", [house_id])


# --- houses -----------------------------------------------------------------

func _build_houses() -> void:
	var all: Array = [Town.HOME_HOUSE]
	all.append_array(Town.lots())
	for lot: Dictionary in all:
		var h := House.new()
		add_child(h)
		h.setup(lot)
		houses[h.id] = h
		fixtures.merge(h.fixtures)


func _owned_ids() -> Array:
	var out := []
	for h: House in houses.values():
		if h.state != House.NEIGHBOUR:
			out.append("%d%s" % [h.id, "(gone)" if h.state == House.GONE else ""])
	return out


## Host: everyone left their furniture behind. It is ordinary carryable stuff.
func _spawn_furniture() -> void:
	for h: House in houses.values():
		for spot: Array in h.furniture():
			_cast(&"_r_spawn", [_next_id, spot[0], spot[1], [0, 0, 0, 0, 0, true, "", 0, 0, false]])
			_next_id += 1


# --- players ----------------------------------------------------------------

func _reconcile_players() -> void:
	var ids := Net.players.keys()
	for id: int in ids:
		if player(id) == null:
			var p := Player.new()
			p.name = str(id)
			p.peer_id = id
			p.position = SPAWNS[ids.find(id) % SPAWNS.size()]
			_players.add_child(p)
	for p: Player in _players.get_children():
		if not Net.players.has(p.peer_id):
			p.queue_free()
	if multiplayer.is_server():
		ready_peers = ready_peers.filter(func(id): return Net.players.has(id))
		for it: Item in items.values():   # someone left while carrying something
			if it.holder != 0 and not Net.players.has(it.holder):
				_cast(&"_r_release", [it.id, it.global_transform, Vector3.ZERO])
			if it.rider != 0 and not Net.players.has(it.rider):
				it.rider = 0
			if it.worn != 0 and not Net.players.has(it.worn):
				_cast(&"_r_release", [it.id, it.global_transform, Vector3.ZERO])
	hud.set_players(Net.players)


func name_of(peer: int) -> String:
	return Net.players.get(peer, {}).get("name", "Someone")


# --- host: handlers -----------------------------------------------------------

func _spawn_starting_items() -> void:
	# laid out side by side on the garage floor: no power but your own legs.
	# The server already has a CPU and one stick of RAM in it; the GPU you install yourself.
	var kit := [["server", Vector3(-1.6, 0, -1.2)], ["gpu_1080", Vector3(-0.8, 0, -1.2)],
		["screwdriver", Vector3(-0.8, 0, -0.8)],
		["powerstrip", Vector3(-0.1, 0, -1.2)], ["gen_bike", Vector3(1.4, 0, -1.4)]]
	for entry: Array in kit:
		var height: float = Catalog.ITEMS[entry[0]]["size"].y
		_spawn(entry[0], Transform3D(Basis(), entry[1] + Vector3(0, height * 0.5 + 0.05, 0)))
	var server: Item = items[1]
	for kind: String in ["cpu_celery", "ram_8"]:
		var slot := free_slot(server, Catalog.ITEMS[kind]["group"])
		_cast(&"_r_spawn", [_next_id, kind, server.global_transform, [0, server.id, slot, 0, 0, false, "", 0, 0, false]])
		_next_id += 1


## `contains` is only for kind "parcel": the item kind boxed up inside.
func _spawn(kind: String, xf: Transform3D, contains := "") -> void:
	_cast(&"_r_spawn", [_next_id, kind, xf, [0, 0, 0, 0, 0, false, contains, 0, 0, false]])
	_next_id += 1


## Host: pulling a part out of, or pushing one into, a machine that has power is a gamble.
func _hot_swap(part: Item, machine: Item, who: String) -> void:
	if machine.def.get("lid", false) and machine.status & 1 and part.def.get("fragile", false) \
			and not part.broken and randf() < hot_swap_chance:
		part.dead = true
		_cast(&"_r_toast", ["%s hot-swapped a %s with the power on. There was a small blue flash." % [who, part.label.to_lower()]])


@rpc("any_peer", "call_remote", "reliable")
func _h_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	for it: Item in items.values():
		_r_spawn.rpc_id(peer, it.id, it.kind, it.global_transform,
				[it.holder, it.parent, it.slot, it.power_to, it.net_to, it.pinned, it.contains, it.coolant_to, it.worn, it.opened, it.routes])
	_r_door.rpc_id(peer, door_open)
	_r_used.rpc_id(peer, _market.state())
	for h: House in houses.values():
		if h.state != House.NEIGHBOUR:
			_r_house.rpc_id(peer, h.id, h.state)
		if h.door_open:
			_r_house_door.rpc_id(peer, h.id, true)
	ready_peers.append(peer)
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_grab(id: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := Net.sender()
	var it: Item = items.get(id)
	var p := player(peer)
	if it == null or p == null or it.holder != 0 or held_by(peer) != null:
		return
	if p.position.distance_to(it.global_position) > 5.0:
		return
	var machine: Item = items.get(it.parent)
	if machine != null:
		if machine.def.get("lid", false) and not machine.opened:
			return   # screwed shut
		_hot_swap(it, machine, name_of(peer))
	it.rider = 0   # picking up a bike throws its rider off
	_cast(&"_r_hold", [id, peer])


@rpc("any_peer", "call_remote", "reliable")
func _h_release(throw: bool) -> void:
	if not multiplayer.is_server():
		return
	var peer := Net.sender()
	var it := held_by(peer)
	if it == null:
		return
	var vel := Vector3.ZERO
	var xf := it.global_transform
	var p := player(peer)
	if p:
		vel = p.velocity_estimate * 0.6
		if throw:
			vel += p.aim_dir() * 7.0 + Vector3.UP * 1.5
		# never let go of something inside or behind a wall
		var from := p.head.global_position
		var query := PhysicsRayQueryParameters3D.create(from, xf.origin, 1, [p.get_rid()])
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit:
			xf.origin = from.lerp(hit["position"], 0.6)
	_cast(&"_r_release", [it.id, xf, vel])


@rpc("any_peer", "call_remote", "reliable")
func _h_place(xf: Transform3D) -> void:
	if not multiplayer.is_server():
		return
	var peer := Net.sender()
	var it := held_by(peer)
	var p := player(peer)
	if it == null or p == null or p.position.distance_to(xf.origin) > 5.0:
		return
	_cast(&"_r_place", [it.id, xf.orthonormalized()])


@rpc("any_peer", "call_remote", "reliable")
func _h_attach(parent_id: int, slot: int) -> void:
	if not multiplayer.is_server():
		return
	var it := held_by(Net.sender())
	var par: Item = items.get(parent_id)
	if it == null or par == null or not can_attach(it, par):
		return
	var group: String = it.def.get("group", "")
	var slots: Array = par.def["slots"]
	var taken := false
	for other: Item in items.values():
		taken = taken or (other.parent == parent_id and other.slot == slot)
	if slot < 0 or slot >= slots.size() or slots[slot]["accepts"] != group or taken:
		slot = free_slot(par, group)   # not a usable slot: take the first free one instead
	_hot_swap(it, par, name_of(Net.sender()))
	_cast(&"_r_attach", [it.id, parent_id, slot])
	_sim_step(0.0)


## Unscrew or screw on a machine's lid. Needs a screwdriver in hand.
@rpc("any_peer", "call_remote", "reliable")
func _h_lid(id: int) -> void:
	if not multiplayer.is_server():
		return
	var tool := held_by(Net.sender())
	var machine: Item = items.get(id)
	if tool == null or tool.def.get("tool", "") != "screwdriver" or machine == null:
		return
	if not machine.def.get("lid", false) or not machine.is_loose():
		return
	_cast(&"_r_lid", [id, not machine.opened])


@rpc("any_peer", "call_remote", "reliable")
func _h_link(id: int, type: String, provider_id: int, pins: Array) -> void:
	if not multiplayer.is_server() or type not in LINKS:
		return
	var it: Item = items.get(id)
	if it == null or not it.def.get(type + "_port", false):
		return
	if provider_id == 0:
		_unplug(it, type, name_of(Net.sender()))
		_sim_step(0.0)
		return
	if provider_id != 0:
		var target := provider(provider_id)
		if target == null or target.provides != type:
			return
		if sockets_used(provider_id, type) >= target.sockets:
			return
		for pin: Variant in pins:
			if not pin is Vector3:
				return
		if route_problem(it.global_position, pins, target.global_position) != "":
			return
		if provider_id == id:   # allowed. It just doesn't do anything useful.
			_cast(&"_r_toast", ["%s plugged a %s into itself" % [name_of(Net.sender()), it.label.to_lower()]])
	_cast(&"_r_link", [id, type, provider_id, pins])


@rpc("any_peer", "call_remote", "reliable")
func _h_buy(kind: String) -> void:
	if not multiplayer.is_server() or kind not in Catalog.SHOP:
		return
	var def: Dictionary = Catalog.ITEMS[kind]
	if _sim.money < def["price"]:
		return
	_sim.money -= def["price"]
	_deliver(kind)
	_cast(&"_r_toast", ["%s bought %s (-%s)" % [name_of(Net.sender()), def["label"], UI.money(def["price"])]])
	_sim_step(0.0)


## Host: a parcel with `kind` on its label arrives on the driveway, in the next free-ish slot of a 5 x 3 grid.
## Returns the parcel's id.
func _deliver(kind: String) -> int:
	var slot := _deliveries % 15
	_deliveries += 1
	var height: float = Catalog.parcel(kind)["size"].y
	var pos := Vector3(-2.0 + (slot % 5) * 1.0, height * 0.5 + 0.15, 7.0 + (slot / 5) * 1.2)
	_spawn("parcel", Transform3D(Basis(), pos), kind)
	return _next_id - 1


## Second-hand: a listing (by id) or a staple (listing 0 and its kind). The condition is decided
## now but only applied, and only shown, when the parcel is unpacked.
@rpc("any_peer", "call_remote", "reliable")
func _h_buy_used(listing: int, staple: String) -> void:
	if not multiplayer.is_server():
		return
	var who := name_of(Net.sender())
	if listing == 0:
		if staple not in UsedMarket.STAPLES:
			return
		var def: Dictionary = Catalog.ITEMS[staple]
		if _sim.money < def["price"]:
			return
		_sim.money -= def["price"]
		_deliver(staple)
		_cast(&"_r_toast", ["%s bought a %s from %s (-%s)" % [who, def["label"].to_lower(), UsedMarket.STAPLE_SELLER, UI.money(def["price"])]])
		_sim_step(0.0)
		return
	var refusal := _market.can_buy(listing, _sim.money)
	if refusal != "":
		_notice_to(Net.sender(), refusal)
		return
	var l := _market.take(listing)
	_sim.money -= l["price"]
	_parcel_cond[_deliver(l["kind"])] = {"cond": l["cond"], "actual": l["actual"]}
	_cast(&"_r_toast", ["%s bought %s from %s (-%s)" % [who, Catalog.ITEMS[l["kind"]]["label"].to_lower(), l["seller"], UI.money(l["price"])]])
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_haggle_used(listing: int) -> void:
	if not multiplayer.is_server():
		return
	var result := _market.haggle(listing)
	if not result.is_empty():
		_cast(&"_r_toast", [result["text"]])
		_sim_step(0.0)


func _notice_to(peer: int, text: String) -> void:
	if peer == multiplayer.get_unique_id():
		_r_notice(text)
	else:
		_r_notice.rpc_id(peer, text)


## Sell everything on the pallet: working things for a share of the price, ruined ones as scrap.
@rpc("any_peer", "call_remote", "reliable")
func _h_sell() -> void:
	if not multiplayer.is_server():
		return
	var doomed := {}
	for it: Item in items.values():
		if it.holder == 0 and it.parent == 0 and _pickup.holds(it.global_position):
			doomed[it.id] = true
	var grew := true
	while grew:   # whatever is mounted on something on the pallet goes with it
		grew = false
		for it: Item in items.values():
			if it.parent != 0 and doomed.has(it.parent) and not doomed.has(it.id):
				doomed[it.id] = true
				grew = true
	var total := 0
	var lines := {}   # label -> [count, money]
	for id: int in doomed:
		var it: Item = items[id]
		var ruined: bool = it.broken or it.dead
		var value := UsedMarket.sale_value(it.kind, ruined, it.contains)
		var label: String = ("ruined " if ruined else "") + it.label.to_lower()
		var row: Array = lines.get(label, [0, 0])
		lines[label] = [row[0] + 1, row[1] + value]
		total += value
		_parcel_cond.erase(id)
		_cast(&"_r_despawn", [id])
	if doomed.is_empty():
		_cast(&"_r_toast", ["%s pressed the pick-up button. Nothing on the pallet. The courier sighs." % name_of(Net.sender())])
		return
	_sim.money += total
	var bits: Array[String] = []
	for label: String in lines:
		bits.append("%s%s %s" % ["%dx " % lines[label][0] if lines[label][0] > 1 else "", label, UI.money(lines[label][1])])
	var shown := ", ".join(bits.slice(0, 4)) + (" and %d more kinds" % (bits.size() - 4) if bits.size() > 4 else "")
	_cast(&"_r_toast", ["%s sold %d %s for %s: %s" % [name_of(Net.sender()), doomed.size(),
		"thing" if doomed.size() == 1 else "things", UI.money(total), shown]])
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_unpack(id: int) -> void:
	if not multiplayer.is_server():
		return
	var box: Item = items.get(id)
	var p := player(Net.sender())
	if box == null or p == null or box.kind != "parcel" or box.holder != 0:
		return
	if p.position.distance_to(box.global_position) > 5.0:
		return
	var inside: String = box.contains
	var cond := "fine"
	var fate: Dictionary = _parcel_cond.get(id, {})
	if not fate.is_empty():   # second-hand: what is really in the box
		cond = fate["cond"]
		inside = fate["actual"]
		_parcel_cond.erase(id)
	var lift: float = (Catalog.ITEMS[inside]["size"].y - box.def["size"].y) * 0.5 + 0.02
	var xf := Transform3D(Basis(Vector3.UP, box.global_rotation.y), box.global_position + Vector3(0, lift, 0))
	var advertised: String = Catalog.ITEMS[box.contains]["label"].to_lower()
	_cast(&"_r_despawn", [id])
	_spawn(inside, xf)
	var thing: Item = items[_next_id - 1]
	if fate.is_empty():
		if Catalog.ITEMS[inside].get("used", false) and randf() < doa_chance:
			thing.dead = true
			_cast(&"_r_toast", ["The %s was dead on arrival. No refunds." % Catalog.ITEMS[inside]["label"].to_lower()])
	else:
		match cond:
			"dead":
				thing.dead = true
				_cast(&"_r_toast", ["The %s was dead on arrival. \"Sold for parts\", said the listing." % advertised])
			"sketchy":
				thing.sketchy = true   # no toast: you find out when it gets warm
			"soaked":
				_cast(&"_r_puddle", [Vector3(xf.origin.x, 0.02, xf.origin.z), 0.6, 12.0])
				_cast(&"_r_toast", ["The %s arrived pre-soaked and is dripping. Grab it, quickly!" % advertised])
			"brick":
				_cast(&"_r_toast", ["The parcel held %s and a note: \"sold as seen\"." % Catalog.ITEMS[inside]["label"].to_lower()])
			"swapped":
				_cast(&"_r_toast", ["That is not a %s. It is a %s. The note says \"close enough\"." % [
					advertised, Catalog.ITEMS[inside]["label"].to_lower()]])
			"bonus":
				for kind: String in ["cpu_celery", "ram_8"]:
					var slot := free_slot(thing, Catalog.ITEMS[kind]["group"])
					if slot >= 0:
						_cast(&"_r_spawn", [_next_id, kind, thing.global_transform, [0, thing.id, slot, 0, 0, false, "", 0, 0, false]])
						_next_id += 1
				_cast(&"_r_toast", ["The %s came with a few things still inside it. Lucky you." % advertised])
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_breaker(circuit: int) -> void:
	if not multiplayer.is_server() or not _sim.tripped.has(circuit):
		return
	_sim.reset_breaker(circuit)
	_cast(&"_r_toast", ["%s reset the breaker in %s" % [name_of(Net.sender()), circuits()[circuit][1]]])
	_sim_step(0.0)


## Host: pull a cable or hose out. A hose with water in it makes a mess, and one under
## pressure (its pump is running) sprays everything nearby.
func _unplug(it: Item, type: String, who: String) -> void:
	if type == "coolant" and it.hose > 0.3:
		var pump: Item = _sim.pump_for(it, self)
		var mains: bool = it.def.has("tank") and it.coolant_to < 0
		var spraying: bool = mains or (pump != null and pump.running and pump.status == 3)
		var at := it.port_pos("coolant")
		var floor_hit := get_world_3d().direct_space_state.intersect_ray(
				PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.1, at + Vector3.DOWN * 4.0, 1))
		if floor_hit:
			at = floor_hit["position"]
		_cast(&"_r_puddle", [at + Vector3(0, 0.01, 0), 2.2 if spraying else 0.9, 90.0 if spraying else 45.0])
		if spraying:
			var soaked := 0
			for other: Item in items.values():
				if other.def.get("fragile", false) and not other.broken and not other.dead \
						and other.global_position.distance_to(it.global_position) < 1.8:
					other.dead = true
					soaked += 1
			var tank: Item = items.get(pump.coolant_to) if pump != null else null
			if tank != null and tank.def.has("tank"):
				tank.fuel = maxf(0.0, tank.fuel - 0.25)
			_cast(&"_r_toast", ["%s pulled a hose off under pressure! Water everywhere, %d %s soaked." % [
				who, soaked, "thing" if soaked == 1 else "things"]])
		else:
			_cast(&"_r_toast", ["%s pulled out a full coolant hose. There is a puddle now." % who])
	it.hose = 0.0
	_cast(&"_r_link", [it.id, type, 0, []])


@rpc("any_peer", "call_remote", "reliable")
func _h_drain(id: int) -> void:
	if not multiplayer.is_server():
		return
	var pump: Item = items.get(id)
	if pump == null or not pump.def.has("pump") or pump.running:
		return
	pump.draining = true
	_cast(&"_r_toast", ["%s is draining the coolant hoses" % name_of(Net.sender())])


@rpc("any_peer", "call_remote", "reliable")
func _h_bucket(target_id: int) -> void:
	if not multiplayer.is_server():
		return
	var bucket := held_by(Net.sender())
	var target := provider(target_id)
	if bucket == null or bucket.kind != "bucket" or target == null:
		return
	if target_id < 0 and target.kind == "tap":
		bucket.fuel = 1.0
	elif target_id > 0 and target.def.has("tank") and bucket.fuel > 0.0:
		target.fuel = minf(1.0, target.fuel + 0.34)
		bucket.fuel = 0.0
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_unwear() -> void:
	if not multiplayer.is_server():
		return
	var peer := Net.sender()
	var suit := worn_by(peer)
	var p := player(peer)
	if suit and p:
		_cast(&"_r_release", [suit.id, Transform3D(Basis(), p.position - p.transform.basis.z * 0.9 + Vector3(0, 0.3, 0)), Vector3.ZERO])


@rpc("any_peer", "call_remote", "reliable")
func _h_fainted() -> void:
	if multiplayer.is_server():
		_cast(&"_r_toast", ["%s passed out from the heat and was dragged outside" % name_of(Net.sender())])


@rpc("any_peer", "call_remote", "reliable")
func _h_console(on: bool) -> void:
	if not multiplayer.is_server():
		return
	if on:
		_at_console[Net.sender()] = true
	else:
		_at_console.erase(Net.sender())


@rpc("any_peer", "call_remote", "reliable")
func _h_company(action: String, args: Array) -> void:
	if not multiplayer.is_server():
		return
	var peer := Net.sender()
	var events: Array = []
	var result := "Unknown action"
	match [action, args.size()]:
		["start", 4]:
			result = _company.start(str(args[0]), str(args[1]), int(args[2]), int(args[3]))
			if result == "":
				events.append("%s started building: %s" % [name_of(peer), _company.jobs[-1]["name"]])
		["update", 1]:
			result = _company.update(int(args[0]), events)
		["retire", 1]:
			result = _company.retire(int(args[0]))
		["cancel", 1]:
			result = _company.cancel(int(args[0]))
		["rush", 1]:
			result = _company.rush(int(args[0]), _sim.money)
		["train", 0]:
			result = _company.train()
			if result == "":
				events.append("%s started training a new model. Do not unplug anything." % name_of(peer))
		["use", 1]:
			result = _company.use_model(str(args[0]), _sim.money)
			if result == "":
				events.append("%s switched the company to %s" % [name_of(peer), _company.info(_company.active)["name"]])
		["buy", 1]:
			result = _company.buy_model(str(args[0]), _sim.money)
			if result.begins_with("$"):
				events.append("%s bought %s" % [name_of(peer), _company.info(str(args[0]))["name"]])
		["code", 1]:
			result = _company.code(str(args[0]))
		["advertise", 1]:
			result = _company.advertise(str(args[0]), _sim.money)
		["priority", 1]:
			result = _company.prioritize(int(args[0]))
		["rent", 1]:
			result = _company.set_renting(bool(args[0]))
	if result.begins_with("$"):          # the company wants money moved
		_sim.money += float(result.substr(1))
	elif result != "":                   # refused: tell only whoever asked
		if peer == multiplayer.get_unique_id():
			_r_notice(result)
		else:
			_r_notice.rpc_id(peer, result)
	_announce(events)
	_sim_step(0.0)


## Host: show company events to everyone. Entries like "$-500" are charges, not messages.
func _announce(events: Array) -> void:
	for text: String in events:
		if text.begins_with("$"):
			_sim.money += float(text.substr(1))
		else:
			_cast(&"_r_toast", [text])


@rpc("any_peer", "call_remote", "reliable")
func _h_empty_bin() -> void:
	if not multiplayer.is_server():
		return
	var doomed := {}
	for it: Item in items.values():
		if it.holder == 0 and it.parent == 0 and _dumpster.holds(it.global_position):
			doomed[it.id] = true
	var grew := true
	while grew:   # whatever is mounted on something in there goes with it
		grew = false
		for it: Item in items.values():
			if it.parent != 0 and doomed.has(it.parent) and not doomed.has(it.id):
				doomed[it.id] = true
				grew = true
	for id: int in doomed:
		_cast(&"_r_despawn", [id])
	_cast(&"_r_toast", ["%s emptied the dumpster (%d %s gone for good)" % [
		name_of(Net.sender()), doomed.size(), "thing" if doomed.size() == 1 else "things"]])
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_trip(id: int, type: String) -> void:
	if not multiplayer.is_server() or type not in LINKS:
		return
	var it: Item = items.get(id)
	var p := player(Net.sender())
	if it == null or p == null or it.link(type) == 0 or p.position.distance_to(it.global_position) > Catalog.MAX_CABLE + 2.0:
		return
	_cast(&"_r_toast", ["%s tripped over a %s and pulled it out of the %s" % [
		name_of(Net.sender()), LINKS[type], it.label.to_lower()]])
	_unplug(it, type, name_of(Net.sender()))
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_extinguish(id: int) -> void:
	if not multiplayer.is_server():
		return
	var can := held_by(Net.sender())
	var target: Item = items.get(id)
	if can == null or can.kind != "extinguisher" or target == null:
		return
	for it: Item in items.values():   # the cloud covers everything close to where you aim
		if it.burning and it.global_position.distance_to(target.global_position) < 1.5:
			it.burning = false
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_door() -> void:
	if multiplayer.is_server():
		_cast(&"_r_door", [not door_open])


@rpc("any_peer", "call_remote", "reliable")
func _h_use(id: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := Net.sender()
	var it: Item = items.get(id)
	var p := player(peer)
	if it == null or p == null or it.holder != 0:
		return
	if it.rider != peer and p.position.distance_to(it.global_position) > 4.0:
		return
	if it.def.has("pump"):
		it.running = not it.running
		it.draining = false
		_cast(&"_r_toast", ["%s switched the coolant pump %s" % [name_of(peer), "on" if it.running else "off"]])
	elif it.def.get("wear", false) and it.is_loose() and worn_by(peer) == null:
		_cast(&"_r_wear", [id, peer])
	match it.def.get("gen", {}).get("kind", ""):
		"pedal":
			if it.rider == peer:
				it.rider = 0
			elif it.rider == 0 and ridden_by(peer) == null and held_by(peer) == null:
				it.rider = peer
		"fuel":
			if it.running:
				it.running = false
			elif it.fuel > 0.0:
				it.running = true
				_cast(&"_r_toast", ["%s started the %s" % [name_of(peer), it.label.to_lower()]])
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_refuel(id: int) -> void:
	if not multiplayer.is_server():
		return
	var can := held_by(Net.sender())
	var it: Item = items.get(id)
	if can == null or can.kind != "fuel" or it == null or it.def.get("gen", {}).get("kind", "") != "fuel":
		return
	it.fuel = 1.0
	_cast(&"_r_despawn", [can.id])
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_offer(house_id: int, amount: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := Net.sender()
	var h: House = houses.get(house_id)
	if h == null or h.state != House.NEIGHBOUR or amount <= 0 or amount > _sim.money:
		return
	if not _haggle.has(house_id):   # what they would really take; they never say
		_haggle[house_id] = {"reserve": h.lot["value"] * randf_range(0.9, 1.5), "mood": 3, "until": 0}
	var deal: Dictionary = _haggle[house_id]
	var who: String = h.lot["name"]
	var mood := "done"
	if Time.get_ticks_msec() >= deal["until"]:
		var ratio: float = amount / deal["reserve"]
		mood = "deal" if ratio >= 1.0 else ("close" if ratio >= 0.85 else ("low" if ratio >= 0.5 else "insult"))
		if mood == "deal":
			_sim.money -= amount
			_cast(&"_r_house", [house_id, House.OURS])
			_cast(&"_r_toast", ["%s bought the house of %s for %s" % [name_of(peer), who, UI.money(amount)]])
			_sim_step(0.0)
		else:
			deal["mood"] -= 2 if mood == "insult" else 1
			if mood == "insult":
				deal["reserve"] *= 1.08   # now it is personal
			if deal["mood"] <= 0:
				deal["mood"] = 3
				deal["until"] = Time.get_ticks_msec() + 90000
				_cast(&"_r_toast", ["%s annoyed %s. They went inside for a while." % [name_of(peer), who]])
	var lines: Array = HAGGLE[mood]
	var reply := [house_id, lines[randi() % lines.size()], mood == "deal"]
	if peer == multiplayer.get_unique_id():
		callv(&"_r_offer_reply", reply)
	else:
		callv(&"rpc_id", [peer, &"_r_offer_reply"] + reply)


@rpc("any_peer", "call_remote", "reliable")
func _h_house_door(house_id: int) -> void:
	if not multiplayer.is_server():
		return
	var h: House = houses.get(house_id)
	if h and h.state == House.OURS:
		_cast(&"_r_house_door", [house_id, not h.door_open])


@rpc("any_peer", "call_remote", "reliable")
func _h_demolish(house_id: int) -> void:
	if not multiplayer.is_server():
		return
	var h: House = houses.get(house_id)
	if h == null or h.state != House.OURS:
		return
	var now := Time.get_ticks_msec()
	if now - int(_demolish_asked.get(house_id, -100000)) > 6000:
		_demolish_asked[house_id] = now
		_cast(&"_r_toast", ["%s wants to DEMOLISH this house. Press again to confirm." % name_of(Net.sender())])
		return
	_cast(&"_r_house", [house_id, House.GONE])
	_cast(&"_r_toast", ["%s knocked the house down. A building pad is all that is left." % name_of(Net.sender())])
	_sim_step(0.0)


# --- host: ticking -------------------------------------------------------------

func _physics_process(dt: float) -> void:
	if not multiplayer.is_server():
		return
	for it: Item in items.values():   # safety net: anything that escapes the level comes back
		if it.is_loose() and it.position.y < -5.0:
			_cast(&"_r_release", [it.id, Transform3D(Basis(), Vector3(0, 1.5, 0)), Vector3.ZERO])
	_sim_t += dt
	if _sim_t >= SIM_STEP:
		_sim_t -= SIM_STEP
		_sim_step(SIM_STEP)
	_tick += 1
	if _tick % 3 != 0 or ready_peers.is_empty():
		return
	var batch := []
	for it: Item in items.values():
		if it.is_loose() and not it.pinned and not it.sleeping:
			batch.append_array([it.id, it.position, it.quaternion])
	if not batch.is_empty():
		for peer: int in ready_peers:
			_r_items.rpc_id(peer, batch)


func _sim_step(dt: float) -> void:
	for it: Item in items.values():   # cables only stretch so far
		for type: String in LINKS:
			var to := it.link(type)
			if to == 0:
				continue
			var target := provider(to)
			if target == null or route_problem(it.global_position, it.routes.get(type, []), target.global_position) != "":
				_cast(&"_r_toast", ["The %s of a %s got yanked out" % [LINKS[type], it.label.to_lower()]])
				_unplug(it, type, "Somebody")
	for puddle: Dictionary in puddles.duplicate():   # puddles dry up
		puddle["left"] -= dt
		if puddle["left"] <= 0.0:
			puddles.erase(puddle)
	_drop_unsupported()
	var events: Array = []
	var status := _sim.step(self, dt, events)
	var ours := 0
	for h: House in houses.values():
		if h.state != House.NEIGHBOUR:
			ours += 1
	_sim.money += _company.tick(dt, _sim.tokens, _sim.money, ours, houses[0].state == House.NEIGHBOUR, events)
	_sim.profit = _company.income
	_announce(events)
	var shared := _company.state()
	var typing: Array[String] = []
	for peer: int in _at_console.keys():
		if Net.players.has(peer):
			typing.append(name_of(peer))
		else:
			_at_console.erase(peer)   # left the game with the menu open
	shared["console"] = typing
	_cast(&"_r_company", [shared])
	_market.tick(dt, _company.level())
	_cast(&"_r_used", [_market.state()])
	var gens := {}   # everything with moving parts: generators, pumps, tanks, buckets, servers, hoses
	for it: Item in items.values():
		if it.def.has("gen") or it.def.has("pump") or it.def.has("tank") or it.kind == "bucket" \
				or it.def.has("psu") or it.coolant_to != 0 or it.hose > 0.0:
			gens[it.id] = [it.running, it.fuel, it.rider, it.load, it.hose, it.heat]
	_cast(&"_r_sim", [[_sim.money, _sim.tokens, _sim.watts, _sim.capacity, _sim.profit, _sim.tripped.keys(), _sim.weather,
		_sim.temps, _sim.outside_temp(), _sim.wiring], status, gens])


## A pinned item whose support was taken away (the crate under it got picked up...) falls.
func _drop_unsupported() -> void:
	var space := get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 3
	for it: Item in items.values():
		if not it.pinned or not it.is_loose():
			continue
		var shape := BoxShape3D.new()
		shape.size = it.def["size"] * 0.9
		query.shape = shape
		# held up by what is below it, or for wall-mounted things by the wall behind it
		var below := it.global_transform.translated(Vector3.DOWN * (it.def["size"].y * 0.05 + 0.06))
		var behind := it.global_transform.translated(it.global_basis.z * (it.def["size"].z * 0.05 + 0.06))
		query.exclude = [it.get_rid()]
		query.transform = below
		if it.def.get("wall", false) and space.intersect_shape(query, 1).is_empty():
			query.transform = behind
		if space.intersect_shape(query, 1).is_empty():
			_cast(&"_r_release", [it.id, it.global_transform, Vector3.ZERO])


func _on_item_sleep(it: Item) -> void:
	if it.sleeping and it.is_loose():   # final exact resting pose, reliably
		for peer: int in ready_peers:
			_r_rest.rpc_id(peer, it.id, it.position, it.quaternion)


# --- replicated ------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _r_spawn(id: int, kind: String, xf: Transform3D, st: Array) -> void:
	var it := Item.new()
	it.setup(id, kind, st[6])
	it.name = str(id)
	it.holder = st[0]
	it.parent = st[1]
	it.slot = st[2]
	it.power_to = st[3]
	it.net_to = st[4]
	it.pinned = st[5]
	it.coolant_to = st[7]
	it.worn = st[8]
	it.opened = st[9]
	if st.size() > 10:
		it.routes = st[10]
	_items.add_child(it)
	it.global_transform = xf
	it._pin_xf = xf
	items[id] = it
	if multiplayer.is_server():
		it.sleeping_state_changed.connect(_on_item_sleep.bind(it))


## A puddle on the floor: wet electronics standing in it are ruined within a couple of seconds.
@rpc("authority", "call_remote", "reliable")
func _r_puddle(pos: Vector3, radius: float, seconds: float) -> void:
	puddles.append({"pos": pos, "radius": radius, "left": seconds})
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.012
	var water := StandardMaterial3D.new()
	water.albedo_color = Color(0.25, 0.55, 0.95, 0.55)
	water.roughness = 0.05
	water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	disc.material = water
	var node := MeshInstance3D.new()
	node.mesh = disc
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	node.global_position = pos
	node.scale = Vector3(0.2, 1, 0.2)
	var tween := node.create_tween()
	tween.tween_property(node, "scale", Vector3.ONE, 0.6)
	tween.tween_interval(maxf(seconds - 6.0, 0.1))
	tween.tween_property(node, "scale", Vector3(0.01, 1, 0.01), 5.0)
	tween.tween_callback(node.queue_free)


@rpc("authority", "call_remote", "reliable")
func _r_wear(id: int, peer: int) -> void:
	var it: Item = items.get(id)
	if it:
		it.worn = peer
		it.pinned = false
		it.apply_mode()


@rpc("authority", "call_remote", "reliable")
func _r_hold(id: int, peer: int) -> void:
	var it: Item = items.get(id)
	if it:
		it.parent = 0
		it.pinned = false
		it.holder = peer
		it.apply_mode()


@rpc("authority", "call_remote", "reliable")
func _r_release(id: int, xf: Transform3D, vel: Vector3) -> void:
	var it: Item = items.get(id)
	if it:
		it.release(xf, vel)


## Placed deliberately: pinned exactly at xf, no physics, so it cannot tip off a shelf edge.
@rpc("authority", "call_remote", "reliable")
func _r_place(id: int, xf: Transform3D) -> void:
	var it: Item = items.get(id)
	if it:
		it.release(xf, Vector3.ZERO, true)


@rpc("authority", "call_remote", "reliable")
func _r_lid(id: int, open: bool) -> void:
	var it: Item = items.get(id)
	if it:
		it.set_open(open)


@rpc("authority", "call_remote", "reliable")
func _r_attach(id: int, parent_id: int, slot: int) -> void:
	var it: Item = items.get(id)
	if it:
		it.holder = 0
		it.parent = parent_id
		it.slot = slot
		it.apply_mode()


@rpc("authority", "call_remote", "reliable")
func _r_link(id: int, type: String, provider_id: int, pins: Array) -> void:
	var it: Item = items.get(id)
	if it:
		it.set_link(type, provider_id)
		if pins.is_empty():
			it.routes.erase(type)
		else:
			it.routes[type] = pins


@rpc("authority", "call_remote", "reliable")
func _r_sim(company: Array, status: Dictionary, gens: Dictionary) -> void:
	money = company[0]
	tokens = company[1]
	watts = company[2]
	capacity = company[3]
	tripped_circuits = company[5]
	tripped = not tripped_circuits.is_empty()
	weather = company[6]
	temps = company[7]
	outside_temp = company[8]
	wiring = company[9]
	profit = company[4]
	_weather.set_weather(weather)
	hud.set_weather(weather)
	for id: int in status:
		var it: Item = items.get(id)
		if it:
			it.set_status(status[id])
	for id: int in gens:
		var it: Item = items.get(id)
		if it:
			it.running = gens[id][0]
			it.fuel = gens[id][1]
			it.rider = gens[id][2]
			it.load = gens[id][3]
			it.hose = gens[id][4]
			it.heat = gens[id][5]
			if it.kind == "bucket":
				it.set_status(3 if it.fuel > 0.0 else 0)   # its "light" is the water in it
	for f: Node3D in fixtures.values():
		if f.kind == "breaker":
			f.set_lamp(1 if tripped_circuits.has(f.circuit) else 2)
	hud.set_stats(money, tokens, watts, capacity, company[4], tripped)
	board.refresh(self)


@rpc("authority", "call_remote", "reliable")
func _r_company(state: Dictionary) -> void:
	co = state
	fixtures[-3].provides = "" if co["overdue"] else "net"   # no money, no internet in the garage
	hud.company_changed()


## The second-hand market's offers (never their hidden conditions).
@rpc("authority", "call_remote", "reliable")
func _r_used(state: Dictionary) -> void:
	used = state


## A message for one player only (why something they asked for was refused).
@rpc("authority", "call_remote", "reliable")
func _r_notice(text: String) -> void:
	hud.toast(text)


@rpc("authority", "call_remote", "reliable")
func _r_despawn(id: int) -> void:
	var it: Item = items.get(id)
	if it:
		items.erase(id)
		it.queue_free()


@rpc("authority", "call_remote", "reliable")
func _r_house(house_id: int, state: int) -> void:
	var h: House = houses[house_id]
	var before := h.fixtures.keys()
	h.set_state(state)
	for id: int in before:   # the neighbour, and after a demolition the door, are gone
		if not h.fixtures.has(id):
			fixtures.erase(id)


@rpc("authority", "call_remote", "reliable")
func _r_house_door(house_id: int, open: bool) -> void:
	houses[house_id].set_door(open)


@rpc("authority", "call_remote", "reliable")
func _r_offer_reply(house_id: int, text: String, accepted: bool) -> void:
	hud.offer_reply(house_id, text, accepted)


@rpc("authority", "call_remote", "reliable")
func _r_door(open: bool) -> void:
	door_open = open
	_garage.set_door(open)


@rpc("authority", "call_remote", "reliable")
func _r_toast(text: String) -> void:
	hud.toast(text)
	board.alert(text)


@rpc("authority", "call_remote", "unreliable_ordered")
func _r_items(batch: Array) -> void:
	for i in range(0, batch.size(), 3):
		var it: Item = items.get(batch[i])
		if it and it.is_loose():
			it.net_target(batch[i + 1], batch[i + 2])


@rpc("authority", "call_remote", "reliable")
func _r_rest(id: int, pos: Vector3, rot: Quaternion) -> void:
	var it: Item = items.get(id)
	if it and it.is_loose():
		it.net_target(pos, rot)


# --- rpc helpers ---------------------------------------------------------------

## Host: run a replicated method here and on every client that has the world loaded.
func _cast(method: StringName, args: Array) -> void:
	callv(method, args)
	for peer: int in ready_peers:
		callv(&"rpc_id", [peer, method] + args)


## Run a host-side handler: directly if we are the host, else by RPC.
func _to_host(method: StringName, args: Array) -> void:
	if multiplayer.is_server():
		callv(method, args)
	else:
		callv(&"rpc_id", [1, method] + args)


## Test aid (host, `--showroom`): one of every catalog item in a single line along X at z = 7, fronts to the
## south, so a camera at z = 7.8 looking north (yaw 0) sees them; positions are printed as SHOWROOM lines.
## Groups, left to right: machines opened and filled, machines closed, loose parts, racks and wiring,
## generators, cooling, sensors and tools, furniture. Each group stands on a low display counter
## (`raise` scales its height, 0 = on the ground) so a camera can get close.
func debug_showroom(raise := 1.0) -> void:
	var by_price := func(a: String, b: String) -> bool: return Catalog.ITEMS[a]["price"] < Catalog.ITEMS[b]["price"]
	var kinds_of := func(group: String) -> Array:
		var out: Array = Catalog.ITEMS.keys().filter(func(k: String) -> bool: return Catalog.ITEMS[k].get("group", "") == group)
		out.sort_custom(by_price)
		return out
	var machines: Array = Catalog.ITEMS.keys().filter(func(k: String) -> bool: return Catalog.ITEMS[k].has("psu"))
	machines.sort_custom(by_price)
	var cpus: Array = kinds_of.call("cpu")
	var rams: Array = kinds_of.call("ram")
	var gpus: Array = kinds_of.call("gpu")
	var fill := {}   # machine kind -> the parts to put in it: the best CPU, mid RAM and a different GPU in every slot
	for m: String in machines:
		var md: Dictionary = Catalog.ITEMS[m]
		var tier: int = md["max_tier"]
		var cpu_ok: Array = cpus.filter(func(k: String) -> bool: return Catalog.ITEMS[k]["tier"] <= tier)
		var gpu_ok: Array = gpus.filter(func(k: String) -> bool: return Catalog.ITEMS[k]["tier"] <= tier \
				and (not Catalog.ITEMS[k].get("liquid", false) or md.get("coolant_port", false)))
		var counts := {}
		for slot_def: Dictionary in md["slots"]:
			counts[slot_def["accepts"]] = counts.get(slot_def["accepts"], 0) + 1
		var picks: Array = []
		for i in counts.get("cpu", 0):
			picks.append(cpu_ok[cpu_ok.size() - 1])
		for i in counts.get("ram", 0):
			picks.append("ram_16" if tier < 3 else ("ram_64" if tier < 5 else "ram_256"))
		for i in counts.get("gpu", 0):
			picks.append(gpu_ok[(gpu_ok.size() - 1 - i) % gpu_ok.size()])
		fill[m] = picks
	var groups: Array = [
		[machines, true, 0.95, 1.0],
		[machines, false, 0.95, 1.0],
		[cpus, false, 1.0, 0.5],
		[rams, false, 1.0, 0.5],
		[gpus, false, 1.0, 0.5],
		[["rack_half", "rack", "rack_tall", "powerstrip", "switch", "inlet", "outlet", "lamp"], false, 0.0],
		[["gen_bike", "gen_mower", "gen_diesel", "gen_solar"], false, 0.0],
		[["pump", "reservoir", "radiator", "manifold", "bucket", "fan", "aircon"], false, 0.5],
		[["thermometer", "sensor_power", "sensor_coolant", "screen", "extinguisher", "fuel", "screwdriver", "suit", "crate", "parcel"], false, 0.9],
		[["sofa", "tv", "table", "bed", "fridge", "plant"], false, 0.0],
	]
	var x := -36.0
	for group: Array in groups:
		var filled: bool = group[1]
		var lift: float = (group[2] if group.size() > 2 else 0.0) * raise
		if x > 2.0 and x < 9.5:   # the dumpster stands there
			x = 9.5
		var depth: float = group[3] if group.size() > 3 else 1.3
		var from_x := x
		for kind: String in group[0]:
			var def: Dictionary = Catalog.parcel("gpu_4090") if kind == "parcel" else Catalog.ITEMS[kind]
			var size: Vector3 = def["size"]
			var reach := maxf(size.x, size.z)
			var gap := 0.1 if reach < 0.35 else 0.35
			var xf := Transform3D(Basis(Vector3.UP, PI), Vector3(x + reach * 0.5, size.y * 0.5 + 0.003 + lift, 7.0))
			x += reach + gap
			var id := _next_id
			print("SHOWROOM %s%s x=%.2f" % [kind, " (open, filled)" if filled else "", xf.origin.x])
			_cast(&"_r_spawn", [id, kind, xf, [0, 0, 0, 0, 0, true, "gpu_4090" if kind == "parcel" else "", 0, 0, filled and fill.has(kind)]])
			_next_id += 1
			if filled and fill.has(kind):
				for part: String in fill[kind]:
					var slot := free_slot(items[id], Catalog.ITEMS[part]["group"])
					if slot >= 0:
						_cast(&"_r_spawn", [_next_id, part, xf, [0, id, slot, 0, 0, false, "", 0, 0, false]])
						_next_id += 1
			if kind.begins_with("rack"):   # racks carry servers in every slot
				var served := ["server_4u", "server_2u", "server_ws", "server_wslc", "server", "server_frame"]
				for i in (Catalog.ITEMS[kind]["slots"] as Array).size():
					var server: String = served[i % served.size()] if kind != "rack_half" else ["server_2u", "server_4u"][i]
					var slot := free_slot(items[id], "server")
					_cast(&"_r_spawn", [_next_id, server, xf, [0, id, slot, 0, 0, false, "", 0, 0, false]])
					_next_id += 1
		if lift > 0.0:   # the display counter under this group
			var counter := StaticBody3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(x - from_x + 0.4, lift, depth)
			var shape := CollisionShape3D.new()
			shape.shape = box
			counter.add_child(shape)
			counter.add_child(Catalog.Shapes.instance(Catalog.Shapes.rounded_box(box.size, 0.02, 1), Catalog.Materials.part(Color(0.35, 0.36, 0.4), "matte")))
			counter.position = Vector3((from_x + x) * 0.5 - 0.05, lift * 0.5, 7.0)
			add_child(counter)
		x += 1.0
