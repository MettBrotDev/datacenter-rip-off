extends Node
## Root: owns the menu and the World, wires them to the session lifecycle.
##
## Test flags (after `--` on the command line):
##   --host | --join[=ip]   skip the menu
##   --name=X               player name
##   --bot                  local player walks, grabs and throws on its own
##   --yaw=DEG              initial facing of the local player
##   --probe=SECONDS        print world state after N seconds, then quit
##   --shot=PATH            save a screenshot after ~2.5 s, then quit

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
		"jump": KEY_SPACE, "sprint": KEY_SHIFT, "interact": KEY_E}
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
	Net.test_yaw = float(args.get("yaw", "0"))
	if args.has("host"):
		Net.host()
	elif args.has("join"):
		Net.join(args["join"] if args["join"] != "" else "127.0.0.1")
	if args.has("probe"):
		await get_tree().create_timer(float(args["probe"])).timeout
		print(world.debug_dump() if world else "PROBE no world")
		get_tree().quit()
	elif args.has("shot"):
		await get_tree().create_timer(2.5).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(args["shot"])
		get_tree().quit()
