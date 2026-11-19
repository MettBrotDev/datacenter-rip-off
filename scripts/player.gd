extends CharacterBody3D
## One player. The owning peer simulates movement and broadcasts it through Net;
## everyone else interpolates towards the last received state.

const Blob = preload("res://scripts/blob.gd")
const WALK := 4.0
const SPRINT := 6.5
const JUMP := 4.6
const GRAVITY := 13.0
const SENS := 0.0022

var peer_id := 1
var is_local := false
var head: Node3D          # pitch pivot at eye height
var hand: Marker3D        # where a carried item sits
var velocity_estimate := Vector3.ZERO

var _world: Node3D
var _blob: Node3D
var _ray: RayCast3D
var _tick := 0
var _last_pos := Vector3.ZERO


func _ready() -> void:
	_world = get_parent().get_parent()
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
		var cam := Camera3D.new()
		cam.fov = 70.0
		cam.near = 0.05
		head.add_child(cam)
		cam.make_current()
		_ray = RayCast3D.new()
		_ray.target_position = Vector3(0, 0, -3.0)
		_ray.collision_mask = 3
		_ray.add_exception(self)
		head.add_child(_ray)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
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


func _unhandled_input(e: InputEvent) -> void:
	if not is_local or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if e is InputEventMouseMotion:
		rotation.y -= e.relative.x * SENS
		head.rotation.x = clampf(head.rotation.x - e.relative.y * SENS, -1.5, 1.5)
	elif e.is_action_pressed("interact"):
		if _world.held_by(peer_id):
			_world.request_release(false)
		else:
			var it := _look_item()
			if it:
				_world.request_grab(it.id)
	elif e.is_action_pressed("throw") and _world.held_by(peer_id):
		_world.request_release(true)


func _physics_process(dt: float) -> void:
	if is_local:
		_move(dt)
		_tick += 1
		if _tick % 2 == 0:
			Net.send_state(position, rotation.y, head.rotation.x)
		_update_prompt()
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


func _look_item() -> Node3D:
	if _ray.is_colliding():
		var c := _ray.get_collider() as RigidBody3D
		if c and c.has_method("set_holder") and c.holder == 0:
			return c
	return null


func _update_prompt() -> void:
	var held: Node3D = _world.held_by(peer_id)
	if held:
		_world.hud.set_prompt("[E] Put down   [Click] Throw")
	else:
		var it := _look_item()
		_world.hud.set_prompt("[E] Pick up %s" % it.label if it else "")
