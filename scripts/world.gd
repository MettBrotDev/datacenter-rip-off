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
const DELIVERY := Vector3(2.6, 1.0, 1.8)   # next to the roller door
const SIM_STEP := 0.5
const OUTSIDE := "res://scripts/outside.gd"   # scenery around the garage

var items: Dictionary = {}      # item id (> 0) -> Item
var fixtures: Dictionary = {}   # fixture id (< 0) -> Fixture
var hud: CanvasLayer
var ready_peers: Array = []     # host only: clients that have loaded the world
var preview: Dictionary = {}    # cable end the local player is carrying: {"id", "type"}
var money := 0.0
var tokens := 0.0
var watts := 0.0
var tripped := false
var door_open := false
var capacity := 0.0             # watts available right now (grid + running generators)
var owned: Dictionary = {}      # plot key -> true once bought

var _garage: Garage
var _players: Node3D
var _items: Node3D
var _sim: Sim                   # host only
var _next_id := 1
var _tick := 0
var _sim_t := 0.0


func _ready() -> void:
	_garage = Garage.new()
	add_child(_garage)
	fixtures = _garage.fixtures
	if ResourceLoader.exists(OUTSIDE):
		add_child(load(OUTSIDE).new())
	_build_plots()
	_players = Node3D.new()
	_players.name = "Players"
	add_child(_players)
	_items = Node3D.new()
	_items.name = "Items"
	add_child(_items)
	var cables := Cables.new()
	cables.world = self
	add_child(cables)
	hud = Hud.new()
	add_child(hud)
	Net.players_changed.connect(_reconcile_players)
	_reconcile_players()
	if multiplayer.is_server():
		_sim = Sim.new()
		_spawn_starting_items()
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


## The bike generator this player is pedalling, if any.
func ridden_by(peer: int) -> Item:
	for it: Item in items.values():
		if it.rider == peer:
			return it
	return null


## Anywhere that is not under the garage roof. Solar panels only work out there.
func is_outdoors(pos: Vector3) -> bool:
	return absf(pos.x) > 5.5 or absf(pos.z) > 4.5


func can_attach(child: Item, par: Item) -> bool:
	if par == child or not par.def.has("slots"):
		return false
	return par.def["slots"]["accepts"] == child.def.get("group", "") and _free_slot(par) >= 0


func debug_dump() -> String:
	var out := "PROBE peer=%d players=%s money=%.0f tokens=%.1f watts=%.0f/%.0f tripped=%s door=%s owned=%s" % [
		multiplayer.get_unique_id(), Net.players.keys(), money, tokens, watts, capacity, tripped, door_open, owned.keys()]
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


func request_breaker() -> void:
	_to_host(&"_h_breaker", [])


func request_door() -> void:
	_to_host(&"_h_door", [])


## Switch a generator on/off, or hop on/off the bike.
func request_use(id: int) -> void:
	_to_host(&"_h_use", [id])


## Pour the held jerry can into a generator.
func request_refuel(id: int) -> void:
	_to_host(&"_h_refuel", [id])


func request_buy_plot(key: String) -> void:
	_to_host(&"_h_buy_plot", [key])


# --- plots ------------------------------------------------------------------

## Each plot: a concrete pad, a sale sign you buy it at, and a fibre pole that works once owned.
func _build_plots() -> void:
	var Fixture := preload("res://scripts/fixture.gd")
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = Color(0.62, 0.62, 0.6)
	pad_mat.roughness = 0.9
	var body := StaticBody3D.new()
	add_child(body)
	var next_id := -100
	for key: String in Catalog.PLOTS:
		var plot: Dictionary = Catalog.PLOTS[key]
		var size := Vector3(plot["size"].x, 0.3, plot["size"].y)
		var mesh := BoxMesh.new()
		mesh.size = size
		mesh.material = pad_mat
		var pad := MeshInstance3D.new()
		pad.mesh = mesh
		pad.position = plot["center"] + Vector3(0, -0.13, 0)   # top 2 cm above the grass
		add_child(pad)
		var shape := BoxShape3D.new()
		shape.size = size
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = pad.position
		body.add_child(col)

		var board := Fixture.new()
		board.setup(next_id, "sign")
		board.tag = key
		board.label = plot["label"]
		board.position = plot["sign"]
		board.rotation.y = deg_to_rad(plot["sign_yaw"])
		board.set_lamp(1)   # orange = for sale, green once sold
		add_child(board)
		fixtures[next_id] = board
		var text := Label3D.new()
		text.name = "Text"
		text.text = "FOR SALE\n%s\n%s" % [plot["label"], UI.money(plot["price"])]
		text.position = Vector3(0, 1.5, 0.03)
		text.font_size = 40
		text.pixel_size = 0.004
		text.modulate = Color(0.08, 0.1, 0.16)
		text.outline_size = 0
		board.add_child(text)

		var pole := Fixture.new()
		pole.setup(next_id - 1, "uplink")
		pole.tag = key
		pole.position = plot["pole"]
		pole.rotation.y = deg_to_rad(plot["sign_yaw"])
		pole.set_lamp(0)
		add_child(pole)
		fixtures[next_id - 1] = pole
		next_id -= 2


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
	hud.set_players(Net.players)


func name_of(peer: int) -> String:
	return Net.players.get(peer, {}).get("name", "Someone")


# --- host: handlers -----------------------------------------------------------

func _spawn_starting_items() -> void:
	var pile := ["server", "gpu_1080", "powerstrip", "crate", "crate"]
	for i in pile.size():
		var pos := Vector3(randf_range(-1.0, 1.0), 0.4 + i * 0.3, randf_range(-1.4, -0.4))
		_spawn(pile[i], Transform3D(Basis.from_euler(Vector3(0, randf() * TAU, 0)), pos))


func _spawn(kind: String, xf: Transform3D) -> void:
	_cast(&"_r_spawn", [_next_id, kind, xf, [0, 0, 0, 0, 0, false]])
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
				[it.holder, it.parent, it.slot, it.power_to, it.net_to, it.pinned])
	_r_door.rpc_id(peer, door_open)
	for key: String in owned:
		_r_plot.rpc_id(peer, key)
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
	if not multiplayer.is_server() or type not in ["power", "net"]:
		return
	var it: Item = items.get(id)
	if it == null or not it.def.get(type + "_port", false):
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
	var pos := DELIVERY + Vector3(randf_range(-0.8, 0.8), 0, randf_range(-0.3, 0.3))
	_spawn(kind, Transform3D(Basis.from_euler(Vector3(0, randf() * TAU, 0)), pos))
	_cast(&"_r_toast", ["%s bought %s (-%s)" % [name_of(Net.sender()), def["label"], UI.money(def["price"])]])
	_sim_step(0.0)


@rpc("any_peer", "call_remote", "reliable")
func _h_breaker() -> void:
	if not multiplayer.is_server() or not _sim.tripped:
		return
	_sim.reset_breaker()
	_cast(&"_r_toast", ["%s reset the breaker" % name_of(Net.sender())])
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
	if it == null or p == null or not it.def.has("gen") or it.holder != 0:
		return
	if it.rider != peer and p.position.distance_to(it.global_position) > 4.0:
		return
	match it.def["gen"]["kind"]:
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
func _h_buy_plot(key: String) -> void:
	if not multiplayer.is_server() or not Catalog.PLOTS.has(key) or owned.has(key):
		return
	var plot: Dictionary = Catalog.PLOTS[key]
	if _sim.money < plot["price"]:
		return
	_sim.money -= plot["price"]
	_cast(&"_r_plot", [key])
	_cast(&"_r_toast", ["%s bought the %s (-%s)" % [name_of(Net.sender()), plot["label"].to_lower(), UI.money(plot["price"])]])
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
		for type: String in ["power", "net"]:
			var to := it.link(type)
			if to == 0:
				continue
			var target := provider(to)
			if target == null or it.global_position.distance_to(target.global_position) > Catalog.MAX_CABLE:
				_cast(&"_r_link", [it.id, type, 0])
				_cast(&"_r_toast", ["The %s cable of a %s got yanked out" % [
					"power" if type == "power" else "network", it.label.to_lower()]])
	_drop_unsupported()
	var events: Array = []
	var status := _sim.step(self, dt, events)
	for text: String in events:
		_cast(&"_r_toast", [text])
	var gens := {}
	for it: Item in items.values():
		if it.def.has("gen"):
			gens[it.id] = [it.running, it.fuel, it.rider, it.load]
	_cast(&"_r_sim", [[_sim.money, _sim.tokens, _sim.watts, _sim.capacity, _sim.profit, _sim.tripped], status, gens])


## A pinned item whose support was taken away (the crate under it got picked up...) falls.
func _drop_unsupported() -> void:
	var space := get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 3
	for it: Item in items.values():
		if not it.pinned or not it.is_loose():
			continue
		var shape := BoxShape3D.new()
		shape.size = it.def["size"] * Vector3(0.9, 1.0, 0.9)
		query.shape = shape
		query.transform = it.global_transform.translated(Vector3.DOWN * 0.06)
		query.exclude = [it.get_rid()]
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
	it.setup(id, kind)
	it.name = str(id)
	it.holder = st[0]
	it.parent = st[1]
	it.slot = st[2]
	it.power_to = st[3]
	it.net_to = st[4]
	it.pinned = st[5]
	_items.add_child(it)
	it.global_transform = xf
	items[id] = it
	if multiplayer.is_server():
		it.sleeping_state_changed.connect(_on_item_sleep.bind(it))


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
	tripped = company[5]
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
	fixtures[-4].set_lamp(1 if tripped else 2)
	hud.set_stats(money, tokens, watts, capacity, company[4], tripped)


@rpc("authority", "call_remote", "reliable")
func _r_despawn(id: int) -> void:
	var it: Item = items.get(id)
	if it:
		items.erase(id)
		it.queue_free()


@rpc("authority", "call_remote", "reliable")
func _r_plot(key: String) -> void:
	owned[key] = true
	for f: Node3D in fixtures.values():
		if f.tag != key:
			continue
		f.set_lamp(2)
		if f.kind == "uplink":
			f.provides = "net"
		else:
			f.get_node("Text").text = "SOLD\n%s" % Catalog.PLOTS[key]["label"]


@rpc("authority", "call_remote", "reliable")
func _r_door(open: bool) -> void:
	door_open = open
	_garage.set_door(open)


@rpc("authority", "call_remote", "reliable")
func _r_toast(text: String) -> void:
	hud.toast(text)


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
