extends Node3D
## The running game: level, players and items. The host owns all item state.
##
## Naming: request_*  = called locally by gameplay code
##         _h_*       = runs on the host (validates a client's request)
##         _r_*       = replicated result, runs on every peer

const Player = preload("res://scripts/player.gd")
const Item = preload("res://scripts/item.gd")
const Garage = preload("res://scripts/garage.gd")
const Hud = preload("res://scripts/hud.gd")
const SPAWNS: Array[Vector3] = [Vector3(-1.5, 0, 2), Vector3(0, 0, 2.4), Vector3(1.5, 0, 2), Vector3(0, 0, 1)]

var items: Dictionary = {}      # item id -> Item
var hud: CanvasLayer
var ready_peers: Array = []     # host only: clients that have loaded the world

var _players: Node3D
var _items: Node3D
var _next_id := 1
var _tick := 0


func _ready() -> void:
	add_child(Garage.new())
	_players = Node3D.new()
	_players.name = "Players"
	add_child(_players)
	_items = Node3D.new()
	_items.name = "Items"
	add_child(_items)
	hud = Hud.new()
	add_child(hud)
	Net.players_changed.connect(_reconcile_players)
	_reconcile_players()
	if multiplayer.is_server():
		_spawn_starting_items()
	else:
		_h_snapshot.rpc_id(1)


func player(id: int) -> Player:
	return _players.get_node_or_null(str(id))


func held_by(peer: int) -> Item:
	for it: Item in items.values():
		if it.holder == peer:
			return it
	return null


func request_grab(id: int) -> void:
	_to_host(&"_h_grab", [id])


func request_release(throw: bool) -> void:
	_to_host(&"_h_release", [throw])


func debug_dump() -> String:
	var out := "PROBE peer=%d players=%s" % [multiplayer.get_unique_id(), Net.players.keys()]
	for p: Player in _players.get_children():
		out += "\n  player %d at %.1v" % [p.peer_id, p.position]
	for it: Item in items.values():
		out += "\n  item %d %s at %.1v holder=%d" % [it.id, it.kind, it.position, it.holder]
	return out


# --- players ---------------------------------------------------------------

func _reconcile_players() -> void:
	var ids := Net.players.keys()
	ids.sort()
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
	hud.set_players(Net.players)


# --- items: host side --------------------------------------------------------

func _spawn_starting_items() -> void:
	var pile := ["crate", "crate", "crate", "server", "server", "gpu", "gpu", "gpu", "powerstrip", "powerstrip"]
	for i in pile.size():
		var pos := Vector3(randf_range(-1.2, 1.2), 0.4 + i * 0.25, randf_range(-1.6, -0.4))
		var xf := Transform3D(Basis.from_euler(Vector3(0, randf() * TAU, 0)), pos)
		_cast(&"_r_spawn", [_next_id, pile[i], xf, 0])
		_next_id += 1


@rpc("any_peer", "call_remote", "reliable")
func _h_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	for it: Item in items.values():
		_r_spawn.rpc_id(peer, it.id, it.kind, it.global_transform, it.holder)
	ready_peers.append(peer)


@rpc("any_peer", "call_remote", "reliable")
func _h_grab(id: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := Net.sender()
	var it: Item = items.get(id)
	var p := player(peer)
	if it == null or p == null or it.holder != 0 or held_by(peer) != null:
		return
	if p.position.distance_to(it.position) > 5.0:
		return
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


func _physics_process(_dt: float) -> void:
	if not multiplayer.is_server():
		return
	for it: Item in items.values():   # safety net: anything that escapes the level comes back
		if it.holder == 0 and it.position.y < -5.0:
			_cast(&"_r_release", [it.id, Transform3D(Basis(), Vector3(0, 1.5, 0)), Vector3.ZERO])
	if ready_peers.is_empty():
		return
	_tick += 1
	if _tick % 3 != 0:
		return
	var batch := []
	for it: Item in items.values():
		if it.holder == 0 and not it.sleeping:
			batch.append_array([it.id, it.position, it.quaternion])
	if not batch.is_empty():
		for peer: int in ready_peers:
			_r_items.rpc_id(peer, batch)


func _on_item_sleep(it: Item) -> void:
	if it.sleeping and it.holder == 0:   # final exact resting pose, reliably
		for peer: int in ready_peers:
			_r_rest.rpc_id(peer, it.id, it.position, it.quaternion)


# --- items: replicated -------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _r_spawn(id: int, kind: String, xf: Transform3D, holder: int) -> void:
	var it := Item.new()
	it.setup(id, kind)
	it.name = str(id)
	_items.add_child(it)
	it.global_transform = xf
	it.set_holder(holder)
	items[id] = it
	if multiplayer.is_server():
		it.sleeping_state_changed.connect(_on_item_sleep.bind(it))


@rpc("authority", "call_remote", "reliable")
func _r_hold(id: int, peer: int) -> void:
	var it: Item = items.get(id)
	if it:
		it.set_holder(peer)


@rpc("authority", "call_remote", "reliable")
func _r_release(id: int, xf: Transform3D, vel: Vector3) -> void:
	var it: Item = items.get(id)
	if it:
		it.release(xf, vel)


@rpc("authority", "call_remote", "unreliable_ordered")
func _r_items(batch: Array) -> void:
	for i in range(0, batch.size(), 3):
		var it: Item = items.get(batch[i])
		if it and it.holder == 0:
			it.net_target(batch[i + 1], batch[i + 2])


@rpc("authority", "call_remote", "reliable")
func _r_rest(id: int, pos: Vector3, rot: Quaternion) -> void:
	var it: Item = items.get(id)
	if it and it.holder == 0:
		it.net_target(pos, rot)


# --- rpc helpers -------------------------------------------------------------

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
