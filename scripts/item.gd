extends RigidBody3D
## A physical object players can carry and throw.
## The host simulates it; clients keep it frozen and follow the host's transforms.
## While held it is frozen everywhere and glued to the holder's hand.

# Each part: [box size, offset, colour, emission energy]
const KINDS := {
	"crate": {"label": "Cardboard box", "size": Vector3(0.45, 0.35, 0.4), "mass": 1.5, "parts": [
		[Vector3(0.45, 0.35, 0.4), Vector3.ZERO, Color(0.72, 0.55, 0.36), 0.0],
		[Vector3(0.46, 0.01, 0.07), Vector3(0, 0.172, 0), Color(0.86, 0.79, 0.62), 0.0],
	]},
	"gpu": {"label": "GPU", "size": Vector3(0.3, 0.05, 0.13), "mass": 1.0, "parts": [
		[Vector3(0.3, 0.05, 0.13), Vector3.ZERO, Color(0.11, 0.11, 0.13), 0.0],
		[Vector3(0.3, 0.012, 0.012), Vector3(0, 0.026, 0.06), Color(0.2, 1.0, 0.5), 2.5],
		[Vector3(0.09, 0.006, 0.09), Vector3(-0.08, 0.027, -0.005), Color(0.4, 0.42, 0.46), 0.0],
		[Vector3(0.09, 0.006, 0.09), Vector3(0.06, 0.027, -0.005), Color(0.4, 0.42, 0.46), 0.0],
	]},
	"server": {"label": "Server", "size": Vector3(0.48, 0.09, 0.6), "mass": 6.0, "parts": [
		[Vector3(0.48, 0.09, 0.6), Vector3.ZERO, Color(0.1, 0.1, 0.13), 0.0],
		[Vector3(0.42, 0.012, 0.01), Vector3(0, 0.02, -0.301), Color(0.7, 0.4, 1.0), 3.0],
		[Vector3(0.02, 0.02, 0.01), Vector3(0.2, -0.02, -0.301), Color(0.2, 1.0, 0.5), 3.0],
	]},
	"powerstrip": {"label": "Power strip", "size": Vector3(0.4, 0.045, 0.07), "mass": 0.6, "parts": [
		[Vector3(0.4, 0.045, 0.07), Vector3.ZERO, Color(0.9, 0.9, 0.87), 0.0],
		[Vector3(0.03, 0.02, 0.04), Vector3(-0.17, 0.025, 0), Color(1.0, 0.15, 0.1), 2.0],
		[Vector3(0.04, 0.004, 0.04), Vector3(-0.08, 0.023, 0), Color(0.15, 0.15, 0.17), 0.0],
		[Vector3(0.04, 0.004, 0.04), Vector3(0.0, 0.023, 0), Color(0.15, 0.15, 0.17), 0.0],
		[Vector3(0.04, 0.004, 0.04), Vector3(0.08, 0.023, 0), Color(0.15, 0.15, 0.17), 0.0],
		[Vector3(0.04, 0.004, 0.04), Vector3(0.16, 0.023, 0), Color(0.15, 0.15, 0.17), 0.0],
	]},
}

var id := 0
var kind := ""
var label := ""
var holder := 0     # peer id carrying this item, 0 = nobody

var _world: Node3D
var _target_pos := Vector3.ZERO
var _target_rot := Quaternion.IDENTITY
var _has_target := false


func setup(p_id: int, p_kind: String) -> void:
	id = p_id
	kind = p_kind
	var def: Dictionary = KINDS[kind]
	label = def["label"]
	mass = def["mass"]
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	continuous_cd = true
	var box := BoxShape3D.new()
	box.size = def["size"]
	var shape := CollisionShape3D.new()
	shape.shape = box
	add_child(shape)
	for part: Array in def["parts"]:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = part[2]
		mat.roughness = 0.6
		if part[3] > 0.0:
			mat.emission_enabled = true
			mat.emission = part[2]
			mat.emission_energy_multiplier = part[3]
		var mesh := BoxMesh.new()
		mesh.size = part[0]
		mesh.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = part[1]
		add_child(mi)


func _ready() -> void:
	_world = get_parent().get_parent()
	_apply_mode()


func set_holder(peer: int) -> void:
	holder = peer
	_has_target = false
	_apply_mode()


func release(xf: Transform3D, vel: Vector3) -> void:
	holder = 0
	global_transform = xf
	_apply_mode()
	if not freeze:
		linear_velocity = vel
		angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4)) \
				* clampf(vel.length() / 6.0, 0.0, 1.0)
		sleeping = false


func net_target(pos: Vector3, rot: Quaternion) -> void:
	_target_pos = pos
	_target_rot = rot
	_has_target = true


func _apply_mode() -> void:
	freeze = holder != 0 or not multiplayer.is_server()
	collision_layer = 0 if holder != 0 else 2
	collision_mask = 0 if holder != 0 else 3


func _process(dt: float) -> void:
	if holder != 0:
		var p: Node3D = _world.player(holder)
		if p:
			global_transform = p.hand.global_transform
	elif freeze and _has_target:
		var k := 1.0 - exp(-20.0 * dt)
		position = position.lerp(_target_pos, k)
		quaternion = quaternion.slerp(_target_rot, k)
