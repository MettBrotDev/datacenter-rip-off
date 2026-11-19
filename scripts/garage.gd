extends Node3D
## The starting location: a brick garage, 9 x 7 m. Built entirely from code.

const Fixture = preload("res://scripts/fixture.gd")
const W := 9.0
const D := 7.0
const H := 3.0

var fixtures: Dictionary = {}   # fixture id -> Fixture

var _body: StaticBody3D
var _env: Environment


func _ready() -> void:
	_body = StaticBody3D.new()
	add_child(_body)
	_environment()

	var brick := ShaderMaterial.new()
	brick.shader = preload("res://shaders/brick.gdshader")
	var concrete := _mat(Color(0.6, 0.57, 0.52), 0.9)
	var wood := _mat(Color(0.3, 0.18, 0.1), 0.8)
	var metal := _mat(Color(0.45, 0.47, 0.5), 0.45)
	var door := _mat(Color(0.8, 0.82, 0.84), 0.6)
	var groove := _mat(Color(0.5, 0.52, 0.55), 0.7)

	# shell
	_box(Vector3(W + 2, 1, D + 2), Vector3(0, -0.5, 0), concrete)
	_box(Vector3(W + 2, 1, D + 2), Vector3(0, H + 0.5, 0), wood)
	_box(Vector3(W + 2, H, 1), Vector3(0, H / 2, -D / 2 - 0.5), brick)
	_box(Vector3(W + 2, H, 1), Vector3(0, H / 2, D / 2 + 0.5), brick)
	_box(Vector3(1, H, D), Vector3(-W / 2 - 0.5, H / 2, 0), brick)
	_box(Vector3(1, H, D), Vector3(W / 2 + 0.5, H / 2, 0), brick)
	for x: float in [-3.0, -1.0, 1.0, 3.0]:
		_box(Vector3(0.16, 0.22, D), Vector3(x, H - 0.11, 0), wood, false)

	# roller door on the back wall
	_box(Vector3(3.4, 2.5, 0.06), Vector3(0, 1.25, D / 2 - 0.03), door, false)
	for i in 6:
		_box(Vector3(3.4, 0.02, 0.07), Vector3(0, 0.4 + i * 0.4, D / 2 - 0.03), groove, false)

	# workbench along the left wall
	_box(Vector3(0.75, 0.06, 2.4), Vector3(-W / 2 + 0.4, 0.9, -1.0), wood)
	for z: float in [-2.1, 0.1]:
		_box(Vector3(0.7, 0.87, 0.08), Vector3(-W / 2 + 0.4, 0.435, z), wood)
	_box(Vector3(0.03, 0.03, 2.2), Vector3(-W / 2 + 0.03, 1.7, -1.0), _glow(Color(0.1, 0.8, 1.0), 1.8), false)

	# metal shelf on the right wall
	for y: float in [0.45, 1.05, 1.65]:
		_box(Vector3(0.7, 0.04, 1.8), Vector3(W / 2 - 0.37, y, -1.5), metal)
	for z: float in [-2.38, -0.62]:
		for x: float in [W / 2 - 0.7, W / 2 - 0.04]:
			_box(Vector3(0.04, 1.9, 0.04), Vector3(x, 0.95, z), metal, false)

	# things players interact with (ids are fixed: host and clients must agree)
	_fixture(-1, "outlet", Vector3(-W / 2, 0.4, 1.6), 90)
	_fixture(-2, "outlet", Vector3(W / 2, 0.4, 0.6), -90)
	_fixture(-3, "router", Vector3(1.6, 1.5, -D / 2), 0)
	_fixture(-4, "breaker", Vector3(-2.4, 1.45, -D / 2), 0)
	_fixture(-5, "shop", Vector3(-W / 2 + 0.38, 0.93, -1.0), 90)

	_lamp(Vector3(-2.2, H, 0.3), true)
	_lamp(Vector3(2.2, H, 0.3), false)


func _fixture(id: int, kind: String, pos: Vector3, yaw: float) -> void:
	var f := Fixture.new()
	f.setup(id, kind)
	f.position = pos
	f.rotation.y = deg_to_rad(yaw)
	add_child(f)
	fixtures[id] = f


func _environment() -> void:
	var env := Environment.new()
	_env = env
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1.0, 0.9, 0.8)
	env.ambient_light_energy = 0.4
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.08
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var settings := get_node_or_null("/root/Settings")
	if settings:
		settings.changed.connect(_apply_settings.bind(settings))
		_apply_settings(settings)


func _apply_settings(settings: Node) -> void:
	_env.glow_enabled = settings.glow
	_env.ssao_enabled = settings.ssao


func _lamp(top: Vector3, shadows: bool) -> void:
	var cord := CylinderMesh.new()
	cord.top_radius = 0.008
	cord.bottom_radius = 0.008
	cord.height = 0.6
	_mesh(cord, top - Vector3(0, 0.3, 0), _mat(Color(0.05, 0.05, 0.05), 0.8), false)
	var shade := CylinderMesh.new()
	shade.top_radius = 0.05
	shade.bottom_radius = 0.26
	shade.height = 0.16
	_mesh(shade, top - Vector3(0, 0.66, 0), _mat(Color(0.08, 0.1, 0.09), 0.5), false)
	var bulb := SphereMesh.new()
	bulb.radius = 0.06
	bulb.height = 0.12
	_mesh(bulb, top - Vector3(0, 0.74, 0), _glow(Color(1.0, 0.9, 0.7), 5.0), false)
	var light := OmniLight3D.new()
	light.position = top - Vector3(0, 0.85, 0)
	light.light_color = Color(1.0, 0.86, 0.68)
	light.light_energy = 1.7
	light.omni_range = 9.0
	light.shadow_enabled = shadows
	add_child(light)


func _box(size: Vector3, pos: Vector3, mat: Material, solid := true) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_mesh(mesh, pos, mat)
	if solid:
		var shape := BoxShape3D.new()
		shape.size = size
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = pos
		_body.add_child(col)


func _mesh(mesh: PrimitiveMesh, pos: Vector3, mat: Material, shadow := true) -> void:
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _mat(color: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m


func _glow(color: Color, energy: float) -> StandardMaterial3D:
	var m := _mat(color, 0.5)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m
