extends Node3D
## The starting location: a brick garage, 9 x 7 m. Built entirely from code.

const Fixture = preload("res://scripts/fixture.gd")
const Materials = preload("res://scripts/materials.gd")
const W := 9.0
const D := 7.0
const H := 3.0
const DOOR_Y := 1.25

var fixtures: Dictionary = {}   # fixture id -> Fixture

var sky_mat: ProceduralSkyMaterial   # the weather changes these three
var sun: DirectionalLight3D
var env: Environment

var _body: StaticBody3D
var _door: StaticBody3D
var _door_shape: CollisionShape3D
var _env: Environment
var _fog_box: FogVolume


func _ready() -> void:
	_body = StaticBody3D.new()
	add_child(_body)
	_environment()

	var brick := Materials.brick()
	var concrete := Materials.surface(Materials.CONCRETE, Color(0.62, 0.59, 0.54))
	var wood := Materials.surface(Materials.WOOD, Color(0.4, 0.25, 0.14), false, {"grain": Vector3(0, 0, 1)})
	var lining := Materials.surface(Materials.WOOD, Color(0.4, 0.25, 0.14), false, {"grain": Vector3(1, 0, 0), "plank": 0.14})
	var metal := _metal(Color(0.5, 0.52, 0.56), 0.4)
	var door := _metal(Color(0.82, 0.84, 0.86), 0.45)
	var groove := _metal(Color(0.5, 0.52, 0.55), 0.6)
	var roof_mat := Materials.surface(Materials.PLAIN, Color(0.16, 0.17, 0.2))

	# shell
	_box(Vector3(W + 2, 1, D + 2), Vector3(0, -0.5, 0), concrete)
	_box(Vector3(W + 2, 1, D + 2), Vector3(0, H + 0.5, 0), brick)
	_box(Vector3(W, 0.04, D), Vector3(0, H - 0.02, 0), lining, false)   # ceiling lining
	_box(Vector3(W + 2, H, 1), Vector3(0, H / 2, -D / 2 - 0.5), brick)
	_box(Vector3(3.8, H, 1), Vector3(-3.6, H / 2, D / 2 + 0.5), brick)    # front wall, left of the door
	_box(Vector3(3.8, H, 1), Vector3(3.6, H / 2, D / 2 + 0.5), brick)     # right of the door
	_box(Vector3(3.4, H - 2.5, 1), Vector3(0, 2.5 + (H - 2.5) / 2, D / 2 + 0.5), brick)   # above it
	_box(Vector3(W + 2.6, 0.16, D + 2.6), Vector3(0, H + 1.08, 0), roof_mat, false)   # roof
	_box(Vector3(1, H, D), Vector3(-W / 2 - 0.5, H / 2, 0), brick)
	_box(Vector3(1, H, D), Vector3(W / 2 + 0.5, H / 2, 0), brick)
	for x: float in [-3.0, -1.0, 1.0, 3.0]:
		_box(Vector3(0.16, 0.22, D), Vector3(x, H - 0.11, 0), wood, false)

	# roller door: its own body so it can slide up into the wall
	_door = StaticBody3D.new()
	_door.position = Vector3(0, DOOR_Y, D / 2 + 0.12)
	add_child(_door)
	var panel := BoxMesh.new()
	panel.size = Vector3(3.4, 2.5, 0.08)
	panel.material = door
	var panel_node := MeshInstance3D.new()
	panel_node.mesh = panel
	_door.add_child(panel_node)
	for i in 6:
		var line := BoxMesh.new()
		line.size = Vector3(3.4, 0.02, 0.1)
		line.material = groove
		var line_node := MeshInstance3D.new()
		line_node.mesh = line
		line_node.position.y = -0.85 + i * 0.4
		_door.add_child(line_node)
	var door_box := BoxShape3D.new()
	door_box.size = Vector3(3.4, 2.5, 0.2)
	_door_shape = CollisionShape3D.new()
	_door_shape.shape = door_box
	_door.add_child(_door_shape)

	# workbench along the left wall
	_box(Vector3(0.75, 0.06, 2.4), Vector3(-W / 2 + 0.4, 0.9, -1.0), wood)
	for z: float in [-2.1, 0.1]:
		_box(Vector3(0.7, 0.87, 0.08), Vector3(-W / 2 + 0.4, 0.435, z), wood)
	_box(Vector3(0.03, 0.03, 2.2), Vector3(-W / 2 + 0.03, 1.7, -1.0), _glow(Color(0.1, 0.8, 1.0), 4.0), false)

	# metal shelf on the right wall
	for y: float in [0.45, 1.05, 1.65]:
		_box(Vector3(0.7, 0.04, 1.8), Vector3(W / 2 - 0.37, y, -1.5), metal)
	for z: float in [-2.38, -0.62]:
		for x: float in [W / 2 - 0.7, W / 2 - 0.04]:
			_box(Vector3(0.04, 1.9, 0.04), Vector3(x, 0.95, z), metal, false)

	# things players interact with (ids are fixed: host and clients must agree)
	_fixture(-3, "router", Vector3(1.6, 1.5, -D / 2), 0)
	_fixture(-4, "breaker", Vector3(-2.4, 1.45, -D / 2), 0)
	_fixture(-5, "shop", Vector3(-W / 2 + 0.38, 0.93, -1.0), 90)
	_fixture(-6, "door", Vector3(2.1, 1.2, D / 2), 180)        # door button, inside
	_fixture(-9, "tap", Vector3(3.4, 0.7, D / 2 + 1.0), 0)     # garden tap on the front wall, outside
	_fixture(-7, "door", Vector3(2.1, 1.2, D / 2 + 1.0), 0)    # door button, outside

	_lamp(Vector3(-2.2, H, 0.3), true)
	_lamp(Vector3(2.2, H, 0.3), false)


func set_door(open: bool) -> void:
	_door_shape.set_deferred("disabled", open)
	var tween := create_tween().set_parallel().set_trans(Tween.TRANS_SINE)   # rolls up into the lintel
	tween.tween_property(_door, "position:y", 2.44 if open else DOOR_Y, 0.8)
	tween.tween_property(_door, "scale:y", 0.04 if open else 1.0, 0.8)


func _fixture(id: int, kind: String, pos: Vector3, yaw: float) -> void:
	var f := Fixture.new()
	f.setup(id, kind)
	f.position = pos
	f.rotation.y = deg_to_rad(yaw)
	add_child(f)
	fixtures[id] = f


func _environment() -> void:
	env = Environment.new()
	_env = env
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.24, 0.5, 0.92)
	sky_mat.sky_horizon_color = Color(0.74, 0.85, 0.97)
	sky_mat.ground_horizon_color = Color(0.74, 0.85, 0.97)
	sky_mat.ground_bottom_color = Color(0.46, 0.42, 0.38)   # warm: this tints every ceiling (ground bounce)
	sky_mat.sky_curve = 0.18
	sky_mat.ground_curve = 0.04
	sky_mat.sun_angle_max = 25.0
	sky_mat.sun_curve = 0.12
	sky_mat.use_debanding = true
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 110.0
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.2
	sun.directional_shadow_split_3 = 0.5
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.85
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.6
	sun.shadow_blur = 1.4
	add_child(sun)
	# filmic tone mapping with a warm, slightly saturated "toy" grade
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_white = 6.0
	env.tonemap_exposure = 1.2
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.18
	# bloom: only things brighter than the picture (LEDs, bulbs, the sun glint) glow
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_intensity = 0.55
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.1
	env.glow_hdr_scale = 1.6
	var levels := [0.2, 0.6, 1.0, 0.9, 0.4, 0.0, 0.0]
	for i in levels.size():
		env.set_glow_level(i, levels[i])
	# contact shadows and bounce (the expensive ones are switched in _apply_settings)
	env.ssao_enabled = true
	env.ssao_radius = 1.1
	env.ssao_intensity = 2.2
	env.ssao_power = 1.6
	env.ssao_detail = 0.6
	env.ssao_light_affect = 0.25
	env.ssil_radius = 4.0
	env.ssil_intensity = 0.9
	env.ssil_sharpness = 0.9
	env.ssr_max_steps = 40
	env.ssr_fade_in = 0.1
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.25
	# aerial perspective: distant things fade into the sky colour (weather.gd tints it)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.0014
	env.fog_light_color = Color(0.74, 0.85, 0.97)
	env.fog_sun_scatter = 0.12
	env.fog_sky_affect = 0.0
	env.volumetric_fog_density = 0.0
	env.volumetric_fog_length = 48.0
	env.volumetric_fog_albedo = Color(1.0, 0.97, 0.92)
	env.volumetric_fog_anisotropy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	# light shafts inside the garage: a fog box that only exists in here (needs volumetric fog)
	_fog_box = FogVolume.new()
	_fog_box.size = Vector3(W, H, D)
	_fog_box.position = Vector3(0, H * 0.5, 0)
	var fog_mat := FogMaterial.new()
	fog_mat.density = 0.05
	fog_mat.albedo = Color(1.0, 0.95, 0.88)
	_fog_box.material = fog_mat
	add_child(_fog_box)
	_dust()
	_vignette()
	var settings := get_node_or_null("/root/Settings")
	if settings:
		settings.changed.connect(_apply_settings.bind(settings))
		_apply_settings(settings)


## `glow` is bloom. `ssao` is the "fancy lighting" switch: contact shadows, screen space bounce
## light, reflections on glossy floors, light shafts, soft sun shadows.
func _apply_settings(settings: Node) -> void:
	var fancy: bool = settings.ssao
	_env.glow_enabled = settings.glow
	_env.ssao_enabled = fancy
	_env.ssil_enabled = fancy
	_env.ssr_enabled = fancy
	_env.volumetric_fog_enabled = fancy
	_fog_box.visible = fancy
	sun.light_angular_distance = 0.45 if fancy else 0.0
	sun.shadow_blur = 1.4 if fancy else 1.0


## Slow dust specks hanging in the air under the two lamps.
func _dust() -> void:
	var speck := QuadMesh.new()
	speck.size = Vector2(0.006, 0.006)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1.0, 0.92, 0.75, 0.3)
	m.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	m.distance_fade_min_distance = 6.0
	m.distance_fade_max_distance = 1.0
	speck.material = m
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(1.6, 1.0, 1.6)
	pm.direction = Vector3(0.3, 0.1, 0.2)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.01
	pm.initial_velocity_max = 0.05
	pm.gravity = Vector3(0, -0.004, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.15
	pm.turbulence_noise_scale = 1.5
	pm.turbulence_influence_min = 0.02
	pm.turbulence_influence_max = 0.06
	pm.scale_min = 0.5
	pm.scale_max = 1.6
	for x: float in [-2.2, 2.2]:
		var p := GPUParticles3D.new()
		p.process_material = pm
		p.draw_pass_1 = speck
		p.amount = 40
		p.lifetime = 14.0
		p.preprocess = 14.0
		p.position = Vector3(x, 1.7, 0.3)
		p.visibility_aabb = AABB(Vector3(-2, -1.5, -2), Vector3(4, 3, 4))
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)


## A soft darkening of the screen corners, drawn under the HUD.
func _vignette() -> void:
	var layer := CanvasLayer.new()
	layer.layer = -1
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """shader_type canvas_item;
void fragment() {
	vec2 q = UV - 0.5;
	q.x *= 1.15;
	float v = smoothstep(0.38, 0.95, length(q));
	COLOR = vec4(0.03, 0.02, 0.05, v * 0.42);
}
"""
	var vm := ShaderMaterial.new()
	vm.shader = sh
	rect.material = vm
	layer.add_child(rect)
	add_child(layer)


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
	_mesh(bulb, top - Vector3(0, 0.74, 0), _glow(Color(1.0, 0.9, 0.7), 9.0), false)
	var light := OmniLight3D.new()
	light.position = top - Vector3(0, 0.85, 0)
	light.light_color = Color(1.0, 0.86, 0.68)
	light.light_energy = 0.85   # dim emergency lighting; buy lamps for more
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


## Satin painted metal (shelves, the roller door).
func _metal(color: Color, rough: float) -> StandardMaterial3D:
	var m := _mat(color, rough)
	m.metallic = 0.55
	m.metallic_specular = 0.6
	return m
