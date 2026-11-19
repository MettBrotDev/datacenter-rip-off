extends RigidBody3D
## A physical object. Exactly one of three states:
##   loose     simulated by the host; clients keep it frozen and follow the host's transforms
##   held      glued to a player's hand (holder = peer id)
##   attached  mounted in a slot of another item (parent = item id), e.g. GPU on a server
## It may also have a power and a network cable plugged into a provider (item id > 0, fixture id < 0).

const Catalog = preload("res://scripts/catalog.gd")

var id := 0
var kind := ""
var def: Dictionary = {}
var label := ""
var provides := ""      # "power" | "net" | "" — what others can plug into this
var sockets := 0
var holder := 0
var parent := 0
var slot := 0
var pinned := false     # placed deliberately: stays exactly put (no physics) until grabbed or unsupported
var power_to := 0
var net_to := 0
var status := -1        # bit 0 powered, bit 1 online; set by the host's simulation
# generators only (the host simulates these and replicates them twice a second)
var running := false    # fuel generators: switched on
var fuel := 0.0         # 0..1 tank level
var rider := 0          # bike generator: peer id pedalling it
var load := 0.0         # watts currently drawn from it

var _world: Node3D
var _leds: Array = []
var _light: OmniLight3D   # lamps only
var _target_pos := Vector3.ZERO
var _target_rot := Quaternion.IDENTITY
var _has_target := false
var _pin_xf := Transform3D.IDENTITY


func setup(p_id: int, p_kind: String) -> void:
	id = p_id
	kind = p_kind
	def = Catalog.ITEMS[kind]
	label = def["label"]
	provides = def.get("provides", "")
	sockets = def.get("sockets", 0)
	mass = def["mass"]
	if def.get("gen", {}).get("kind", "") == "fuel":
		fuel = 0.3   # sold with a splash in the tank
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	continuous_cd = true
	for s: Array in def.get("shapes", [[def["size"], Vector3.ZERO]]):
		var box := BoxShape3D.new()
		box.size = s[0]
		var shape := CollisionShape3D.new()
		shape.shape = box
		shape.position = s[1]
		add_child(shape)
	for tagged: Array in Catalog.build_parts(self, def["parts"]):
		_leds.append(tagged[1])
	if def.get("light", false):
		_light = OmniLight3D.new()
		_light.position.y = def["size"].y * 0.4
		_light.light_color = Color(1.0, 0.9, 0.75)
		_light.light_energy = 2.2
		_light.omni_range = 9.0
		_light.distance_fade_enabled = true
		_light.distance_fade_begin = 30.0
		_light.distance_fade_length = 10.0
		add_child(_light)
	set_status(0)


func _ready() -> void:
	_world = get_parent().get_parent()
	apply_mode()


func is_loose() -> bool:
	return holder == 0 and parent == 0


func link(type: String) -> int:
	return power_to if type == "power" else net_to


func set_link(type: String, to: int) -> void:
	if type == "power":
		power_to = to
	else:
		net_to = to


## Where this item's own cable of the given type leaves it (world space).
func port_pos(type: String) -> Vector3:
	var size: Vector3 = def["size"]
	return global_transform * Vector3(size.x * (-0.3 if type == "power" else 0.3), 0, size.z * 0.5)


func set_status(bits: int) -> void:
	if bits == status:
		return
	status = bits
	if _light:
		_light.visible = bits == 3
	for mat: StandardMaterial3D in _leds:
		Catalog.set_light(mat, 2 if bits == 3 else (1 if bits & 1 else 0))


func release(xf: Transform3D, vel: Vector3, pin := false) -> void:
	holder = 0
	parent = 0
	pinned = pin
	_pin_xf = xf
	global_transform = xf
	apply_mode()
	# Tell the physics engine directly as well: a body that was being carried a moment ago
	# otherwise gets its old hand position written back over the new one.
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	if not freeze:
		linear_velocity = vel
		angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4)) \
				* clampf(vel.length() / 6.0, 0.0, 1.0)
		sleeping = false


func net_target(pos: Vector3, rot: Quaternion) -> void:
	_target_pos = pos
	_target_rot = rot
	_has_target = true


## Call after changing holder/parent. Layer 2 = loose, layer 4 = attached (ray-only), 0 = held.
## Loose items collide with the world and each other (mask 3), never with players.
func apply_mode() -> void:
	_has_target = false
	freeze = not is_loose() or pinned or not multiplayer.is_server()
	var loose_layer := 2 | (16 if def.get("solid", false) else 0)   # 16 = players cannot walk through
	collision_layer = loose_layer if is_loose() else (4 if holder == 0 else 0)
	collision_mask = 3 if is_loose() else 0


func _process(dt: float) -> void:
	if holder != 0:
		var p: Node3D = _world.player(holder)
		if p:
			global_transform = p.hand.global_transform
	elif parent != 0:
		var par: Node3D = _world.items.get(parent)
		if par:
			var slots: Dictionary = par.def["slots"]
			var local := Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(slots["yaw"]), 0)), slots["at"][slot])
			global_transform = par.global_transform * local
	elif pinned:
		if not global_transform.is_equal_approx(_pin_xf):
			global_transform = _pin_xf
	elif freeze and _has_target:
		var k := 1.0 - exp(-20.0 * dt)
		position = position.lerp(_target_pos, k)
		quaternion = quaternion.slerp(_target_rot, k)
