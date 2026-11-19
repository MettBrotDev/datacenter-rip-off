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
##   --doa                  host: every used part is dead on arrival
##   --demo                 host: give the company a few hours of history (products, a model, users)
##   --company[=TAB]        open the company menu (overview, slop, products, lab, platform, market)
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
		"jump": KEY_SPACE, "sprint": KEY_SHIFT, "interact": KEY_E, "power": KEY_F, "net": KEY_G, "rotate": KEY_R, "use": KEY_Q, "coolant": KEY_H, "company": KEY_TAB}
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
	if Net.test_mode and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)   # never take the keyboard
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
	if args.has("doa") and world:
		world.doa_chance = 1.0
	if args.has("demo") and world:
		world._company.demo()
		world._sim_step(0.0)
	if args.has("company") and world:
		world.hud.open_company(args["company"] if args["company"] != "" else "overview")
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

	# 2. a rack arrives as a parcel on the driveway: unpack it, carry it in, mount the server,
	#    then pull the server out again and put it on the shelf through the real key path
	await _buy(["rack"])
	var rack: Node3D = _by_kind()["rack"]
	me.position = Vector3(-1, 0, 5)
	world.request_grab(rack.id)
	world.request_place(Transform3D(Basis(), Vector3(-3.0, 0.92, 2.0)))
	me.position = server.global_position + Vector3(0, 0, 1.5)
	world.request_grab(server.id)
	world.request_attach(rack.id)
	await _wait(0.2)
	print("CHECK server in the rack: parent=%d rack at %.1v" % [server.parent, rack.global_position])
	me.position = Vector3(-1.5, 0, 1.0)
	world.request_grab(server.id)
	me.position = Vector3(2.5, 0, -1.0)
	me.rotation.y = -PI / 2
	me.head.rotation.x = -0.24
	await _wait(0.6)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_E
	key.pressed = true
	key.set_meta("test", true)   # the player ignores every other key press during test runs
	Input.parse_input_event(key)
	await _wait(0.3)
	print("CHECK server on the shelf: at %.1v pinned=%s" % [server.global_position, server.pinned])

	# 3. wire the garage: a mower generator outside feeding a power inlet, wall sockets inside
	await _buy(["gen_mower", "fuel", "inlet", "outlet", "lamp"])
	kit = _by_kind()
	me.position = Vector3(0.5, 0, 5.5)
	world.request_grab(kit["inlet"].id)
	world.request_place(Transform3D(Basis(), Vector3(3.6, 0.13, 3.2)))
	world.request_grab(kit["outlet"].id)
	world.request_place(Transform3D(Basis(), Vector3(1.0, 0.07, 2.4)))
	world.request_grab(kit["lamp"].id)
	world.request_place(Transform3D(Basis(), Vector3(-1.0, 0.81, 3.0)))
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

	# 5. solar: carry a panel onto the lawn; what it adds depends on the weather
	await _buy(["gen_solar"])
	me.position = Vector3(4, 0, 6)
	world.request_grab(_by_kind()["gen_solar"].id)
	world.request_place(Transform3D(Basis(), Vector3(8, 0.05, 4)))
	await _wait(0.6)
	_check("solar panel on the lawn")

	# 6. a second socket mounted on the garage's left wall, 1 m up: it must stay there
	await _buy(["outlet"])
	me.position = Vector3(-1.5, 0, 4.5)
	var socket: Node3D = _by_kind()["outlet"]
	world.request_grab(socket.id)
	world.request_place(Transform3D(Basis.looking_at(Vector3.RIGHT), Vector3(-4.47, 1.0, 1.0)))
	await _wait(1.3)
	print("CHECK socket on the wall: at %.2v pinned=%s live=%s" % [socket.global_position, socket.pinned, socket.status == 3])

	# 7. weather: a GPU left unpacked on the driveway and one still in its parcel. Only rain ruins
	#    anything, and only the unpacked one.
	await _buy(["gpu_4070"])
	world.request_buy("gpu_4090")
	await _wait(7.0)
	var ruined: Array[String] = []
	for it: Node3D in world.items.values():
		if it.broken:
			ruined.append(it.kind)
	print("CHECK after 7 s outdoors: ruined=%s parcels still closed=%d" % [ruined, _count("parcel")])


	# 8. chip temperatures: a busy air-cooled server sits about 48 degrees above the room.
	#    Force its chips hot and watch it throttle, shut down, and come back.
	var sim: RefCounted = world._sim
	var garage: int = world.GARAGE_CIRCUIT
	await _run(60.0)
	_check("garage %d °C, outside %d °C, chips %d °C" % [sim.temps[garage], sim.outside_temp(), server.heat])
	server.heat = 92.0
	_check("chips forced to 92 °C: half speed")
	server.heat = 104.0
	_check("chips forced to 104 °C: shut down")
	server.heat = 60.0
	world._sim_step(0.5)
	_check("chips back at 60 °C")

	# 9. fire: set the server alight, put it out with an extinguisher
	await _buy(["extinguisher"])
	world.request_grab(_by_kind()["extinguisher"].id)
	sim.ignite(server)
	world._sim_step(0.0)
	me.position = Vector3(2.5, 0, 0)
	print("CHECK server on fire: flames=%s" % server.on_fire())
	world.request_extinguish(server.id)
	print("CHECK after the extinguisher: flames=%s ruined=%s" % [server.on_fire(), server.broken])

	# 10. running over the power strip's cable pulls it out
	world.request_release(false)
	me.position = strip.global_position + Vector3(0, 0, 1)
	world.request_trip(strip.id, "power")
	_check("tripped over the strip's cable (plugged into %d)" % strip.power_to)

	# 11. dumpster: put the two starter crates in, press the button
	var before := _count("crate")
	for it: Node3D in world.items.values().duplicate():
		if it.kind == "crate":
			me.position = it.global_position + Vector3(0, 0, 1)
			world.request_grab(it.id)
			me.position = Vector3(4.9, 0, 6.5)
			world.request_place(Transform3D(Basis(), Vector3(4.9, 0.5, 8.2 + (it.id % 2) * 0.6 - 0.3)))
	await _wait(0.3)
	world.request_empty_bin()
	print("CHECK dumpster: crates %d -> %d" % [before, _count("crate")])

	# 12. a used GPU: dead on arrival only when the run was started with --doa
	await _buy(["gpu_1080"])
	await _wait(0.3)
	var newest: Node3D = null
	for it: Node3D in world.items.values():
		if it.kind == "gpu_1080" and (newest == null or it.id > newest.id):
			newest = it
	print("CHECK newly unpacked used GPU: ruined=%s" % newest.broken)


	# 13. liquid cooling. An A100 has no fans: on its own it cooks within seconds.
	world.request_link(strip.id, "power", _by_kind()["outlet"].id)   # plug the strip back in
	await _buy(["gpu_a100", "pump", "reservoir", "radiator", "manifold", "bucket"])
	kit = _by_kind()
	var pump: Node3D = kit["pump"]
	var tank: Node3D = kit["reservoir"]
	for step: Array in [["gpu_a100", Vector3(3.0, 0.3, 0.5)], ["pump", Vector3(2.0, 0.2, 3.4)],
			["reservoir", Vector3(1.2, 0.4, 3.6)], ["manifold", Vector3(3.2, 0.1, 1.6)],
			["radiator", Vector3(4.2, 0.55, 5.6)]]:
		me.position = kit[step[0]].global_position + Vector3(0, 0, -1)
		world.request_grab(kit[step[0]].id)
		me.position = Vector3(2.5, 0, 4.2)
		world.request_place(Transform3D(Basis(), step[1]))
	me.position = Vector3(3.0, 0, 1.5)
	world.request_grab(kit["gpu_a100"].id)
	world.request_attach(server.id)
	await _run(40.0)
	_check("A100 with no coolant: chips %d °C" % server.heat)

	#     Build the loop: reservoir <- pump <- manifold <- server, radiator outside, three buckets of water.
	world.request_link(pump.id, "power", _by_kind()["outlet"].id)
	world.request_link(pump.id, "coolant", tank.id)
	world.request_link(kit["manifold"].id, "coolant", pump.id)
	world.request_link(kit["radiator"].id, "coolant", pump.id)
	world.request_link(server.id, "coolant", kit["manifold"].id)
	me.position = Vector3(3.0, 0, 5.2)
	world.request_grab(kit["bucket"].id)
	for trip in 3:
		world.request_bucket(-9)
		world.request_bucket(tank.id)
	world.request_release(false)
	world.request_use(pump.id)
	await _run(120.0)
	_check("loop running: chips %d °C, coolant %d °C, reservoir %d%%, server hose %d%% full" % [
		server.heat, pump.heat, tank.fuel * 100.0, server.hose * 100.0])

	#     Pull the server's hose off with the pump running: spray. Then the safe way: pump off, drain, unplug.
	world.request_link(server.id, "coolant", 0)
	print("CHECK hose pulled under pressure: puddles=%d server ruined=%s reservoir %d%%" % [
		world.puddles.size(), server.dead, tank.fuel * 100.0])
	world.request_use(pump.id)
	world.request_drain(pump.id)
	await _run(5.0)
	var puddles_before: int = world.puddles.size()
	world.request_link(kit["manifold"].id, "coolant", 0)
	print("CHECK drained, then unplugged the manifold: its hose was %d%% full, new puddles=%d" % [
		kit["manifold"].hose * 100.0, world.puddles.size() - puddles_before])

	#     Reservoir hosed to the garden tap stays full.
	tank.fuel = 0.2
	world.request_link(tank.id, "coolant", -9)
	world._sim_step(0.5)
	print("CHECK reservoir on the tap: %d%% full" % (tank.fuel * 100.0))

	# 14. people: ten minutes' worth of a 60 °C garage, without and with the heat suit
	await _buy(["suit"])
	sim.temps[garage] = 60.0
	world.temps[garage] = 60.0
	me.position = Vector3(0, 0, 0)
	me.exposure = 0.0
	me._feel_heat(30.0)
	print("CHECK 30 s at 60 °C without a suit: exposure %d%%" % (me.exposure * 100.0))
	me._feel_heat(35.0)
	print("CHECK 65 s at 60 °C: now at %.1v (fainted and moved outside if z is 6.5)" % me.position)
	me.position = _by_kind()["suit"].global_position + Vector3(0, 0, 1)
	world.request_use(_by_kind()["suit"].id)
	me.position = Vector3(0, 0, 0)
	me.exposure = 0.0
	me._feel_heat(600.0)
	print("CHECK 10 min at 60 °C in the suit: exposure %d%%, wearing=%s" % [me.exposure * 100.0, world.worn_by(1) != null])

	# 15a. the company: tokens are not money. Sell some raw, make slop, then the model ladder.
	var company: RefCounted = world._company
	company.earned = 30000.0     # a Seed-round company: 180k tokens of storage
	company.tokens = 170000.0
	var cash: float = sim.money
	world.request_company("sell", [1000])
	print("CHECK sold 1000 raw tokens at $%.2f each: got $%d" % [company.spot, sim.money - cash])
	world.request_company("start", ["slop", "seo", 0, 0])
	print("CHECK a product with the starter model: %s" % company.start("product", "wrapper", 0, 0))
	print("CHECK training with no code written: %s" % company.train())
	world.request_company("use", ["llama"])   # rented by the minute from here on
	world._sim_step(0.5)
	print("CHECK renting %s; running costs per minute: %s" % [world.co["model"]["name"], str(world.co["costs"])])
	#      the model writes the five parts of the training stack (each attempt can fail)
	for part: String in company.stack:
		for attempt in 6:
			if company.stack[part] < 1:
				world.request_company("code", [part])
				await _run(32.0)
	print("CHECK training stack after the model wrote it: %s" % str(company.stack))
	print("CHECK level 2 code with a smartness-1 model: %s" % company.code("data"))
	var plan: Dictionary = world.co["plan"]
	print("CHECK the model this stack would train: smartness %d, productivity x%.2f, reliability %d%%, %d tokens" % [
		plan["smart"], plan["productivity"], plan["reliability"] * 100.0, plan["tokens"]])
	for attempt in 4:
		if company.own.is_empty():
			company.tokens = 170000.0
			world.request_company("train", [])
			await _run(plan["time"] + 2.0)
	print("CHECK after training: using %s, owned %s, costs %s" % [world.co["model"]["name"], str(company.owned), str(world.co["costs"])])
	print("CHECK live now: %s, stage %s" % [
		str(company.live.map(func(item: Dictionary) -> String: return "%s $%d/min" % [item["name"], item["peak"] * item["hype"]])),
		world.co["stage"]])
	#      going broke: the landlady pulls the plug
	var saved: float = sim.money
	sim.money = -50.0
	world._sim_step(0.5)
	print("CHECK account below zero: overdue=%s garage internet=%s" % [world.co["overdue"], world.fixtures[-3].provides != ""])
	sim.money = saved
	world._sim_step(0.5)
	print("CHECK debts paid: overdue=%s garage internet=%s" % [world.co["overdue"], world.fixtures[-3].provides != ""])

	# 15. sensors feed the ops board: nothing is listed until they are installed
	print("CHECK board with no sensors: %s" % str(world.board.readings(world)))
	await _buy(["thermometer", "sensor_power", "sensor_coolant"])
	kit = _by_kind()
	for step: Array in [["thermometer", Vector3(-1.0, 0.2, -2.0)], ["sensor_power", Vector3(0.6, 0.06, 2.6)],
			["sensor_coolant", Vector3(2.4, 0.07, 3.0)]]:
		me.position = kit[step[0]].global_position + Vector3(0, 0, -1)
		world.request_grab(kit[step[0]].id)
		me.position = Vector3(1.5, 0, 3.0)
		world.request_place(Transform3D(Basis(), step[1]))
	world.request_link(kit["sensor_power"].id, "power", kit["gen_mower"].id)
	world.request_link(kit["sensor_coolant"].id, "coolant", pump.id)
	world.request_use(pump.id)
	await _run(30.0)
	for line: String in world.board.readings(world):
		print("CHECK board: " + line)
	print("CHECK thermometer in the garage lets you read the room: %s" % world.temp_known_at(Vector3.ZERO))
	me.position = Vector3(0.6, 0, 1.2)   # leave the camera looking at the big screen
	me.rotation.y = 0.15
	me.head.rotation.x = 0.12


## Lets simulated time pass quickly: `seconds` of game time in half-second steps.
func _run(seconds: float) -> void:
	for i in int(seconds * 2.0):
		world._sim_step(0.5)
	await _wait(0.1)


## Buys things, then walks to the driveway and unpacks every parcel there.
func _buy(kinds: Array) -> void:
	for kind: String in kinds:
		world.request_buy(kind)
	await _wait(0.4)
	world.player(1).position = Vector3(0, 0, 8)
	for it: Node3D in world.items.values().duplicate():
		if it.kind == "parcel":
			world.request_unpack(it.id)
	await _wait(0.2)


func _count(kind: String) -> int:
	var n := 0
	for it: Node3D in world.items.values():
		if it.kind == kind:
			n += 1
	return n


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
