extends CharacterBody3D
## One player. The owning peer simulates movement and broadcasts it through Net;
## everyone else interpolates towards the last received state.

const Blob = preload("res://scripts/blob.gd")
const Catalog = preload("res://scripts/catalog.gd")
const WALK := 4.0
const SPRINT := 6.5
const JUMP := 4.6
const GRAVITY := 13.0
const SENS := 0.0022
const KEYS := {"power": "F", "net": "G"}
const WORDS := {"power": "power", "net": "network"}

var peer_id := 1
var is_local := false
var head: Node3D          # pitch pivot at eye height
var hand: Marker3D        # where a carried item sits
var velocity_estimate := Vector3.ZERO

var _world: Node3D
var _blob: Node3D
var _cam: Camera3D
var _ray: RayCast3D
var _settings: Node
var _tick := 0
var _last_pos := Vector3.ZERO
var _cable: Dictionary = {}   # cable end in hand: {"id": item id, "type": "power" | "net"}
var _acts: Array = []         # what the keys do right now: [[input action, prompt text, Callable]]


func _ready() -> void:
	_world = get_parent().get_parent()
	_settings = get_node_or_null("/root/Settings")
	is_local = peer_id == multiplayer.get_unique_id()
	var info: Dictionary = Net.players.get(peer_id, {"name": "?", "color": Color.WHITE})

	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.6
	var col := CollisionShape3D.new()
	col.shape = cap
	col.position.y = 0.8
	add_child(col)

	_blob = Blob.new()
	add_child(_blob)
	_blob.setup(info["color"])
	head = Node3D.new()
	head.position.y = 1.4
	add_child(head)
	hand = Marker3D.new()
	hand.position = Vector3(0.3, -0.32, -0.8)
	head.add_child(hand)
	_last_pos = position

	if is_local:
		rotation.y = deg_to_rad(Net.test_yaw)
		_blob.visible = false
		_cam = Camera3D.new()
		_cam.near = 0.05
		head.add_child(_cam)
		_cam.make_current()
		_ray = RayCast3D.new()
		_ray.target_position = Vector3(0, 0, -3.0)
		_ray.collision_mask = 7   # world + loose items + attached items
		_ray.add_exception(self)
		head.add_child(_ray)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if _settings:
			_settings.changed.connect(_apply_settings)
		_apply_settings()
	else:
		var tag := Label3D.new()
		tag.text = info["name"]
		tag.position.y = 1.95
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.font_size = 48
		tag.pixel_size = 0.0022
		tag.outline_size = 12
		tag.outline_modulate = Color(0.04, 0.06, 0.12)
		add_child(tag)


func aim_dir() -> Vector3:
	return -head.global_basis.z


func _apply_settings() -> void:
	_cam.fov = _settings.fov if _settings else 70.0


func _unhandled_input(e: InputEvent) -> void:
	if not is_local or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if e is InputEventMouseMotion:
		var sens: float = SENS * (_settings.mouse_sens if _settings else 1.0)
		var flip := -1.0 if _settings and _settings.invert_y else 1.0
		rotation.y -= e.relative.x * sens
		head.rotation.x = clampf(head.rotation.x - e.relative.y * sens * flip, -1.5, 1.5)
		return
	for act: Array in _acts:
		if act[0] != "" and e.is_action_pressed(act[0]):
			act[2].call()
			return


func _physics_process(dt: float) -> void:
	if is_local:
		_move(dt)
		_tick += 1
		if _tick % 2 == 0:
			Net.send_state(position, rotation.y, head.rotation.x)
		_update_actions()
	else:
		var s: Variant = Net.pstates.get(peer_id)
		if s:
			var k := 1.0 - exp(-18.0 * dt)
			position = s[0] if position.distance_to(s[0]) > 3.0 else position.lerp(s[0], k)
			rotation.y = lerp_angle(rotation.y, s[1], k)
			head.rotation.x = lerpf(head.rotation.x, s[2], k)
	velocity_estimate = (position - _last_pos) / dt
	_last_pos = position
	_blob.animate(dt, Vector2(velocity_estimate.x, velocity_estimate.z).length(), head.rotation.x)


func _move(dt: float) -> void:
	var active := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var dir := Vector3.ZERO
	var speed := WALK
	if Net.bot:
		_bot(dt)
		dir = -transform.basis.z
	elif active:
		var i := Input.get_vector("left", "right", "fwd", "back")
		dir = (transform.basis * Vector3(i.x, 0, i.y)).normalized()
		if Input.is_action_pressed("sprint"):
			speed = SPRINT
	var accel := (40.0 if is_on_floor() else 8.0) * dt
	velocity.x = move_toward(velocity.x, dir.x * speed, accel)
	velocity.z = move_toward(velocity.z, dir.z * speed, accel)
	if not is_on_floor():
		velocity.y -= GRAVITY * dt
	elif active and Input.is_action_just_pressed("jump"):
		velocity.y = JUMP
	move_and_slide()


func _bot(dt: float) -> void:
	rotation.y += dt * 1.2
	if _tick == 60:
		var nearest: Node3D = null
		for it: Node3D in _world.items.values():
			if nearest == null or position.distance_to(it.position) < position.distance_to(nearest.position):
				nearest = it
		if nearest:
			_world.request_grab(nearest.id)
	elif _tick == 150:
		_world.request_release(true)


# --- interaction -----------------------------------------------------------------

## The item or fixture under the crosshair, if any.
func _target() -> Node3D:
	if _ray.is_colliding():
		var c := _ray.get_collider() as Node3D
		if c and "provides" in c:
			return c
	return null


func _update_actions() -> void:
	var t := _target()
	var held: Node3D = _world.held_by(peer_id)
	var acts: Array = []
	if not _cable.is_empty() and (held or not _world.items.has(_cable["id"])):
		_set_cable({})
	if not _cable.is_empty():
		var type: String = _cable["type"]
		if t and t.provides == type:
			if _world.sockets_used(t.id, type) < t.sockets:
				acts.append(["throw", "[Click] Plug into %s" % t.label.to_lower(), _plug.bind(t.id)])
			else:
				acts.append(["", "%s is full" % t.label, Callable()])
		else:
			acts.append(["", "Holding a %s cable. Find somewhere to plug it in." % WORDS[type], Callable()])
		acts.append([type, "[%s] Let go" % KEYS[type], _set_cable.bind({})])
	elif held:
		if t is RigidBody3D and _world.can_attach(held, t):
			acts.append(["interact", "[E] Mount on %s" % t.label.to_lower(), _world.request_attach.bind(t.id)])
		else:
			acts.append(["interact", "[E] Put down", _world.request_release.bind(false)])
		acts.append(["throw", "[Click] Throw", _world.request_release.bind(true)])
	elif t is RigidBody3D:
		acts.append(["interact", "[E] %s %s" % ["Pull out" if t.parent != 0 else "Pick up", t.label.to_lower()],
				_world.request_grab.bind(t.id)])
		for type: String in ["power", "net"]:
			if not t.def.get(type + "_port", false):
				continue
			if t.link(type) != 0:
				acts.append([type, "[%s] Unplug %s" % [KEYS[type], WORDS[type]], _world.request_link.bind(t.id, type, 0)])
			else:
				acts.append([type, "[%s] Grab %s cable" % [KEYS[type], WORDS[type]],
						_set_cable.bind({"id": t.id, "type": type})])
		if t.provides != "":
			acts.append(["", "%d/%d sockets used" % [_world.sockets_used(t.id, t.provides), t.sockets], Callable()])
	elif t:
		match t.kind:
			"shop":
				acts.append(["interact", "[E] Open the parts market", _world.hud.open_shop])
			"breaker":
				if _world.tripped:
					acts.append(["interact", "[E] Reset the breaker", _world.request_breaker])
				else:
					acts.append(["", "Breaker box: %d / %d W" % [_world.watts, Catalog.BREAKER_WATTS], Callable()])
			_:
				acts.append(["", "%s: %d/%d sockets used" % [t.label, _world.sockets_used(t.id, t.provides), t.sockets], Callable()])
	_acts = acts
	var lines: Array[String] = []
	for act: Array in acts:
		lines.append(act[1])
	_world.hud.set_prompt("\n".join(lines))


func _set_cable(cable: Dictionary) -> void:
	_cable = cable
	_world.preview = cable


func _plug(provider_id: int) -> void:
	_world.request_link(_cable["id"], _cable["type"], provider_id)
	_set_cable({})
