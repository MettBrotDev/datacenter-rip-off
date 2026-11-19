extends RefCounted
## Host-only simulation of power, network and money. Runs twice a second.
## Rule: nothing is ever forbidden when you build it — this is where the consequences happen.
##
## Power comes from "roots": a building's wall circuit (one breaker each) or any generator.
## Every device follows its cable chain to exactly one root; each root has its own limit.
## Root keys: generators use their item id (> 0), circuit c uses -(c + 1).

const Catalog = preload("res://scripts/catalog.gd")
const OVERLOAD_STEPS := 3   # 1.5 s over the limit before something gives

var money := Catalog.START_MONEY
var tokens := 0.0       # tokens per second being produced
var watts := 0.0        # total load being served
var capacity := 0.0     # total power currently available (grid + running generators)
var profit := 0.0       # $ per second
var tripped: Dictionary = {}   # circuit id -> true while its breaker is off
var weather := 0       # index into Catalog.WEATHER
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

	# which generators are producing right now
	var live := {}
	for it: Node3D in items.values():
		if it.def.has("gen"):
			live[it.id] = _generating(it, world)

	# every device's power root: 0 none, GRID, or a generator's item id
	var root := {}
	for it: Node3D in items.values():
		root[it.id] = _power_root(it, world, live) if it.def.get("power_port", false) else 0
	var loads := {}
	for it: Node3D in items.values():
		var r: int = root[it.id]
		if it.parent != 0 and it.def.get("group", "") == "gpu":
			r = root.get(it.parent, 0)   # GPUs draw through the server they sit on
		if r != 0:
			loads[r] = loads.get(r, 0.0) + it.def.get("watts", 0.0)

	# limits: breakers trip (one per building we own), generators stall
	var dead := {}
	var grid_watts := 0.0
	capacity = 0.0
	var circuits: Dictionary = world.circuits()   # circuit id -> [limit in watts, where it is]
	for c: int in circuits:
		var key := -(c + 1)
		var on_circuit: float = loads.get(key, 0.0)
		if not tripped.has(c) and _overloaded(key, on_circuit, circuits[c][0], dt):
			tripped[c] = true
			events.append("Breaker tripped in %s! %d W on a %d W circuit" % [circuits[c][1], on_circuit, circuits[c][0]])
		if tripped.has(c):
			dead[key] = true
		else:
			capacity += circuits[c][0]
			grid_watts += on_circuit
	for it: Node3D in items.values():
		if not it.def.has("gen"):
			continue
		var gen: Dictionary = it.def["gen"]
		var limit: float = gen["watts"] * (sun if gen["kind"] == "solar" else 1.0)
		var load: float = loads.get(it.id, 0.0)
		it.load = load
		if not live[it.id]:
			_over.erase(it.id)
			continue
		if gen["kind"] == "solar":   # a panel just browns out for as long as it is overloaded
			if load > limit:
				dead[it.id] = true
			else:
				capacity += limit
			continue
		if _overloaded(it.id, load, limit, dt):
			dead[it.id] = true
			_over.erase(it.id)
			if gen["kind"] == "fuel":
				it.running = false
				events.append("The %s stalled: %d W on a %d W generator" % [it.label.to_lower(), load, gen["watts"]])
			elif gen["kind"] == "pedal":
				events.append("%s could not keep up with %d W and fell off the bike" % [world.name_of(it.rider), load])
				it.rider = 0
			continue
		capacity += limit
		if gen["kind"] == "fuel":
			it.fuel = maxf(0.0, it.fuel - dt / gen["burn"] * (0.25 + 0.75 * load / gen["watts"]))
			if it.fuel <= 0.0:
				it.running = false
				dead[it.id] = true
				events.append("The %s ran out of fuel" % it.label.to_lower())

	var powered := {}
	watts = 0.0
	for id: int in root:
		powered[id] = root[id] != 0 and not dead.has(root[id])
	for r: int in loads:
		if not dead.has(r):
			watts += loads[r]

	var status := {}
	var running := {}
	for it: Node3D in items.values():
		var bits := 0
		if it.def.has("gen"):
			bits = 3 if live[it.id] and not dead.has(it.id) else 0
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
		elif group == "gpu" and it.parent != 0 and running.get(it.parent, false):
			tokens += it.def.get("tokens", 0.0)
			status[it.id] = 3

	profit = tokens * Catalog.TOKEN_PRICE - grid_watts * Catalog.POWER_PRICE   # generator power is paid in fuel
	money += profit * dt
	return status


func _overloaded(key: int, load: float, limit: float, dt: float) -> bool:
	if load <= limit:
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


## Follows a power cable chain. Returns GRID, a live generator's id, or 0 for no power.
## A chain that loops back on itself (strip plugged into itself...) never gets anywhere.
func _power_root(it: Node3D, world: Node3D, live: Dictionary) -> int:
	var cur := it
	for hop in 16:
		var to: int = cur.power_to
		if to == 0:
			return 0
		if to < 0:
			var fixture: Node3D = world.fixtures.get(to)
			return -(fixture.circuit + 1) if fixture != null and fixture.provides == "power" else 0
		var next: Node3D = world.items.get(to)
		if next == null or next.provides != "power":
			return 0
		if next.def.has("gen"):
			return next.id if live.get(next.id, false) else 0
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
		if next == null or next.provides != "net" or not powered.get(next.id, false):
			return false
		cur = next
	return false
