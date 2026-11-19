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
var power_to := 0
var net_to := 0
var status := -1        # bit 0 powered, bit 1 online; set by the host's simulation

var _world: Node3D
var _leds: Array = []
var _target_pos := Vector3.ZERO
var _target_rot := Quaternion.IDENTITY
var _has_target := false


func setup(p_id: int, p_kind: String) -> void:
	id = p_id
	kind = p_kind
	def = Catalog.ITEMS[kind]
	label = def["label"]
	provides = def.get("provides", "")
	sockets = def.get("sockets", 0)
	mass = def["mass"]
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
	for mat: StandardMaterial3D in _leds:
		Catalog.set_light(mat, 2 if bits == 3 else (1 if bits & 1 else 0))


func release(xf: Transform3D, vel: Vector3) -> void:
	holder = 0
	parent = 0
	global_transform = xf
	apply_mode()
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
func apply_mode() -> void:
	_has_target = false
	freeze = not is_loose() or not multiplayer.is_server()
	collision_layer = 2 if is_loose() else (4 if holder == 0 else 0)
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
	elif freeze and _has_target:
		var k := 1.0 - exp(-20.0 * dt)
		position = position.lerp(_target_pos, k)
		quaternion = quaternion.slerp(_target_rot, k)
