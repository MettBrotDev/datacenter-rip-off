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
# --- rooms: see room_loss() and _room_step() ---
const AIR_HEAT := 1206.0       # joules to warm one cubic metre of air by one degree
const ROOM_MASS := 0.25        # share of that the game uses: rooms react four times faster than real air would
const ROOM_ACH := 0.5          # air changes per hour through the cracks of a closed building
const DOOR_FLOW := 0.2         # discharge coefficient / 3 of an open doorway (warm air out at the top, cool in below)
const PAD_LOSS := 6000.0       # watts per degree of a pad with no walls: it is simply outdoors
const ROOM_FLOOR := 16.0       # air conditioners do not cool a room below this
const TAP_TEMP := 14.0         # water from the garden tap
const TAP_COST := 6.0           # dollars a minute for the water such a loop runs down the drain
const TAP_FLOW := 120.0        # watts per degree a loop fed from the tap gets rid of with the water it wastes
const CHIP_TIME := 12.0        # ...and for a chip
const COOLANT_TIME := 30.0     # ...and for the coolant in a loop
# --- chips: see _chip_step() ---
const CASE_SINK := 2.5         # watts per degree a chassis' own fans carry off before any part's cooler helps
const DUST_CHOKE := 0.45       # share of its airflow a machine choked with dust has lost
const CHIP_RISE_LIQUID := 25.0 # degrees a liquid-cooled chip sits above its coolant
const CHIP_RISE_DRY := 110.0   # a fanless card with no coolant moving: far too much
const CHIP_THROTTLE := 85.0    # half speed
const CHIP_SHUTDOWN := 100.0   # switches itself off...
const CHIP_RESUME := 80.0      # ...until it is this cool again
const DUST_OPEN := 1.0 / 720.0     # dust per second in a running machine with no lid on: full in 12 minutes
const DUST_CLOSED := 1.0 / 7200.0  # ...with its lid on: full in two hours
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
var taps := 0           # coolant loops running on tap water right now: each one is on the water bill

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
	# machines: what is screwed into each one, and whether that combination boots at all
	var inside := {}    # machine id -> [parts mounted in it]
	for it: Node3D in items.values():
		var host: Node3D = items.get(it.parent)
		if host != null and host.def.has("psu"):
			if not inside.has(host.id):
				inside[host.id] = []
			inside[host.id].append(it)
	var reports := {}   # machine id -> machine_report()
	for it: Node3D in items.values():
		if it.def.has("psu"):
			reports[it.id] = machine_report(it, inside.get(it.id, []), ruined)
	var loads := {}
	for it: Node3D in items.values():
		var feeder: int = _feeder(it, ruined)
		var r: int = root.get(feeder, 0)
		if r != 0:
			var draw := _draw(it, reports)
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
	var gpus := {}      # machine id -> [GPUs in it that are actually working]
	for it: Node3D in items.values():
		if it.def.get("coolant_port", false) and not it.def.has("pump") and not it.def.has("tank"):
			pump_of[it.id] = pump_id(it, world.items)
		if reports.has(it.id):
			gpus[it.id] = reports[it.id]["cards"]
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
		var draw: float = _draw(it, reports) if powered.get(_feeder(it, ruined), false) else 0.0
		watts += draw
		var p: int = pump_of.get(it.parent, 0)
		if draw > 0.0 and it.def.get("liquid", false) and flowing.get(p, false):
			into[p] = into.get(p, 0.0) + draw
			continue
		if c < 0:
			continue
		var warmth := draw
		if reports.has(it.id):
			warmth = it.shed      # a machine warms the room by what its fans actually blow out (see _chip_step)
		elif reports.has(it.parent):
			warmth = 0.0          # a part inside one: counted in the machine's figure
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
	_chip_step(world, powered, ruined, pump_of, flowing, reports, dt, events)

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
			var boots: bool = reports.get(it.id, {"boots": true})["boots"]   # a switch always "boots"
			var online: bool = powered[it.id] and boots and not it.cooked and _reaches_net(it, world, powered)
			bits = int(powered[it.id]) | (int(online) << 1)
			running[it.id] = online
		elif powered[it.id]:
			bits = 3
		status[it.id] = bits

	tokens = 0.0
	for it: Node3D in items.values():
		if not reports.has(it.id):
			continue
		var report: Dictionary = reports[it.id]
		var working: bool = running.get(it.id, false)
		if working:
			tokens += report["tokens"] * (0.5 if it.heat >= CHIP_THROTTLE else 1.0)
		for part: Node3D in inside.get(it.id, []):   # lit when doing something, orange when just sitting there
			status[part.id] = 3 if working and report["running"].has(part.id) else int(powered[it.id])
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
	taps = 0
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
			if tank != null and tank.coolant_to < 0:   # fed from the tap: cold water in, warm water down the drain
				shed += TAP_FLOW
				taps += 1
				air += TAP_FLOW * TAP_TEMP
			var target: float = (air + into.get(pump.id, 0.0)) / shed if shed > 0.0 else 160.0
			pump.heat += (target - pump.heat) * (1.0 - exp(-dt / COOLANT_TIME))
			# A radiator indoors trades heat with its room in whichever direction the temperatures say:
			# hot coolant warms the room, coolant that was cooled outdoors (or comes from the tap) cools it.
			for entry: Array in indoors:
				heat[entry[0]] = heat.get(entry[0], 0.0) + entry[1] * (pump.heat - entry[2])
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


## Watts a building loses for every degree its air is above the outside air, when it is `above` degrees warmer.
##   walls and roof:   u * area
##   cracks:           AIR_HEAT * volume * ROOM_ACH / 3600
##   an open doorway:  AIR_HEAT * DOOR_FLOW * door * sqrt(9.81 * door_h * above / 300)
##                     (warm air leaves at the top of the opening and cool air comes in below; the bigger
##                     the difference, the faster it goes, so an open door matters most when it is needed)
##   fans in the room: `vent` watts per degree on top
static func room_loss(shape: Dictionary, above: float, vent := 0.0) -> float:
	if shape["open"]:
		return PAD_LOSS
	var loss: float = shape["u"] * shape["area"] + AIR_HEAT * shape["volume"] * ROOM_ACH / 3600.0 + vent
	if shape["door"] > 0.0:
		loss += AIR_HEAT * DOOR_FLOW * shape["door"] * sqrt(9.81 * shape["door_h"] * maxf(absf(above), 1.0) / 300.0)
	return loss


## Degrees above outside a building settles at with `watts` of heat going into it.
static func room_settles(shape: Dictionary, watts: float, vent := 0.0) -> float:
	var above := 5.0
	for i in 30:
		above = watts / room_loss(shape, above, vent)
	return above


## Every building's air:  heat capacity * dT/dt = heat in - heat taken out - room_loss * (T - outside)
## where heat capacity = AIR_HEAT * volume * ROOM_MASS. Bigger rooms warm more slowly and lose more.
func _room_step(world: Node3D, circuits: Dictionary, heat: Dictionary, cooling: Dictionary,
		dt: float, events: Array) -> void:
	var outside := outside_temp()
	for c: int in circuits:
		var cool: Array = cooling.get(c, [0.0, 0.0])
		var shape: Dictionary = world.room(c)
		var now: float = temps.get(c, outside)
		var loss := room_loss(shape, now - outside, cool[0])
		var target: float = maxf(outside + (heat.get(c, 0.0) - cool[1]) / loss, minf(outside, ROOM_FLOOR))
		var mass: float = AIR_HEAT * shape["volume"] * ROOM_MASS
		now += (target - now) * (1.0 - exp(-dt * loss / mass))
		temps[c] = now
		if now >= 55.0:
			_say(events, "room%d" % c, "It is %d °C in %s. Nobody should stay in there for long." % [now, circuits[c][1]])


## Chip temperature of every server, and what it does about it.
func _chip_step(world: Node3D, powered: Dictionary, ruined: Dictionary, pump_of: Dictionary,
		flowing: Dictionary, reports: Dictionary, dt: float, events: Array) -> void:
	var outside := outside_temp()
	var filtered := {}   # circuit id -> true where a running air purifier keeps the dust out of the air
	var parts_of := {}   # machine id -> the parts in it
	for it: Node3D in world.items.values():
		if it.parent != 0 and reports.has(it.parent):
			if not parts_of.has(it.parent):
				parts_of[it.parent] = []
			parts_of[it.parent].append(it)
	for it: Node3D in world.items.values():
		if it.def.get("purifier", false) and powered.get(it.id, false) and not ruined.has(it.id) and not world.is_outdoors(it.global_position):
			filtered[world.circuit_at(it.global_position)] = true
	for it: Node3D in world.items.values():
		if not reports.has(it.id):
			continue
		var c: int = world.circuit_at(it.global_position)
		var room: float = temps.get(c, outside) if c >= 0 and not world.is_outdoors(it.global_position) else outside
		if it.heat == 0.0:
			it.heat = room
		# A machine makes `making` watts of heat. Its coolers move  sink * (chip - air)  watts into the air:
		#   sink = (CASE_SINK + airflow * sum of its parts' own coolers) * (1 - DUST_CHOKE * dust)
		# so it settles where both are equal, at  air + making / sink:  the warmer the air, the hotter the chip.
		# Liquid cards give their heat to the coolant instead, and sit CHIP_RISE_LIQUID above it.
		var target := room
		var making := 0.0
		var sink := CASE_SINK
		if powered[it.id] and not ruined.has(it.id) and reports[it.id]["boots"]:
			making = it.def.get("watts", 0.0)
			var p: int = pump_of.get(it.id, 0)
			var flow: bool = flowing.get(p, false)
			var wet := false
			var dry := false
			if not it.cooked:
				for part: Node3D in parts_of.get(it.id, []):
					if part.broken or ruined.has(part.id):
						continue
					if part.def.get("liquid", false):
						wet = wet or flow
						dry = dry or not flow
						if flow:
							continue   # that heat leaves through the hose
					making += part.def.get("watts", 0.0)
					sink += part.def.get("sink", 0.0) * float(it.def.get("airflow", 1.0))
				# Fans pull dust in, much faster with the lid off; a purifier in the building stops it.
				if not (filtered.has(c) and not world.is_outdoors(it.global_position)):
					var lidless: bool = it.opened or not it.def.get("lid", false)
					it.dust = minf(1.0, it.dust + (DUST_OPEN if lidless else DUST_CLOSED) * dt)
			sink *= 1.0 - DUST_CHOKE * it.dust
			target = room + making / sink
			if wet:
				target = maxf(target, world.items[p].heat + CHIP_RISE_LIQUID)
			if dry:
				target = maxf(target, room + CHIP_RISE_DRY)   # a fanless card with nothing flowing through it
		it.heat += (target - it.heat) * (1.0 - exp(-dt / CHIP_TIME))
		it.shed = clampf(sink * (it.heat - room), 0.0, making * 1.2) if making > 0.0 else 0.0
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


## What a machine with these parts screwed into it does. Static, so that any peer can explain a
## machine to its player. `ruined` = ids known to be dead that may not be flagged on the item yet.
## Returns {boots, why, tokens, watts, ram, ram_used, cards (working GPUs), running {part id: true},
## notes [what is wrong with individual parts]}.
static func machine_report(machine: Node3D, parts: Array, ruined: Dictionary = {}) -> Dictionary:
	var def: Dictionary = machine.def
	var cpus: Array = []
	var gpus: Array = []
	var sticks: Array = []
	var ram := 0.0
	var watts: float = def.get("watts", 0.0)
	for part: Node3D in parts:
		if part.broken or ruined.has(part.id):
			continue
		watts += part.def.get("watts", 0.0)
		match part.def.get("group", ""):
			"cpu":
				cpus.append(part)
			"gpu":
				gpus.append(part)
			"ram":
				sticks.append(part)
				ram += part.def["gb"]
	var out := {"boots": true, "why": "", "tokens": 0.0, "watts": watts, "ram": ram, "ram_used": 0.0,
		"cards": [], "running": {}, "notes": []}
	if cpus.is_empty():
		out["boots"] = false
		out["why"] = "No CPU in it"
	elif sticks.is_empty():
		out["boots"] = false
		out["why"] = "No RAM in it"
	elif watts > def["psu"]:
		out["boots"] = false
		out["why"] = "Its power supply gives %d W; the parts in it want %d W" % [def["psu"], watts]
	if not out["boots"]:
		out["watts"] = def.get("watts", 0.0)
		return out
	var best := 0
	for cpu: Node3D in cpus:
		best = maxi(best, cpu.def["tier"])
		out["tokens"] += cpu.def["tokens"]
		out["running"][cpu.id] = true
	for stick: Node3D in sticks:
		out["running"][stick.id] = true
	gpus.sort_custom(func(a: Node3D, b: Node3D) -> bool: return a.slot < b.slot)
	for gpu: Node3D in gpus:
		var need: float = gpu.def["needs_ram"]
		if need > ram - out["ram_used"]:
			out["notes"].append("%s is idle: it needs %d GB of RAM, %d GB are free" % [gpu.label, need, ram - out["ram_used"]])
			continue
		out["ram_used"] += need
		var held_back: bool = best < gpu.def["tier"] - 1
		if held_back:
			out["notes"].append("%s runs at half speed: the CPU cannot keep up with it" % gpu.label)
		out["tokens"] += gpu.def["tokens"] * (0.5 if held_back else 1.0) * float(Catalog.RAM_SPEED.get(def.get("ram", ""), 1.0))
		out["cards"].append(gpu)
		out["running"][gpu.id] = true
	return out


## Watts an item draws when it has power: parts inside a machine that does not boot draw nothing.
func _draw(it: Node3D, reports: Dictionary) -> float:
	if reports.has(it.parent) and not reports[it.parent]["boots"]:
		return 0.0
	return it.def.get("watts", 0.0)


## The item whose power cable decides whether `it` draws anything: itself, or for a part inside
## a machine, that machine. Returns 0 if it is ruined.
func _feeder(it: Node3D, ruined: Dictionary) -> int:
	if ruined.has(it.id):
		return 0
	if it.parent != 0 and it.def.get("group", "") in ["cpu", "ram", "gpu"]:
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
