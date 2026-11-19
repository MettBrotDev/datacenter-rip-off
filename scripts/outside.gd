extends Node3D
## The whole town around the garage: ground, streets with sidewalks and furniture, our own lot
## (driveway, front path and the back garden), every neighbour's yard, the park, a treeline along
## the playable bounds, invisible walls and distant hills. The houses themselves are NOT built here.
##
## Structure
##  - Layout comes from town.gd (streets, lots, park, bounds); this file only dresses it.
##  - Everything repeated is queued with `_put()` / `_rb()` and flushed in `_flush()` as MultiMeshes,
##    one per mesh kind and 150 m map quarter (so the GPU can cull them); colour is per instance.
##  - Round shapes: unit spheres / cylinders / cones, and Shapes.rounded_box() for anything boxy.
##    Plain unit boxes ("flat") are used only for huge slabs like asphalt and paving.
##  - Colliders are plain boxes / cylinders on one StaticBody3D (`_col_box`, `_col_cyl`).
##  - Fully deterministic: one RandomNumberGenerator with a fixed seed, called in a fixed order.
##
## Layers (y): ground top -0.03, lawn patches -0.018, soil -0.008, asphalt -0.01, paths / driveways 0.0,
## sidewalks 0.02 (kerb 5 cm). Clear rectangles around houses only get flat ground-level things.
##
## Landmarks: driveway x[-2.5,2.5] z[4.5,20]; home front path x -14 z[6,18]; garden pond (-16,-18.5),
## greenhouse (-6,-21.5), shed (-28.5,-22.5), gates at (3.5,-14) and (-14,-11); open lawn x[6,14];
## park pond (4,50), fountain (-22,38), gazebo (-24,50), playground x[33,46] z[42,60].

const Town = preload("res://scripts/town.gd")
const Shapes = preload("res://scripts/shapes.gd")
const Materials = preload("res://scripts/materials.gd")

const CELL := 150.0
const GROUND_Y := -0.03
const LAWN_TOP := -0.018
const SOIL_TOP := -0.008
const ASPHALT_TOP := -0.01
const WALK_TOP := 0.02

const GRASS := Color(0.42, 0.67, 0.28)
const ASPHALT := Color(0.27, 0.28, 0.32)
const WALK := Color(0.66, 0.63, 0.59)
const PAVING := Color(0.62, 0.59, 0.54)
const WOOD := Color(0.62, 0.42, 0.25)
const WHITE := Color(0.96, 0.94, 0.88)
const SOIL := Color(0.34, 0.22, 0.14)
const LINE_WHITE := Color(0.93, 0.92, 0.88)
const LINE_YELLOW := Color(0.96, 0.80, 0.30)
const METAL := Color(0.26, 0.28, 0.32)
const LEAVES: Array[Color] = [Color(0.27, 0.58, 0.24), Color(0.36, 0.67, 0.27), Color(0.20, 0.50, 0.28), Color(0.45, 0.70, 0.30)]
const FLOWERS: Array[Color] = [Color(0.95, 0.32, 0.38), Color(0.98, 0.80, 0.22), Color(0.96, 0.56, 0.76), Color(0.64, 0.45, 0.88), Color(1.0, 0.98, 0.92), Color(0.99, 0.55, 0.18)]
const CAR_COLORS: Array[Color] = [Color(0.85, 0.25, 0.22), Color(0.22, 0.46, 0.80), Color(0.93, 0.80, 0.25), Color(0.90, 0.90, 0.88), Color(0.25, 0.60, 0.45), Color(0.35, 0.36, 0.40), Color(0.92, 0.55, 0.25)]
const FENCE_COLORS: Array[Color] = [Color(0.96, 0.94, 0.88), Color(0.80, 0.88, 0.92), Color(0.78, 0.88, 0.76), Color(0.62, 0.42, 0.25)]

var _rng := RandomNumberGenerator.new()
var _body: StaticBody3D
var _mats: Dictionary = {}
var _kinds: Dictionary = {}      # kind -> {"mesh", "mat", "shadow"}
var _batches: Dictionary = {}    # "kind#cell" -> {"x": transforms, "c": colours}
var _shape_cache: Dictionary = {}
var _shape_count := 0
var _lot_rects: Array[Rect2] = []
var _park_pts: Array[Vector2] = []     # sampled path points of the park (for keeping trees off them)
var _park_lobes: Array[Vector4] = []   # park pond ellipses (cx, cz, rx, rz)
var _park_blocks: Array[Rect2] = []    # park areas where no random trees may grow


## One yard's coordinate frame: u runs along x from the lot centre, v runs from the street edge into the lot.
class Yard extends RefCounted:
	var origin: Vector3
	var f: float   # +1: the street is on the +Z side

	func _init(lot_pos: Vector3, yaw_deg: float) -> void:
		f = 1.0 if yaw_deg < 90.0 else -1.0
		origin = Vector3(lot_pos.x, 0.0, lot_pos.z + f * 17.0)

	func p2(u: float, v: float) -> Vector2:
		return Vector2(origin.x + u, origin.z - f * v)

	func p(u: float, v: float, y := 0.0) -> Vector3:
		return Vector3(origin.x + u, y, origin.z - f * v)

	func rect(u0: float, v0: float, u1: float, v1: float) -> Rect2:
		return Rect2(p2(u0, v0), Vector2.ZERO).expand(p2(u1, v1))

	## Yaw that makes a model (front = +Z) face the street, or away from it.
	func yaw(toward_street := true) -> float:
		return 0.0 if (f > 0.0) == toward_street else PI


func _ready() -> void:
	_rng.seed = 20261119
	_body = StaticBody3D.new()
	add_child(_body)
	_make_materials()
	_make_kinds()
	_ground()
	_streets()
	_street_furniture()
	_home()
	_lots()
	_park()
	_filler()
	_bounds()
	_hills()
	_flush()


# ================================================================ batching core

func _make_materials() -> void:
	# per-instance colour drives every one of these, so objects keep their own colour
	_mats["vc"] = Materials.surface(Materials.PLAIN, Color.WHITE, true)
	_mats["foliage"] = Materials.surface(Materials.FOLIAGE, Color.WHITE, true)
	_mats["lawn"] = Materials.surface(Materials.GRASS, Color.WHITE, true)
	_mats["asphalt"] = Materials.surface(Materials.ASPHALT, Color.WHITE, true)
	_mats["walk"] = Materials.surface(Materials.SLABS, Color.WHITE, true)
	_mats["paint"] = Materials.surface(Materials.PAINT, Color.WHITE, true)
	var glow := StandardMaterial3D.new()
	glow.vertex_color_use_as_albedo = true
	glow.vertex_color_is_srgb = true
	glow.roughness = 0.5
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.86, 0.55)
	glow.emission_energy_multiplier = 5.0
	_mats["glow"] = glow
	_mats["water"] = Materials.water()
	_mats["glass"] = Materials.glass(Color.WHITE, true)


func _make_kinds() -> void:
	var sph := SphereMesh.new()
	sph.radius = 0.5
	sph.height = 1.0
	sph.radial_segments = 14
	sph.rings = 7
	_kind("sphere", sph)
	_kind("leaf", sph, "foliage")
	var small := SphereMesh.new()
	small.radius = 0.5
	small.height = 1.0
	small.radial_segments = 8
	small.rings = 4
	_kind("fsph", small, "vc", false)
	_kind("glow", sph, "glow", false)
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.5
	cyl.height = 1.0
	cyl.radial_segments = 16
	cyl.rings = 1
	_kind("cyl", cyl)
	_kind("disc", cyl, "vc", false)
	var wcyl := cyl.duplicate() as CylinderMesh
	wcyl.radial_segments = 28
	_kind("water", wcyl, "water", false)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.5
	cone.height = 1.0
	cone.radial_segments = 14
	cone.rings = 1
	_kind("cone", cone)
	_kind("pine", cone, "foliage")
	var tuft := cone.duplicate() as CylinderMesh
	tuft.radial_segments = 5
	_kind("tuft", tuft, "vc", false)
	var box := BoxMesh.new()
	_kind("flat", box, "vc", false)
	_kind("asphalt", box, "asphalt", false)
	_kind("walk", box, "walk", false)
	_kind("paint", box, "paint", false)
	_kind("lawn", box, "lawn", false)
	var hill := SphereMesh.new()
	hill.radius = 0.5
	hill.height = 1.0
	hill.radial_segments = 32
	hill.rings = 16
	_kind("hill", hill, "lawn", false)


func _kind(name: String, mesh: Mesh, mat := "vc", shadow := true) -> void:
	_kinds[name] = {"mesh": mesh, "mat": mat, "shadow": shadow}


## Queue one instance of a unit mesh kind, scaled by `size`, rotated by `rot`.
func _put(kind: String, pos: Vector3, size: Vector3, col: Color, rot := Basis.IDENTITY) -> void:
	var cx := clampi(int((pos.x - Town.BOUNDS.position.x) / CELL), 0, 1)
	var cz := clampi(int((pos.z - Town.BOUNDS.position.y) / CELL), 0, 1)
	var key := "%s#%d" % [kind, cz * 2 + cx]
	if not _batches.has(key):
		_batches[key] = {"x": [], "c": []}
	var b: Dictionary = _batches[key]
	(b["x"] as Array).append(Transform3D(rot * Basis.from_scale(size), pos))
	(b["c"] as Array).append(col)


## Queue a rounded box (`size` is the real size, `scl` an optional extra stretch), centred on `pos`.
func _rb(size: Vector3, radius: float, pos: Vector3, col: Color, rot := Basis.IDENTITY, scl := Vector3.ONE, mat := "vc", steps := 1) -> void:
	var kind := "rb %.3v %.3f %d %s" % [size, radius, steps, mat]
	if not _kinds.has(kind):
		_kind(kind, Shapes.rounded_box(size, radius, steps), mat, mat != "glass")
	_put(kind, pos, scl, col, rot)


## A prism roof (ridge along local X), base centred on `pos`.
func _roof(size: Vector3, pos: Vector3, col: Color, rot := Basis.IDENTITY) -> void:
	var kind := "prism %.3v" % size
	if not _kinds.has(kind):
		_kind(kind, Shapes.prism(size))
	_put(kind, pos, Vector3.ONE, col, rot)


## Local-frame variants: place parts relative to an object's transform.
func _putl(xf: Transform3D, kind: String, lp: Vector3, size: Vector3, col: Color, rot := Basis.IDENTITY) -> void:
	_put(kind, xf * lp, size, col, xf.basis * rot)


func _rbl(xf: Transform3D, lp: Vector3, size: Vector3, radius: float, col: Color, mat := "vc") -> void:
	_rb(size, radius, xf * lp, col, xf.basis, Vector3.ONE, mat)


func _xf(pos: Vector3, yaw: float, scl := 1.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scl), pos)


func _flush() -> void:
	for key: String in _batches:
		var b: Dictionary = _batches[key]
		var xs: Array = b["x"]
		var cs: Array = b["c"]
		var info: Dictionary = _kinds[key.get_slice("#", 0)]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = info["mesh"] as Mesh
		mm.instance_count = xs.size()
		for i in xs.size():
			mm.set_instance_transform(i, xs[i] as Transform3D)
			mm.set_instance_color(i, cs[i] as Color)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = _mats[info["mat"]] as Material
		if not (info["shadow"] as bool):
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)


# ================================================================ colliders

func _col_box(pos: Vector3, size: Vector3, yaw := 0.0) -> void:
	var key := "b%.2v" % size
	if not _shape_cache.has(key):
		var s := BoxShape3D.new()
		s.size = size
		_shape_cache[key] = s
	_add_shape(_shape_cache[key] as Shape3D, pos, yaw)


func _col_cyl(pos: Vector3, radius: float, height: float) -> void:
	var key := "c%.2f,%.2f" % [radius, height]
	if not _shape_cache.has(key):
		var s := CylinderShape3D.new()
		s.radius = radius
		s.height = height
		_shape_cache[key] = s
	_add_shape(_shape_cache[key] as Shape3D, pos, 0.0)


func _add_shape(shape: Shape3D, pos: Vector3, yaw: float) -> void:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = pos
	cs.rotation.y = yaw
	_body.add_child(cs)
	_shape_count += 1


# ================================================================ small helpers

func _pick(arr: Array[Color]) -> Color:
	return arr[_rng.randi() % arr.size()]


func _tint(c: Color, amt := 0.08) -> Color:
	var k := _rng.randf_range(-amt, amt)
	return c.lightened(k) if k > 0.0 else c.darkened(-k)


func _r(a: float, b: float) -> float:
	return _rng.randf_range(a, b)


func _face_yaw(dir: Vector2) -> float:
	return atan2(dir.x, dir.y)


## A flat rectangle (x, z rect) whose top face sits at `top`.
func _slab(rect: Rect2, top: float, col: Color, thick := 0.1, kind := "flat") -> void:
	var c := rect.get_center()
	_put(kind, Vector3(c.x, top - thick * 0.5, c.y), Vector3(rect.size.x, thick, rect.size.y), col)


## A flat disc / ellipse (diameters in `size`) whose top sits at `top`.
func _disc(c: Vector2, size: Vector2, top: float, col: Color, thick := 0.03, yaw := 0.0, kind := "disc") -> void:
	_put(kind, Vector3(c.x, top - thick * 0.5, c.y), Vector3(size.x, thick, size.y), col, Basis(Vector3.UP, yaw))


## A round rod between two points.
func _rod(a: Vector3, b: Vector3, d: float, col: Color) -> void:
	var length := a.distance_to(b)
	if length < 0.001:
		return
	var rot := Basis(Quaternion(Vector3.UP, (b - a) / length))
	_put("cyl", (a + b) * 0.5, Vector3(d, length, d), col, rot)


## Intervals of [lo, hi] left over after removing cuts (x = centre, y = half width); cuts sorted by centre.
func _spans(lo: float, hi: float, cuts: Array[Vector2]) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var t := lo
	for c: Vector2 in cuts:
		if c.x - c.y > t:
			out.append(Vector2(t, c.x - c.y))
		t = maxf(t, c.x + c.y)
	if t < hi:
		out.append(Vector2(t, hi))
	return out


func _sorted(cuts: Array[Vector2]) -> Array[Vector2]:
	cuts.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	return cuts


## Splits a line a->b around gaps (x = distance of the gap centre from a, y = width); returns pairs of points.
func _split(a: Vector2, b: Vector2, gaps: Array[Vector2]) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var length := a.distance_to(b)
	var dir := (b - a) / length
	var t := 0.0
	for g: Vector2 in gaps:
		var g0 := g.x - g.y * 0.5
		if g0 > t + 0.2:
			out.append(a + dir * t)
			out.append(a + dir * g0)
		t = g.x + g.y * 0.5
	if t < length - 0.2:
		out.append(a + dir * t)
		out.append(b)
	return out


# ================================================================ trees, bushes, hedges, fences

## Species: 0 round, 1 tall poplar, 2 conifer, 3 blossom, 4 autumn. `s` is the scale.
func _tree(pos: Vector3, kind: int, s: float, collide := true) -> void:
	var bark := _tint(Color(0.42, 0.29, 0.19), 0.08)
	var base := _pick(LEAVES)
	if kind == 3:
		base = Color(0.96, 0.68, 0.76)
	elif kind == 4:
		base = Color(0.92, 0.58, 0.20)
	var a0 := _r(0.0, TAU)
	match kind:
		1:
			_put("cyl", pos + Vector3(0, 0.7 * s, 0), Vector3(0.3, 1.4, 0.3) * s, bark)
			for k in 4:
				var w := (2.1 - 0.35 * k) * s
				_put("leaf", pos + Vector3(_r(-0.1, 0.1) * s, (2.4 + 1.5 * k) * s, _r(-0.1, 0.1) * s), Vector3(w, 2.6 * s, w), _tint(base, 0.06).lightened(0.04 * k))
			_put("leaf", pos + Vector3(0, 8.2 * s, 0), Vector3(0.9, 1.4, 0.9) * s, base.lightened(0.15))
		2:
			_put("cyl", pos + Vector3(0, 0.8 * s, 0), Vector3(0.36, 1.6, 0.36) * s, bark)
			var dark := Color(0.14, 0.40, 0.24).lerp(Color(0.22, 0.50, 0.26), _rng.randf())
			for k in 4:
				var w := (3.4 - 0.75 * k) * s
				var y := (1.3 + 1.25 * k) * s
				_put("pine", pos + Vector3(0, y + 1.2 * s, 0), Vector3(w, 2.4 * s, w), dark.lightened(0.04 * k))
				_put("leaf", pos + Vector3(0, y + 0.1 * s, 0), Vector3(w * 0.95, 0.9 * s, w * 0.95), dark.darkened(0.05))
			_put("pine", pos + Vector3(0, 6.6 * s, 0), Vector3(0.7, 1.6, 0.7) * s, dark.lightened(0.14))
		_:
			_put("cyl", pos + Vector3(0, 1.1 * s, 0), Vector3(0.38, 2.2, 0.38) * s, bark)
			_put("sphere", pos + Vector3(0, 0.12 * s, 0), Vector3(0.75, 0.45, 0.75) * s, bark)
			_put("cyl", pos + Vector3(0.3 * s, 2.5 * s, 0.1 * s), Vector3(0.14, 1.1, 0.14) * s, bark, Basis(Vector3.FORWARD, 0.6))
			_put("leaf", pos + Vector3(0, 3.5 * s, 0), Vector3(3.5, 3.0, 3.5) * s, _tint(base, 0.05))
			for k in 4:
				var a := a0 + k * TAU / 4.0
				var d := _r(0.9, 1.2) * s
				var w := _r(2.0, 2.5) * s
				_put("leaf", pos + Vector3(cos(a) * d, _r(2.8, 3.6) * s, sin(a) * d), Vector3(w, w * 0.85, w), _tint(base, 0.07))
			_put("leaf", pos + Vector3(_r(-0.3, 0.3) * s, 4.7 * s, _r(-0.3, 0.3) * s), Vector3(2.3, 1.8, 2.3) * s, base.lightened(0.1))
			if kind == 3:
				for k in 5:
					var a := _r(0.0, TAU)
					_disc(Vector2(pos.x + cos(a) * _r(0.8, 2.4) * s, pos.z + sin(a) * _r(0.8, 2.4) * s), Vector2.ONE * 0.28, 0.0, Color(0.98, 0.8, 0.86), 0.01)
	if collide:
		_col_cyl(pos + Vector3(0, 1.5 * s, 0), 0.3 * s, 3.0 * s)


func _random_tree(pos: Vector3, s: float, collide := true) -> void:
	var r := _rng.randf()
	var kind := 0 if r < 0.4 else (1 if r < 0.55 else (2 if r < 0.75 else (3 if r < 0.9 else 4)))
	_tree(pos, kind, s, collide)


func _bush(pos: Vector3, s: float, flowering := false) -> void:
	var c := _tint(_pick(LEAVES).darkened(0.1), 0.06)
	_put("leaf", pos + Vector3(0, 0.42 * s, 0), Vector3(1.3, 0.95, 1.15) * s, c)
	_put("leaf", pos + Vector3(0.5 * s, 0.34 * s, 0.2 * s), Vector3(0.85, 0.7, 0.8) * s, c.lightened(0.08))
	_put("leaf", pos + Vector3(-0.4 * s, 0.32 * s, -0.25 * s), Vector3(0.8, 0.65, 0.8) * s, c.darkened(0.04))
	if flowering:
		var fc := _pick(FLOWERS)
		for i in 7:
			var a := _r(0.0, TAU)
			_put("fsph", pos + Vector3(cos(a) * 0.5 * s, _r(0.45, 0.85) * s, sin(a) * 0.45 * s), Vector3.ONE * _r(0.12, 0.2), fc)


## A clipped hedge of soft blobs from a to b, with optional gaps; one collider box per run.
func _hedge(a: Vector2, b: Vector2, h: float, t: float, gaps: Array[Vector2] = [], collide := true) -> void:
	var base := Color(0.17, 0.43, 0.19).lerp(Color(0.30, 0.58, 0.22), _rng.randf())
	var pts := _split(a, b, gaps)
	for i in range(0, pts.size(), 2):
		var p0 := pts[i]
		var p1 := pts[i + 1]
		var length := p0.distance_to(p1)
		var n := maxi(1, ceili(length / (t * 0.7)))
		var dir := (p1 - p0) / length
		for k in n:
			var p := p0 + dir * (k + 0.5) * length / n
			var hh := h * _r(0.95, 1.18)
			_put("leaf", Vector3(p.x, hh * 0.46, p.y), Vector3(t * 1.35, hh, t * 1.3), _tint(base, 0.06))
		if collide:
			var mid := (p0 + p1) * 0.5
			_col_box(Vector3(mid.x, h * 0.5, mid.y), Vector3(length, h, t * 0.85), atan2(-dir.y, dir.x))


## A fence from a to b. style 0: pickets, 1: ranch rails. Gaps as in _split().
func _fence(a: Vector2, b: Vector2, style: int, h: float, col: Color, gaps: Array[Vector2] = [], collide := true) -> void:
	var pts := _split(a, b, gaps)
	var post_col := col.darkened(0.12)
	for i in range(0, pts.size(), 2):
		var p0 := pts[i]
		var p1 := pts[i + 1]
		var length := p0.distance_to(p1)
		var dir := (p1 - p0) / length
		var yaw := atan2(-dir.y, dir.x)
		var rot := Basis(Vector3.UP, yaw)
		var posts := maxi(2, ceili(length / 2.2) + 1)
		for k in posts:
			var p := p0 + dir * length * k / (posts - 1)
			_put("cyl", Vector3(p.x, (h + 0.12) * 0.5, p.y), Vector3(0.11, h + 0.12, 0.11), post_col)
			_put("sphere", Vector3(p.x, h + 0.12, p.y), Vector3(0.14, 0.12, 0.14), post_col)
		var rails: Array[float] = [0.3, 0.78]
		if style != 0:
			rails = [0.25, 0.55, 0.85]
		for ry: float in rails:
			_rod(Vector3(p0.x, h * ry, p0.y), Vector3(p1.x, h * ry, p1.y), 0.06, col.darkened(0.06))
		if style == 0:
			var n := maxi(1, int(length / 0.3))
			for k in n:
				var p := p0 + dir * (k + 0.5) * length / n
				var hh := h * _r(0.94, 1.04)
				_rb(Vector3(0.16, h, 0.035), 0.016, Vector3(p.x, hh * 0.5, p.y), _tint(col, 0.04), rot, Vector3(1, hh / h, 1))
		if collide:
			var mid := (p0 + p1) * 0.5
			_col_box(Vector3(mid.x, h * 0.5, mid.y), Vector3(length, h, 0.12), yaw)


## Gate posts with cap balls and an open gate leaf. `along_x`: the fence line runs along X.
func _gate(c: Vector2, along_x: bool, width: float, col: Color) -> void:
	var dir := Vector2(1, 0) if along_x else Vector2(0, 1)
	for sgn: float in [-1.0, 1.0]:
		var p := c + dir * sgn * width * 0.5
		_put("cyl", Vector3(p.x, 0.7, p.y), Vector3(0.18, 1.4, 0.18), col.darkened(0.15))
		_put("sphere", Vector3(p.x, 1.45, p.y), Vector3(0.24, 0.24, 0.24), col.lightened(0.05))
		_col_cyl(Vector3(p.x, 0.7, p.y), 0.1, 1.4)
	var hinge := c - dir * width * 0.5
	var out := Vector2(-dir.y, dir.x)
	_rod(Vector3(hinge.x, 0.3, hinge.y), Vector3(hinge.x + out.x * width * 0.9, 0.3, hinge.y + out.y * width * 0.9), 0.05, col)
	_rod(Vector3(hinge.x, 0.8, hinge.y), Vector3(hinge.x + out.x * width * 0.9, 0.8, hinge.y + out.y * width * 0.9), 0.05, col)


## A flower bed: soil patch and `n` flowers with stems.
func _flowers(rect: Rect2, n: int, soil := true) -> void:
	if soil:
		_slab(rect, SOIL_TOP, SOIL, 0.04)
	var c1 := _pick(FLOWERS)
	var c2 := _pick(FLOWERS)
	for i in n:
		var x := _r(rect.position.x + 0.12, rect.end.x - 0.12)
		var z := _r(rect.position.y + 0.12, rect.end.y - 0.12)
		var h := _r(0.2, 0.45)
		_put("tuft", Vector3(x, h * 0.5, z), Vector3(0.1, h, 0.1), Color(0.25, 0.56, 0.22))
		_put("fsph", Vector3(x, h + 0.02, z), Vector3.ONE * _r(0.12, 0.2), c1 if _rng.randf() < 0.6 else c2)


func _round_bed(c: Vector2, radius: float, n: int) -> void:
	_disc(c, Vector2.ONE * radius * 2.0, SOIL_TOP, SOIL, 0.04)
	var c1 := _pick(FLOWERS)
	var c2 := _pick(FLOWERS)
	for i in n:
		var a := _r(0.0, TAU)
		var d := radius * sqrt(_rng.randf()) * 0.92
		var h := _r(0.2, 0.45)
		var p := c + Vector2(cos(a), sin(a)) * d
		_put("tuft", Vector3(p.x, h * 0.5, p.y), Vector3(0.1, h, 0.1), Color(0.25, 0.56, 0.22))
		_put("fsph", Vector3(p.x, h + 0.02, p.y), Vector3.ONE * _r(0.13, 0.22), c1 if _rng.randf() < 0.6 else c2)


func _grass_tufts(rect: Rect2, n: int) -> void:
	for i in n:
		var h := _r(0.1, 0.22)
		_put("tuft", Vector3(_r(rect.position.x, rect.end.x), h * 0.5, _r(rect.position.y, rect.end.y)), Vector3(0.1, h, 0.1), _tint(Color(0.3, 0.6, 0.22), 0.1))


# ================================================================ small props

func _bench(pos: Vector3, yaw: float) -> void:
	var xf := _xf(pos, yaw)
	var wood := _tint(WOOD, 0.06)
	_rbl(xf, Vector3(0, 0.46, 0), Vector3(1.6, 0.07, 0.5), 0.03, wood)
	_rbl(xf, Vector3(0, 0.78, -0.22), Vector3(1.6, 0.42, 0.06), 0.03, wood)
	for lx: float in [-0.7, 0.7]:
		_rbl(xf, Vector3(lx, 0.23, 0), Vector3(0.07, 0.46, 0.46), 0.03, METAL)
	_col_box(pos + Vector3(0, 0.45, 0).rotated(Vector3.UP, yaw), Vector3(1.6, 0.9, 0.55), yaw)


func _bin(pos: Vector3) -> void:
	_put("cyl", pos + Vector3(0, 0.4, 0), Vector3(0.52, 0.8, 0.52), Color(0.22, 0.46, 0.34))
	_put("sphere", pos + Vector3(0, 0.82, 0), Vector3(0.58, 0.2, 0.58), Color(0.17, 0.36, 0.27))
	_col_cyl(pos + Vector3(0, 0.45, 0), 0.27, 0.9)


func _hydrant(pos: Vector3) -> void:
	var red := Color(0.86, 0.2, 0.18)
	_put("cyl", pos + Vector3(0, 0.3, 0), Vector3(0.26, 0.6, 0.26), red)
	_put("sphere", pos + Vector3(0, 0.62, 0), Vector3(0.3, 0.22, 0.3), red.lightened(0.05))
	_put("cyl", pos + Vector3(0, 0.42, 0), Vector3(0.18, 0.5, 0.18), red.darkened(0.08), Basis(Vector3.FORWARD, PI / 2))
	_put("cyl", pos + Vector3(0, 0.05, 0), Vector3(0.34, 0.1, 0.34), red.darkened(0.2))
	_col_cyl(pos + Vector3(0, 0.35, 0), 0.17, 0.7)


func _mailbox(pos: Vector3, yaw: float) -> void:
	var xf := _xf(pos, yaw)
	var col := _pick(FENCE_COLORS)
	_putl(xf, "cyl", Vector3(0, 0.55, 0), Vector3(0.09, 1.1, 0.09), WOOD.darkened(0.1))
	_rbl(xf, Vector3(0, 1.2, 0), Vector3(0.26, 0.24, 0.42), 0.1, Color(0.25, 0.42, 0.72).lerp(col, 0.2))
	_rbl(xf, Vector3(0.16, 1.28, 0.05), Vector3(0.025, 0.14, 0.08), 0.01, Color(0.9, 0.2, 0.15))
	_col_cyl(pos + Vector3(0, 0.6, 0), 0.14, 1.2)


func _gnome(pos: Vector3) -> void:
	_put("cone", pos + Vector3(0, 0.17, 0), Vector3(0.28, 0.36, 0.28), Color(0.25, 0.45, 0.78))
	_put("sphere", pos + Vector3(0, 0.42, 0), Vector3(0.17, 0.17, 0.17), Color(0.95, 0.78, 0.65))
	_put("cone", pos + Vector3(0, 0.34, 0.07), Vector3(0.17, 0.2, 0.12), Color(0.96, 0.96, 0.94))
	_put("cone", pos + Vector3(0, 0.62, 0), Vector3(0.22, 0.34, 0.22), Color(0.86, 0.15, 0.15))


func _birdbath(pos: Vector3) -> void:
	_put("cyl", pos + Vector3(0, 0.35, 0), Vector3(0.22, 0.7, 0.22), Color(0.72, 0.72, 0.7))
	_put("cyl", pos + Vector3(0, 0.72, 0), Vector3(0.7, 0.1, 0.7), Color(0.78, 0.78, 0.76))
	_put("water", pos + Vector3(0, 0.76, 0), Vector3(0.58, 0.04, 0.58), Color(0.35, 0.6, 0.8))
	_put("cyl", pos + Vector3(0, 0.05, 0), Vector3(0.45, 0.1, 0.45), Color(0.68, 0.68, 0.66))
	_col_cyl(pos + Vector3(0, 0.4, 0), 0.35, 0.8)


func _rocks(c: Vector2, n: int, spread: float, big := 0.6) -> void:
	for i in n:
		var a := _r(0.0, TAU)
		var d := _r(0.0, spread)
		var g := _r(0.5, 0.75)
		var w := _r(0.5, 1.0) * big
		_put("sphere", Vector3(c.x + cos(a) * d, 0.05, c.y + sin(a) * d), Vector3(w, w * _r(0.4, 0.65), w * _r(0.7, 1.0)), Color(g, g, g * 0.95), Basis(Vector3.UP, _r(0.0, TAU)))


func _stones(from: Vector2, to: Vector2, n: int) -> void:
	for i in n:
		var t := (i + 0.5) / n
		var p := from.lerp(to, t) + Vector2(_r(-0.2, 0.2), _r(-0.2, 0.2))
		var g := _r(0.6, 0.74)
		_disc(p, Vector2(_r(0.5, 0.7), _r(0.4, 0.55)), 0.0, Color(g, g, g * 0.96), 0.05, _r(0.0, PI))


## Pond made of overlapping ellipses (cx, cz, rx, rz): mud rim, water, rocks, lily pads, reeds.
func _pond(lobes: Array[Vector4], pads: int, rim_rocks := 8) -> void:
	for l in lobes:
		_disc(Vector2(l.x, l.y), Vector2(l.z, l.w) * 2.0 + Vector2.ONE * 0.8, -0.012, Color(0.38, 0.30, 0.20), 0.03)
	for l in lobes:
		_disc(Vector2(l.x, l.y), Vector2(l.z, l.w) * 2.0, -0.006, Color(0.20, 0.50, 0.68), 0.03, 0.0, "water")
	for l in lobes:
		for i in rim_rocks:
			var a := (i + _r(-0.3, 0.3)) * TAU / rim_rocks
			var p := Vector2(l.x + cos(a) * (l.z + 0.35), l.y + sin(a) * (l.w + 0.35))
			if not _in_lobes(p, lobes, 0.0):
				_rocks(p, 1, 0.1, 1.1)
				if _rng.randf() < 0.4:
					for k in 3:
						var h := _r(0.7, 1.2)
						_put("tuft", Vector3(p.x + _r(-0.4, 0.4), h * 0.5, p.y + _r(-0.4, 0.4)), Vector3(0.12, h, 0.12), Color(0.3, 0.55, 0.25))
	for i in pads:
		var l := lobes[_rng.randi() % lobes.size()]
		var a := _r(0.0, TAU)
		var d := sqrt(_rng.randf()) * 0.75
		var p := Vector2(l.x + cos(a) * l.z * d, l.y + sin(a) * l.w * d)
		_disc(p, Vector2.ONE * _r(0.5, 0.8), 0.002, Color(0.25, 0.6, 0.27), 0.01)
		if _rng.randf() < 0.3:
			_put("fsph", Vector3(p.x, 0.05, p.y), Vector3.ONE * 0.16, Color(1.0, 0.65, 0.82))


func _in_lobes(p: Vector2, lobes: Array[Vector4], margin: float) -> bool:
	for l in lobes:
		var dx := (p.x - l.x) / (l.z + margin)
		var dz := (p.y - l.y) / (l.w + margin)
		if dx * dx + dz * dz < 1.0:
			return true
	return false


## A parked car, front towards local +Z. `sc` shrinks it uniformly.
func _car(pos: Vector3, yaw: float, col: Color, sc := 1.0) -> void:
	var xf := _xf(pos, yaw, sc)
	_rbl(xf, Vector3(0, 0.66, 0), Vector3(1.8, 0.62, 4.2), 0.26, col)
	_rbl(xf, Vector3(0, 1.17, -0.25), Vector3(1.55, 0.58, 2.3), 0.24, col.lightened(0.04))
	_rbl(xf, Vector3(0, 1.2, -0.25), Vector3(1.6, 0.34, 2.0), 0.12, Color(0.22, 0.30, 0.40))
	for sx: float in [-1.0, 1.0]:
		for z: float in [-1.3, 1.3]:
			_putl(xf, "cyl", Vector3(sx * 0.9, 0.33, z), Vector3(0.66, 0.26, 0.66), Color(0.1, 0.1, 0.12), Basis(Vector3.FORWARD, PI / 2))
			_putl(xf, "cyl", Vector3(sx * 1.0, 0.33, z), Vector3(0.34, 0.1, 0.34), Color(0.75, 0.76, 0.78), Basis(Vector3.FORWARD, PI / 2))
		_putl(xf, "glow", Vector3(sx * 0.6, 0.72, 2.08), Vector3(0.26, 0.2, 0.12), Color(1, 0.95, 0.75))
		_putl(xf, "fsph", Vector3(sx * 0.62, 0.74, -2.08), Vector3(0.24, 0.16, 0.1), Color(0.8, 0.1, 0.1))
	_rbl(xf, Vector3(0, 0.4, 2.05), Vector3(1.84, 0.16, 0.2), 0.07, Color(0.2, 0.2, 0.22))
	_rbl(xf, Vector3(0, 0.4, -2.05), Vector3(1.84, 0.16, 0.2), 0.07, Color(0.2, 0.2, 0.22))
	_col_box(pos + Vector3(0, 0.7 * sc, 0), Vector3(1.8, 1.4, 4.2) * sc, yaw)


# ================================================================ ground

func _ground() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(1800, 1800)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = Materials.surface(Materials.GRASS, GRASS)
	mi.position = Vector3(0, GROUND_Y, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var c := Town.BOUNDS.get_center()
	_col_box(Vector3(c.x, GROUND_Y - 0.5, c.y), Vector3(Town.BOUNDS.size.x + 60.0, 1.0, Town.BOUNDS.size.y + 60.0))


# ================================================================ streets

func _streets() -> void:
	var b := Town.BOUNDS
	var hw := Town.STREET_WIDTH * 0.5
	var sw := Town.SIDEWALK_WIDTH
	var ns_cuts: Array[Vector2] = []
	for sx: float in Town.STREETS_NS:
		ns_cuts.append(Vector2(sx, hw))
	var ew_cuts: Array[Vector2] = []
	for ez: float in Town.STREETS_EW:
		ew_cuts.append(Vector2(ez, hw + sw))
	for c: float in Town.STREETS_EW:
		_slab(Rect2(b.position.x, c - hw, b.size.x, Town.STREET_WIDTH), ASPHALT_TOP, ASPHALT, 0.2, "asphalt")
		for s: float in [-1.0, 1.0]:
			var cuts: Array[Vector2] = ns_cuts.duplicate()
			if is_equal_approx(c, 23.5) and s < 0.0:
				cuts.append(Vector2(0.0, 2.5))   # our driveway crosses this sidewalk
			for iv in _spans(b.position.x, b.end.x, _sorted(cuts)):
				_slab(Rect2(iv.x, c + (hw if s > 0.0 else -hw - sw), iv.y - iv.x, sw), WALK_TOP, WALK, 0.2, "walk")
	for c: float in Town.STREETS_NS:
		_slab(Rect2(c - hw, b.position.y, Town.STREET_WIDTH, b.size.y), ASPHALT_TOP, ASPHALT, 0.2, "asphalt")
		for s: float in [-1.0, 1.0]:
			for iv in _spans(b.position.y, b.end.y, _sorted(ew_cuts.duplicate())):
				_slab(Rect2(c + (hw if s > 0.0 else -hw - sw), iv.x, sw, iv.y - iv.x), WALK_TOP, WALK, 0.2, "walk")
	# centre dashes, zebra crossings
	for c: float in Town.STREETS_EW:
		var x := b.position.x + 3.0
		while x < b.end.x - 3.0:
			if _far_from(x, Town.STREETS_NS, 8.5):
				_slab(Rect2(x - 1.2, c - 0.07, 2.4, 0.14), -0.004, LINE_YELLOW, 0.01, "paint")
			x += 5.4
	for c: float in Town.STREETS_NS:
		var z := b.position.y + 3.0
		while z < b.end.y - 3.0:
			if _far_from(z, Town.STREETS_EW, 8.5):
				_slab(Rect2(c - 0.07, z - 1.2, 0.14, 2.4), -0.004, LINE_YELLOW, 0.01, "paint")
			z += 5.4
	for ez: float in Town.STREETS_EW:
		for sx: float in Town.STREETS_NS:
			for d: float in [-1.0, 1.0]:
				for k in range(-3, 4):
					_slab(Rect2(sx + d * 5.8 - 1.5, ez + k - 0.27, 3.0, 0.54), -0.004, LINE_WHITE, 0.01, "paint")
					_slab(Rect2(sx + k - 0.27, ez + d * 5.8 - 1.5, 0.54, 3.0), -0.004, LINE_WHITE, 0.01, "paint")
	# manhole covers
	for c: float in Town.STREETS_EW:
		for i in 4:
			var x := _r(b.position.x + 10.0, b.end.x - 10.0)
			if _far_from(x, Town.STREETS_NS, 9.0):
				_manhole(Vector2(x, c + _r(1.0, 2.2) * (1.0 if _rng.randf() < 0.5 else -1.0)))
	for c: float in Town.STREETS_NS:
		for i in 3:
			var z := _r(b.position.y + 10.0, b.end.y - 10.0)
			if _far_from(z, Town.STREETS_EW, 9.0):
				_manhole(Vector2(c + _r(1.0, 2.2) * (1.0 if _rng.randf() < 0.5 else -1.0), z))


func _manhole(c: Vector2) -> void:
	_disc(c, Vector2.ONE * 0.95, 0.0, Color(0.20, 0.20, 0.22), 0.02)
	_disc(c, Vector2.ONE * 0.7, 0.005, Color(0.30, 0.30, 0.33), 0.01)


func _far_from(v: float, centres: Array[float], dist: float) -> bool:
	for c: float in centres:
		if absf(v - c) < dist:
			return false
	return true


# ================================================================ street furniture

func _street_furniture() -> void:
	for c: float in Town.STREETS_EW:
		for s: float in [-1.0, 1.0]:
			_street_side(c, true, s)
	for c: float in Town.STREETS_NS:
		for s: float in [-1.0, 1.0]:
			_street_side(c, false, s)
	_bus_stop(_sw_pos(23.5, true, 1.0, 8.0), 0.0)
	_bus_stop(_sw_pos(-66.5, true, 1.0, -100.0), 0.0)
	_bus_stop(_sw_pos(113.5, true, -1.0, 30.0), PI)
	_bus_stop(_sw_pos(62.0, false, 1.0, -45.0), -PI / 2.0)
	_bus_stop(_sw_pos(-64.0, false, -1.0, 80.0), PI / 2.0)
	# parked cars along the kerbs
	for c: float in Town.STREETS_EW:
		for s: float in [-1.0, 1.0]:
			for i in 4:
				var x := _r(Town.BOUNDS.position.x + 12.0, Town.BOUNDS.end.x - 12.0)
				if _far_from(x, Town.STREETS_NS, 14.0) and absf(x - 8.0) > 5.0:
					_car(Vector3(x, 0, c + s * 2.4), PI / 2.0 if s > 0.0 else -PI / 2.0, _pick(CAR_COLORS))
	for c: float in Town.STREETS_NS:
		for s: float in [-1.0, 1.0]:
			for i in 3:
				var z := _r(Town.BOUNDS.position.y + 12.0, Town.BOUNDS.end.y - 12.0)
				if _far_from(z, Town.STREETS_EW, 14.0):
					_car(Vector3(c + s * 2.4, 0, z), PI if s > 0.0 else 0.0, _pick(CAR_COLORS))


## World position on a sidewalk: street centre `c`, along-street coordinate, side s, offset from the centre.
func _sw_pos(c: float, ew: bool, s: float, along: float, off := 4.6) -> Vector3:
	return Vector3(along, 0, c + s * off) if ew else Vector3(c + s * off, 0, along)


func _street_side(c: float, ew: bool, s: float) -> void:
	var b := Town.BOUNDS
	var lo := (b.position.x if ew else b.position.y) + 6.0
	var hi := (b.end.x if ew else b.end.y) - 6.0
	var crossings: Array[float] = Town.STREETS_NS if ew else Town.STREETS_EW
	var to_street := Vector2(0, -s) if ew else Vector2(-s, 0)
	var yaw := _face_yaw(to_street)
	var lamps: Array[float] = []
	var a := lo + 4.0 + (15.0 if s > 0.0 else 0.0)
	while a < hi:
		if _far_from(a, crossings, 9.0) and not (ew and is_equal_approx(c, 23.5) and s < 0.0 and absf(a) < 6.0):
			_lamp(_sw_pos(c, ew, s, a, 4.9), to_street)
			lamps.append(a)
		a += 30.0
	a = lo + _r(4.0, 12.0)
	while a < hi:
		var ok := _far_from(a, crossings, 10.0) and not (ew and is_equal_approx(c, 23.5) and s < 0.0 and absf(a) < 6.0)
		for l in lamps:
			if absf(l - a) < 3.0:
				ok = false
		if ok:
			var r := _rng.randf()
			if r < 0.3:
				_bench(_sw_pos(c, ew, s, a, 5.05), yaw)
			elif r < 0.5:
				_bin(_sw_pos(c, ew, s, a, 5.0))
			elif r < 0.7:
				_hydrant(_sw_pos(c, ew, s, a, 3.9))
		a += _r(12.0, 22.0)


func _lamp(pos: Vector3, dir: Vector2) -> void:
	var top := pos + Vector3(dir.x * 1.1, 4.7, dir.y * 1.1)
	_put("cyl", pos + Vector3(0, 0.15, 0), Vector3(0.44, 0.3, 0.44), METAL.lightened(0.05))
	_put("cyl", pos + Vector3(0, 2.4, 0), Vector3(0.14, 4.8, 0.14), METAL)
	_put("sphere", pos + Vector3(0, 4.8, 0), Vector3(0.22, 0.22, 0.22), METAL)
	_rod(pos + Vector3(0, 4.7, 0), top, 0.09, METAL)
	_put("sphere", top + Vector3(0, 0.04, 0), Vector3(0.62, 0.2, 0.42), METAL.lightened(0.08), Basis(Vector3.UP, _face_yaw(dir) + PI / 2.0))
	_put("glow", top + Vector3(0, -0.07, 0), Vector3(0.44, 0.16, 0.3), Color(1.0, 0.88, 0.6), Basis(Vector3.UP, _face_yaw(dir) + PI / 2.0))
	_col_cyl(pos + Vector3(0, 2.0, 0), 0.14, 4.0)


## Bus shelter: roof, glass back, bench and a round sign. Opens towards local +Z (the street).
func _bus_stop(pos: Vector3, yaw: float) -> void:
	var xf := _xf(pos, yaw)
	var frame := Color(0.22, 0.46, 0.52)
	_rbl(xf, Vector3(0, 2.5, 0), Vector3(3.6, 0.12, 1.6), 0.05, frame)
	for px: float in [-1.6, 1.6]:
		_putl(xf, "cyl", Vector3(px, 1.25, -0.6), Vector3(0.09, 2.5, 0.09), METAL)
	_rbl(xf, Vector3(0, 1.3, -0.62), Vector3(3.2, 1.9, 0.05), 0.02, Color(0.6, 0.8, 0.9, 0.35), "glass")
	_rbl(xf, Vector3(0, 0.5, -0.32), Vector3(2.4, 0.07, 0.42), 0.03, WOOD)
	for lx: float in [-1.0, 1.0]:
		_rbl(xf, Vector3(lx, 0.25, -0.32), Vector3(0.06, 0.5, 0.36), 0.025, METAL)
	_putl(xf, "cyl", Vector3(2.2, 1.35, 0.5), Vector3(0.07, 2.7, 0.07), METAL)
	_putl(xf, "cyl", Vector3(2.2, 2.5, 0.5), Vector3(0.62, 0.05, 0.62), Color(0.15, 0.4, 0.85), Basis(Vector3.RIGHT, PI / 2.0))
	_col_box(xf * Vector3(0, 1.25, -0.62), Vector3(3.6, 2.5, 0.3), yaw)
	_col_cyl(xf * Vector3(2.2, 1.3, 0.5), 0.1, 2.6)


# ================================================================ our own lot

func _home() -> void:
	var h := Town.HOME
	# driveway across the sidewalk to the street, with joints
	_slab(Rect2(-2.5, 4.5, 5.0, 15.9), 0.0, Color(0.72, 0.70, 0.66), 0.06, "walk")
	for z in range(1, 6):
		_slab(Rect2(-2.5, 4.5 + z * 2.6, 5.0, 0.05), 0.002, Color(0.52, 0.50, 0.47), 0.01)
	# front path to the door (-14, 6)
	_slab(Rect2(-14.7, 6.0, 1.4, 12.0), 0.0, PAVING, 0.06, "walk")
	_slab(Rect2(-15.4, 6.0, 2.8, 0.9), 0.0, PAVING.darkened(0.04), 0.06, "walk")
	# lighter lawns: the open east lawn and the main front/west lawn
	_slab(Rect2(h.position.x, h.position.y, 48.0, 45.0), LAWN_TOP, GRASS.lerp(Color(0.5, 0.74, 0.32), 0.3), 0.02, "lawn")
	_slab(Rect2(6.0, -12.0, 8.0, 28.0), LAWN_TOP + 0.004, Color(0.48, 0.72, 0.31), 0.02, "lawn")
	# boundary: front hedges with gaps for the path and driveway, west and north hedges
	var front_a := Vector2(-33.4, 17.3)
	_hedge(front_a, Vector2(-15.4, 17.3), 0.8, 0.8)
	_hedge(Vector2(-12.6, 17.3), Vector2(-3.4, 17.3), 0.8, 0.8)
	_hedge(Vector2(-33.6, -26.8), Vector2(-33.6, 17.3), 1.7, 1.1)
	_hedge(Vector2(-33.6, -26.8), Vector2(14.0, -26.8), 1.7, 1.1)
	_mailbox(Vector3(-16.6, 0, 17.75), 0.0)
	# front-yard beds (outside the house clear rectangle)
	_flowers(Rect2(-31.5, 14.2, 7.0, 1.8), 40)
	_flowers(Rect2(-10.5, 14.2, 5.0, 1.8), 26)
	_bush(Vector3(-18.0, 0, 15.0), 0.9, true)
	_bush(Vector3(-21.0, 0, 15.3), 0.8)
	_bush(Vector3(-1.0, 0, 15.5), 0.8)
	_tree(Vector3(-28.5, 0, 12.0), 3, 1.0)
	_tree(Vector3(-5.5, 0, 15.5), 0, 0.9)
	# west side yard
	_tree(Vector3(-30.0, 0, -2.0), 0, 1.15)
	_tree(Vector3(-29.0, 0, 6.5), 2, 0.95)
	_tree(Vector3(-31.5, 0, 14.0), 1, 0.8)
	_bush(Vector3(-27.5, 0, 1.5), 1.0, true)
	_bush(Vector3(-32.0, 0, 2.5), 1.1)
	_bush(Vector3(-26.5, 0, 9.5), 0.9)
	_bench(Vector3(-27.5, 0, -2.0), -PI / 2.0)
	_flowers(Rect2(-32.5, 8.0, 1.5, 4.0), 16)
	_garden()


## The back garden (north of the house and garage), see the header for the main landmarks.
func _garden() -> void:
	var white := WHITE
	# picket enclosure with gates east (3.5, -14) and south (-14, -11)
	_fence(Vector2(-32.2, -25.2), Vector2(3.5, -25.2), 0, 1.0, white)
	_fence(Vector2(3.5, -25.2), Vector2(3.5, -6.0), 0, 1.0, white, [Vector2(11.2, 2.0)] as Array[Vector2])
	_fence(Vector2(3.5, -6.0), Vector2(-3.8, -6.0), 0, 1.0, white)
	_fence(Vector2(-3.8, -6.0), Vector2(-3.8, -11.0), 0, 1.0, white)
	_fence(Vector2(-3.8, -11.0), Vector2(-24.6, -11.0), 0, 1.0, white, [Vector2(10.2, 2.0)] as Array[Vector2])
	_fence(Vector2(-24.6, -11.0), Vector2(-24.6, -6.0), 0, 1.0, white)
	_fence(Vector2(-24.6, -6.0), Vector2(-32.2, -6.0), 0, 1.0, white)
	_fence(Vector2(-32.2, -6.0), Vector2(-32.2, -25.2), 0, 1.0, white)
	_gate(Vector2(3.5, -14.0), false, 2.0, white)
	_gate(Vector2(-14.0, -11.0), true, 2.0, white)
	# pond with rocks and lily pads, stepping stones to both gates
	_pond([Vector4(-16.0, -18.5, 3.4, 2.4), Vector4(-13.6, -17.6, 2.0, 1.7), Vector4(-18.5, -19.9, 1.9, 1.5)] as Array[Vector4], 9)
	_stones(Vector2(-14.0, -12.0), Vector2(-14.2, -15.0), 4)
	_stones(Vector2(2.5, -14.0), Vector2(-9.0, -15.5), 9)
	# greenhouse (-6, -21.5)
	var gh := _xf(Vector3(-6.0, 0, -21.5), 0.0)
	_rbl(gh, Vector3(0, 0.25, 0), Vector3(4.2, 0.5, 3.2), 0.08, Color(0.9, 0.9, 0.86))
	_rbl(gh, Vector3(0, 1.3, 0), Vector3(4.0, 1.5, 3.0), 0.1, Color(0.7, 0.88, 0.92, 0.35), "glass")
	_roof(Vector3(4.4, 1.0, 3.4), Vector3(-6.0, 2.05, -21.5), Color(0.72, 0.9, 0.94))
	for px: float in [-2.0, 2.0]:
		for pz: float in [-1.5, 1.5]:
			_putl(gh, "cyl", Vector3(px, 1.1, pz), Vector3(0.1, 2.2, 0.1), Color(0.9, 0.9, 0.86))
	_rbl(gh, Vector3(0, 0.75, -1.1), Vector3(3.0, 0.9, 0.7), 0.08, WOOD)
	for i in 8:
		_put("leaf", gh * Vector3(-1.3 + i * 0.37, 1.3, -1.1), Vector3.ONE * _r(0.25, 0.4), _pick(LEAVES))
	_col_box(Vector3(-6.0, 1.2, -21.5), Vector3(4.2, 2.4, 3.2))
	# shed (-28.5, -22.5), door facing the garden
	var sh := _xf(Vector3(-28.5, 0, -22.5), 0.0)
	_rbl(sh, Vector3(0, 1.2, 0), Vector3(3.2, 2.4, 2.4), 0.1, Color(0.58, 0.38, 0.24))
	_roof(Vector3(3.8, 0.9, 3.0), Vector3(-28.5, 2.4, -22.5), Color(0.3, 0.34, 0.4))
	_rbl(sh, Vector3(-0.6, 1.0, 1.22), Vector3(0.9, 1.9, 0.08), 0.03, Color(0.25, 0.42, 0.56))
	_rbl(sh, Vector3(0.8, 1.4, 1.22), Vector3(0.7, 0.6, 0.06), 0.03, Color(0.6, 0.8, 0.9))
	_col_box(Vector3(-28.5, 1.2, -22.5), Vector3(3.2, 2.4, 2.4))
	# vegetable patch
	for r in 3:
		var bz := -17.6 + r * 1.4
		_rb(Vector3(3.4, 0.28, 0.9), 0.08, Vector3(-28.5, 0.12, bz), Color(0.38, 0.25, 0.16))
		for i in 6:
			var px := -29.9 + i * 0.56
			if r == 0:
				_put("leaf", Vector3(px, 0.34, bz), Vector3(0.4, 0.3, 0.4), Color(0.55, 0.78, 0.4))
			elif r == 1:
				_put("tuft", Vector3(px, 0.4, bz), Vector3(0.22, 0.4, 0.22), Color(0.3, 0.62, 0.25))
				_put("cone", Vector3(px, 0.2, bz), Vector3(0.12, 0.14, 0.12), Color(0.95, 0.5, 0.1), Basis(Vector3.RIGHT, PI))
			else:
				_rod(Vector3(px, 0.1, bz), Vector3(px, 0.9, bz), 0.03, WOOD)
				_put("sphere", Vector3(px, 0.4, bz + 0.05), Vector3.ONE * 0.16, Color(0.9, 0.2, 0.15))
				_put("sphere", Vector3(px, 0.65, bz - 0.05), Vector3.ONE * 0.14, Color(0.92, 0.3, 0.2))
	# flower beds, bench, washing line
	_flowers(Rect2(-25.0, -24.8, 6.0, 1.3), 50)
	_flowers(Rect2(-12.5, -24.8, 4.0, 1.3), 30)
	_flowers(Rect2(-2.0, -24.8, 5.2, 1.3), 34)
	_flowers(Rect2(1.6, -22.0, 1.4, 6.0), 36)
	_round_bed(Vector2(-22.5, -14.5), 1.1, 20)
	_bench(Vector3(-9.5, 0, -17.5), -PI / 2.0)
	for pz: float in [-22.4, -15.8]:
		_put("cyl", Vector3(-0.5, 1.1, pz), Vector3(0.1, 2.2, 0.1), WOOD.darkened(0.1))
		_put("sphere", Vector3(-0.5, 2.22, pz), Vector3(0.14, 0.14, 0.14), WOOD)
		_col_cyl(Vector3(-0.5, 1.1, pz), 0.1, 2.2)
	_rod(Vector3(-0.5, 2.0, -22.4), Vector3(-0.5, 1.9, -15.8), 0.015, Color(0.9, 0.9, 0.9))
	var cloth: Array[Color] = [Color(0.9, 0.3, 0.3), Color(0.3, 0.5, 0.9), Color(0.95, 0.85, 0.3), Color(0.96, 0.96, 0.95), Color(0.4, 0.75, 0.45)]
	for i in 6:
		var cz := -21.8 + i * 1.0
		_rb(Vector3(0.03, _r(0.5, 0.8), _r(0.35, 0.55)), 0.012, Vector3(-0.5, 1.6, cz), cloth[i % cloth.size()])
	# trees, bushes, grass
	_tree(Vector3(-21.5, 0, -23.0), 3, 1.0)
	_tree(Vector3(-24.0, 0, -9.0), 0, 1.0)
	_tree(Vector3(-10.5, 0, -23.5), 1, 0.9)
	_tree(Vector3(0.5, 0, -9.5), 4, 0.9)
	_tree(Vector3(-30.5, 0, -10.5), 2, 0.8)
	for bp: Vector2 in [Vector2(-31.0, -8.0), Vector2(-2.0, -8.0), Vector2(2.2, -24.0), Vector2(-31.0, -24.0), Vector2(-9.5, -12.5), Vector2(-5.5, -12.5), Vector2(2.4, -10.0), Vector2(-20.5, -12.5)]:
		_bush(Vector3(bp.x, 0, bp.y), _r(0.8, 1.1), _rng.randf() < 0.4)
	_grass_tufts(Rect2(-31.5, -24.5, 34.0, 12.5), 90)


# ================================================================ neighbours' yards

func _lots() -> void:
	for lot: Dictionary in Town.lots():
		_lot_rects.append(Town.lot_rect(lot))
		_yard(lot)


func _yard(lot: Dictionary) -> void:
	var y := Yard.new(lot["pos"] as Vector3, lot["yaw"] as float)
	var sz: int = lot["size"]
	var fp: Vector2 = Town.FOOTPRINTS[sz]
	var door_v := 17.0 - fp.y * 0.5
	var toward := y.yaw(true)
	_slab(y.rect(-11.95, 0.6, 11.95, 33.95), LAWN_TOP, _tint(GRASS.lerp(Color(0.48, 0.72, 0.3), _r(0.0, 0.6)), 0.03), 0.02, "lawn")
	var has_drive := _rng.randf() < 0.4
	var drive_u := 6.0 * (1.0 if _rng.randf() < 0.5 else -1.0)
	# borders: sides and back
	var style := _rng.randi() % 4
	var fcol := _pick(FENCE_COLORS)
	var hedge_h := 1.2 + 0.2 * sz
	for su: float in [-1.0, 1.0]:
		var a := y.p2(su * 11.5, 0.8)
		var b := y.p2(su * 11.5, 33.6)
		match style:
			0, 3:
				_hedge(a, b, hedge_h, 1.0)
			1:
				_fence(a, b, 0, 1.1, fcol)
			_:
				_fence(a, b, 1, 1.1, fcol)
	var back_a := y.p2(-11.5, 33.6)
	var back_b := y.p2(11.5, 33.6)
	match style:
		0:
			_hedge(back_a, back_b, hedge_h, 1.0)
		2:
			_fence(back_a, back_b, 1, 1.1, fcol)
		_:
			_fence(back_a, back_b, 0, 1.1, fcol)
	# front: open, a low fence or a low hedge, with gaps for the path and the driveway
	var front_style := _rng.randi() % 4
	if front_style == 1 or front_style == 2:
		var gaps: Array[Vector2] = [Vector2(11.5, 2.2)]
		if has_drive:
			gaps.append(Vector2(11.5 + drive_u, 3.8))
			_sort_gaps(gaps)
		var fa := y.p2(-11.5, 1.5)
		var fb := y.p2(11.5, 1.5)
		if front_style == 1:
			_fence(fa, fb, 0, 0.55, fcol, gaps)
		else:
			_hedge(fa, fb, 0.7, 0.7, gaps)
	# path from the door to the sidewalk, and the doorstep
	var path_col := [PAVING, Color(0.72, 0.5, 0.4), Color(0.62, 0.62, 0.65), Color(0.66, 0.5, 0.34)][_rng.randi() % 4] as Color
	if _rng.randf() < 0.6:
		_slab(y.rect(-0.7, 0.5, 0.7, door_v), 0.0, path_col, 0.06, "walk")
	else:
		var v := 1.0
		while v < door_v:
			_disc(y.p2(_r(-0.15, 0.15), v), Vector2(_r(0.9, 1.1), _r(0.6, 0.75)), 0.0, _tint(path_col, 0.04), 0.06, _r(-0.2, 0.2))
			v += 1.0
	_slab(y.rect(-1.4, door_v - 0.9, 1.4, door_v), 0.0, path_col.darkened(0.05), 0.06, "walk")
	_mailbox(y.p(_r(2.2, 4.0) * (1.0 if _rng.randf() < 0.5 else -1.0), 0.5), toward)
	# optional driveway pad with a car (the front yard is only ~4 m deep, so the car is a little small)
	if has_drive:
		_slab(y.rect(drive_u - 1.7, 0.5, drive_u + 1.7, 4.9), 0.0, Color(0.7, 0.68, 0.64), 0.06, "walk")
		if _rng.randf() < 0.8:
			_car(y.p(drive_u, 2.7), toward + (PI if _rng.randf() < 0.5 else 0.0), _pick(CAR_COLORS), 0.9)
	# front yard decoration
	var left_free := not (has_drive and drive_u < 0.0)
	var right_free := not (has_drive and drive_u > 0.0)
	if left_free:
		_flowers(y.rect(-5.5, 1.8, -1.6, 4.0), 14 + 8 * sz)
	if right_free:
		_flowers(y.rect(1.6, 1.8, 5.5, 4.0), 14 + 8 * sz)
	var deco := _rng.randi() % 4
	if deco == 0 and left_free:
		_gnome(y.p(-1.4, 4.4))
	elif deco == 1 and left_free:
		_birdbath(y.p(-3.5, 3.0))
	elif deco == 2 and right_free:
		_gnome(y.p(1.5, 4.4))
		_gnome(y.p(5.2, 4.0))
	for su: float in [-1.0, 1.0]:
		var tr := _rng.randf()
		if tr < 0.6 or sz == 2:
			_random_tree(y.p(su * 9.4, 3.2), _r(0.75, 0.95) + 0.08 * sz)
		else:
			_bush(y.p(su * 9.0, 3.0), _r(0.9, 1.3), true)
	# side strips: bushes
	var v := _r(8.0, 11.0)
	while v < 31.0:
		_bush(y.p((11.0 if _rng.randf() < 0.5 else -11.0) * 0.98 + _r(-0.1, 0.1), v), _r(0.7, 1.1), _rng.randf() < 0.3)
		v += _r(4.0, 7.0)
	# back strip: corner trees and the odd extras
	_random_tree(y.p(-9.0, 31.4), _r(0.85, 1.05) + 0.1 * sz)
	_random_tree(y.p(9.0, 31.4), _r(0.85, 1.05) + 0.1 * sz)
	if sz >= 1:
		_flowers(y.rect(-6.0, 32.2, -3.5, 33.2), 14)
	var items: Array[int] = [0, 1, 2, 3, 4, 5, 6]
	var slots: Array[float] = [-6.5, -1.5, 3.5, 7.5]
	var count := mini(1 + sz + _rng.randi() % 2, 3)
	for i in count:
		var it: int = items.pop_at(_rng.randi() % items.size())
		_back_item(it, y, slots[i] + _r(-0.5, 0.5), 30.9 + (0.6 if it == 3 else 0.0), toward)
	# side extras
	if _rng.randf() < 0.3 + 0.15 * sz:
		_dish(y.p(-10.9 if _rng.randf() < 0.5 else 10.9, _r(14.0, 24.0)))
	if sz == 2:
		_birdbath(y.p(-9.0, 7.0) if left_free else y.p(9.0, 7.0))
		_flowers(y.rect(-5.5, 4.2, -1.6, 4.9), 12)
	_grass_tufts(y.rect(-9.0, 1.0, 9.0, 4.8), 16)


func _sort_gaps(gaps: Array[Vector2]) -> void:
	gaps.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)


## Yard extras for the back strip: 0 woodpile, 1 barbecue, 2 sandbox, 3 trampoline, 4 paddling pool, 5 sunbed + parasol, 6 small shed.
func _back_item(kind: int, y: Yard, u: float, v: float, toward: float) -> void:
	var pos := y.p(u, v)
	var xf := _xf(pos, toward)
	match kind:
		0:
			for row in 3:
				for k in 3 - row:
					_putl(xf, "cyl", Vector3(-0.3 * (2 - row) + 0.6 * k + 0.3 * row, 0.15 + 0.27 * row, 0.0), Vector3(0.28, 1.5, 0.28), _tint(WOOD, 0.1), Basis(Vector3.RIGHT, PI / 2.0))
			_col_box(pos + Vector3(0, 0.4, 0), Vector3(1.7, 0.8, 1.5), toward)
		1:
			_putl(xf, "cyl", Vector3(0, 0.75, 0), Vector3(0.7, 0.3, 0.7), Color(0.15, 0.15, 0.17))
			_putl(xf, "sphere", Vector3(0, 0.88, -0.1), Vector3(0.7, 0.35, 0.7), Color(0.2, 0.2, 0.22))
			for a in 3:
				var an := a * TAU / 3.0
				_rod(Vector3(pos.x, 0.75, pos.z) + Vector3(cos(an) * 0.2, 0, sin(an) * 0.2), pos + Vector3(cos(an) * 0.35, 0.0, sin(an) * 0.35), 0.04, METAL)
			_rbl(xf, Vector3(1.0, 0.8, 0), Vector3(0.9, 0.06, 0.5), 0.02, WOOD)
			_rbl(xf, Vector3(1.0, 0.4, 0), Vector3(0.8, 0.8, 0.45), 0.04, Color(0.8, 0.8, 0.78))
			_col_box(pos + Vector3(0.5, 0.45, 0), Vector3(1.8, 0.9, 0.8), toward)
		2:
			var sand := Color(0.92, 0.82, 0.55)
			_slab(Rect2(pos.x - 0.9, pos.z - 0.9, 1.8, 1.8), 0.1, sand, 0.1)
			for e: float in [-1.0, 1.0]:
				_rb(Vector3(2.0, 0.22, 0.14), 0.05, pos + Vector3(0, 0.11, e * 0.93), Color(0.3, 0.55, 0.8))
				_rb(Vector3(0.14, 0.22, 2.0), 0.05, pos + Vector3(e * 0.93, 0.11, 0), Color(0.3, 0.55, 0.8))
		3:
			_disc(Vector2(pos.x, pos.z), Vector2.ONE * 3.2, 0.7, Color(0.25, 0.4, 0.7), 0.1)
			_disc(Vector2(pos.x, pos.z), Vector2.ONE * 2.6, 0.72, Color(0.12, 0.12, 0.15), 0.04)
			for a in 6:
				var an := a * TAU / 6.0
				_rod(pos + Vector3(cos(an) * 1.4, 0.0, sin(an) * 1.4), pos + Vector3(cos(an) * 1.4, 0.65, sin(an) * 1.4), 0.06, METAL)
			_col_cyl(pos + Vector3(0, 0.4, 0), 1.6, 0.8)
		4:
			_disc(Vector2(pos.x, pos.z), Vector2.ONE * 2.6, 0.3, Color(1.0, 0.85, 0.3), 0.3)
			_disc(Vector2(pos.x, pos.z), Vector2.ONE * 2.3, 0.26, Color(0.3, 0.65, 0.88), 0.02, 0.0, "water")
		5:
			_rbl(xf, Vector3(0, 0.35, 0), Vector3(0.7, 0.1, 1.8), 0.05, Color(0.95, 0.95, 0.9))
			_rbl(xf, Vector3(0, 0.55, -0.7), Vector3(0.7, 0.1, 0.6), 0.05, Color(0.95, 0.95, 0.9), "vc")
			_putl(xf, "cyl", Vector3(1.4, 1.1, 0), Vector3(0.06, 2.2, 0.06), METAL)
			_putl(xf, "sphere", Vector3(1.4, 2.2, 0), Vector3(2.2, 0.6, 2.2), _pick(CAR_COLORS))
			_col_box(pos + Vector3(0, 0.3, 0), Vector3(0.8, 0.6, 1.9), toward)
			_col_cyl(pos + Vector3(1.4, 1.1, 0).rotated(Vector3.UP, toward), 0.1, 2.2)
		_:
			_rbl(xf, Vector3(0, 1.0, 0), Vector3(2.2, 2.0, 1.8), 0.08, _tint(Color(0.7, 0.5, 0.32), 0.1))
			_roof(Vector3(2.6, 0.7, 2.2), pos + Vector3(0, 2.0, 0), Color(0.34, 0.36, 0.42), Basis(Vector3.UP, toward))
			_rbl(xf, Vector3(0, 0.9, 0.92), Vector3(0.8, 1.7, 0.06), 0.03, Color(0.3, 0.45, 0.55))
			_col_box(pos + Vector3(0, 1.0, 0), Vector3(2.2, 2.0, 1.8), toward)


func _dish(pos: Vector3) -> void:
	_put("cyl", pos + Vector3(0, 1.4, 0), Vector3(0.08, 2.8, 0.08), METAL)
	_put("sphere", pos + Vector3(0, 2.85, 0), Vector3(0.9, 0.2, 0.9), Color(0.92, 0.92, 0.9), Basis(Vector3.RIGHT, -0.9))
	_rod(pos + Vector3(0, 2.85, 0), pos + Vector3(0, 3.1, 0.35), 0.03, METAL)
	_put("sphere", pos + Vector3(0, 3.12, 0.36), Vector3.ONE * 0.12, METAL)
	_col_cyl(pos + Vector3(0, 1.4, 0), 0.1, 2.8)


# ================================================================ the park

func _park() -> void:
	var pk := Town.PARK
	_slab(pk, LAWN_TOP, GRASS.lerp(Color(0.5, 0.75, 0.32), 0.4), 0.02, "lawn")
	_park_lobes = [Vector4(4.0, 50.0, 8.0, 5.5), Vector4(-2.0, 47.0, 5.0, 4.0), Vector4(12.0, 52.0, 5.5, 4.5)] as Array[Vector4]
	_pond(_park_lobes, 22, 12)
	_rocks(Vector2(4.0, 49.0), 4, 1.0, 0.7)
	# paths: east-west main, loop round the pond, entrances, playground link
	var gravel := Color(0.62, 0.55, 0.42)
	_path([Vector2(-37, 36), Vector2(-30, 36.5), Vector2(-22, 38), Vector2(-8, 37), Vector2(6, 38.5), Vector2(20, 38), Vector2(32, 36), Vector2(49, 37)] as Array[Vector2], 2.4, gravel)
	_path([Vector2(-8, 37.5), Vector2(-12, 46), Vector2(-11, 56), Vector2(-4, 60), Vector2(8, 60), Vector2(18, 59), Vector2(22, 52), Vector2(21, 44), Vector2(20, 38.5)] as Array[Vector2], 2.2, gravel)
	_path([Vector2(-20, 28.5), Vector2(-18, 33), Vector2(-22, 38)] as Array[Vector2], 2.2, gravel)
	_path([Vector2(22, 28.5), Vector2(24, 33), Vector2(20, 38)] as Array[Vector2], 2.2, gravel)
	_path([Vector2(31, 37), Vector2(29, 44), Vector2(27, 51), Vector2(24, 58)] as Array[Vector2], 2.0, gravel)
	_path([Vector2(-11, 46), Vector2(-17, 47.5), Vector2(-23, 49)] as Array[Vector2], 2.0, gravel)
	# fountain plaza (-22, 38)
	var fc := Vector2(-22.0, 38.0)
	_disc(fc, Vector2.ONE * 9.0, 0.0, Color(0.70, 0.67, 0.62), 0.04)
	_disc(fc, Vector2.ONE * 4.6, 0.3, Color(0.72, 0.72, 0.7), 0.5)
	_disc(fc, Vector2.ONE * 4.0, 0.36, Color(0.25, 0.55, 0.75), 0.02, 0.0, "water")
	_put("cyl", Vector3(fc.x, 0.7, fc.y), Vector3(0.5, 1.4, 0.5), Color(0.74, 0.74, 0.72))
	_put("cyl", Vector3(fc.x, 1.3, fc.y), Vector3(1.4, 0.14, 1.4), Color(0.78, 0.78, 0.76))
	_put("water", Vector3(fc.x, 1.9, fc.y), Vector3(0.1, 1.2, 0.1), Color(0.6, 0.82, 0.95))
	_put("sphere", Vector3(fc.x, 2.5, fc.y), Vector3(0.3, 0.3, 0.3), Color(0.6, 0.82, 0.95))
	_col_cyl(Vector3(fc.x, 0.5, fc.y), 2.35, 1.0)
	# gazebo (-24, 50)
	var gz := Vector3(-24.0, 0, 50.0)
	_disc(Vector2(gz.x, gz.z), Vector2.ONE * 6.0, 0.03, Color(0.82, 0.8, 0.74), 0.05)
	for i in 6:
		var an := i * TAU / 6.0
		var pp := gz + Vector3(cos(an) * 2.5, 0, sin(an) * 2.5)
		_put("cyl", pp + Vector3(0, 1.4, 0), Vector3(0.2, 2.8, 0.2), WHITE)
		_col_cyl(pp + Vector3(0, 1.4, 0), 0.12, 2.8)
	_put("cone", gz + Vector3(0, 3.7, 0), Vector3(6.6, 1.7, 6.6), Color(0.3, 0.5, 0.45))
	_put("cyl", gz + Vector3(0, 2.9, 0), Vector3(6.0, 0.2, 6.0), WHITE)
	_put("sphere", gz + Vector3(0, 4.6, 0), Vector3.ONE * 0.4, Color(0.9, 0.8, 0.4))
	_bench(gz + Vector3(0, 0, -1.9), 0.0)
	# playground floor and equipment, x 33..46, z 42..60
	_slab(Rect2(33.0, 42.0, 13.0, 18.0), 0.0, Color(0.82, 0.72, 0.5), 0.05)
	_swings(Vector3(40.0, 0, 46.0))
	_slide(Vector3(43.5, 0, 54.0))
	_seesaw(Vector3(36.0, 0, 52.0))
	_sandbox(Vector3(37.5, 0, 57.0))
	_park_blocks = [Rect2(32.0, 41.0, 15.0, 20.0), Rect2(-27.5, 46.5, 7.0, 7.0), Rect2(-27.0, 33.0, 10.0, 10.0)]
	# picnic tables, benches along the paths, bins, lamps
	_picnic(Vector3(-16.0, 0, 56.0), 0.3)
	_picnic(Vector3(27.0, 0, 33.0), -0.2)
	var step := 0
	for i in range(8, _park_pts.size(), 26):
		var p := _park_pts[i]
		var q := _park_pts[mini(i + 1, _park_pts.size() - 1)]
		var along := (q - p).normalized()
		if along == Vector2.ZERO:
			continue
		var side := Vector2(-along.y, along.x) * (1.0 if step % 2 == 0 else -1.0)
		var bp := p + side * 2.0
		if not _in_blocks(bp) and not _in_lobes(bp, _park_lobes, 0.5):
			_bench(Vector3(bp.x, 0, bp.y), _face_yaw(-side))
			if step % 3 == 0:
				_bin(Vector3(bp.x + along.x * 1.3, 0, bp.y + along.y * 1.3))
		step += 1
	for lp: Vector2 in [Vector2(-8, 35.5), Vector2(16, 36.5), Vector2(-24, 31.0), Vector2(24, 31.0), Vector2(-13, 52), Vector2(21, 56), Vector2(10, 61)]:
		_lamp(Vector3(lp.x, 0, lp.y), Vector2(0, 1))
	# flower beds
	for bed: Vector3 in [Vector3(-30, 41, 1.8), Vector3(-14, 33, 1.5), Vector3(14, 41, 2.0), Vector3(30, 34, 1.5), Vector3(-5, 60.5, 1.4), Vector3(26, 62.0 - 2.0, 1.4), Vector3(-27, 56, 1.8), Vector3(-34, 47, 1.2)]:
		_round_bed(Vector2(bed.x, bed.y), bed.z, 28)
	# boundary hedges with gaps at the path ends
	var gaps_n: Array[Vector2] = [Vector2(16.0, 3.4), Vector2(58.0, 3.4)]
	_hedge(Vector2(-35.4, 30.6), Vector2(47.4, 30.6), 0.9, 0.8, gaps_n)
	var gaps_w: Array[Vector2] = [Vector2(5.9, 3.4)]
	_hedge(Vector2(-35.4, 30.6), Vector2(-35.4, 61.4), 1.2, 0.9, gaps_w)
	var gaps_e: Array[Vector2] = [Vector2(6.4, 3.4)]
	_hedge(Vector2(47.4, 30.6), Vector2(47.4, 61.4), 1.2, 0.9, gaps_e)
	_hedge(Vector2(-35.4, 61.4), Vector2(47.4, 61.4), 1.4, 1.0)
	# trees and bushes
	var planted := 0
	for attempt in 400:
		if planted >= 70:
			break
		var p := Vector2(_r(pk.position.x + 1.5, pk.end.x - 1.5), _r(pk.position.y + 2.0, pk.end.y - 2.0))
		if _park_free(p, 2.2):
			_random_tree(Vector3(p.x, 0, p.y), _r(0.9, 1.35))
			planted += 1
	for i in 60:
		var p := Vector2(_r(pk.position.x + 1.0, pk.end.x - 1.0), _r(pk.position.y + 1.5, pk.end.y - 1.0))
		if _park_free(p, 1.0):
			_bush(Vector3(p.x, 0, p.y), _r(0.8, 1.3), _rng.randf() < 0.4)
	_grass_tufts(Rect2(pk.position.x + 1.0, pk.position.y + 1.0, pk.size.x - 2.0, pk.size.y - 2.0), 160)


## A winding path: Catmull-Rom through the points, drawn as overlapping discs with a darker edge.
func _path(pts: Array[Vector2], width: float, col: Color) -> void:
	var samples: Array[Vector2] = []
	for i in pts.size() - 1:
		var p0 := pts[maxi(i - 1, 0)]
		var p1 := pts[i]
		var p2 := pts[i + 1]
		var p3 := pts[mini(i + 2, pts.size() - 1)]
		var n := maxi(2, ceili(p1.distance_to(p2) / (width * 0.3)))
		for k in n:
			samples.append(p1.cubic_interpolate(p2, p0, p3, float(k) / n))
	samples.append(pts[pts.size() - 1])
	for s in samples:
		_disc(s, Vector2.ONE * (width + 0.4), -0.004, col.darkened(0.2), 0.03)
	for s in samples:
		_disc(s, Vector2.ONE * width, 0.0, col, 0.03)
	_park_pts.append_array(samples)


func _in_blocks(p: Vector2) -> bool:
	for r in _park_blocks:
		if r.has_point(p):
			return true
	return false


func _park_free(p: Vector2, margin: float) -> bool:
	if _in_lobes(p, _park_lobes, margin + 1.0) or _in_blocks(p):
		return false
	for q in _park_pts:
		if q.distance_squared_to(p) < (margin + 1.4) * (margin + 1.4):
			return false
	return true


func _picnic(pos: Vector3, yaw: float) -> void:
	var xf := _xf(pos, yaw)
	_rbl(xf, Vector3(0, 0.8, 0), Vector3(2.0, 0.08, 0.85), 0.03, WOOD)
	for sz: float in [-1.0, 1.0]:
		_rbl(xf, Vector3(0, 0.45, sz * 0.65), Vector3(2.0, 0.07, 0.3), 0.03, WOOD.darkened(0.05))
	for sx: float in [-0.8, 0.8]:
		_rbl(xf, Vector3(sx, 0.4, 0), Vector3(0.09, 0.8, 1.5), 0.03, WOOD.darkened(0.2))
	_col_box(pos + Vector3(0, 0.45, 0), Vector3(2.1, 0.9, 1.7), yaw)


func _swings(pos: Vector3) -> void:
	var red := Color(0.85, 0.3, 0.25)
	for sx: float in [-2.0, 2.0]:
		_rod(pos + Vector3(sx, 0, -0.9), pos + Vector3(sx, 2.5, 0), 0.12, red)
		_rod(pos + Vector3(sx, 0, 0.9), pos + Vector3(sx, 2.5, 0), 0.12, red)
		_col_box(pos + Vector3(sx, 1.25, 0), Vector3(0.3, 2.5, 1.9))
	_rod(pos + Vector3(-2.1, 2.5, 0), pos + Vector3(2.1, 2.5, 0), 0.14, red.darkened(0.1))
	for sx: float in [-0.8, 0.8]:
		_rod(pos + Vector3(sx - 0.2, 0.55, 0), pos + Vector3(sx - 0.2, 2.5, 0), 0.02, METAL)
		_rod(pos + Vector3(sx + 0.2, 0.55, 0), pos + Vector3(sx + 0.2, 2.5, 0), 0.02, METAL)
		_rb(Vector3(0.5, 0.06, 0.22), 0.03, pos + Vector3(sx, 0.52, 0), Color(0.2, 0.4, 0.8))


func _slide(pos: Vector3) -> void:
	var blue := Color(0.25, 0.5, 0.85)
	_rb(Vector3(1.3, 0.1, 1.3), 0.04, pos + Vector3(0, 1.6, 0), Color(0.9, 0.7, 0.25))
	for sx: float in [-0.55, 0.55]:
		for sz: float in [-0.55, 0.55]:
			_put("cyl", pos + Vector3(sx, 0.8, sz), Vector3(0.1, 1.6, 0.1), Color(0.85, 0.3, 0.25))
	var ang := atan2(1.6, 2.6)
	_rb(Vector3(0.8, 0.07, 3.0), 0.03, pos + Vector3(0, 0.8, 1.9), Color(0.85, 0.85, 0.88), Basis(Vector3.RIGHT, ang))
	for sx: float in [-0.4, 0.4]:
		_rb(Vector3(0.06, 0.14, 3.0), 0.025, pos + Vector3(sx, 0.86, 1.9), blue, Basis(Vector3.RIGHT, ang))
	for k in 5:
		_rb(Vector3(0.7, 0.05, 0.08), 0.02, pos + Vector3(0, 0.2 + 0.32 * k, -0.9 - 0.12 * k + 0.5), METAL)
	_col_box(pos + Vector3(0, 0.8, 0), Vector3(1.3, 1.6, 1.3))
	_col_box(pos + Vector3(0, 0.4, 2.0), Vector3(0.9, 0.8, 2.2))


func _seesaw(pos: Vector3) -> void:
	_put("cyl", pos + Vector3(0, 0.35, 0), Vector3(0.14, 0.7, 0.5), Color(0.3, 0.3, 0.35), Basis(Vector3.UP, PI / 2.0))
	var tilt := Basis(Vector3.RIGHT, 0.2)
	_rb(Vector3(0.35, 0.08, 3.2), 0.03, pos + Vector3(0, 0.72, 0), Color(0.9, 0.7, 0.25), tilt)
	for e: float in [-1.5, 1.5]:
		_rb(Vector3(0.08, 0.3, 0.08), 0.02, pos + Vector3(0, 0.72 + e * -0.2, e * 0.98) + Vector3(0, 0.18, 0), METAL)
	_col_box(pos + Vector3(0, 0.4, 0), Vector3(0.6, 0.8, 3.0))


func _sandbox(pos: Vector3) -> void:
	_slab(Rect2(pos.x - 1.5, pos.z - 1.5, 3.0, 3.0), 0.12, Color(0.93, 0.83, 0.56), 0.12)
	for e: float in [-1.0, 1.0]:
		_rb(Vector3(3.3, 0.26, 0.16), 0.06, pos + Vector3(0, 0.13, e * 1.57), Color(0.3, 0.55, 0.8))
		_rb(Vector3(0.16, 0.26, 3.3), 0.06, pos + Vector3(e * 1.57, 0.13, 0), Color(0.3, 0.55, 0.8))


# ================================================================ filler, bounds, hills

## Random trees and bushes on every bit of ground that nothing else uses.
func _filler() -> void:
	var b := Town.BOUNDS
	var x := b.position.x + 8.0
	while x < b.end.x - 8.0:
		var z := b.position.y + 8.0
		while z < b.end.y - 8.0:
			var p := Vector2(x + _r(-4.0, 4.0), z + _r(-4.0, 4.0))
			if _free_ground(p, 1.5):
				if _rng.randf() < 0.75:
					_random_tree(Vector3(p.x, 0, p.y), _r(0.9, 1.4))
				else:
					_bush(Vector3(p.x, 0, p.y), _r(1.0, 1.5), _rng.randf() < 0.4)
			z += 13.0
		x += 13.0
	# street trees on the verges of the north-south streets
	for sx: float in Town.STREETS_NS:
		for s: float in [-1.0, 1.0]:
			var z := b.position.y + 14.0
			while z < b.end.y - 10.0:
				var p := Vector2(sx + s * 8.0, z)
				if _free_ground(p, 2.0) and _far_from(z, Town.STREETS_EW, 10.0):
					_tree(Vector3(p.x, 0, p.y), 0, _r(0.8, 1.0))
				z += 15.0


func _free_ground(p: Vector2, m: float) -> bool:
	var b := Town.BOUNDS
	if p.x < b.position.x + 6.0 or p.x > b.end.x - 6.0 or p.y < b.position.y + 6.0 or p.y > b.end.y - 6.0:
		return false
	var clear := Town.STREET_WIDTH * 0.5 + Town.SIDEWALK_WIDTH + 1.0 + m
	for c: float in Town.STREETS_EW:
		if absf(p.y - c) < clear:
			return false
	for c: float in Town.STREETS_NS:
		if absf(p.x - c) < clear:
			return false
	if Town.HOME.grow(m + 2.0).has_point(p) or Town.PARK.grow(m + 3.0).has_point(p):
		return false
	for r in _lot_rects:
		if r.grow(m + 2.5).has_point(p):
			return false
	return true


## Point along the bounds perimeter, `off` metres outside (negative: inside).
func _perimeter(t: float, off: float) -> Vector2:
	var b := Town.BOUNDS
	if t < b.size.x:
		return Vector2(b.position.x + t, b.position.y - off)
	t -= b.size.x
	if t < b.size.y:
		return Vector2(b.end.x + off, b.position.y + t)
	t -= b.size.y
	if t < b.size.x:
		return Vector2(b.end.x - t, b.end.y + off)
	t -= b.size.x
	return Vector2(b.position.x - off, b.end.y - t)


func _bounds() -> void:
	var b := Town.BOUNDS
	var c := b.get_center()
	var wall := 6.0
	_col_box(Vector3(c.x, wall * 0.5, b.position.y - 0.5), Vector3(b.size.x + 4.0, wall, 1.0))
	_col_box(Vector3(c.x, wall * 0.5, b.end.y + 0.5), Vector3(b.size.x + 4.0, wall, 1.0))
	_col_box(Vector3(b.position.x - 0.5, wall * 0.5, c.y), Vector3(1.0, wall, b.size.y + 4.0))
	_col_box(Vector3(b.end.x + 0.5, wall * 0.5, c.y), Vector3(1.0, wall, b.size.y + 4.0))
	var perimeter := 2.0 * (b.size.x + b.size.y)
	# dense hedge of big blobs just inside the walls
	var t := 0.0
	while t < perimeter:
		var p := _perimeter(t, -1.8)
		var w := _r(3.6, 5.0)
		_put("leaf", Vector3(p.x, w * 0.4, p.y), Vector3(w, w * _r(0.9, 1.3), w), _tint(Color(0.18, 0.46, 0.2), 0.08))
		t += 2.6
	# outer rows of conifers, poplars and round trees (no colliders: nobody gets there)
	for row in 3:
		t = _r(0.0, 2.0)
		while t < perimeter:
			var p := _perimeter(t, 4.0 + row * 6.0 + _r(0.0, 2.5))
			var r := _rng.randf()
			var kind := 2 if r < 0.5 else (1 if r < 0.65 else 0)
			_tree(Vector3(p.x, 0, p.y), kind, _r(1.3, 2.0), false)
			t += _r(5.0, 8.0)


func _hills() -> void:
	var c := Town.BOUNDS.get_center()
	var hx := Town.BOUNDS.size.x * 0.5
	var hz := Town.BOUNDS.size.y * 0.5
	for ring in 2:
		var count := 30 if ring == 0 else 24
		for i in count:
			var a := (i + _r(-0.3, 0.3)) * TAU / count
			var off := _r(80.0, 120.0) if ring == 0 else _r(220.0, 320.0)
			var r := off * _r(0.4, 0.55)
			var h := r * _r(0.22, 0.42)
			var ca := cos(a)
			var sa := sin(a)
			var x := c.x + signf(ca) * pow(absf(ca), 0.5) * (hx + off)
			var z := c.y + signf(sa) * pow(absf(sa), 0.5) * (hz + off)
			var col := Color(0.36, 0.60, 0.30).lerp(Color(0.46, 0.64, 0.62), 0.25 + 0.5 * ring + _r(-0.1, 0.1))
			_put("hill", Vector3(x, -h * 0.3, z), Vector3(r * 2.0, h * 2.0, r * 2.0), col)
