extends Node
## Root: owns the menu and the World, wires them to the session lifecycle.
##
## Test flags (after `--` on the command line):
##   --host | --join[=ip]   skip the menu
##   --name=X               player name
##   --bot                  local player walks, grabs and throws on its own
##   --yaw=DEG              initial facing of the local player
##   --pos=X,Y,Z            initial position of the local player
##   --money=N              host: set the company balance
##   --weather=N            host: force the weather (0 sunny, 1 cloudy, 2 rain) and keep it
##   --open                 host: start with the garage door open
##   --selftest             host: wire up a working server through the real request path
##   --probe=SECONDS        print world state after N seconds, then quit
##   --shot=PATH            save a screenshot after --wait=SECONDS (default 2.5), then quit

const World = preload("res://scripts/world.gd")
const Menu = preload("res://scripts/menu.gd")

var world: Node3D
var menu: Control


func _ready() -> void:
	_setup_input()
	Net.joined.connect(_on_joined)
	Net.left.connect(_on_left)
	menu = Menu.new()
	add_child(menu)
	_handle_args()


func _setup_input() -> void:
	var keys := {"fwd": KEY_W, "back": KEY_S, "left": KEY_A, "right": KEY_D,
		"jump": KEY_SPACE, "sprint": KEY_SHIFT, "interact": KEY_E, "power": KEY_F, "net": KEY_G, "rotate": KEY_R, "use": KEY_Q}
	for action: String in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = keys[action]
		InputMap.add_action(action)
		InputMap.action_add_event(action, ev)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	InputMap.add_action("throw")
	InputMap.action_add_event("throw", click)


func _on_joined() -> void:
	menu.hide()
	world = World.new()
	world.name = "World"
	add_child(world)


func _on_left(reason: String) -> void:
	if world:
		remove_child(world)
		world.queue_free()
		world = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	menu.show()
	menu.set_status(reason)


func _handle_args() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if args.has("name"):
		Net.my_name = args["name"]
		Net.my_color = Net.PALETTE[absi(hash(Net.my_name)) % Net.PALETTE.size()]
	Net.bot = args.has("bot")
	Net.test_mode = args.has("bot") or args.has("probe") or args.has("shot") or args.has("selftest")
	if args.has("pos"):
		var xyz: PackedStringArray = args["pos"].split(",")
		Net.test_pos = Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2]))
	Net.test_yaw = float(args.get("yaw", "0"))
	if args.has("host"):
		Net.host()
	elif args.has("join"):
		Net.join(args["join"] if args["join"] != "" else "127.0.0.1")
	if args.has("money") and world:
		world._sim.money = float(args["money"])
	if args.has("weather") and world:
		world._sim.weather = int(args["weather"])
		world._sim.weather_left = 1e9
	if args.has("open") and world:
		world.request_door()
	if args.has("selftest"):
		_selftest()
	if args.has("probe"):
		await get_tree().create_timer(float(args["probe"])).timeout
		print(world.debug_dump() if world else "PROBE no world")
		get_tree().quit()
	elif args.has("shot"):
		await get_tree().create_timer(float(args.get("wait", "2.5"))).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(args["shot"])
		get_tree().quit()


## Plays through a whole session using the real request path, printing a CHECK line per stage.
func _selftest() -> void:
	await _wait(1.5)
	var me: Node3D = world.player(1)
	var kit := _by_kind()
	var server: Node3D = kit["server"]
	var strip: Node3D = kit["powerstrip"]
	var bike: Node3D = kit["gen_bike"]

	# 1. leg power: GPU on the server, server -> strip -> bike, internet from the wall box
	world.request_grab(kit["gpu_1080"].id)
	world.request_attach(server.id)
	world.request_link(strip.id, "power", bike.id)
	world.request_link(server.id, "power", strip.id)
	world.request_link(server.id, "net", -3)
	_check("wired to the bike, nobody pedalling")
	me.position = bike.global_position + Vector3(0, 0, 1)
	world.request_use(bike.id)
	await _wait(0.6)
	_check("pedalling")
	world.request_use(bike.id)

	# 2. rack, then placement through the real key path: carry the server, look at the front
	#    edge of the middle shelf board and press E
	world.request_buy("rack")
	await _wait(1.0)
	world.request_grab(server.id)
	world.request_attach(_by_kind()["rack"].id)
	await _wait(0.2)
	me.position = server.global_position + Vector3(0, 0, -1.5)
	world.request_grab(server.id)   # pull it back out of the rack
	me.position = Vector3(2.5, 0, -1.0)
	me.rotation.y = -PI / 2
	me.head.rotation.x = -0.24
	await _wait(0.6)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_E
	key.pressed = true
	Input.parse_input_event(key)
	await _wait(0.3)
	print("CHECK server on the shelf: at %.1v pinned=%s" % [server.global_position, server.pinned])

	# 3. wire the garage: a mower generator feeding a power inlet, wall sockets delivering it
	for kind: String in ["gen_mower", "fuel", "inlet", "outlet", "lamp"]:
		world.request_buy(kind)
	await _wait(0.4)
	kit = _by_kind()
	me.position = Vector3(0, 0, 1.0)
	world.request_grab(kit["inlet"].id)
	world.request_place(Transform3D(Basis(), Vector3(3.6, 0.13, 3.2)))
	world.request_grab(kit["outlet"].id)
	world.request_place(Transform3D(Basis(), Vector3(1.0, 0.07, 2.4)))
	world.request_link(kit["inlet"].id, "power", kit["gen_mower"].id)
	world.request_link(strip.id, "power", 0)
	world.request_link(strip.id, "power", kit["outlet"].id)
	_check("garage wired, mower off")
	world.request_use(kit["gen_mower"].id)
	world.request_grab(kit["fuel"].id)
	world.request_refuel(kit["gen_mower"].id)
	world.request_link(kit["lamp"].id, "power", kit["outlet"].id)
	await _wait(0.6)
	_check("mower running, lamp plugged in")

	# 4. real estate: insult neighbour 17 (next door, east), then pay well over the odds;
	#    buy number 16 and knock it down
	world.request_offer(17, 1000)
	world.request_offer(17, 40000)
	world.request_house_door(17)
	world.request_offer(16, 30000)
	world.request_demolish(16)
	world.request_demolish(16)

	# 5. solar: carry a panel out onto the lawn; what it adds depends on the weather
	world.request_buy("gen_solar")
	await _wait(0.4)
	me.position = Vector3(6, 0, 3)
	world.request_grab(_by_kind()["gen_solar"].id)
	world.request_place(Transform3D(Basis(), Vector3(8, 0.05, 2)))
	await _wait(0.6)
	_check("solar panel on the lawn")

	# 6. a second socket mounted on the garage's left wall, 1 m up: it must stay there
	world.request_buy("outlet")
	await _wait(0.4)
	me.position = Vector3(-2, 0, 1)
	var socket: Node3D = _by_kind()["outlet"]
	world.request_grab(socket.id)
	world.request_place(Transform3D(Basis.looking_at(Vector3.RIGHT), Vector3(-4.47, 1.0, 1.0)))
	await _wait(1.3)
	print("CHECK socket on the wall: at %.2v pinned=%s live=%s" % [socket.global_position, socket.pinned, socket.status == 3])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _by_kind() -> Dictionary:
	var out := {}
	for it: Node3D in world.items.values():
		out[it.kind] = it
	return out


func _check(stage: String) -> void:
	world._sim_step(0.0)
	print("CHECK %s: tokens=%.1f power=%.0f/%.0f W" % [stage, world.tokens, world.watts, world.capacity])
