extends Node
## Root: owns the menu and the World, wires them to the session lifecycle.
##
## Test flags (after `--` on the command line):
##   --host | --join[=ip]   skip the menu
##   --name=X               player name
##   --port=N               UDP port to host or join on (default 24565)
##   --bot                  local player walks, grabs and throws on its own
##   --yaw=DEG              initial facing of the local player
##   --pos=X,Y,Z            initial position of the local player
##   --money=N              host: set the company balance
##   --weather=N            host: force the weather (0 sunny, 1 cloudy, 2 rain) and keep it
##   --doa                  host: every used part is dead on arrival
##   --demo[=starved]       host: give the company a few hours of history (products, a model, users, 300 tok/s);
##                          "starved" adds a product the servers cannot keep up with
##   --company[=TAB]        open the company menu (overview, slop, products, lab, platform, market)
##   --shop[=CATEGORY/SUB]  open the parts market, e.g. --shop=compute/gpu
##   --used                 open the parts market on its second-hand side
##   --bench                host: put two opened, fully fitted machines on the driveway
##   --cables               host: cable up the garage, three machines loosely and one neatly pinned
##   --showroom[=RAISE]     host: one of every catalog item in rows on the driveway and lawn (a line along X at z = 7, positions printed), to photograph
##   --pitch=DEG            initial look up (+) or down (-) of the local player
##   --open                 host: start with the garage door open
##   --selftest             host: wire up a working server through the real request path
##   --port=N               UDP port to host/join on (default 24565)
##   --pose=N               host: character showcase, set 1..4 of dummies frozen in one situation each
##                          (--pose_t=SECONDS: freeze the animation at that moment, --pose_yaw=DEG: their facing,
##                          --pose_pick=0,2: only those entries of the set)
##   --probe=SECONDS        print world state after N seconds, then quit
##   --shot=PATH            save a screenshot after --wait=SECONDS (default 2.5), then quit

const World = preload("res://scripts/world.gd")
const Menu = preload("res://scripts/menu.gd")
const PoseStage = preload("res://scripts/pose_stage.gd")
const UsedMarket = preload("res://scripts/used_market.gd")
const Catalog = preload("res://scripts/catalog.gd")
const Company = preload("res://scripts/company.gd")

var world: Node3D
var menu: Control


func _ready() -> void:
	load("res://scripts/ui.gd").setup()   # fonts and the default UI theme, before any UI exists
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
	for button: Array in [["primary", MOUSE_BUTTON_LEFT], ["throw", MOUSE_BUTTON_RIGHT]]:   # grab / put down, throw
		var click := InputEventMouseButton.new()
		click.button_index = button[1]
		InputMap.add_action(button[0])
		InputMap.action_add_event(button[0], click)


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
	if args.has("port"):
		Net.port = int(args["port"])
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
		world._company.demo(args["demo"] == "starved")
		world._sim_step(0.0)
	if args.has("company") and world:
		world.hud.open_company(args["company"] if args["company"] != "" else "overview")
	if args.has("bench") and world:
		world.debug_bench()
	if args.has("cables") and world:
		world.debug_cables()
	if args.has("showroom") and world:
		world.debug_showroom(float(args["showroom"]) if args["showroom"] != "" else 1.0)
	if args.has("pitch") and world:
		world.player(multiplayer.get_unique_id()).head.rotation.x = deg_to_rad(float(args["pitch"]))
	if args.has("shop") and world:
		world.hud.open_shop()
		if args["shop"] != "":
			world.hud._shop.open_to(args["shop"])
	if args.has("used") and world:
		world.hud.open_used_market()
	if args.has("open") and world:
		world.request_door()
	if args.has("pose") and world:
		var stage := PoseStage.new()
		world.add_child(stage)
		stage.setup(int(args["pose"]), float(args.get("pose_t", "0")), float(args.get("pose_yaw", "180")), args.get("pose_pick", ""))
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
	#    The starter server has a CPU and RAM in it, but its lid is screwed on: open it with the
	#    screwdriver, put the GPU into a slot, close it again.
	var card: Node3D = kit["gpu_1080"]
	me.position = server.global_position + Vector3(0, 0, 1.2)
	world.request_grab(card.id)
	print("CHECK GPU into a closed server: %s" % world.attach_problem(card, server))
	world.request_release(false)
	world.request_grab(kit["screwdriver"].id)
	world.request_lid(server.id)
	world.request_release(false)
	world.request_grab(card.id)
	world.request_attach(server.id, world.free_slot(server, "gpu"))
	print("CHECK lid off=%s, GPU sits in slot %d of the server" % [server.opened, card.slot])
	world.request_grab(kit["screwdriver"].id)
	world.request_lid(server.id)
	world.request_release(false)
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
	var key := InputEventMouseButton.new()   # left click puts down what you hold
	key.button_index = MOUSE_BUTTON_LEFT
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
	#    cables: loose ones reach 7 m; pinned along the way they go much further and nobody trips
	var lamp: Node3D = kit["lamp"]
	var far: Vector3 = lamp.global_position + Vector3(12, 0, 0)
	var along: Array = [lamp.global_position + Vector3(4, 0.02, 0), lamp.global_position + Vector3(8, 0.02, 0)]
	print("CHECK 12 m of loose cable: '%s'; pinned twice: '%s'; 60 m pinned: '%s'" % [world.route_problem(lamp.global_position, [], far),
		world.route_problem(lamp.global_position, along, far),
		world.route_problem(lamp.global_position, [far, far + Vector3(0, 0, 6), far + Vector3(40, 0, 6)], far + Vector3(46, 0, 6))])
	var plug_at: Vector3 = kit["outlet"].global_position
	var mid: Vector3 = (lamp.global_position + plug_at) * 0.5 + Vector3(0, 0.02 - (lamp.global_position.y + plug_at.y) * 0.5, 0)
	world.request_link(lamp.id, "power", 0)
	world.request_link(lamp.id, "power", kit["outlet"].id, [mid + Vector3(-0.5, 0, 0.4), mid + Vector3(0.5, 0, 0.4)])
	await _wait(0.6)
	var clipped: Vector3 = mid + Vector3(0, 0, 0.4)
	print("CHECK lamp cable re-run with 2 pins: pins=%d lit=%s, trips on the pinned stretch=%s, on the loose end=%s" % [
		lamp.routes.get("power", []).size(), lamp.status == 3, not world.cables.tripped_by(clipped).is_empty(),
		not world.cables.tripped_by((mid + Vector3(-0.5, 0, 0.4)).lerp(lamp.global_position, 0.15) * Vector3(1, 0, 1)).is_empty()])

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
	_check("garage %d Â°C, outside %d Â°C, chips %d Â°C" % [sim.temps[garage], sim.outside_temp(), server.heat])
	server.heat = 92.0
	_check("chips forced to 92 Â°C: half speed")
	server.heat = 104.0
	_check("chips forced to 104 Â°C: shut down")
	server.heat = 60.0
	world._sim_step(0.5)
	_check("chips back at 60 Â°C")

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

	# 11. dumpster: put two crates in, press the button
	for x: float in [-2.6, 2.8]:
		world._spawn("crate", Transform3D(Basis(), Vector3(x, 0.4, -1.5)))
	await _wait(0.5)
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
	#     It also needs a machine that can take it: a GPU server with a Xenon and 64 GB.
	await _buy(["gpu_a100", "pump", "reservoir", "radiator", "manifold", "bucket", "server_4u", "cpu_xenon", "ram_64"])
	kit = _by_kind()
	var pump: Node3D = kit["pump"]
	var tank: Node3D = kit["reservoir"]
	var big: Node3D = kit["server_4u"]
	print("CHECK A100 into the old tower server: %s" % world.attach_problem(kit["gpu_a100"], server))
	for step: Array in [["server_4u", Vector3(2.6, 0.12, 0.4)], ["gpu_a100", Vector3(3.3, 0.3, 1.2)], ["pump", Vector3(2.0, 0.2, 3.4)],
			["reservoir", Vector3(1.2, 0.4, 3.6)], ["manifold", Vector3(3.2, 0.1, 1.6)],
			["radiator", Vector3(4.2, 0.55, 5.6)]]:
		me.position = kit[step[0]].global_position + Vector3(0, 0, -1)
		world.request_grab(kit[step[0]].id)
		me.position = Vector3(2.5, 0, 4.2)
		world.request_place(Transform3D(Basis(), step[1]))
	var driver: Node3D = kit["screwdriver"]
	me.position = driver.global_position + Vector3(0, 0, 1)
	world.request_grab(driver.id)
	me.position = Vector3(2.6, 0, 1.6)
	world.request_lid(big.id)
	world.request_release(false)
	for kind: String in ["cpu_xenon", "ram_64", "gpu_a100"]:
		me.position = kit[kind].global_position + Vector3(0, 0, 1)
		world.request_grab(kit[kind].id)
		me.position = Vector3(2.6, 0, 1.6)
		world.request_attach(big.id)
	world.request_grab(driver.id)
	world.request_lid(big.id)
	world.request_release(false)
	world.request_link(big.id, "power", strip.id)
	world.request_link(big.id, "net", -3)
	await _run(40.0)
	_check("A100 with no coolant: chips %d Â°C" % big.heat)

	#     Build the loop: reservoir <- pump <- manifold <- server, radiator outside, three buckets of water.
	world.request_link(pump.id, "power", _by_kind()["outlet"].id)
	world.request_link(pump.id, "coolant", tank.id)
	world.request_link(kit["manifold"].id, "coolant", pump.id)
	world.request_link(kit["radiator"].id, "coolant", pump.id)
	world.request_link(big.id, "coolant", kit["manifold"].id)
	me.position = Vector3(3.0, 0, 5.2)
	world.request_grab(kit["bucket"].id)
	for trip in 3:
		world.request_bucket(-9)
		world.request_bucket(tank.id)
	world.request_release(false)
	world.request_use(pump.id)
	await _run(120.0)
	_check("loop running: chips %d Â°C, coolant %d Â°C, reservoir %d%%, server hose %d%% full" % [
		big.heat, pump.heat, tank.fuel * 100.0, big.hose * 100.0])

	#     Pull the server's hose off with the pump running: spray. Then the safe way: pump off, drain, unplug.
	world.request_link(big.id, "coolant", 0)
	print("CHECK hose pulled under pressure: puddles=%d server ruined=%s reservoir %d%%" % [
		world.puddles.size(), big.dead, tank.fuel * 100.0])
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

	# 14. people: ten minutes' worth of a 60 Â°C garage, without and with the heat suit
	await _buy(["suit"])
	sim.temps[garage] = 60.0
	world.temps[garage] = 60.0
	me.position = Vector3(0, 0, 0)
	me.exposure = 0.0
	me._feel_heat(30.0)
	print("CHECK 30 s at 60 Â°C without a suit: exposure %d%%" % (me.exposure * 100.0))
	me._feel_heat(35.0)
	print("CHECK 65 s at 60 Â°C: now at %.1v (fainted and moved outside if z is 6.5)" % me.position)
	me.position = _by_kind()["suit"].global_position + Vector3(0, 0, 1)
	world.request_use(_by_kind()["suit"].id)
	me.position = Vector3(0, 0, 0)
	me.exposure = 0.0
	me._feel_heat(600.0)
	print("CHECK 10 min at 60 Â°C in the suit: exposure %d%%, wearing=%s" % [me.exposure * 100.0, world.worn_by(1) != null])

	# 15a. the company: tokens per second are a live stream. Use it, serve with it, rent it out, or waste it.
	var company: RefCounted = world._company
	company.earned = 30000.0     # a Seed-round company: 5 slots, rental x1.5
	company._event_left = 1.0e9   # no random events while we measure
	company.live.clear()
	company.jobs.clear()
	#      nothing to do: the stream is rented out for pennies, or wasted when the switch is off
	_co_run(10.0, 3.5)
	var flow: Dictionary = world.co["flow"]
	print("CHECK idle at 3.5 tok/s, renting: serving %.1f, jobs %.1f, rented %.1f, wasted %.1f, rent pays=%s" % [
		flow["serving"], flow["jobs"], flow["rented"], flow["wasted"], world.co["rental"]["income"] > 0.0])
	world.request_company("rent", [false])
	_co_run(2.0, 3.5)
	flow = world.co["flow"]
	print("CHECK rental switched off: rented %.1f, wasted %.1f (%d%% of the compute), rent pays=%s" % [
		flow["rented"], flow["wasted"], roundi(flow["wasted"] / flow["total"] * 100.0), world.co["rental"]["income"] > 0.0])
	world.request_company("rent", [true])
	#      slop: 120 tokens of work, finished by the stream
	world.request_company("start", ["slop", "seo", 0, 0])
	_co_run(1.0, 3.5)
	var job: Dictionary = company.jobs[0]
	print("CHECK slop job: %d tokens of work, %.1f tok/s, ETA %d s, rented %.1f" % [job["total"], job["rate"], roundi(job["eta"]), world.co["flow"]["rented"]])
	_co_run(40.0, 3.5)
	print("CHECK slop done after 41 s at 3.5 tok/s: jobs %d, live %s" % [company.jobs.size(), str(company.live.map(func(it: Dictionary) -> String: return it["name"]))])
	var made: float = company.live[0]["earned"]
	_co_run(30.0, 3.5)
	print("CHECK slop pays out: earned more=%s, peak $%d/min" % [company.live[0]["earned"] > made, company.live[0]["peak"]])
	#      no compute: the job waits, it does not fail
	world.request_company("start", ["slop", "linkedin", 0, 0])
	_co_run(20.0, 0.0)
	job = company.jobs[0]
	print("CHECK no compute for 20 s: job still there=%s, %d of %d tokens done, stalled=%s" % [company.jobs.size() == 1, job["total"] - job["left"], job["total"], job["eta"] < 0.0])
	_co_run(70.0, 3.5)
	print("CHECK compute is back: job finished=%s, live %d" % [company.jobs.is_empty(), company.live.size()])
	#      rushing with money
	world.request_company("start", ["slop", "recipes", 0, 0])
	var cash0: float = sim.money
	_co_run(1.0, 0.0)
	var price: float = Company.rush_price(company.jobs[0])
	world.request_company("rush", [company.jobs[0]["id"]])
	print("CHECK rush with no compute: price $%d, job finished=%s, money -$%d" % [price, company.jobs.is_empty(), cash0 - sim.money])
	#      two jobs share equally; priority takes everything it can use
	company.live.clear()
	world.request_company("start", ["slop", "recipes", 0, 0])
	world.request_company("start", ["slop", "linkedin", 0, 0])
	var job_a: Dictionary = company.jobs[0]
	var job_b: Dictionary = company.jobs[1]
	_co_run(1.0, 10.0)
	print("CHECK two jobs at 10 tok/s: %.1f and %.1f tok/s" % [job_a["rate"], job_b["rate"]])
	world.request_company("priority", [job_b["id"]])
	_co_run(1.0, 10.0)
	print("CHECK priority on the second: %.1f and %.1f tok/s" % [job_a["rate"], job_b["rate"]])
	world.request_company("priority", [job_b["id"]])
	_co_run(1.0, 10.0)
	print("CHECK priority switched off again: %.1f and %.1f tok/s" % [job_a["rate"], job_b["rate"]])
	world.request_company("cancel", [job_a["id"]])
	world.request_company("cancel", [job_b["id"]])
	print("CHECK cancelled both: jobs %d" % company.jobs.size())
	#      a live product needs serving: starve it and it earns proportionally less
	world.request_company("rent", [false])
	company.live.append(company._live("product", "wrapper", "Test wrapper", 0, 2100.0, 1.0, 0.0, 0.0))
	var item: Dictionary = company.live[0]
	_co_run(1.0, 12.0)
	var full: float = world.co["income"]
	_co_run(1.0, 6.0)
	var half: float = world.co["income"]
	print("CHECK product needs %.0f tok/s: income $%d/min fed, $%d/min with half the compute (%d%%), fed %d%%" % [
		item["demand"], roundi(full / 10.0) * 10, roundi(half / 10.0) * 10, roundi(half / full * 100.0), roundi(item["fed"] * 100.0)])
	var age0: float = item["age"]
	_co_run(100.0, 6.0)
	print("CHECK starved for 100 s: aged %d s in 100 s (rots faster=%s), starved for %d s" % [item["age"] - age0, item["age"] - age0 > 120.0, item["starved"]])
	_co_run(1.0, 40.0)
	flow = world.co["flow"]
	print("CHECK 40 tok/s, a product serving 12, rental off: serving %.1f, wasted %.1f (%d%%)" % [flow["serving"], flow["wasted"], roundi(flow["wasted"] / flow["total"] * 100.0)])
	world.request_company("rent", [true])
	_co_run(1.0, 40.0)
	flow = world.co["flow"]
	print("CHECK rental back on: rented %.1f, wasted %.1f" % [flow["rented"], flow["wasted"]])
	#      updating is a job like any other and costs no slot
	item["hype"] = 0.4
	item["age"] = item["half_life"] * 1.32
	world.request_company("update", [item["id"]])
	var queued: int = company.jobs.size()
	_co_run(1.0, 400.0)
	print("CHECK update job queued=%d (slots used %d), rate %.0f tok/s" % [queued, company.slots_used(), company.jobs[0]["rate"] if not company.jobs.is_empty() else 0.0])
	_co_run(30.0, 400.0)
	print("CHECK update finished: jobs %d, hype %d%%" % [company.jobs.size(), roundi(item["hype"] * 100.0)])
	#      the model ladder: too dumb for a product, then the model writes the training stack and trains the next one
	print("CHECK a product with the starter model: %s" % company.start("product", "wrapper", 0, 0))
	print("CHECK training with no code written: %s" % company.train())
	world.request_company("use", ["llama"])   # rented by the minute from here on
	world._sim_step(0.5)
	print("CHECK renting %s; running costs per minute: %s" % [world.co["model"]["name"], str(world.co["costs"].keys())])
	#      the model writes the five parts of the training stack (each attempt can fail)
	for part: String in company.stack:
		for attempt in 8:
			if company.stack[part] < 1:
				world.request_company("code", [part])
				_co_run(10.0, 50.0)
	print("CHECK training stack after the model wrote it: %s" % str(company.stack))
	print("CHECK level 2 code with a smartness-1 model: %s" % company.code("data"))
	var plan: Dictionary = world.co["plan"]
	print("CHECK the model this stack would train: smartness %d, productivity x%.2f, reliability %d%%, %d tokens of work" % [
		plan["smart"], plan["productivity"], plan["reliability"] * 100.0, plan["tokens"]])
	world.request_company("train", [])
	_co_run(30.0, 500.0)
	for attempt in 12:
		if company.own.is_empty():
			_co_run(30.0, 500.0)
	world._sim_step(0.5)
	print("CHECK after training: using %s, owned %s, costs %s" % [world.co["model"]["name"], str(company.owned), str(world.co["costs"].keys())])
	print("CHECK live now: %s, stage %s" % [
		str(company.live.map(func(it: Dictionary) -> String: return "%s $%d/min" % [it["name"], it["peak"] * it["hype"]])),
		world.co["stage"]])
	company.test_tps = -1.0
	company.live.clear()
	await _run(360.0)   # the lab used to take this long in real sim time: keeps the heat and fuel of later stages comparable
	#      going broke: the landlady pulls the plug
	var saved: float = sim.money
	sim.money = -50.0
	world._sim_step(0.5)
	print("CHECK account below zero: overdue=%s garage internet=%s" % [world.co["overdue"], world.fixtures[-3].provides != ""])
	sim.money = saved
	world._sim_step(0.5)
	print("CHECK debts paid: overdue=%s garage internet=%s" % [world.co["overdue"], world.fixtures[-3].provides != ""])
	#      the company menu lives at the ops screens; the board shows who is at a console
	world.hud.open_company()
	world._sim_step(0.5)
	var typing: Array = world.co["console"]
	for tab: String in ["slop", "products", "lab", "platform", "market", "overview"]:
		world.hud._company._go(tab)
	print("CHECK company menu refreshed on every tab: %s" % world.hud._company._tab)
	world.hud._close_overlays()
	world._sim_step(0.5)
	print("CHECK console fixture=%s, at the console: %s, after closing: %s" % [world.fixtures.has(-20), str(typing), str(world.co["console"])])

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

	# 14. the second-hand market: one listing per hidden condition, bought and unpacked for real
	var market = world._market
	print("CHECK used market: %d offers, staples %s" % [market.listings.size(), str(UsedMarket.STAPLES)])
	for spec: Array in [["fine", "server_ws", ""], ["dead", "gpu_4070", ""], ["sketchy", "server_ws", ""], ["brick", "gpu_4090", ""],
			["swapped", "gpu_4090", "gpu_1080"], ["bonus", "server_ws", ""], ["soaked", "gpu_4070", ""],
			["fine", "server_ws", "", ["cpu_ryzer", "ram_16", "ram_16", "gpu_4070"]],
			["gutted", "server_ws", "", ["cpu_ryzer", "ram_16", "ram_16", "gpu_4070"]],
			["dud", "server_ws", "", ["cpu_ryzer", "ram_16", "ram_16", "gpu_4070"]]]:
		var listing: int = market.test_listing(spec[1], spec[0], spec[2], spec[3] if spec.size() > 3 else [])
		var asked: float = market.find(listing)["price"]
		var cash_before: float = world._sim.money
		var parcels_before := _count("parcel")
		world.request_buy_used(listing)
		await _wait(0.4)
		print("CHECK used %s: bought %s for $%d (new $%d), paid $%d, listing gone=%s, parcels %d -> %d" % [spec[0], spec[1], asked,
			Catalog.ITEMS[spec[1]]["price"], cash_before - world._sim.money, market.find(listing).is_empty(), parcels_before, _count("parcel")])
		world.player(1).position = Vector3(0, 0, 8)
		var box: Node3D = null
		for it: Node3D in world.items.values():
			if it.kind == "parcel" and (box == null or it.id > box.id):
				box = it
		var first: int = world._next_id
		world.request_unpack(box.id)
		await _wait(0.2)
		if spec[0] == "soaked":
			await _run(4.0)
		var got: Node3D = world.items[first]
		var duds := 0
		var mounted := 0
		for it: Node3D in world.items.values():
			mounted += 1 if it.parent == got.id else 0
			duds += 1 if it.parent == got.id and it.dead else 0
		print("CHECK used %s%s unpacked: it is a %s, ruined=%s sketchy=%s parts inside=%d dead parts=%d" % [spec[0],
			" rig" if spec.size() > 3 else "", got.kind, got.dead or got.broken, got.sketchy, mounted, duds])
	var ids_before: Array = market.listings.map(func(l: Dictionary) -> int: return l["id"])
	market.tick(500.0, 0)
	var ids_after: Array = market.listings.map(func(l: Dictionary) -> int: return l["id"])
	print("CHECK used market after 500 s: offers %d -> %d, still the same ids: %d" % [ids_before.size(), ids_after.size(),
		ids_before.filter(func(i: int) -> bool: return i in ids_after).size()])
	var offer: Dictionary = market.listings[0] if not market.listings.is_empty() else {}
	var asked_before: int = 0
	if not offer.is_empty():
		asked_before = offer["price"]
		var said: Dictionary = market.haggle(offer["id"])
		print("CHECK used haggle: $%d -> %s (%s)" % [asked_before, str(said.get("text", "?")), "gone" if said.get("gone", false) else "still listed"])
	print("CHECK used market state for clients has no condition: %s" % str(not world.used["listings"].is_empty() and not world.used["listings"][0].has("cond")))

	# 15. selling: a working RAM stick, a ruined GPU, a sofa and a PC with a CPU in it, on the pallet
	var pad := Vector3(-4.6, 0.5, 8.2)
	world._spawn("ram_16", Transform3D(Basis(), pad + Vector3(0.2, 0, -0.5)))
	world._spawn("gpu_1080", Transform3D(Basis(), pad + Vector3(-0.2, 0, -0.4)))
	world.items[world._next_id - 1].dead = true
	world._spawn("sofa", Transform3D(Basis(), pad + Vector3(0, 0.2, 0.3)))
	world._spawn("pc_office", Transform3D(Basis(), pad + Vector3(0.2, 0.9, 0.0)))
	var pc: Node3D = world.items[world._next_id - 1]
	world._cast(&"_r_spawn", [world._next_id, "cpu_celery", pc.global_transform, [0, pc.id, world.free_slot(pc, "cpu"), 0, 0, false, "", 0, 0, false]])
	world._next_id += 1
	await _wait(1.0)
	var before_sale: float = world._sim.money
	var count_before: int = world.items.size()
	world.request_sell()
	await _wait(0.3)
	print("CHECK sold on the pallet: items %d -> %d, money +$%d (expect ram 21 + ruined gpu 12 + sofa 40 + pc 18 + cpu 21 = 112)" % [
		count_before, world.items.size(), world._sim.money - before_sale])
	before_sale = world._sim.money
	world.request_sell()
	print("CHECK empty pallet: money +$%d" % (world._sim.money - before_sale))
	print("CHECK thermometer in the garage lets you read the room: %s" % world.temp_known_at(Vector3.ZERO))
	me.position = Vector3(0.6, 0, 1.2)   # leave the camera looking at the big screen
	me.rotation.y = 0.15
	me.head.rotation.x = 0.12

	# 17. delicate parts: a gentle drop is fine, a throw is not, and neither is sprinting over one
	var sticks: Array = []
	for i in 3:
		world._spawn("ram_16", Transform3D(Basis(), Vector3(-2.0 + i, 1.2, 14.0)))
		sticks.append(world.items[world._next_id - 1])
		world._cast(&"_r_release", [sticks[i].id, Transform3D(Basis(), Vector3(-2.0 + i, 1.2, 14.0)),
			Vector3(0, -11.0 if i == 1 else 0.0, 0)])
	me.position = Vector3(5, 0, 14)
	await _wait(1.5)
	var after_fall: Array = sticks.map(func(it: Node3D) -> bool: return it.dead)
	me.position = sticks[2].global_position - Vector3(0, 0.02, 0)
	me.velocity_estimate = Vector3(6.5, 0, 0)
	world._tick = 6
	world._physics_process(0.0)
	print("CHECK RAM dropped from 1.2 m: broken=%s; slammed down at 11 m/s: broken=%s; sprinted over: broken=%s" % [
		after_fall[0], after_fall[1], sticks[2].dead])
	me.position = Vector3(0.6, 0, 1.2)


## Lets simulated time pass quickly: `seconds` of game time in half-second steps.
## Run the company alone (no power, no heat, no running costs: only what the compute earns) for `seconds`
## with the servers making exactly `tps` tokens per second, then publish its state as world.co.
func _co_run(seconds: float, tps: float) -> void:
	var company: RefCounted = world._company
	company.test_tps = tps
	for i in int(round(seconds)):
		var events: Array = []
		world._sim.money += company.tick(1.0, 0.0, world._sim.money, 0, false, events)
		world._announce(events)
	world.co = company.state()


func _run(seconds: float) -> void:
	for i in int(seconds * 2.0):
		world._sim_step(0.5)
	await _wait(0.1)


## Buys things, then walks to the driveway and unpacks every parcel there.
func _buy(kinds: Array) -> void:
	for kind: String in kinds:
		if kind in UsedMarket.STAPLES:   # the cheap beginner parts moved to the second-hand market
			world.request_buy_used(0, kind)
		else:
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
