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
const OpsBoard = preload("res://scripts/ops_board.gd")
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
var preview: Dictionary = {}    # cable end the local player is carrying: {"id", "type"}
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
var profit := 0.0                # $ per second
var wiring: Dictionary = {}      # circuit id -> watts drawn through that building's wiring
var puddles: Array = []          # [{"pos", "radius", "left"}] water on the floor
var doa_chance := 0.12           # host: odds that a used part turns out dead when unpacked
var door_open := false
var capacity := 0.0             # watts available right now (grid + running generators)

var weather := 0                # index into Catalog.WEATHER

var _garage: Garage
var _dumpster: Dumpster
var _weather: Weather
var _players: Node3D
var _items: Node3D
var _sim: Sim                   # host only
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
	if par == child or not par.def.has("slots"):
		return false
	return par.def["slots"]["accepts"] == child.def.get("group", "") and _free_slot(par) >= 0


func debug_dump() -> String:
	var out := "PROBE peer=%d players=%s money=%.0f tokens=%.1f watts=%.0f/%.0f tripped=%s door=%s owned=%s weather=%s" % [
		multiplayer.get_unique_id(), Net.players.keys(), money, tokens, watts, capacity, tripped_circuits, door_open, _owned_ids(),
		Catalog.WEATHER[weather]["name"]]
	for p: Player in _players.get_children():
		out += "\n  player %d at %.1v" % [p.peer_id, p.position]
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


func request_attach(parent_id: int) -> void:
	_to_host(&"_h_attach", [parent_id])


## provider_id 0 = unplug.
func request_link(id: int, type: String, provider_id: int) -> void:
	_to_host(&"_h_link", [id, type, provider_id])


func request_buy(kind: String) -> void:
	_to_host(&"_h_buy", [kind])


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
			_cast(&"_r_spawn", [_next_id, spot[0], spot[1], [0, 0, 0, 0, 0, true, "", 0, 0]])
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
	# laid out side by side on the garage floor: no power but your own legs
	var kit := [["server", Vector3(-1.6, 0, -1.2)], ["gpu_1080", Vector3(-0.8, 0, -1.2)],
		["powerstrip", Vector3(-0.1, 0, -1.2)], ["gen_bike", Vector3(1.4, 0, -1.4)],
		["crate", Vector3(-2.6, 0, -1.4)], ["crate", Vector3(2.8, 0, -1.6)]]
	for entry: Array in kit:
		var height: float = Catalog.ITEMS[entry[0]]["size"].y
		_spawn(entry[0], Transform3D(Basis(), entry[1] + Vector3(0, height * 0.5 + 0.05, 0)))


## `contains` is only for kind "parcel": the item kind boxed up inside.
func _spawn(kind: String, xf: Transform3D, contains := "") -> void:
	_cast(&"_r_spawn", [_next_id, kind, xf, [0, 0, 0, 0, 0, false, contains, 0, 0]])
	_next_id += 1


func _free_slot(par: Item) -> int:
	var used := {}
	for it: Item in items.values():
		if it.parent == par.id:
			used[it.slot] = true
	for s in par.def["slots"]["at"].size():
		if not used.has(s):
			return s
	return -1


@rpc("any_peer", "call_remote", "reliable")
func _h_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	for it: Item in items.values():
		_r_spawn.rpc_id(peer, it.id, it.kind, it.global_transform,
				[it.holder, it.parent, it.slot, it.power_to, it.net_to, it.pinned, it.contains, it.coolant_to, it.worn])
	_r_door.rpc_id(peer, door_open)
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
func _h_attach(parent_id: int) -> void:
	if not multiplayer.is_server():
		return
	var it := held_by(Net.sender())
	var par: Item = items.get(parent_id)
	if it == null or par == null or not can_attach(it, par):
		return
	_cast(&"_r_attach", [it.id, parent_id, _free_slot(par)])


@rpc("any_peer", "call_remote", "reliable")
func _h_link(id: int, type: String, provider_id: int) -> void:
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
		if it.global_position.distance_to(target.global_position) > Catalog.MAX_CABLE:
			return
		if provider_id == id:   # allowed. It just doesn't do anything useful.
			_cast(&"_r_toast", ["%s plugged a %s into itself" % [name_of(Net.sender()), it.label.to_lower()]])
	_cast(&"_r_link", [id, type, provider_id])


@rpc("any_peer", "call_remote", "reliable")
func _h_buy(kind: String) -> void:
	if not multiplayer.is_server() or kind not in Catalog.SHOP:
		return
	var def: Dictionary = Catalog.ITEMS[kind]
	if _sim.money < def["price"]:
		return
	_sim.money -= def["price"]
	# dropped off as a parcel on the driveway, in the next free-ish slot of a 5 x 3 grid
	var slot := _deliveries % 15
	_deliveries += 1
	var height: float = Catalog.parcel(kind)["size"].y
	var pos := Vector3(-2.0 + (slot % 5) * 1.0, height * 0.5 + 0.15, 7.0 + (slot / 5) * 1.2)
	_spawn("parcel", Transform3D(Basis(), pos), kind)
	_cast(&"_r_toast", ["%s bought %s (-%s)" % [name_of(Net.sender()), def["label"], UI.money(def["price"])]])
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
	var lift: float = (Catalog.ITEMS[inside]["size"].y - box.def["size"].y) * 0.5 + 0.02
	var xf := Transform3D(Basis(Vector3.UP, box.global_rotation.y), box.global_position + Vector3(0, lift, 0))
	_cast(&"_r_despawn", [id])
	_spawn(inside, xf)
	if Catalog.ITEMS[inside].get("used", false) and randf() < doa_chance:
		items[_next_id - 1].dead = true
		_cast(&"_r_toast", ["The %s was dead on arrival. No refunds." % Catalog.ITEMS[inside]["label"].to_lower()])
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
	_cast(&"_r_link", [it.id, type, 0])


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
			if target == null or it.global_position.distance_to(target.global_position) > Catalog.MAX_CABLE:
				_cast(&"_r_toast", ["The %s of a %s got yanked out" % [LINKS[type], it.label.to_lower()]])
				_unplug(it, type, "Somebody")
	for puddle: Dictionary in puddles.duplicate():   # puddles dry up
		puddle["left"] -= dt
		if puddle["left"] <= 0.0:
			puddles.erase(puddle)
	_drop_unsupported()
	var events: Array = []
	var status := _sim.step(self, dt, events)
	for text: String in events:
		_cast(&"_r_toast", [text])
	var gens := {}   # everything with moving parts: generators, pumps, tanks, buckets, servers, hoses
	for it: Item in items.values():
		if it.def.has("gen") or it.def.has("pump") or it.def.has("tank") or it.kind == "bucket" \
				or it.def.get("group", "") == "server" or it.coolant_to != 0 or it.hose > 0.0:
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
func _r_attach(id: int, parent_id: int, slot: int) -> void:
	var it: Item = items.get(id)
	if it:
		it.holder = 0
		it.parent = parent_id
		it.slot = slot
		it.apply_mode()


@rpc("authority", "call_remote", "reliable")
func _r_link(id: int, type: String, provider_id: int) -> void:
	var it: Item = items.get(id)
	if it:
		it.set_link(type, provider_id)


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
