extends RefCounted
## The material library: every procedural look in the game comes from here. All materials are
## cached by their parameters, so a hundred houses with the same wall colour share one material.
## No image files: surfaces are shaders in shaders/ that work in world space.

const SURFACE = preload("res://shaders/surface.gdshader")
const BRICK = preload("res://shaders/brick.gdshader")
const WATER = preload("res://shaders/water.gdshader")
const GLASS = preload("res://shaders/glass.gdshader")

# `surface()` modes (must match shaders/surface.gdshader)
const PLAIN := 0
const GRASS := 1
const ASPHALT := 2
const SLABS := 3
const WOOD := 4
const PLASTER := 5
const ROOF := 6
const FOLIAGE := 7
const PAINT := 8
const CONCRETE := 9

static var _cache: Dictionary = {}


## A procedural surface. With `instance_colors` the colour comes from the MultiMesh instance
## (outside.gd); otherwise from `color`. `opts` may hold grain (Vector3), plank (float),
## detail (float) and floor_y (float).
static func surface(mode: int, color := Color.WHITE, instance_colors := false, opts := {}) -> ShaderMaterial:
	var key := "s%d %s %s %s" % [mode, color, instance_colors, opts]
	if _cache.has(key):
		return _cache[key]
	var m := ShaderMaterial.new()
	m.shader = SURFACE
	m.set_shader_parameter("mode", mode)
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("use_instance_color", instance_colors)
	for k: String in opts:
		m.set_shader_parameter(k, opts[k])
	_cache[key] = m
	return m


static func brick() -> ShaderMaterial:
	if not _cache.has("brick"):
		var m := ShaderMaterial.new()
		m.shader = BRICK
		_cache["brick"] = m
	return _cache["brick"]


## Pond water; the colour comes from the instance colour.
static func water() -> ShaderMaterial:
	if not _cache.has("water"):
		var m := ShaderMaterial.new()
		m.shader = WATER
		_cache["water"] = m
	return _cache["water"]


## Window glass, either with a fixed tint or taking colour and alpha from the instance.
static func glass(tint := Color(0.7, 0.86, 0.95, 0.3), instance_colors := false) -> ShaderMaterial:
	var key := "g %s %s" % [tint, instance_colors]
	if not _cache.has(key):
		var m := ShaderMaterial.new()
		m.shader = GLASS
		m.set_shader_parameter("tint", tint)
		m.set_shader_parameter("use_instance_color", instance_colors)
		_cache[key] = m
	return _cache[key]


## Hardware finish derived from a part's colour: dark chassis get a glossy clear coat and a
## touch of metal, mid tones a satin coat, light colours soft plastic. A part with an emissive
## `energy` is a lit LED or screen: crisp, bright, and it blooms.
static func hardware(color: Color, energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if energy > 0.0:
		m.roughness = 0.3
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = energy
		return m
	var lum := color.get_luminance()
	var dark := 1.0 - smoothstep(0.08, 0.5, lum)   # 1 for black chassis, 0 for pale plastic
	m.roughness = lerpf(0.52, 0.36, dark)
	m.metallic = lerpf(0.0, 0.3, dark)
	m.metallic_specular = 0.6
	m.clearcoat_enabled = true
	m.clearcoat = lerpf(0.12, 0.6, dark)
	m.clearcoat_roughness = lerpf(0.3, 0.12, dark)
	return m
