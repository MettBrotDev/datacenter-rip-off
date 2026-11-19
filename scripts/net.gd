extends Node
## Connection + lobby state (autoload "Net"). Host-authoritative: peer 1 is always the host.
## Lives for the whole app, so RPCs here are safe even while a peer has no World loaded.

signal joined                  # we are now in a session (hosting, or registered as client)
signal left(reason: String)    # session ended
signal players_changed

const PORT := 24565
const MAX_PLAYERS := 4
const PALETTE: Array[Color] = [
	Color(0.15, 0.85, 0.25), Color(0.1, 0.6, 1.0), Color(1.0, 0.2, 0.5), Color(1.0, 0.85, 0.1),
	Color(1.0, 0.5, 0.1), Color(0.65, 0.35, 1.0), Color(0.1, 0.9, 0.85), Color(0.95, 0.95, 0.95),
]

var players: Dictionary = {}   # peer id -> {"name": String, "color": Color}
var pstates: Dictionary = {}   # peer id -> [position: Vector3, yaw: float, pitch: float]
var my_name := "Player"
var my_color := PALETTE[0]
var in_session := false
var bot := false               # test mode: local player moves on its own
var test_mode := false         # any test flag given: never capture or read the real mouse
var test_pos: Variant = null   # test mode: initial position of the local player (Vector3)
var test_yaw := 0.0            # test mode: initial facing of the local player, degrees


func _ready() -> void:
	multiplayer.connected_to_server.connect(func(): _register.rpc_id(1, my_name, my_color))
	multiplayer.connection_failed.connect(func(): leave.call_deferred("Could not connect"))
	multiplayer.server_disconnected.connect(func(): leave.call_deferred("The host closed the game"))
	multiplayer.peer_disconnected.connect(_on_peer_left)


func host() -> String:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, MAX_PLAYERS - 1) != OK:
		return "Port %d is already in use" % PORT
	multiplayer.multiplayer_peer = peer
	players = {1: {"name": my_name, "color": my_color}}
	in_session = true
	joined.emit()
	players_changed.emit()
	return ""


func join(address: String) -> String:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, PORT) != OK:
		return "Invalid address"
	multiplayer.multiplayer_peer = peer
	return ""


func leave(reason := "") -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	pstates.clear()
	in_session = false
	left.emit(reason)


## Peer that sent the RPC being handled; our own id when the host calls a handler directly.
func sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return id if id != 0 else multiplayer.get_unique_id()


func send_state(pos: Vector3, yaw: float, pitch: float) -> void:
	_pstate.rpc(pos, yaw, pitch)


@rpc("any_peer", "call_remote", "reliable")
func _register(pname: String, color: Color) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	pname = pname.strip_edges().substr(0, 16)
	players[id] = {"name": pname if pname != "" else "Player", "color": color}
	_sync_players.rpc(players)
	players_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_players(p: Dictionary) -> void:
	if not p.has(multiplayer.get_unique_id()):
		return   # we are connected but not registered yet
	players = p
	for id in pstates.keys():
		if not players.has(id):
			pstates.erase(id)
	if not in_session:
		in_session = true
		joined.emit()
	players_changed.emit()


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _pstate(pos: Vector3, yaw: float, pitch: float) -> void:
	pstates[multiplayer.get_remote_sender_id()] = [pos, yaw, pitch]


func _on_peer_left(id: int) -> void:
	if not multiplayer.is_server() or not players.has(id):
		return
	players.erase(id)
	pstates.erase(id)
	_sync_players.rpc(players)
	players_changed.emit()
