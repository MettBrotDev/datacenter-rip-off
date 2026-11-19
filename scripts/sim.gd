extends RefCounted
## Host-only simulation of power, network and money. Runs twice a second.
## Rule: nothing is ever forbidden when you build it — this is where the consequences happen.

const Catalog = preload("res://scripts/catalog.gd")

var money := Catalog.START_MONEY
var tokens := 0.0       # tokens per second being produced
var watts := 0.0        # load on the breaker
var tripped := false

var _over := 0          # consecutive steps above the breaker limit


func reset_breaker() -> void:
	tripped = false
	_over = 0


## Advances the simulation. Returns {item id: status bits}; appends messages for players to `events`.
func step(world: Node3D, dt: float, events: Array) -> Dictionary:
	var items: Dictionary = world.items
	var powered := {}
	for it: Node3D in items.values():
		powered[it.id] = it.def.get("power_port", false) and _reaches(it, "power", world, {})

	watts = 0.0
	for it: Node3D in items.values():
		if powered[it.id] or (it.parent != 0 and powered.get(it.parent, false) and it.def.get("group", "") == "gpu"):
			watts += it.def.get("watts", 0.0)
	if not tripped:
		_over = _over + 1 if watts > Catalog.BREAKER_WATTS else 0
		if _over >= 3:
			tripped = true
			events.append("Breaker tripped! %d W on a %d W circuit" % [watts, Catalog.BREAKER_WATTS])
	if tripped:
		watts = 0.0
		for id: int in powered:
			powered[id] = false

	var status := {}
	var running := {}
	for it: Node3D in items.values():
		var bits := 0
		if it.def.get("net_port", false):
			var online: bool = powered[it.id] and _reaches(it, "net", world, powered)
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

	money += (tokens * Catalog.TOKEN_PRICE - watts * Catalog.POWER_PRICE) * dt
	return status


## Follows an item's cable chain until it hits a wall fixture of the right type.
## A chain that loops back on itself (strip plugged into itself...) never gets there.
func _reaches(it: Node3D, type: String, world: Node3D, powered: Dictionary) -> bool:
	var cur := it
	for hop in 16:
		var to: int = cur.link(type)
		if to == 0:
			return false
		if to < 0:
			var fixture: Node3D = world.fixtures.get(to)
			return fixture != null and fixture.provides == type
		var next: Node3D = world.items.get(to)
		if next == null or next.provides != type:
			return false
		if type == "net" and not powered.get(next.id, false):
			return false   # an unpowered switch passes nothing on
		cur = next
	return false
