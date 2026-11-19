extends Node3D
## The player's body: a glossy bean with sleepy eyes, stubby limbs and a waddle.
## Origin at the feet, facing -Z.

var _body: Node3D
var _legs: Array[Node3D] = []
var _arms: Array[Node3D] = []
var _phase := 0.0
var _time := 0.0


func setup(color: Color) -> void:
	var skin := StandardMaterial3D.new()
	skin.albedo_color = color
	skin.roughness = 0.3
	skin.rim_enabled = true
	skin.rim = 0.5
	skin.rim_tint = 0.5
	var white := _flat(Color(0.97, 0.97, 0.97), 0.15)
	var black := _flat(Color(0.03, 0.03, 0.04), 0.1)
	var lid := _flat(color.lerp(Color(0.5, 0.35, 0.65), 0.55), 0.4)

	_body = Node3D.new()
	_body.position.y = 0.3
	add_child(_body)
	var torso := _capsule(0.36, 1.25, skin)
	torso.position.y = 0.6
	torso.scale.z = 0.88
	_body.add_child(torso)

	for side: float in [-1.0, 1.0]:
		var eye := _sphere(0.095, white)
		eye.position = Vector3(0.14 * side, 0.93, -0.27)
		_body.add_child(eye)
		var pupil := _sphere(0.045, black)
		pupil.position = Vector3(0.01 * -side, -0.012, -0.062)
		eye.add_child(pupil)
		var cap := SphereMesh.new()
		cap.radius = 0.102
		cap.height = 0.102
		cap.is_hemisphere = true
		cap.material = lid
		var cap_node := MeshInstance3D.new()
		cap_node.mesh = cap
		cap_node.position.y = 0.012
		cap_node.rotation = Vector3(0.3, 0, 0.18 * side)
		eye.add_child(cap_node)

		var arm := Node3D.new()
		arm.position = Vector3(0.36 * side, 0.72, 0)
		arm.rotation.z = 0.3 * side
		_body.add_child(arm)
		var arm_mesh := _capsule(0.085, 0.42, skin)
		arm_mesh.position.y = -0.15
		arm.add_child(arm_mesh)
		_arms.append(arm)

		var leg := Node3D.new()
		leg.position = Vector3(0.16 * side, 0.4, 0)
		add_child(leg)
		var leg_mesh := _capsule(0.13, 0.44, skin)
		leg_mesh.position.y = -0.18
		leg.add_child(leg_mesh)
		_legs.append(leg)


## speed: horizontal m/s, pitch: head pitch in radians (up is positive).
func animate(dt: float, speed: float, pitch: float) -> void:
	_time += dt
	_phase += dt * speed * 2.8
	var amp := clampf(speed / 3.0, 0.0, 1.2)
	var s := sin(_phase)
	_legs[0].rotation.x = s * 0.8 * amp
	_legs[1].rotation.x = -s * 0.8 * amp
	_arms[0].rotation.x = -s * 0.6 * amp
	_arms[1].rotation.x = s * 0.6 * amp
	_body.rotation.z = s * 0.08 * amp
	_body.rotation.x = pitch * 0.25
	_body.position.y = 0.3 + absf(cos(_phase)) * 0.04 * amp
	_body.scale.y = 1.0 + sin(_time * 2.0) * 0.012


func _flat(color: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m


func _capsule(radius: float, height: float, mat: Material) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _sphere(radius: float, mat: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi
