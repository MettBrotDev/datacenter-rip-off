extends CharacterBody3D
## One player. The owning peer simulates movement and broadcasts it through Net;
## everyone else interpolates towards the last received state.

const Blob = preload("res://scripts/blob.gd")
const Catalog = preload("res://scripts/catalog.gd")
const Sim = preload("res://scripts/sim.gd")
const UI = preload("res://scripts/ui.gd")
const WALK := 4.0
const SPRINT := 6.5
const JUMP := 4.6
const GRAVITY := 13.0
const SENS := 0.0022
const KEYS := {"power": "F", "net": "G", "coolant": "H"}
const WORDS := {"power": "power cable", "net": "network cable", "coolant": "coolant hose"}
const HEAT_SAFE := 50.0       # room temperature a person can take indefinitely (generous on purpose)
const HEAT_SCALE := 600.0     # degree-seconds above that before passing out (60 C: a minute)

var peer_id := 1
var is_local := false
var head: Node3D          # pitch pivot at eye height
var hand: Marker3D        # where a carried item sits
var velocity_estimate := Vector3.ZERO
var exposure := 0.0       # local player only: 0..1 towards passing out from the heat

var _world: Node3D
var _blob: Node3D
var _cam: Camera3D
var _ray: RayCast3D
var _settings: Node
var _send_t := 0.0
var _bot_t := 0.0
var _last_pos := Vector3.ZERO
var _spawn := Vector3.ZERO
var _air_hold := 0.0          # remote players: seconds left of "in the air"
var _exp_est := 0.0           # remote players: estimated overheating (same sums as the owner)
var _stumble := 0.0           # seconds left without control after tripping
var _trip_wait := 0.0         # seconds until we can trip again
var _ghost: MeshInstance3D    # preview of where the held item would be placed
var _place_xf: Variant = null # Transform3D of that spot, or null when there is none
var _place_turns := 0         # extra quarter turns chosen with R
var _cable: Dictionary = {}   # cable end in hand: {"id": item id, "type": "power" | "net"}
var _acts: Array = []         # what the keys do right now: [[input action, prompt text, Callable]]


func _ready() -> void:
	_world = get_parent().get_parent()
	_settings = get_node_or_null("/root/Settings")
	is_local = peer_id == multiplayer.get_unique_id()
	var info: Dictionary = Net.players.get(peer_id, {"name": "?", "color": Color.WHITE})

	# Layers: 1 world, 2 loose items, 4 mounted items (ray only), 8 players, 16 big items.
	# Players walk through small items on purpose: bumping them made everything twitch.
	collision_layer = 8
	collision_mask = 1 | 8 | 16
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
	process_priority = -1   # before the items, so a carried one follows the hands of this frame
	head = Node3D.new()
	head.position.y = 1.4
	add_child(head)
	hand = Marker3D.new()
	hand.position = Vector3(0.3, -0.32, -0.8)
	head.add_child(hand)
	_last_pos = position

	if is_local:
		rotation.y = deg_to_rad(Net.test_yaw)
		if Net.test_pos != null:
			position = Net.test_pos
		_spawn = position
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
		if not Net.test_mode:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		var ghost_mat := StandardMaterial3D.new()
		ghost_mat.albedo_color = Color(0.3, 1.0, 0.6, 0.35)
		ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost = MeshInstance3D.new()
		_ghost.mesh = BoxMesh.new()
		_ghost.material_override = ghost_mat
		_ghost.top_level = true
		_ghost.visible = false
		add_child(_ghost)
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


## True while the player controls the character (no menu open). Test runs never capture the mouse.
func _active() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or Net.test_mode


func _apply_settings() -> void:
	_cam.fov = _settings.fov if _settings else 70.0


func _unhandled_input(e: InputEvent) -> void:
	if not is_local or not _active():
		return
	if Net.test_mode and not e.has_meta("test"):
		return   # automated runs must not react to whoever is using the PC, mouse or keyboard
	if e is InputEventMouseMotion:
		var sens: float = SENS * (_settings.mouse_sens if _settings else 1.0)
		var flip := -1.0 if _settings and _settings.invert_y else 1.0
		rotation.y -= e.relative.x * sens
		head.rotation.x = clampf(head.rotation.x - e.relative.y * sens * flip, -1.5, 1.5)
		return
	for act: Array in _acts:
		if act[0] != "" and e.is_action_pressed(act[0]):
			_blob.poke()
			act[2].call()
			return


## Runs every rendered frame (not on the physics tick) so motion is smooth at any refresh rate.
func _process(dt: float) -> void:
	if is_local:
		_move(dt)
		_send_t += dt
		if _send_t >= 1.0 / 30.0:
			_send_t = 0.0
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
	var pace := Vector2(velocity_estimate.x, velocity_estimate.z).length()
	_animate_blob(dt, pace)


## Tells the blob what this player is doing. Everything but stumbling and overheating can be seen
## from the world state on every peer; for other players those two are estimated or left out.
func _animate_blob(dt: float, pace: float) -> void:
	var held: Node3D = _world.held_by(peer_id)
	var bike: Node3D = _world.ridden_by(peer_id)
	var suited: bool = _world.worn_by(peer_id) != null
	var air := not is_on_floor()
	if not is_local:
		_air_hold = 0.12 if absf(velocity_estimate.y) > 1.2 else _air_hold - dt
		air = _air_hold > 0.0
		if suited or _world.temp_at(position) <= HEAT_SAFE:   # same sums as _feel_heat
			_exp_est = maxf(0.0, _exp_est - dt / 20.0)
		else:
			_exp_est = minf(_exp_est + dt * (_world.temp_at(position) - HEAT_SAFE) / HEAT_SCALE, 1.0)
	var st := {"speed": pace, "vel": velocity_estimate, "vy": velocity_estimate.y, "air": air,
			"pitch": head.rotation.x, "suit": suited, "ride": -1.0,
			"exposure": exposure if is_local else _exp_est,
			"stumble": 1.0 if (is_local and _stumble > 0.0) else 0.0,
			"cable": is_local and not _cable.is_empty()}
	if held:
		st["held"] = held.def
	if bike:
		var watts: float = bike.def["gen"]["watts"]
		st["ride"] = clampf(bike.load / watts, 0.0, 1.0)
		st["ride_yaw"] = wrapf(bike.global_rotation.y - global_rotation.y, -PI, PI)
		st["speed"] = 0.0
	_blob.animate(dt, st)
	if held and not is_local:   # the item sits between the character's hands
		hand.global_transform = _blob.global_transform * _blob.carry_xf()


func _move(dt: float) -> void:
	var active := _active() and not Net.test_mode
	var dir := Vector3.ZERO
	if position.y < -20.0:   # fell out of the world
		position = _spawn
		velocity = Vector3.ZERO
	var bike: Node3D = _world.ridden_by(peer_id)
	if bike:   # pedalling: stuck to the saddle until we hop off
		position = bike.global_position + Vector3(0, 0.1, 0)
		velocity = Vector3.ZERO
		return
	_feel_heat(dt)
	var suited: bool = _world.worn_by(peer_id) != null
	var speed := WALK * (0.75 if suited else 1.0)
	if Net.bot:
		_bot(dt)
		dir = -transform.basis.z
	elif active and _stumble <= 0.0:
		var i := Input.get_vector("left", "right", "fwd", "back")
		dir = (transform.basis * Vector3(i.x, 0, i.y)).normalized()
		if Input.is_action_pressed("sprint"):
			speed = SPRINT * (0.75 if suited else 1.0)
	# Running across a cable on the floor yanks it out. Walking is always safe.
	_stumble -= dt
	_trip_wait -= dt
	if _trip_wait <= 0.0 and is_on_floor() and Vector2(velocity.x, velocity.z).length() > WALK + 0.8:
		var cable: Array = _world.cables.tripped_by(position)
		if not cable.is_empty():
			_world.request_trip(cable[0], cable[1])
			_trip_wait = 1.5
			_stumble = 0.45
			velocity *= 0.15
			head.rotation.x = maxf(head.rotation.x - 0.6, -1.4)   # face first
	var accel := (40.0 if is_on_floor() else 8.0) * dt
	velocity.x = move_toward(velocity.x, dir.x * speed, accel)
	velocity.z = move_toward(velocity.z, dir.z * speed, accel)
	if not is_on_floor():
		velocity.y -= GRAVITY * dt
	elif active and Input.is_action_just_pressed("jump"):
		velocity.y = JUMP
	move_and_slide()


## Hot rooms wear you down. Without a heat suit you eventually pass out and wake up outside.
func _feel_heat(dt: float) -> void:
	var room: float = _world.temp_at(position)
	if room > HEAT_SAFE and _world.worn_by(peer_id) == null:
		exposure += dt * (room - HEAT_SAFE) / HEAT_SCALE
	else:
		exposure = maxf(0.0, exposure - dt / 20.0)
	if exposure >= 1.0:
		exposure = 0.4
		if _world.held_by(peer_id):
			_world.request_release(false)
		_set_cable({})
		position = Vector3(randf_range(-1.5, 1.5), 0.1, 6.5)   # the driveway
		velocity = Vector3.ZERO
		_world.request_fainted()
	_world.hud.set_exposure(exposure)


func _bot(dt: float) -> void:
	rotation.y += dt * 1.2
	var before := _bot_t
	_bot_t += dt
	if before < 1.0 and _bot_t >= 1.0:
		var nearest: Node3D = null
		for it: Node3D in _world.items.values():
			if nearest == null or position.distance_to(it.position) < position.distance_to(nearest.position):
				nearest = it
		if nearest:
			_world.request_grab(nearest.id)
	elif before < 2.5 and _bot_t >= 2.5:
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
	_place_xf = null
	if not _cable.is_empty() and (held or not _world.items.has(_cable["id"])):
		_set_cable({})
	var bike: Node3D = _world.ridden_by(peer_id)
	if bike:
		acts.append(["use", "[Q] Hop off", _world.request_use.bind(bike.id)])
		acts.append(["", "Pedalling: %d / %d W" % [bike.load, bike.def["gen"]["watts"]], Callable()])
	elif not _cable.is_empty():
		var type: String = _cable["type"]
		if t and t.provides == type:
			if _world.sockets_used(t.id, type) < t.sockets:
				acts.append(["throw", "[Click] Plug into %s" % t.label.to_lower(), _plug.bind(t.id)])
			else:
				acts.append(["", "%s is full" % t.label, Callable()])
		else:
			acts.append(["", "Holding a %s. Find somewhere to plug it in." % WORDS[type], Callable()])
		acts.append([type, "[%s] Let go" % KEYS[type], _set_cable.bind({})])
	elif held:
		if held.kind == "fuel" and t is RigidBody3D and t.def.get("gen", {}).get("kind", "") == "fuel":
			acts.append(["interact", "[E] Refuel %s (%d%% full)" % [t.label.to_lower(), t.fuel * 100.0],
					_world.request_refuel.bind(t.id)])
		elif held.kind == "bucket" and t and t.get("kind") == "tap":
			acts.append(["interact", "[E] Fill the bucket", _world.request_bucket.bind(t.id)])
		elif held.kind == "bucket" and held.fuel > 0.0 and t is RigidBody3D and t.def.has("tank"):
			acts.append(["interact", "[E] Pour into the reservoir (%d%% full)" % (t.fuel * 100.0), _world.request_bucket.bind(t.id)])
		elif held.def.get("tool", "") == "screwdriver" and t is RigidBody3D and t.def.get("lid", false):
			if t.is_loose():
				acts.append(["interact", "[E] %s" % ("Screw the lid back on" if t.opened else "Unscrew the lid"),
						_world.request_lid.bind(t.id)])
			else:
				acts.append(["", "Take it out of the rack before opening it", Callable()])
		else:
			# Parts snap into a free slot of the machine (or rack) you are looking into.
			var mount := _mount_spot(held, t)
			if mount.size() == 2:
				_place_xf = mount[0].global_transform * (mount[0].def["slots"][mount[1]]["xf"] as Transform3D)
				acts.append(["interact", "[E] Install in the %s" % mount[0].label.to_lower(),
						_world.request_attach.bind(mount[0].id, mount[1])])
			elif mount.size() == 1:
				acts.append(["", mount[0], Callable()])
			if _place_xf == null:
				_place_xf = _placement(held)
			if mount.size() == 2:
				pass
			elif _place_xf != null:
				acts.append(["interact", "[E] Place here", _place])
				acts.append(["rotate", "[R] Rotate", _rotate])
			else:
				acts.append(["interact", "[E] Drop", _world.request_release.bind(false)])
		if held.kind == "extinguisher" and t is RigidBody3D and t.on_fire():
			acts.append(["throw", "[Click] Put out the fire", _world.request_extinguish.bind(t.id)])
		else:
			acts.append(["throw", "[Click] Throw", _world.request_release.bind(true)])
	elif t is RigidBody3D:
		if t.on_fire():
			acts.append(["", "ON FIRE. Get a fire extinguisher!", Callable()])
		acts.append(["interact", "[E] %s %s" % ["Pull out" if t.parent != 0 else "Pick up", t.label.to_lower()],
				_world.request_grab.bind(t.id)])
		for type: String in ["power", "net", "coolant"]:
			if not t.def.get(type + "_port", false):
				continue
			if t.link(type) != 0:
				var warning := "  (FULL: it will spill!)" if type == "coolant" and t.hose > 0.3 else ""
				acts.append([type, "[%s] Unplug %s%s" % [KEYS[type], WORDS[type], warning], _world.request_link.bind(t.id, type, 0)])
			else:
				acts.append([type, "[%s] Grab %s" % [KEYS[type], WORDS[type]],
						_set_cable.bind({"id": t.id, "type": type})])
		if t.kind == "parcel":
			acts.append(["use", "[Q] Unpack", _world.request_unpack.bind(t.id)])
		if t.def.get("wear", false) and _world.worn_by(peer_id) == null:
			acts.append(["use", "[Q] Put on the heat suit", _world.request_use.bind(t.id)])
		if t.def.has("pump"):
			acts.append(["use", "[Q] Switch the pump %s" % ("off" if t.running else "on"), _world.request_use.bind(t.id)])
			if not t.running:
				acts.append(["rotate", "[R] Drain the hoses back into the reservoir", _world.request_drain.bind(t.id)])
			var moving := "Water is moving" if t.status == 3 else ("Switched on but nothing is moving" if t.running else "Off")
			var reading := "Coolant at %d °C" % t.heat if _world.loop_measured(t.id) \
					else "No coolant sensor on this loop: temperature unknown"
			acts.append(["", "%s. %s" % [moving, reading], Callable()])
		if t.def.has("tank"):
			acts.append(["", "Reservoir %d%% full%s" % [ceilf(t.fuel * 100.0),
					"   kept full by the tap" if t.coolant_to < 0 else "   (bucket, or hose it to a tap)"], Callable()])
		if t.kind == "bucket":
			acts.append(["", "Full of water" if t.fuel > 0.0 else "Empty: fill it at a garden tap", Callable()])
		if t.def.has("psu"):
			_machine_lines(t, acts)
		if t.broken:
			acts.append(["", "Water damage. It will never work again.", Callable()])
		if t.def.has("gen"):
			_generator_actions(t, acts)
		if t.def.get("feeds", false) or t.def.get("bus", false):
			var where: Array = _world.circuits().get(_world.circuit_at(t.global_position), [])
			if where.is_empty():
				acts.append(["", "Not inside a building of yours: it does nothing here", Callable()])
			elif t.def.get("feeds", false):
				acts.append(["", "Feeds %s" % where[1] if t.status == 3 else "Cable it to a running generator to power %s" % where[1], Callable()])
			else:
				acts.append(["", "Live" if t.status == 3 else "Dead: %s has no power coming in" % where[1], Callable()])
		if t.provides != "":
			acts.append(["", "%d/%d sockets used" % [_world.sockets_used(t.id, t.provides), t.sockets], Callable()])
	elif t:
		match t.kind:
			"shop":
				acts.append(["interact", "[E] Open the parts market", _world.hud.open_shop])
			"neighbour":
				acts.append(["interact", "[E] Talk to %s about buying their house" % t.label, _world.hud.open_offer.bind(t.house)])
			"hdoor":
				var home: Node3D = _world.houses[t.house]
				if home.state == 0:
					acts.append(["", "Locked. This is the house of %s." % home.lot["name"], Callable()])
				else:
					acts.append(["interact", "[E] %s the door" % ("Close" if home.door_open else "Open"),
							_world.request_house_door.bind(t.house)])
			"deed":
				acts.append(["interact", "[E] Demolish this house (press twice)", _world.request_demolish.bind(t.house)])
			"bin":
				acts.append(["interact", "[E] Empty the dumpster. Everything in it is gone for good.", _world.request_empty_bin])
			"door":
				acts.append(["interact", "[E] %s the garage door" % ("Close" if _world.door_open else "Open"),
						_world.request_door])
			"breaker":
				var limit: float = _world.circuits().get(t.circuit, [0.0])[0]
				if _world.tripped_circuits.has(t.circuit):
					acts.append(["interact", "[E] Reset the breaker", _world.request_breaker.bind(t.circuit)])
				else:
					acts.append(["", "Breaker box: this building's wiring carries up to %d W.\nIt has no power of its own: cable a power inlet to a generator." % limit, Callable()])
			_:
				acts.append(["", "%s: %d/%d sockets used" % [t.label, _world.sockets_used(t.id, t.provides), t.sockets], Callable()])
	if _world.worn_by(peer_id) != null:   # Q takes the suit off unless Q already does something here
		var busy := false
		for act: Array in acts:
			busy = busy or act[0] == "use"
		if not busy:
			acts.append(["use", "[Q] Take off the heat suit", _world.request_unwear])
	_acts = acts
	var lines: Array[String] = []
	for act: Array in acts:
		lines.append(act[1])
	_world.hud.set_prompt("\n".join(lines))
	_world.hud.set_temp(_world.temp_at(position), _world.temp_known_at(position))
	_ghost.visible = _place_xf != null
	if _place_xf != null:
		(_ghost.mesh as BoxMesh).size = held.def["size"]
		_ghost.global_transform = _place_xf


## Where the held item would sit if placed now: flat on the surface under the crosshair,
## front towards the player. Null when not looking at a surface you can put things on.
func _placement(held: Node3D) -> Variant:
	if not _ray.is_colliding():
		return null
	var size: Vector3 = held.def["size"]
	var normal := _ray.get_collision_normal()
	if absf(normal.y) < 0.3 and held.def.get("wall", false):   # mount it flat on the wall, facing out
		normal.y = 0.0
		normal = normal.normalized()
		var turned := Basis.looking_at(normal).rotated(normal, _place_turns * PI * 0.5)
		return Transform3D(turned, _ray.get_collision_point() + normal * (size.z * 0.5 + 0.005))
	if normal.y < 0.7:
		return null
	var basis := Basis(Vector3.UP, rotation.y + PI + _place_turns * PI * 0.5)
	var point := _ray.get_collision_point() + Vector3.UP * (size.y * 0.5 + 0.01)
	# If it would stick into a wall or another object, slide it back towards us until it fits.
	var back := global_position - point
	back.y = 0.0
	back = back.normalized()
	var shape := BoxShape3D.new()
	shape.size = size * 0.96
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1 | 2
	var space := get_world_3d().direct_space_state
	for step in 14:
		query.transform = Transform3D(basis, point + back * step * 0.05)
		if space.intersect_shape(query, 1).is_empty():
			return query.transform
	return null


## Where the held part would be installed: [machine, slot index] when the crosshair is near a
## free slot that takes it, [reason] when it would fit here but something is in the way,
## [] when the thing under the crosshair is not somewhere this part mounts at all.
func _mount_spot(held: Node3D, t: Node3D) -> Array:
	if not (t is RigidBody3D):
		return []
	var machine: Node3D = t if t.def.has("slots") else _world.items.get(t.parent)
	if machine == null or machine == held or not machine.def.has("slots"):
		return []
	var group: String = held.def.get("group", "")
	var takes := false
	for slot: Dictionary in machine.def["slots"]:
		takes = takes or slot["accepts"] == group
	if not takes:
		return []
	var problem: String = _world.attach_problem(held, machine)
	if problem != "":
		return [problem]
	var spot: int = _world.free_slot(machine, group, _ray.get_collision_point(), 0.7 if group == "server" else 0.25)
	return [machine, spot] if spot >= 0 else ["Aim at an empty %s slot" % Catalog.GROUP_NAMES.get(group, group)]


## What a machine says about itself when you look at it.
func _machine_lines(t: Node3D, acts: Array) -> void:
	var parts: Array = []
	for other: Node3D in _world.items.values():
		if other.parent == t.id:
			parts.append(other)
	var report: Dictionary = Sim.machine_report(t, parts)
	if report["boots"]:
		acts.append(["", "%.1f tokens/s   %d of %d W   RAM %d of %d GB   chips %d °C%s" % [report["tokens"],
				report["watts"], t.def["psu"], report["ram_used"], report["ram"], t.heat,
				"   THROTTLING" if t.heat >= 85.0 else ""], Callable()])
	else:
		acts.append(["", "Will not boot: %s" % report["why"], Callable()])
	for note: String in report["notes"]:
		acts.append(["", note, Callable()])
	acts.append(["", "The lid is off: parts go in and out" if t.opened else "Lid screwed on: a screwdriver opens it", Callable()])


func _place() -> void:
	_world.request_place(_place_xf)


func _rotate() -> void:
	_place_turns += 1


func _generator_actions(t: Node3D, acts: Array) -> void:
	var gen: Dictionary = t.def["gen"]
	var output := "%d / %d W" % [t.load, gen["watts"]]
	match gen["kind"]:
		"pedal":
			if t.rider == 0:
				acts.append(["use", "[Q] Hop on and pedal", _world.request_use.bind(t.id)])
			else:
				acts.append(["", "%s is pedalling: %s" % [_world.name_of(t.rider), output], Callable()])
		"fuel":
			if t.running:
				acts.append(["use", "[Q] Switch off", _world.request_use.bind(t.id)])
			elif t.fuel > 0.0:
				acts.append(["use", "[Q] Start it up", _world.request_use.bind(t.id)])
			acts.append(["", "Fuel %d%%   %s" % [ceilf(t.fuel * 100.0), output] if t.fuel > 0.0
					else "Out of fuel: bring a jerry can", Callable()])
		"solar":
			var state: Dictionary = Catalog.WEATHER[_world.weather]
			if not _world.is_outdoors(t.global_position):
				acts.append(["", "Solar panels need to be outdoors", Callable()])
			else:
				acts.append(["", "%s: %d / %d W" % [state["name"], t.load, gen["watts"] * state["solar"]], Callable()])


func _set_cable(cable: Dictionary) -> void:
	_cable = cable
	_world.preview = cable


func _plug(provider_id: int) -> void:
	_world.request_link(_cable["id"], _cable["type"], provider_id)
	_set_cable({})
