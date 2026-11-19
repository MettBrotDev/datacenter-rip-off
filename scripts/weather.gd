extends Node3D
## The visible side of the weather: sky colour, sunlight, drifting clouds and rain.
## The host's simulation decides the weather (Catalog.WEATHER); this only shows it.

# One entry per Catalog.WEATHER state.
const LOOKS: Array[Dictionary] = [
	{"top": Color(0.22, 0.46, 0.9), "horizon": Color(0.72, 0.84, 0.96), "sun": 1.3, "ambient": 0.5,
		"cloud": Color(1.0, 1.0, 1.0, 0.0)},
	{"top": Color(0.45, 0.54, 0.68), "horizon": Color(0.78, 0.81, 0.85), "sun": 0.5, "ambient": 0.48,
		"cloud": Color(0.92, 0.93, 0.95, 0.95)},
	{"top": Color(0.27, 0.3, 0.35), "horizon": Color(0.44, 0.47, 0.51), "sun": 0.1, "ambient": 0.36,
		"cloud": Color(0.36, 0.38, 0.42, 1.0)},
]
const DRIFT := 1.5       # cloud speed, m/s
const SPAN := 260.0      # clouds wrap around after this many metres
const RAIN_REACH := 18.0 # rain falls within this many metres of the viewer
const RAIN_TOP := 14.0   # and starts this far above them

var current := -1

var _env: Environment
var _sky: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _clouds: Node3D
var _cloud_mat: StandardMaterial3D
var _rain: GPUParticles3D
var _cover: GPUParticlesCollisionHeightField3D


func setup(env: Environment, sky: ProceduralSkyMaterial, sun: DirectionalLight3D) -> void:
	_env = env
	_sky = sky
	_sun = sun


func _ready() -> void:
	_cloud_mat = StandardMaterial3D.new()
	_cloud_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cloud_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cloud_mat.albedo_color = LOOKS[0]["cloud"]
	var puff := SphereMesh.new()
	puff.radius = 1.0
	puff.height = 2.0
	puff.radial_segments = 12
	puff.rings = 6
	puff.material = _cloud_mat
	_clouds = Node3D.new()
	add_child(_clouds)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 26:
		var centre := Vector3(rng.randf_range(-SPAN, SPAN) * 0.5, rng.randf_range(48, 70), rng.randf_range(-130, 130))
		for j in 3:
			var blob := MeshInstance3D.new()
			blob.mesh = puff
			blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			blob.position = centre + Vector3(rng.randf_range(-9, 9), rng.randf_range(-1, 1), rng.randf_range(-6, 6))
			blob.scale = Vector3(rng.randf_range(10, 18), rng.randf_range(2.5, 4.5), rng.randf_range(8, 13))
			_clouds.add_child(blob)

	var drop_mat := StandardMaterial3D.new()
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.albedo_color = Color(0.75, 0.82, 0.95, 0.45)
	var drop := BoxMesh.new()
	drop.size = Vector3(0.012, 0.35, 0.012)
	drop.material = drop_mat
	# Real drops in the world: they start high above whoever is looking and vanish the moment
	# they touch anything, so it rains outside a window but never under a roof (or a tree).
	var fall := ParticleProcessMaterial.new()
	fall.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	fall.emission_box_extents = Vector3(RAIN_REACH, 0.5, RAIN_REACH)
	fall.direction = Vector3.DOWN
	fall.spread = 1.5
	fall.initial_velocity_min = 16.0
	fall.initial_velocity_max = 20.0
	fall.gravity = Vector3.ZERO
	fall.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	_rain = GPUParticles3D.new()
	_rain.process_material = fall
	_rain.draw_pass_1 = drop
	_rain.amount = 3000
	_rain.lifetime = 1.1
	_rain.visibility_aabb = AABB(Vector3(-RAIN_REACH, -RAIN_TOP - 8, -RAIN_REACH), Vector3(RAIN_REACH * 2, RAIN_TOP + 10, RAIN_REACH * 2))
	_rain.emitting = false
	_rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_rain)
	# a top-down height map of everything around the viewer, which the drops collide with
	_cover = GPUParticlesCollisionHeightField3D.new()
	_cover.size = Vector3(RAIN_REACH * 2 + 4, RAIN_TOP + 10, RAIN_REACH * 2 + 4)
	_cover.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_1024
	_cover.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_WHEN_MOVED
	add_child(_cover)


func set_weather(index: int) -> void:
	if index == current:
		return
	var instant := current < 0
	current = index
	var look: Dictionary = LOOKS[index]
	var seconds := 0.01 if instant else 6.0
	var tween := create_tween().set_parallel()
	tween.tween_property(_sky, "sky_top_color", look["top"], seconds)
	tween.tween_property(_sky, "sky_horizon_color", look["horizon"], seconds)
	tween.tween_property(_sky, "ground_horizon_color", look["horizon"], seconds)
	tween.tween_property(_sun, "light_energy", look["sun"], seconds)
	tween.tween_property(_env, "ambient_light_energy", look["ambient"], seconds)
	tween.tween_property(_cloud_mat, "albedo_color", look["cloud"], seconds)


func _process(dt: float) -> void:
	for blob: Node3D in _clouds.get_children():
		blob.position.x += DRIFT * dt
		if blob.position.x > SPAN * 0.5:
			blob.position.x -= SPAN
	# rain falls in a box around whoever is looking, and only where there is no roof
	var cam := get_viewport().get_camera_3d()
	if cam:
		_rain.emitting = current == 2
		_rain.global_position = cam.global_position + Vector3(0, RAIN_TOP, 0)
		_cover.global_position = cam.global_position + Vector3(0, RAIN_TOP * 0.5 - 3.0, 0)
