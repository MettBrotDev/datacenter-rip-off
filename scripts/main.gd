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


## GPU onto server, strip into the wall, server into the strip and the router,
## then buy a rack and mount the server in it.
func _selftest() -> void:
	await get_tree().create_timer(1.5).timeout
	var by_kind := {}
	for it: Node3D in world.items.values():
		by_kind[it.kind] = it
	var server: Node3D = by_kind["server"]
	world.request_grab(by_kind["gpu_1080"].id)
	world.request_attach(server.id)
	world.request_link(by_kind["powerstrip"].id, "power", -1)
	world.request_link(server.id, "power", by_kind["powerstrip"].id)
	world.request_link(server.id, "net", -3)
	world.request_buy("rack")
	await get_tree().create_timer(1.0).timeout
	for it: Node3D in world.items.values():
		if it.kind == "rack":
			world.request_grab(server.id)
			world.request_attach(it.id)
	# placement through the real key path: carry the server, look at the front edge of the
	# middle shelf board and press E
	await get_tree().create_timer(0.5).timeout
	var me: Node3D = world.player(1)
	me.position = Vector3(2.5, 0, -1.0)
	me.rotation.y = -PI / 2
	me.head.rotation.x = -0.24
	world.request_grab(server.id)
	await get_tree().create_timer(0.6).timeout
	var key := InputEventKey.new()
	key.physical_keycode = KEY_E
	key.pressed = true
	Input.parse_input_event(key)

	# generators and land: mower generator takes over the power strip, someone pedals the bike,
	# and the backyard gets bought (needs --money)
	await get_tree().create_timer(0.5).timeout
	for kind: String in ["gen_mower", "gen_bike", "fuel"]:
		world.request_buy(kind)
	await get_tree().create_timer(0.3).timeout
	for it: Node3D in world.items.values():
		by_kind[it.kind] = it
	var strip: Node3D = by_kind["powerstrip"]
	me.position = by_kind["gen_mower"].global_position + Vector3(0, 0, 1)
	world.request_use(by_kind["gen_mower"].id)
	world.request_link(strip.id, "power", 0)
	world.request_link(strip.id, "power", by_kind["gen_mower"].id)
	world.request_grab(by_kind["fuel"].id)
	world.request_refuel(by_kind["gen_mower"].id)
	world.request_use(by_kind["gen_bike"].id)
	world.request_buy_plot("backyard")
	# overload: the 250 W bike cannot carry a 260 W server, so the rider gets thrown off
	await get_tree().create_timer(1.0).timeout
	world.request_link(strip.id, "power", 0)
	world.request_link(strip.id, "power", by_kind["gen_bike"].id)
	# solar: carry a panel out onto the lawn; what it adds depends on the weather
	world.request_buy("gen_solar")
	await get_tree().create_timer(0.3).timeout
	for it: Node3D in world.items.values():
		if it.kind == "gen_solar":
			world.request_use(by_kind["gen_bike"].id)   # hop off if still on
			me.position = Vector3(6, 0, 3)
			world.request_grab(it.id)
			world.request_place(Transform3D(Basis(), Vector3(8, 0.05, 2)))
