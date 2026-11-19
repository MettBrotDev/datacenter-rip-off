extends RefCounted
## Host-only simulation of power, network, heat, cooling, fire and money. Runs twice a second.
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
## HEAT. Temperatures are meant to be believable. Every watt used inside a building warms its
## air; doors, fans and air conditioners cool it. A busy air-cooled chip sits about 48 degrees
## above the room, throttles at 85 and shuts down at 100. Consumer cards are fine in any
## sensible room. Datacenter cards (`liquid`) have no fans: their server needs coolant.
##
## COOLANT. Hoses form a chain like cables: server -> manifold -> pump -> reservoir (-> tap).
## A loop flows while its pump is on, powered and has water. Radiators on the loop shed the
## heat into the air around them, so they belong outdoors. Hoses fill up when water flows and
## stay full until the pump drains them.

const Catalog = preload("res://scripts/catalog.gd")
const OVERLOAD_STEPS := 3      # 1.5 s over the limit before something gives
const LEAK := 120.0            # watts a closed building loses per degree above outside
const ROOM_TIME := 45.0        # seconds for a room to get most of the way to a new temperature
const CHIP_TIME := 12.0        # ...and for a chip
const COOLANT_TIME := 30.0     # ...and for the coolant in a loop
const CHIP_RISE_IDLE := 12.0   # degrees a chip sits above the room when doing nothing
const CHIP_RISE_CPU := 30.0    # ...a busy server with no GPUs
const CHIP_RISE_AIR := 48.0    # ...a busy server with air-cooled GPUs
const CHIP_RISE_LIQUID := 25.0 # degrees a liquid-cooled chip sits above its coolant
const CHIP_RISE_DRY := 110.0   # a fanless card with no coolant moving: far too much
const CHIP_THROTTLE := 85.0    # half speed
const CHIP_SHUTDOWN := 100.0   # switches itself off...
const CHIP_RESUME := 80.0      # ...until it is this cool again
const CHIP_IGNITE := 110.0     # hardware whose protection is broken keeps going, then burns
const EVAPORATION := 0.0011    # share of a reservoir lost per second while its loop runs
const BURN_RUINS := 6.0        # seconds on fire before an item is ruined
const BURN_OUT := 22.0         # seconds until a fire dies down by itself
const SPREAD_RANGE := 1.3      # metres a fire can jump

var money := Catalog.START_MONEY
var tokens := 0.0       # tokens per second being produced
var watts := 0.0        # total load being served
var capacity := 0.0     # what the running generators could deliver right now
var profit := 0.0       # $ per second, set by the world from what the company earns
var tripped: Dictionary = {}   # circuit id -> true while its breaker is off
var weather := 0        # index into Catalog.WEATHER
var weather_left := 150.0   # seconds until it changes
var temps: Dictionary = {}     # circuit id -> degrees C of the air inside that building
var wiring: Dictionary = {}    # circuit id -> watts currently drawn through that building's wiring

var _over: Dictionary = {}     # root key or strip id -> consecutive steps above its limit
var _said: Dictionary = {}     # message key -> clock time it was last announced
var _clock := 0.0


func reset_breaker(circuit: int) -> void:
	tripped.erase(circuit)
	_over.erase(-(circuit + 1))


func outside_temp() -> float:
	return Catalog.WEATHER[weather]["temp"]


func ignite(it: Node3D) -> void:
	if not it.burning:
		it.burning = true
		it.burn = 0.0


## The pump pressurising this item's coolant hose, or null. A pump or reservoir answers for itself.
func pump_for(it: Node3D, world: Node3D) -> Node3D:
	if it.def.has("pump"):
		return it
	if it.def.has("tank"):
		for other: Node3D in world.items.values():
			if other.def.has("pump") and other.coolant_to == it.id:
				return other
		return null
	return world.items.get(pump_id(it, world.items))


## Advances the simulation. Returns {item id: status bits}; appends messages for players to `events`.
func step(world: Node3D, dt: float, events: Array) -> Dictionary:
	var items: Dictionary = world.items
	_clock += dt
	weather_left -= dt
	if weather_left <= 0.0:
		var roll := randf()
		var next := 0 if roll < 0.5 else (1 if roll < 0.8 else 2)
		weather = next if next != weather else (weather + 1) % Catalog.WEATHER.size()
		weather_left = randf_range(90.0, 240.0)
		events.append(Catalog.WEATHER[weather]["news"])
	var sun: float = Catalog.WEATHER[weather]["solar"]
	var raining: bool = Catalog.WEATHER[weather].get("rain", false)

	# what is ruined: wet electronics (rain, puddles), burnt things, used parts that never worked
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
			var soaking: float = (1.0 if raining and outdoors else 0.0) + (3.0 if world.in_puddle(it) else 0.0)
			if soaking > 0.0:
				it.wet += dt * soaking
				if it.wet >= Catalog.RAIN_GRACE:
					ruined[it.id] = true
					events.append("A %s got soaked. It is ruined." % it.label.to_lower())
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
		wiring[c] = on_wiring
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
	var powered := {}
	for id: int in root:
		powered[id] = root[id] != 0 and not dead.has(root[id])

	# coolant loops: which pump everything hangs off, and whether water is moving
	var pump_of := {}   # item id -> pump item id (0 = not on a loop)
	var flowing := {}   # pump id -> true
	var gpus := {}      # server id -> [GPUs mounted on it that still work]
	for it: Node3D in items.values():
		if it.def.get("coolant_port", false) and not it.def.has("pump") and not it.def.has("tank"):
			pump_of[it.id] = pump_id(it, world.items)
		if it.parent != 0 and it.def.get("group", "") == "gpu" and not ruined.has(it.id):
			if not gpus.has(it.parent):
				gpus[it.parent] = []
			gpus[it.parent].append(it)
	for pump: Node3D in items.values():
		if pump.def.has("pump"):
			var tank := _tank(pump, world)
			var water: bool = pump.coolant_to < 0 or (tank != null and tank.fuel > 0.0)
			flowing[pump.id] = pump.running and powered[pump.id] and water and not ruined.has(pump.id)

	# what is being served, and where its heat goes: into a coolant loop or into the room
	var heat := {}      # circuit id -> watts of heat into that building's air
	var cooling := {}   # circuit id -> [extra leak in W per degree, watts removed outright]
	var into := {}      # pump id -> watts of heat into its coolant
	watts = 0.0
	for it: Node3D in items.values():
		var c: int = world.circuit_at(it.global_position)
		var draw: float = it.def.get("watts", 0.0) if powered.get(_feeder(it, ruined), false) else 0.0
		watts += draw
		var p: int = pump_of.get(it.parent, 0)
		if draw > 0.0 and it.def.get("liquid", false) and flowing.get(p, false):
			into[p] = into.get(p, 0.0) + draw
			continue
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
	_coolant_step(world, pump_of, flowing, into, heat, dt, events)
	_room_step(world, circuits, heat, cooling, dt, events)
	_chip_step(world, powered, ruined, pump_of, flowing, gpus, dt, events)

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
		elif it.def.has("pump"):
			bits = 3 if flowing[it.id] else int(powered[it.id])
		elif it.def.get("net_port", false):
			var online: bool = powered[it.id] and not it.cooked and _reaches_net(it, world, powered)
			bits = int(powered[it.id]) | (int(online) << 1)
			running[it.id] = online
		elif powered[it.id]:
			bits = 3
		status[it.id] = bits

	tokens = 0.0
	for it: Node3D in items.values():
		if it.def.get("group", "") == "server" and running.get(it.id, false):
			var speed := 0.5 if it.heat >= CHIP_THROTTLE else 1.0
			tokens += it.def.get("tokens", 0.0) * speed
			for gpu: Node3D in gpus.get(it.id, []):
				tokens += gpu.def.get("tokens", 0.0) * speed
				status[gpu.id] = 3
	for id: int in ruined:
		status[id] = 4
	for it: Node3D in items.values():
		if it.burning:
			status[it.id] = status.get(it.id, 0) | 8

	return status   # tokens are not money: what they turn into is the company's business (company.gd)


## Each loop's coolant warms with the heat going into it and cools through its radiators.
## Also fills and drains hoses and uses up the reservoir.
func _coolant_step(world: Node3D, pump_of: Dictionary, flowing: Dictionary, into: Dictionary,
		heat: Dictionary, dt: float, events: Array) -> void:
	var outside := outside_temp()
	var weather_boost: float = Catalog.WEATHER[weather]["cooling"]
	for pump: Node3D in world.items.values():
		if not pump.def.has("pump"):
			continue
		if pump.heat == 0.0:
			pump.heat = outside
		pump.load = into.get(pump.id, 0.0) if flowing[pump.id] else 0.0   # heat it is carrying, for sensors
		var tank := _tank(pump, world)
		if tank != null and tank.coolant_to < 0:
			tank.fuel = 1.0      # plumbed to the tap: tops itself up
			tank.hose = 1.0      # and that hose is always under mains pressure
		var members: Array = []
		for it: Node3D in world.items.values():
			if pump_of.get(it.id, 0) == pump.id:
				members.append(it)
		if flowing[pump.id]:
			var shed := 0.0        # watts per degree all radiators manage together
			var air := 0.0         # the air they shed into, weighted
			var indoors := []      # [circuit id, watts per degree, air temperature there]
			for it: Node3D in members:
				if it.def.has("radiator"):
					var c: int = world.circuit_at(it.global_position)
					var inside: bool = c >= 0 and not world.is_outdoors(it.global_position)
					var per_degree: float = it.def["radiator"] * (1.0 if inside else weather_boost)
					var around: float = temps.get(c, outside) if inside else outside
					shed += per_degree
					air += per_degree * around
					if inside:
						indoors.append([c, per_degree, around])
			var target: float = (air + into.get(pump.id, 0.0)) / shed if shed > 0.0 else 160.0
			pump.heat += (target - pump.heat) * (1.0 - exp(-dt / COOLANT_TIME))
			for entry: Array in indoors:   # a radiator indoors just heats the room it is in
				heat[entry[0]] = heat.get(entry[0], 0.0) + maxf(0.0, entry[1] * (pump.heat - entry[2]))
			var boiling: bool = pump.heat >= 100.0
			if tank != null and tank.coolant_to >= 0:
				tank.fuel = maxf(0.0, tank.fuel - EVAPORATION * dt * (8.0 if boiling else 1.0))
				if tank.fuel <= 0.0:
					_say(events, "dry%d" % pump.id, "A coolant reservoir has run dry. The pump is moving nothing.")
			if boiling:
				_say(events, "boil%d" % pump.id, "The coolant is boiling: that loop has no working radiator.")
			pump.draining = false
		else:
			pump.heat += (outside - pump.heat) * (1.0 - exp(-dt / 120.0))
		# hoses fill while water moves, empty while the pump drains them, otherwise stay as they are
		var hoses: Array = members.duplicate()
		hoses.append(pump)
		var emptied := true
		for it: Node3D in hoses:
			if it.coolant_to == 0:
				it.hose = 0.0
			elif flowing[pump.id]:
				it.hose = minf(1.0, it.hose + dt * 0.5)
			elif pump.draining:
				it.hose = maxf(0.0, it.hose - dt * 0.5)
			emptied = emptied and it.hose <= 0.0
		if pump.draining and emptied and dt > 0.0:
			pump.draining = false
			events.append("The hoses on that coolant loop are empty. Safe to unplug.")


## Moves every building's air temperature towards where its heat and cooling would settle.
func _room_step(world: Node3D, circuits: Dictionary, heat: Dictionary, cooling: Dictionary,
		dt: float, events: Array) -> void:
	var outside := outside_temp()
	for c: int in circuits:
		var cool: Array = cooling.get(c, [0.0, 0.0])
		var leak: float = LEAK * world.vent_factor(c) + cool[0]
		var target: float = maxf(outside + (heat.get(c, 0.0) - cool[1]) / leak, outside - 6.0)
		var now: float = temps.get(c, outside)
		now += (target - now) * (1.0 - exp(-dt / ROOM_TIME))
		temps[c] = now
		if now >= 55.0:
			_say(events, "room%d" % c, "It is %d °C in %s. Nobody should stay in there for long." % [now, circuits[c][1]])


## Chip temperature of every server, and what it does about it.
func _chip_step(world: Node3D, powered: Dictionary, ruined: Dictionary, pump_of: Dictionary,
		flowing: Dictionary, gpus: Dictionary, dt: float, events: Array) -> void:
	var outside := outside_temp()
	for it: Node3D in world.items.values():
		if it.def.get("group", "") != "server":
			continue
		var c: int = world.circuit_at(it.global_position)
		var room: float = temps.get(c, outside) if c >= 0 and not world.is_outdoors(it.global_position) else outside
		if it.heat == 0.0:
			it.heat = room
		var target := room
		if powered[it.id] and not ruined.has(it.id):
			target = room + CHIP_RISE_IDLE
			if not it.cooked:
				var cards: Array = gpus.get(it.id, [])
				var fanless := false
				for gpu: Node3D in cards:
					fanless = fanless or gpu.def.get("liquid", false)
				var p: int = pump_of.get(it.id, 0)
				if fanless and flowing.get(p, false):
					target = world.items[p].heat + CHIP_RISE_LIQUID
				elif fanless:
					target = room + CHIP_RISE_DRY
				else:
					target = room + (CHIP_RISE_CPU if cards.is_empty() else CHIP_RISE_AIR)
		it.heat += (target - it.heat) * (1.0 - exp(-dt / CHIP_TIME))
		if it.heat >= CHIP_IGNITE and it.sketchy and not it.burning and not ruined.has(it.id):
			ignite(it)
			events.append("A used server hit %d °C, ignored it, and caught fire!" % it.heat)
		elif it.heat >= CHIP_SHUTDOWN and not it.sketchy and not it.cooked:
			it.cooked = true
			_say(events, "hot%d" % it.id, "A server hit %d °C and shut itself down." % it.heat)
		elif it.heat < CHIP_RESUME:
			it.cooked = false


## Announces something at most once a minute per key.
func _say(events: Array, key: String, text: String) -> void:
	if _clock - _said.get(key, -1000.0) >= 60.0:
		_said[key] = _clock
		events.append(text)


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


## Follows a coolant hose chain through manifolds to the pump at the end. 0 if there is none.
## Static so that clients (which have no simulation) can ask the same question.
static func pump_id(it: Node3D, items: Dictionary) -> int:
	var cur := it
	for hop in 16:
		var next: Node3D = items.get(cur.coolant_to) if cur.coolant_to > 0 else null
		if next == null or next.provides != "coolant" or next.def.has("tank"):
			return 0
		if next.def.has("pump"):
			return next.id
		cur = next
	return 0


## What a power cable ends in, without judging whether it is live: a generator's item id,
## -(circuit + 1) for a building's wall socket, or 0. Static, for sensors on any peer.
static func power_end(it: Node3D, items: Dictionary, world: Node3D) -> int:
	var cur := it
	for hop in 16:
		var next: Node3D = items.get(cur.power_to) if cur.power_to > 0 else null
		if next == null or next.provides != "power":
			return 0
		if next.def.has("gen"):
			return next.id
		if next.def.get("bus", false):
			return -(world.circuit_at(next.global_position) + 1)
		cur = next
	return 0


## The reservoir a pump draws from, or null (no hose, or plugged straight into a tap).
func _tank(pump: Node3D, world: Node3D) -> Node3D:
	var tank: Node3D = world.items.get(pump.coolant_to) if pump.coolant_to > 0 else null
	return tank if tank != null and tank.def.has("tank") else null


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
