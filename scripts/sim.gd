extends RefCounted
## Host-only simulation of power, network, heat, fire and money. Runs twice a second.
## Rule: nothing is ever forbidden when you build it — this is where the consequences happen.
##
## POWER. There is no electricity grid. All power comes from generators (catalog `gen`):
##   - plug a device (or a power strip) straight into a generator, or
##   - wire a building: a power INLET inside it, cabled to a generator, energises the building's
##     wiring; every wall SOCKET inside that building then delivers power.
## A building's wiring has a breaker with a limit. Its load is shared between the generators
## feeding it, in proportion to their size. Overloaded generators stall, which dumps their share
## onto the others on the next step. Power strips carry only so much before they catch fire.
## Root keys: a generator is its item id (> 0); building circuit c is -(c + 1).
##
## HEAT. Every watt used inside a building heats it. Heat leaks out faster through an open door
## and with fans; an air conditioner removes it outright. Hot rooms throttle servers, hotter
## rooms shut them down, and past that things start to burn.

const Catalog = preload("res://scripts/catalog.gd")
const OVERLOAD_STEPS := 3    # 1.5 s over the limit before something gives
const LEAK := 120.0          # watts a closed building loses per degree above outside
const HEAT_TIME := 45.0      # seconds for a room to get most of the way to its new temperature
const THROTTLE_AT := 40.0    # servers at half speed
const SHUTDOWN_AT := 50.0    # servers switch themselves off...
const RESUME_AT := 42.0      # ...until it is this cool again
const FIRE_AT := 60.0        # something in the room may catch fire
const BURN_RUINS := 6.0      # seconds on fire before an item is ruined
const BURN_OUT := 22.0       # seconds until a fire dies down by itself
const SPREAD_RANGE := 1.3    # metres a fire can jump

var money := Catalog.START_MONEY
var tokens := 0.0       # tokens per second being produced
var watts := 0.0        # total load being served
var capacity := 0.0     # what the running generators could deliver right now
var profit := 0.0       # $ per second
var tripped: Dictionary = {}   # circuit id -> true while its breaker is off
var weather := 0        # index into Catalog.WEATHER
var weather_left := 150.0   # seconds until it changes
var temps: Dictionary = {}     # circuit id -> degrees C inside that building

var _over: Dictionary = {}     # root key or strip id -> consecutive steps above its limit
var _cooked: Dictionary = {}   # circuit id -> true while in thermal shutdown
var _warned: Dictionary = {}   # circuit id -> highest heat warning already announced


func reset_breaker(circuit: int) -> void:
	tripped.erase(circuit)
	_over.erase(-(circuit + 1))


func outside_temp() -> float:
	return Catalog.WEATHER[weather]["temp"]


func ignite(it: Node3D) -> void:
	if not it.burning:
		it.burning = true
		it.burn = 0.0


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
	var raining: bool = Catalog.WEATHER[weather].get("rain", false)

	# what is ruined: rained-on electronics, burnt things, used parts that never worked
	var ruined := {}
	for it: Node3D in items.values():
		var outdoors: bool = world.is_outdoors(it.global_position)
		if it.burning:
			it.burn += dt
			if it.burn >= BURN_OUT or (raining and outdoors):
				it.burning = false
			elif it.burn >= BURN_RUINS:
				it.dead = true
		if it.broken or it.dead:
			ruined[it.id] = true
		elif it.def.get("fragile", false):
			if raining and outdoors:
				it.wet += dt
				if it.wet >= Catalog.RAIN_GRACE:
					ruined[it.id] = true
					events.append("A %s got rained on. It is ruined." % it.label.to_lower())
			else:
				it.wet = maxf(0.0, it.wet - dt)
	_spread_fire(items, dt)

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
			var g := _source(it, world, limit, false, ruined, [])
			if c >= 0 and g > 0:
				feeding[it.id] = true
				if not feeders.has(c):
					feeders[c] = []
				if g not in feeders[c]:
					feeders[c].append(g)

	# every device's root, the strips its power runs through, and the load on each root and strip
	var root := {}
	var via := {}       # device id -> [power strip ids on the way to its root]
	for it: Node3D in items.values():
		var wired: bool = it.def.get("power_port", false) and not it.def.get("feeds", false)
		via[it.id] = []
		root[it.id] = _source(it, world, limit, true, ruined, via[it.id]) if wired and not ruined.has(it.id) else 0
	var loads := {}
	for it: Node3D in items.values():
		var feeder: int = _feeder(it, ruined)
		var r: int = root.get(feeder, 0)
		if r != 0:
			var draw: float = it.def.get("watts", 0.0)
			loads[r] = loads.get(r, 0.0) + draw
			for strip: int in via[feeder]:
				loads[strip] = loads.get(strip, 0.0) + draw

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

	# power strips: carry too much for too long and they catch fire
	for it: Node3D in items.values():
		var rated: float = it.def.get("max_watts", 0.0)
		if rated > 0.0 and not it.burning and _overloaded(it.id, loads.get(it.id, 0.0), rated, dt):
			_over.erase(it.id)
			ignite(it)
			events.append("A power strip carrying %d W (it is rated for %d W) caught fire!" % [loads[it.id], rated])

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

	# who has power, what is being served, and the heat it leaves in each building
	var powered := {}
	var heat := {}      # circuit id -> watts of heat
	var cooling := {}   # circuit id -> [extra leak in W per degree, watts removed outright]
	watts = 0.0
	for id: int in root:
		powered[id] = root[id] != 0 and not dead.has(root[id])
	for it: Node3D in items.values():
		var c: int = world.circuit_at(it.global_position)
		var draw: float = it.def.get("watts", 0.0) if powered.get(_feeder(it, ruined), false) else 0.0
		watts += draw
		if c < 0:
			continue
		var warmth := draw
		if it.burning:
			warmth += 1500.0
		if it.def.has("gen") and limit.has(it.id) and it.def["gen"]["kind"] == "fuel":
			warmth += it.def["gen"]["watts"] * 0.5   # an engine running indoors
		heat[c] = heat.get(c, 0.0) + warmth
		if draw > 0.0 and it.def.has("cool"):
			var cool: Dictionary = it.def["cool"]
			var sofar: Array = cooling.get(c, [0.0, 0.0])
			cooling[c] = [sofar[0] + cool.get("vent", 0.0), sofar[1] + cool.get("remove", 0.0)]
	_heat_step(world, circuits, heat, cooling, dt, events)

	var status := {}
	var running := {}
	var speed := {}     # server id -> share of full speed (heat throttling)
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
			var c: int = world.circuit_at(it.global_position)
			var hot: float = temps.get(c, 0.0)
			var online: bool = powered[it.id] and _reaches_net(it, world, powered)
			if it.def.get("group", "") == "server" and _cooked.has(c):
				online = false   # thermal shutdown: powered, but refusing to work
			bits = int(powered[it.id]) | (int(online) << 1)
			running[it.id] = online
			speed[it.id] = 0.5 if hot >= THROTTLE_AT else 1.0
		elif powered[it.id]:
			bits = 3
		status[it.id] = bits

	tokens = 0.0
	for it: Node3D in items.values():
		var group: String = it.def.get("group", "")
		if group == "server" and running.get(it.id, false):
			tokens += it.def.get("tokens", 0.0) * speed[it.id]
		elif group == "gpu" and it.parent != 0 and running.get(it.parent, false) and not ruined.has(it.id):
			tokens += it.def.get("tokens", 0.0) * speed[it.parent]
			status[it.id] = 3
	for id: int in ruined:
		status[id] = 4
	for it: Node3D in items.values():
		if it.burning:
			status[it.id] = status.get(it.id, 0) | 8

	profit = tokens * Catalog.TOKEN_PRICE   # power is paid for in fuel, sweat or weather
	money += profit * dt
	return status


## Moves every building's temperature towards where its heat and cooling would settle,
## and reacts to rooms that got too hot.
func _heat_step(world: Node3D, circuits: Dictionary, heat: Dictionary, cooling: Dictionary,
		dt: float, events: Array) -> void:
	var outside := outside_temp()
	for c: int in circuits:
		var cool: Array = cooling.get(c, [0.0, 0.0])
		var leak: float = LEAK * world.vent_factor(c) + cool[0]
		var target: float = maxf(outside + (heat.get(c, 0.0) - cool[1]) / leak, outside - 6.0)
		var now: float = temps.get(c, outside)
		now += (target - now) * (1.0 - exp(-dt / HEAT_TIME))
		temps[c] = now
		var where: String = circuits[c][1]
		if now >= SHUTDOWN_AT:
			_cooked[c] = true
		elif now < RESUME_AT:
			_cooked.erase(c)
		var level := 3 if now >= FIRE_AT else (2 if now >= SHUTDOWN_AT else (1 if now >= THROTTLE_AT else 0))
		if level > _warned.get(c, 0):
			events.append([
				"It is %d °C in %s. Servers are running at half speed." % [now, where],
				"It is %d °C in %s. Servers have shut themselves down." % [now, where],
				"It is %d °C in %s. Things are about to catch fire." % [now, where]][level - 1])
		if level < _warned.get(c, 0) and now < RESUME_AT - 2.0 or level > _warned.get(c, 0):
			_warned[c] = level
		if now >= FIRE_AT and dt > 0.0 and randf() < 0.2:   # the hottest thing in there goes up
			var fuel: Array = []
			for it: Node3D in world.items.values():
				if it.def.get("fragile", false) and not it.burning and world.circuit_at(it.global_position) == c:
					fuel.append(it)
			if not fuel.is_empty():
				var victim: Node3D = fuel[randi() % fuel.size()]
				ignite(victim)
				events.append("A %s in %s caught fire!" % [victim.label.to_lower(), where])


## Fire jumps to anything flammable close by.
func _spread_fire(items: Dictionary, dt: float) -> void:
	if dt <= 0.0:
		return
	var burning: Array = []
	for it: Node3D in items.values():
		if it.burning and it.burn > 2.0:
			burning.append(it)
	for fire: Node3D in burning:
		for it: Node3D in items.values():
			if not it.burning and it.burn == 0.0 and (it.def.get("fragile", false) or it.def.get("flammable", false)) \
					and it.global_position.distance_to(fire.global_position) < SPREAD_RANGE and randf() < 0.1:
				ignite(it)


## The item whose power cable decides whether `it` draws anything: itself, or for a GPU the
## server it is mounted on. Returns 0 if it is ruined.
func _feeder(it: Node3D, ruined: Dictionary) -> int:
	if ruined.has(it.id):
		return 0
	if it.parent != 0 and it.def.get("group", "") == "gpu":
		return 0 if ruined.has(it.parent) else it.parent
	return it.id


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
## `path` collects the power strips passed on the way.
## A chain that loops back on itself (strip plugged into itself...) never gets anywhere.
## Inlets pass via_sockets = false: a building cannot be fed from another building's socket.
func _source(it: Node3D, world: Node3D, limit: Dictionary, via_sockets: bool, ruined: Dictionary, path: Array) -> int:
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
		path.append(next.id)
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
