extends RefCounted
## Host-only simulation of power, network and money. Runs twice a second.
## Rule: nothing is ever forbidden when you build it — this is where the consequences happen.
##
## There is no electricity grid. All power comes from generators (catalog `gen`):
##   - plug a device (or a power strip) straight into a generator, or
##   - wire a building: a power INLET inside it, cabled to a generator, energises the building's
##     wiring; every wall SOCKET inside that building then delivers power.
## A building's wiring has a breaker with a limit. Its load is shared between the generators
## feeding it, in proportion to their size. Overloaded generators stall, which dumps their share
## onto the others on the next step.
## Root keys: a generator is its item id (> 0); building circuit c is -(c + 1).

const Catalog = preload("res://scripts/catalog.gd")
const OVERLOAD_STEPS := 3   # 1.5 s over the limit before something gives

var money := Catalog.START_MONEY
var tokens := 0.0       # tokens per second being produced
var watts := 0.0        # total load being served
var capacity := 0.0     # what the running generators could deliver right now
var profit := 0.0       # $ per second
var tripped: Dictionary = {}   # circuit id -> true while its breaker is off
var weather := 0        # index into Catalog.WEATHER
var weather_left := 150.0   # seconds until it changes

var _over: Dictionary = {}   # root key -> consecutive steps above its limit


func reset_breaker(circuit: int) -> void:
	tripped.erase(circuit)
	_over.erase(-(circuit + 1))


## Advances the simulation. Returns {item id: status bits}; appends messages for players to `events`.
func step(world: Node3D, dt: float, events: Array) -> Dictionary:
	var items: Dictionary = world.items
	weather_left -= dt
	if weather_left <= 0.0:
		var roll := randf()
		var next := 0 if roll < 0.5 else (1 if roll < 0.8 else 2)
		weather = next if next != weather else (weather + 1) % Catalog.WEATHER.size()
		weather_left = randf_range(90.0, 240.0)
		events.append(Catalog.WEATHER[weather]["news"])
	var sun: float = Catalog.WEATHER[weather]["solar"]

	# rain ruins electronics that are outdoors and not in a parcel (parcels are a different item kind)
	var raining: bool = Catalog.WEATHER[weather].get("rain", false)
	var ruined := {}
	for it: Node3D in items.values():
		if it.broken:
			ruined[it.id] = true
		elif it.def.get("fragile", false):
			if raining and world.is_outdoors(it.global_position):
				it.wet += dt
				if it.wet >= Catalog.RAIN_GRACE:
					ruined[it.id] = true
					events.append("A %s got rained on. It is ruined." % it.label.to_lower())
			else:
				it.wet = maxf(0.0, it.wet - dt)

	# generators: which are producing, and how much each can give
	var limit := {}
	for it: Node3D in items.values():
		if it.def.has("gen") and _generating(it, world):
			var gen: Dictionary = it.def["gen"]
			limit[it.id] = gen["watts"] * (sun if gen["kind"] == "solar" else 1.0)

	# buildings: which generators feed each one through its inlets
	var feeders := {}   # circuit id -> [generator ids]
	var feeding := {}   # inlet item id -> true
	for it: Node3D in items.values():
		if it.def.get("feeds", false) and it.holder == 0:
			var c: int = world.circuit_at(it.global_position)
			var g := _source(it, world, limit, false, ruined)
			if c >= 0 and g > 0:
				feeding[it.id] = true
				if not feeders.has(c):
					feeders[c] = []
				if g not in feeders[c]:
					feeders[c].append(g)

	# every device's root, and the load on each root
	var root := {}
	for it: Node3D in items.values():
		var wired: bool = it.def.get("power_port", false) and not it.def.get("feeds", false)
		root[it.id] = _source(it, world, limit, true, ruined) if wired and not ruined.has(it.id) else 0
	var loads := {}
	for it: Node3D in items.values():
		var r: int = root[it.id]
		if it.parent != 0 and it.def.get("group", "") == "gpu":
			r = 0 if ruined.has(it.id) else root.get(it.parent, 0)   # GPUs draw through the server they sit on
		if r != 0:
			loads[r] = loads.get(r, 0.0) + it.def.get("watts", 0.0)

	# building wiring: breakers, then hand the building's load to its generators
	var dead := {}
	var circuits: Dictionary = world.circuits()   # circuit id -> [limit in watts, where it is]
	for c: int in circuits:
		var key := -(c + 1)
		var on_wiring: float = loads.get(key, 0.0)
		if not tripped.has(c) and _overloaded(key, on_wiring, circuits[c][0], dt):
			tripped[c] = true
			events.append("Breaker tripped in %s! %d W on wiring rated for %d W" % [circuits[c][1], on_wiring, circuits[c][0]])
		var fed_by: Array = feeders.get(c, [])
		if tripped.has(c) or fed_by.is_empty():
			dead[key] = true
			continue
		var total := 0.0
		for g: int in fed_by:
			total += limit[g]
		for g: int in fed_by:
			loads[g] = loads.get(g, 0.0) + on_wiring * limit[g] / total

	# generators: overloaded ones stall, fuel burns
	capacity = 0.0
	for it: Node3D in items.values():
		if not it.def.has("gen"):
			continue
		var gen: Dictionary = it.def["gen"]
		var load: float = loads.get(it.id, 0.0)
		it.load = load
		if not limit.has(it.id):
			_over.erase(it.id)
			dead[it.id] = true
			continue
		if gen["kind"] == "solar":   # a panel just browns out for as long as it is overloaded
			if load > limit[it.id]:
				dead[it.id] = true
			else:
				capacity += limit[it.id]
			continue
		if _overloaded(it.id, load, limit[it.id], dt):
			dead[it.id] = true
			_over.erase(it.id)
			if gen["kind"] == "fuel":
				it.running = false
				events.append("The %s stalled: %d W on a %d W generator" % [it.label.to_lower(), load, gen["watts"]])
			else:
				events.append("%s could not keep up with %d W and fell off the bike" % [world.name_of(it.rider), load])
				it.rider = 0
			continue
		capacity += limit[it.id]
		if gen["kind"] == "fuel":
			it.fuel = maxf(0.0, it.fuel - dt / gen["burn"] * (0.25 + 0.75 * load / gen["watts"]))
			if it.fuel <= 0.0:
				it.running = false
				dead[it.id] = true
				events.append("The %s ran out of fuel" % it.label.to_lower())
	for c: int in feeders:   # a building whose generators all just died is dark too
		var alive := false
		for g: int in feeders[c]:
			alive = alive or not dead.has(g)
		if not alive:
			dead[-(c + 1)] = true

	var powered := {}
	watts = 0.0
	for id: int in root:
		powered[id] = root[id] != 0 and not dead.has(root[id])
	for it: Node3D in items.values():   # what is actually being served, counted once
		var r: int = root[it.id]
		if it.parent != 0 and it.def.get("group", "") == "gpu":
			r = 0 if ruined.has(it.id) else root.get(it.parent, 0)
		if r != 0 and not dead.has(r):
			watts += it.def.get("watts", 0.0)

	var status := {}
	var running := {}
	for it: Node3D in items.values():
		var bits := 0
		if it.def.has("gen"):
			bits = 0 if dead.has(it.id) else 3
		elif it.def.get("feeds", false):
			bits = 3 if feeding.has(it.id) else 0
		elif it.def.get("bus", false):
			var c: int = world.circuit_at(it.global_position)
			bits = 3 if c >= 0 and circuits.has(c) and not dead.has(-(c + 1)) else 0
		elif it.def.get("net_port", false):
			var online: bool = powered[it.id] and _reaches_net(it, world, powered)
			bits = int(powered[it.id]) | (int(online) << 1)
			running[it.id] = online
		elif powered[it.id]:
			bits = 3
		status[it.id] = bits

	tokens = 0.0
	for it: Node3D in items.values():
		var group: String = it.def.get("group", "")
		if group == "server" and running.get(it.id, false):
			tokens += it.def.get("tokens", 0.0)
		elif group == "gpu" and it.parent != 0 and running.get(it.parent, false) and not ruined.has(it.id):
			tokens += it.def.get("tokens", 0.0)
			status[it.id] = 3
	for id: int in ruined:
		status[id] = 4

	profit = tokens * Catalog.TOKEN_PRICE   # power is paid for in fuel, sweat or weather
	money += profit * dt
	return status


func _overloaded(key: int, load: float, max_load: float, dt: float) -> bool:
	if load <= max_load:
		_over.erase(key)
		return false
	if dt > 0.0:
		_over[key] = _over.get(key, 0) + 1
	return _over.get(key, 0) >= OVERLOAD_STEPS


func _generating(it: Node3D, world: Node3D) -> bool:
	match it.def["gen"]["kind"]:
		"pedal":
			return it.rider != 0
		"fuel":
			return it.running and it.fuel > 0.0
		"solar":
			return it.holder == 0 and world.is_outdoors(it.global_position) \
					and Catalog.WEATHER[weather]["solar"] > 0.0
	return false


## Follows a power cable chain from `it`. Returns a live generator's id, or (if `via_sockets`)
## the key of the building whose wall socket the chain ends in, or 0 for nothing.
## A chain that loops back on itself (strip plugged into itself...) never gets anywhere.
## Inlets pass via_sockets = false: a building cannot be fed from another building's socket.
func _source(it: Node3D, world: Node3D, limit: Dictionary, via_sockets: bool, ruined: Dictionary) -> int:
	var cur := it
	for hop in 16:
		var next: Node3D = world.items.get(cur.power_to) if cur.power_to > 0 else null
		if next == null or next.provides != "power" or ruined.has(next.id):
			return 0
		if next.def.has("gen"):
			return next.id if limit.has(next.id) else 0
		if next.def.get("bus", false):
			var c: int = world.circuit_at(next.global_position)
			return -(c + 1) if via_sockets and c >= 0 and next.holder == 0 else 0
		cur = next
	return 0


## Follows a network cable chain to an uplink fixture. Unpowered switches pass nothing on.
func _reaches_net(it: Node3D, world: Node3D, powered: Dictionary) -> bool:
	var cur := it
	for hop in 16:
		var to: int = cur.net_to
		if to == 0:
			return false
		if to < 0:
			var fixture: Node3D = world.fixtures.get(to)
			return fixture != null and fixture.provides == "net"
		var next: Node3D = world.items.get(to)
		if next == null or next.provides != "net" or next.broken or not powered.get(next.id, false):
			return false
		cur = next
	return false
