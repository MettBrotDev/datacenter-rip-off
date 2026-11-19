extends Node3D
## Everything outside the garage: grass, driveway, street, the owner's house and garden (west),
## neighbours, trees, props, invisible world bounds with a hedge, and a distant horizon.
## Fully deterministic (fixed RNG seed). Repetitive pieces are batched into a few MultiMeshes
## (unit box / sphere / cylinder / cone / prism with per-instance colour); solid things get
## box colliders on one StaticBody3D.
##
## Landmarks: owner house x[-20,-7.5] z[-4,8] (door at x -12.5, z 8); garden x[-28,-8.2] z[-22,-4.2]
## (gate gap in the east fence at x -8.2, z -14.6..-12.4; pond (-20,-12); shed (-25.5,-19.5);
## bench (-20,-8.5)); driveway x[-2.5,2.5] z[4.5,20]; street z[20,27]; bus stop (22,28.6).

const X_MIN := -45.0
const X_MAX := 45.0
const Z_MIN := -35.0
const Z_MAX := 62.0

var _rng := RandomNumberGenerator.new()
var _body: StaticBody3D
var _vc: StandardMaterial3D
var _xf: Dictionary = {}    # kind -> Array[Transform3D]
var _cl: Dictionary = {}    # kind -> Array[Color]
var _glow_mat: StandardMaterial3D
var _bulb_mesh: BoxMesh


func _ready() -> void:
	_rng.seed = 20240611
	_body = StaticBody3D.new()
	add_child(_body)
	_vc = StandardMaterial3D.new()
	_vc.vertex_color_use_as_albedo = true
	_vc.vertex_color_is_srgb = true
	_vc.roughness = 0.9
	_glow_mat = _glow(Color(1.0, 0.85, 0.5), 2.0)
	_bulb_mesh = BoxMesh.new()
	_bulb_mesh.size = Vector3(0.34, 0.1, 0.34)
	for kind: String in ["box", "sphere", "cyl", "cone", "prism"]:
		var xs: Array[Transform3D] = []
		var cs: Array[Color] = []
		_xf[kind] = xs
		_cl[kind] = cs

	_ground()
	_street()
	_owner_house()
	_garden()
	_neighbours()
	_trees()
	_props()
	_bounds()
	_horizon()
	_flush()


# ---------------------------------------------------------------- helpers

func _mat(c: Color, rough := 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func _glow(c: Color, energy: float) -> StandardMaterial3D:
	var m := _mat(c, 0.5)
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


func _brick(c: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/brick.gdshader")
	m.set_shader_parameter("brick_color", c)
	return m


func _box(sz: Vector3, pos: Vector3, mat: Material, collide := true) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = sz
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)
	if collide:
		_col(pos, sz)
	return mi


func _col(pos: Vector3, sz: Vector3) -> void:
	var shape := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = sz
	shape.shape = b
	shape.position = pos
	_body.add_child(shape)


## Queue one instance of a unit mesh (kind: box, sphere, cyl, cone, prism), sized by `sz`.
func _put(kind: String, pos: Vector3, sz: Vector3, c: Color, rot := Basis.IDENTITY) -> void:
	var xs: Array[Transform3D] = _xf[kind]
	var cs: Array[Color] = _cl[kind]
	xs.append(Transform3D(rot * Basis.from_scale(sz), pos))
	cs.append(c)


func _flush() -> void:
	var meshes := {}
	var bm := BoxMesh.new()
	meshes["box"] = bm
	var sph := SphereMesh.new()
	sph.radial_segments = 10
	sph.rings = 5
	meshes["sphere"] = sph
	var cyl := CylinderMesh.new()
	cyl.radial_segments = 8
	meshes["cyl"] = cyl
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.radial_segments = 8
	meshes["cone"] = cone
	meshes["prism"] = PrismMesh.new()
	for kind: String in meshes:
		var xs: Array[Transform3D] = _xf[kind]
		var cs: Array[Color] = _cl[kind]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = meshes[kind]
		mm.instance_count = xs.size()
		for i in xs.size():
			mm.set_instance_transform(i, xs[i])
			mm.set_instance_color(i, cs[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = _vc
		add_child(mmi)


func _r(a: float, b: float) -> float:
	return _rng.randf_range(a, b)


func _green() -> Color:
	return Color(0.2, 0.5, 0.18).lerp(Color(0.42, 0.68, 0.24), _rng.randf())


# ---------------------------------------------------------------- ground, driveway, street

func _ground() -> void:
	_box(Vector3(300, 1, 300), Vector3(0, -0.53, 0), _mat(Color(0.4, 0.66, 0.26)))
	# the garden lawn is a slightly lighter, mown slab (1 cm above the field)
	_put("box", Vector3(-18.1, -0.025, -13.1), Vector3(19.8, 0.01, 17.8), Color(0.46, 0.72, 0.3))
	# driveway with expansion joints
	_box(Vector3(5, 0.5, 15.5), Vector3(0, -0.26, 12.25), _mat(Color(0.7, 0.68, 0.64)))
	for z in range(1, 5):
		_put("box", Vector3(0, -0.004, 4.5 + z * 3.1), Vector3(5, 0.012, 0.05), Color(0.45, 0.43, 0.4))


func _street() -> void:
	_box(Vector3(100, 0.5, 7), Vector3(0, -0.26, 23.5), _mat(Color(0.22, 0.23, 0.26)))
	var walk := _mat(Color(0.78, 0.76, 0.72))
	_box(Vector3(47.5, 0.5, 2), Vector3(-26.25, -0.23, 19), walk)    # north sidewalk, split by the driveway
	_box(Vector3(47.5, 0.5, 2), Vector3(26.25, -0.23, 19), walk)
	_box(Vector3(100, 0.5, 2), Vector3(0, -0.23, 28), walk)
	var x := -48.0
	while x < 48.0:
		_put("box", Vector3(x, -0.004, 23.5), Vector3(2.0, 0.012, 0.15), Color(0.95, 0.85, 0.35))
		x += 4.0
	for lx: float in [-34.0, -16.0, 16.0, 34.0]:
		_lamp(Vector3(lx, 0, 27.7), -1.0)
	for lx: float in [-24.0, -10.0, 10.0, 24.0]:
		_lamp(Vector3(lx, 0, 19.3), 1.0)


func _lamp(pos: Vector3, arm: float) -> void:
	_put("cyl", pos + Vector3(0, 2.1, 0), Vector3(0.14, 4.2, 0.14), Color(0.22, 0.24, 0.27))
	_put("box", pos + Vector3(0, 4.15, arm * 0.5), Vector3(0.1, 0.1, 1.0), Color(0.22, 0.24, 0.27))
	var bulb := MeshInstance3D.new()
	bulb.mesh = _bulb_mesh
	bulb.material_override = _glow_mat
	bulb.position = pos + Vector3(0, 4.08, arm * 0.95)
	add_child(bulb)
	_col(pos + Vector3(0, 2.0, 0), Vector3(0.3, 4.0, 0.3))


# ---------------------------------------------------------------- houses

## A simple house: solid walls, prism roof, windows and a door (batched), optional chimney.
func _house(c: Vector2, sz: Vector3, face: float, wall: Material, roof: Color, gable_front := false) -> void:
	var w := sz.x
	var h := sz.y
	var d := sz.z
	_box(sz, Vector3(c.x, h / 2, c.y), wall)
	var rh := clampf(minf(w, d) * 0.3, 1.4, 2.4)
	var rpos := Vector3(c.x, h + rh / 2, c.y)
	if gable_front:
		_put("prism", rpos, Vector3(w + 0.8, rh, d + 0.8), roof)
	else:
		_put("prism", rpos, Vector3(d + 0.8, rh, w + 0.8), roof, Basis(Vector3.UP, PI / 2))
	if _rng.randf() < 0.7:
		_put("box", Vector3(c.x + w * 0.3, h + rh * 0.5 + 0.3, c.y), Vector3(0.7, rh + 0.9, 0.7), Color(0.55, 0.25, 0.2))
	var floors := 2 if h > 4.5 else 1
	var zf := c.y + face * d / 2
	var zb := c.y - face * d / 2
	var front := Vector3(0, 0, face)
	for f in floors:
		var y := 1.7 + f * 2.5
		var offs: Array[float] = [-0.28, 0.33]
		if f > 0:
			offs.append(0.1)
		for k in offs:
			_window(Vector3(c.x + k * w, y, zf), front)
		_window(Vector3(c.x - 0.25 * w, y, zb), -front)
		_window(Vector3(c.x + 0.25 * w, y, zb), -front)
		_window(Vector3(c.x - w / 2, y, c.y), Vector3.LEFT)
		_window(Vector3(c.x + w / 2, y, c.y), Vector3.RIGHT)
	var doors: Array[Color] = [Color(0.75, 0.2, 0.18), Color(0.2, 0.4, 0.65), Color(0.2, 0.5, 0.35), Color(0.9, 0.7, 0.2)]
	_put("box", Vector3(c.x + w * 0.1, 1.0, zf + face * 0.03), Vector3(1.0, 2.0, 0.1), doors[_rng.randi() % 4])
	_put("box", Vector3(c.x + w * 0.1, 0.01, zf + face * 0.4), Vector3(1.6, 0.04, 0.8), Color(0.65, 0.63, 0.6))


func _window(pos: Vector3, nrm: Vector3) -> void:
	var on_z := absf(nrm.z) > 0.5
	var frame := Vector3(1.4, 1.3, 0.1) if on_z else Vector3(0.1, 1.3, 1.4)
	var glass := Vector3(1.15, 1.05, 0.14) if on_z else Vector3(0.14, 1.05, 1.15)
	_put("box", pos + nrm * 0.02, frame, Color(0.95, 0.94, 0.9))
	_put("box", pos + nrm * 0.03, glass, Color(0.62, 0.74, 0.86))


func _owner_house() -> void:
	_house(Vector2(-13.75, 2.0), Vector3(12.5, 5.0, 12.0), 1.0, _mat(Color(0.95, 0.84, 0.58)), Color(0.72, 0.3, 0.2))
	# front path, low front hedges, front flowerbeds
	_put("box", Vector3(-12.5, -0.02, 13.3), Vector3(1.2, 0.02, 10.0), Color(0.72, 0.7, 0.66))
	_hedge(Vector2(-20.2, 17.2), Vector2(-13.4, 17.2), 0.8, 0.7, true)
	_hedge(Vector2(-11.6, 17.2), Vector2(-7.4, 17.2), 0.8, 0.7, true)
	_bed(-19.5, -14.0, 8.4, 9.2, 22)
	_bed(-11.0, -8.0, 8.4, 9.2, 14)


## A rectangular flowerbed: soil, stems and coloured heads (all batched, no colliders).
func _bed(x0: float, x1: float, z0: float, z1: float, n: int) -> void:
	_put("box", Vector3((x0 + x1) / 2, 0.0, (z0 + z1) / 2), Vector3(x1 - x0, 0.04, z1 - z0), Color(0.33, 0.21, 0.13))
	var cols: Array[Color] = [Color(0.95, 0.3, 0.35), Color(0.98, 0.8, 0.2), Color(0.95, 0.55, 0.75), Color(0.6, 0.4, 0.85), Color(1, 1, 0.95), Color(0.98, 0.5, 0.15)]
	for i in n:
		var p := Vector3(_r(x0 + 0.1, x1 - 0.1), 0.0, _r(z0 + 0.1, z1 - 0.1))
		var h := _r(0.25, 0.5)
		_put("box", p + Vector3(0, h / 2, 0), Vector3(0.025, h, 0.025), Color(0.25, 0.55, 0.2))
		_put("sphere", p + Vector3(0, h, 0), Vector3.ONE * _r(0.12, 0.2), cols[_rng.randi() % cols.size()])


## A run of hedge segments from a to b (axis aligned), optional collider.
func _hedge(a: Vector2, b: Vector2, h: float, t: float, collide: bool) -> void:
	var length := a.distance_to(b)
	var dir := (b - a) / length
	var along_x := absf(dir.x) > 0.5
	var n := ceili(length / 1.6)
	var step := length / n
	for i in n:
		var p := a + dir * (i + 0.5) * step
		var hh := h * _r(0.85, 1.15)
		var col := Color(0.16, 0.42, 0.17).lerp(Color(0.3, 0.58, 0.2), _rng.randf())
		var sz := Vector3(step + 0.1, hh, t) if along_x else Vector3(t, hh, step + 0.1)
		_put("box", Vector3(p.x, hh / 2, p.y), sz, col)
		if _rng.randf() < 0.35:
			_put("sphere", Vector3(p.x, hh, p.y), Vector3(t * 1.1, 0.7, t * 1.1), col.lightened(0.08))
	if collide:
		var mid := (a + b) / 2
		_col(Vector3(mid.x, h / 2, mid.y), Vector3(length, h, t) if along_x else Vector3(t, h, length))


# ---------------------------------------------------------------- garden

func _garden() -> void:
	# fence: north, west, south-west stub, east with a gate gap at z -14.6..-12.4
	_fence(Vector2(-28, -22), Vector2(-8.2, -22))
	_fence(Vector2(-28, -22), Vector2(-28, -4.2))
	_fence(Vector2(-28, -4.2), Vector2(-20, -4.2))
	_fence(Vector2(-8.2, -4.6), Vector2(-8.2, -12.4))
	_fence(Vector2(-8.2, -14.6), Vector2(-8.2, -22))
	for gz: float in [-12.4, -14.6]:
		_put("box", Vector3(-8.2, 0.7, gz), Vector3(0.18, 1.4, 0.18), Color(0.55, 0.38, 0.22))
		_col(Vector3(-8.2, 0.7, gz), Vector3(0.2, 1.4, 0.2))

	# flowerbeds, vegetable patch
	_bed(-21.0, -10.0, -21.6, -20.4, 60)
	_bed(-27.6, -26.2, -17.0, -13.0, 26)
	_bed(-9.6, -8.6, -11.0, -6.0, 16)
	_put("box", Vector3(-15.5, 0.0, -17.0), Vector3(5.0, 0.04, 4.0), Color(0.3, 0.19, 0.12))
	for r in 4:
		var rz := -18.4 + r * 0.9
		_put("box", Vector3(-15.5, 0.08, rz), Vector3(4.6, 0.12, 0.45), Color(0.4, 0.26, 0.16))
		for i in 7:
			var px := -17.5 + i * 0.66 + _r(-0.1, 0.1)
			if r % 2 == 0:
				_put("sphere", Vector3(px, 0.25, rz), Vector3(0.38, 0.28, 0.38), Color(0.5, 0.75, 0.35))
			else:
				_put("cone", Vector3(px, 0.3, rz), Vector3(0.22, 0.4, 0.22), Color(0.3, 0.6, 0.25))
				_put("cone", Vector3(px, 0.06, rz), Vector3(0.06, 0.12, 0.06), Color(0.95, 0.5, 0.1))

	# pond with rocks and lily pads
	var water := CylinderMesh.new()
	water.top_radius = 1.9
	water.bottom_radius = 1.9
	water.height = 0.03
	water.material = _mat(Color(0.22, 0.5, 0.7), 0.15)
	var pond := MeshInstance3D.new()
	pond.mesh = water
	pond.position = Vector3(-20, -0.015, -12)
	add_child(pond)
	for i in 12:
		var a := i * TAU / 12.0
		var g := _r(0.5, 0.75)
		_put("sphere", Vector3(-20 + cos(a) * 2.0, 0.05, -12 + sin(a) * 2.0), Vector3(_r(0.5, 0.8), 0.3, _r(0.5, 0.8)), Color(g, g, g * 0.95))
	for p: Vector2 in [Vector2(-20.6, -12.4), Vector2(-19.3, -11.5), Vector2(-19.6, -12.9)]:
		_put("cyl", Vector3(p.x, 0.005, p.y), Vector3(0.45, 0.01, 0.45), Color(0.25, 0.6, 0.25))
	_put("sphere", Vector3(-19.3, 0.04, -11.5), Vector3(0.15, 0.1, 0.15), Color(1.0, 0.6, 0.8))

	# stepping stones from the gate toward the pond
	for i in 7:
		var sp := Vector3(-9.6 - i * 1.25, 0.0, -13.5 + sin(i * 0.8) * 1.3)
		var gs := _r(0.55, 0.7)
		_put("cyl", sp, Vector3(0.6, 0.04, 0.5), Color(gs, gs, gs * 0.95))

	# shed (door faces east), bench, washing line
	_box(Vector3(3.2, 2.3, 2.4), Vector3(-25.5, 1.15, -19.5), _mat(Color(0.55, 0.36, 0.22)))
	_put("prism", Vector3(-25.5, 2.3 + 0.4, -19.5), Vector3(2.9, 0.8, 3.6), Color(0.3, 0.32, 0.36), Basis(Vector3.UP, PI / 2))
	_put("box", Vector3(-23.88, 1.0, -19.5), Vector3(0.08, 1.9, 0.9), Color(0.25, 0.4, 0.55))
	_put("box", Vector3(-25.5, 1.4, -18.28), Vector3(0.8, 0.7, 0.08), Color(0.6, 0.78, 0.9))
	_bench(Vector3(-20, 0, -8.5))
	for pz: float in [-6.5, -11.0]:
		_put("cyl", Vector3(-25, 1.1, pz), Vector3(0.1, 2.2, 0.1), Color(0.5, 0.35, 0.2))
	_put("box", Vector3(-25, 2.0, -8.75), Vector3(0.015, 0.015, 4.5), Color(0.9, 0.9, 0.9))
	var cloth: Array[Color] = [Color(0.9, 0.3, 0.3), Color(0.3, 0.5, 0.9), Color(0.95, 0.85, 0.3), Color(0.95, 0.95, 0.95), Color(0.4, 0.75, 0.45)]
	for i in 5:
		_put("box", Vector3(-25, 1.65, -7.3 - i * 0.75), Vector3(0.03, _r(0.5, 0.8), _r(0.35, 0.55)), cloth[i])

	# trees, bushes, grass tufts
	_tree(Vector3(-23, 0, -15), 1.0, Color(0.9, 0.55, 0.65))
	_tree(Vector3(-10.5, 0, -17), 1.1, Color(0.35, 0.65, 0.25))
	for bp: Vector3 in [Vector3(-27, 0, -5.4), Vector3(-27, 0, -21), Vector3(-9.2, 0, -21), Vector3(-9.3, 0, -5.6), Vector3(-14, 0, -6.2), Vector3(-17.5, 0, -5.8)]:
		_bush(bp, _r(0.8, 1.2))
	for i in 160:
		var tp := Vector3(_r(-27.5, -8.8), 0.1, _r(-21.5, -4.8))
		if tp.distance_to(Vector3(-20, 0.1, -12)) > 2.2:
			_put("cone", tp, Vector3(0.09, _r(0.1, 0.2), 0.09), _green())


func _fence(a: Vector2, b: Vector2) -> void:
	var length := a.distance_to(b)
	var dir := (b - a) / length
	var along_x := absf(dir.x) > 0.5
	var yaw := Basis(Vector3.UP, 0.0 if along_x else PI / 2)
	var n := int(length / 0.2)
	var wood := Color(0.96, 0.93, 0.85)
	for i in n:
		var p := a + dir * (i + 0.5) * 0.2
		var h := _r(0.88, 1.05)
		var roll := _r(-0.12, 0.12) if _rng.randf() < 0.12 else 0.0
		var tint := wood.darkened(_r(0.0, 0.1))
		_put("box", Vector3(p.x, h / 2, p.y), Vector3(0.12, h, 0.04), tint, yaw * Basis(Vector3.BACK, roll))
	var mid := (a + b) / 2
	for ry: float in [0.3, 0.75]:
		var sz := Vector3(length, 0.07, 0.06) if along_x else Vector3(0.06, 0.07, length)
		_put("box", Vector3(mid.x, ry, mid.y), sz, Color(0.8, 0.74, 0.62))
	_col(Vector3(mid.x, 0.5, mid.y), Vector3(length, 1.0, 0.12) if along_x else Vector3(0.12, 1.0, length))


func _bench(pos: Vector3) -> void:
	var wood := Color(0.62, 0.42, 0.24)
	_put("box", pos + Vector3(0, 0.45, 0), Vector3(1.6, 0.06, 0.5), wood)
	_put("box", pos + Vector3(0, 0.75, 0.22), Vector3(1.6, 0.4, 0.05), wood)
	for lx: float in [-0.7, 0.7]:
		_put("box", pos + Vector3(lx, 0.22, 0), Vector3(0.06, 0.44, 0.45), Color(0.3, 0.3, 0.33))
	_col(pos + Vector3(0, 0.45, 0.05), Vector3(1.6, 0.9, 0.55))


# ---------------------------------------------------------------- neighbours

func _neighbours() -> void:
	var walls: Array[Material] = [
		_brick(Color(0.5, 0.2, 0.14)), _brick(Color(0.62, 0.38, 0.24)), _brick(Color(0.4, 0.2, 0.18)),
		_mat(Color(0.9, 0.9, 0.84)), _mat(Color(0.62, 0.78, 0.86)), _mat(Color(0.7, 0.82, 0.62)),
		_mat(Color(0.95, 0.72, 0.62)), _mat(Color(0.96, 0.88, 0.6)),
	]
	var roofs: Array[Color] = [Color(0.3, 0.32, 0.38), Color(0.55, 0.25, 0.2), Color(0.25, 0.4, 0.38), Color(0.4, 0.3, 0.26)]
	# x, z, width, height, depth, facing (+1 = door toward +Z), gable towards the street
	var list: Array = [
		[-36, 10, 9, 3.4, 8, 1], [36, 13, 8, 5.0, 8, 1], [38, -2, 8, 3.4, 8, 1],
		[-38, -14, 8, 3.4, 8, 1], [22, -27, 10, 5.0, 8, 1], [0, -30, 10, 3.4, 6, 1],
		[-28, 36, 10, 3.4, 8, -1], [24, 36, 10, 5.0, 8, -1], [38, 36, 8, 3.4, 8, -1],
		[-35, 55, 10, 3.4, 6, -1], [0, 57, 10, 5.0, 6, -1],
	]
	for i in list.size():
		var e: Array = list[i]
		var sz := Vector3(float(e[2]), float(e[3]), float(e[4]))
		_house(Vector2(float(e[0]), float(e[1])), sz, float(e[5]), walls[(i * 3) % walls.size()], roofs[i % roofs.size()], i % 4 == 1)


# ---------------------------------------------------------------- trees and bushes

func _tree(pos: Vector3, s: float, foliage: Color) -> void:
	_put("cyl", pos + Vector3(0, 1.1 * s, 0), Vector3(0.4, 2.2, 0.4) * s, Color(0.4, 0.27, 0.17))
	var blobs := _rng.randi_range(1, 3)
	for i in blobs:
		var o := Vector3(_r(-0.8, 0.8), 0, _r(-0.8, 0.8)) * s if i > 0 else Vector3.ZERO
		var r := _r(1.6, 2.4) * s
		_put("sphere", pos + Vector3(0, 2.8 * s + i * 0.6 * s, 0) + o, Vector3(r, r * 0.85, r), foliage.lerp(_green(), 0.15 * i))
	_col(pos + Vector3(0, 1.5, 0), Vector3(0.5, 3.0, 0.5))


func _bush(pos: Vector3, s: float) -> void:
	var c := _green().darkened(0.1)
	_put("sphere", pos + Vector3(0, 0.45 * s, 0), Vector3(1.3, 0.9, 1.1) * s, c)
	_put("sphere", pos + Vector3(0.5 * s, 0.35 * s, 0.2 * s), Vector3(0.8, 0.7, 0.8) * s, c.lightened(0.08))
	_col(pos + Vector3(0.1, 0.4, 0), Vector3(1.2, 0.8, 1.0) * s)


func _trees() -> void:
	var pts: Array[Vector2] = [
		Vector2(-18, 12.5), Vector2(-9.5, 13), Vector2(16, 13), Vector2(-32, 17), Vector2(28, 17),
		Vector2(-18, 30.4), Vector2(18, 30.4), Vector2(34, 30.4), Vector2(-36, 30.4),
		Vector2(-22, -27), Vector2(-12, -28), Vector2(12, -28), Vector2(32, -13), Vector2(-32, -4),
		Vector2(-30, 48), Vector2(32, 46), Vector2(-20, 45), Vector2(20, 48), Vector2(42, 20),
	]
	var cols: Array[Color] = [Color(0.3, 0.62, 0.25), Color(0.4, 0.7, 0.28), Color(0.22, 0.5, 0.28), Color(0.85, 0.6, 0.25), Color(0.88, 0.55, 0.68)]
	for p in pts:
		_tree(Vector3(p.x, 0, p.y), _r(0.8, 1.35), cols[_rng.randi() % cols.size()])
	for i in 26:
		var bp := Vector3(_r(-42, 42), 0, _r(-31, 58))
		# keep bushes off streets, driveway, plots, garden and houses' footprints (simple rejects)
		var in_street := bp.z > 17.5 and bp.z < 29.5
		var in_plot := (absf(bp.x) < 15 and bp.z > -23 and bp.z < 51) or (bp.x > 11 and bp.x < 31 and absf(bp.z) < 9)
		var near_house := bp.x > -30 and bp.x < -6 and bp.z > -23 and bp.z < 18
		if not in_street and not in_plot and not near_house and absf(bp.x) < 42:
			_bush(bp, _r(0.7, 1.2))


# ---------------------------------------------------------------- props

func _props() -> void:
	for p: Vector2 in [Vector2(-8.5, 17.4), Vector2(-37, 17.4), Vector2(40, 17.4), Vector2(-26, 29.6), Vector2(30, 29.6)]:
		_put("box", Vector3(p.x, 0.5, p.y), Vector3(0.08, 1.0, 0.08), Color(0.5, 0.35, 0.2))
		_put("box", Vector3(p.x, 1.1, p.y), Vector3(0.24, 0.24, 0.5), Color(0.25, 0.4, 0.75))
		_put("box", Vector3(p.x + 0.14, 1.2, p.y), Vector3(0.02, 0.14, 0.08), Color(0.9, 0.2, 0.15))
		_col(Vector3(p.x, 0.6, p.y), Vector3(0.3, 1.2, 0.5))
	for p: Vector2 in [Vector2(-18.5, 8.7), Vector2(-17.5, 8.7), Vector2(33, 9.5), Vector2(-34, 31.5)]:
		_put("box", Vector3(p.x, 0.48, p.y), Vector3(0.6, 0.96, 0.7), Color(0.2, 0.5, 0.3))
		_put("box", Vector3(p.x, 1.0, p.y), Vector3(0.66, 0.08, 0.76), Color(0.14, 0.38, 0.22))
		_col(Vector3(p.x, 0.5, p.y), Vector3(0.6, 1.0, 0.7))
	_car(Vector3(-16, 0, 21.4), 1.0, Color(0.85, 0.25, 0.2))
	_car(Vector3(24, 0, 25.6), -1.0, Color(0.2, 0.45, 0.8))
	# bus stop on the south sidewalk
	var frame := Color(0.25, 0.27, 0.3)
	for px: float in [20.4, 23.6]:
		_put("box", Vector3(px, 1.25, 28.5), Vector3(0.08, 2.5, 0.08), frame)
	_put("box", Vector3(22, 2.55, 28.7), Vector3(3.6, 0.1, 1.5), Color(0.2, 0.45, 0.5))
	_put("box", Vector3(22, 1.5, 29.3), Vector3(3.2, 1.6, 0.05), Color(0.6, 0.8, 0.9))
	_put("box", Vector3(22, 0.45, 29.0), Vector3(2.4, 0.06, 0.45), Color(0.6, 0.42, 0.25))
	_put("cyl", Vector3(25, 1.3, 27.6), Vector3(0.08, 2.6, 0.08), frame)
	_put("cyl", Vector3(25, 2.5, 27.6), Vector3(0.6, 0.04, 0.6), Color(0.15, 0.4, 0.85), Basis(Vector3.RIGHT, PI / 2))
	_col(Vector3(22, 1.25, 29.3), Vector3(3.2, 2.5, 0.2))
	_col(Vector3(25, 1.3, 27.6), Vector3(0.2, 2.6, 0.2))


func _car(pos: Vector3, dir: float, c: Color) -> void:
	_put("box", pos + Vector3(0, 0.6, 0), Vector3(4.3, 0.65, 1.8), c)
	_put("box", pos + Vector3(-0.3 * dir, 1.18, 0), Vector3(2.3, 0.55, 1.6), c)
	_put("box", pos + Vector3(-0.3 * dir, 1.2, 0), Vector3(2.1, 0.36, 1.64), Color(0.3, 0.45, 0.6))
	for wx: float in [-1.35, 1.35]:
		for wz: float in [-0.9, 0.9]:
			_put("cyl", pos + Vector3(wx, 0.33, wz), Vector3(0.66, 0.25, 0.66), Color(0.1, 0.1, 0.12), Basis(Vector3.RIGHT, PI / 2))
	for wz: float in [-0.65, 0.65]:
		_put("box", pos + Vector3(2.16 * dir, 0.65, wz), Vector3(0.05, 0.16, 0.3), Color(1.0, 0.95, 0.7))
		_put("box", pos + Vector3(-2.16 * dir, 0.65, wz), Vector3(0.05, 0.14, 0.3), Color(0.8, 0.1, 0.1))
	_col(pos + Vector3(0, 0.75, 0), Vector3(4.3, 1.3, 1.8))


# ---------------------------------------------------------------- bounds, edge hedge, horizon

func _bounds() -> void:
	_col(Vector3(0, 3, Z_MIN - 0.5), Vector3(96, 6, 1))
	_col(Vector3(0, 3, Z_MAX + 0.5), Vector3(96, 6, 1))
	_col(Vector3(X_MIN - 0.5, 3, (Z_MIN + Z_MAX) / 2), Vector3(1, 6, 104))
	_col(Vector3(X_MAX + 0.5, 3, (Z_MIN + Z_MAX) / 2), Vector3(1, 6, 104))
	# dense hedge just inside the walls, a double treeline of pines just outside
	_hedge(Vector2(X_MIN, Z_MIN + 0.8), Vector2(X_MAX, Z_MIN + 0.8), 2.6, 1.6, false)
	_hedge(Vector2(X_MIN, Z_MAX - 0.8), Vector2(X_MAX, Z_MAX - 0.8), 2.6, 1.6, false)
	_hedge(Vector2(X_MIN + 0.8, Z_MIN), Vector2(X_MIN + 0.8, Z_MAX), 2.6, 1.6, false)
	_hedge(Vector2(X_MAX - 0.8, Z_MIN), Vector2(X_MAX - 0.8, Z_MAX), 2.6, 1.6, false)
	for row in 2:
		var off := 3.0 + row * 4.0
		var x := X_MIN - 8.0
		while x < X_MAX + 8.0:
			_pine(Vector3(x + _r(-1, 1), 0, Z_MIN - off - _r(0, 1.5)))
			_pine(Vector3(x + _r(-1, 1), 0, Z_MAX + off + _r(0, 1.5)))
			x += 3.4
		var z := Z_MIN
		while z < Z_MAX:
			_pine(Vector3(X_MIN - off - _r(0, 1.5), 0, z + _r(-1, 1)))
			_pine(Vector3(X_MAX + off + _r(0, 1.5), 0, z + _r(-1, 1)))
			z += 3.4


func _pine(pos: Vector3) -> void:
	var h := _r(5.0, 9.0)
	var c := Color(0.12, 0.38, 0.2).lerp(Color(0.25, 0.5, 0.25), _rng.randf())
	_put("cyl", pos + Vector3(0, 1.0, 0), Vector3(0.4, 2.0, 0.4), Color(0.35, 0.24, 0.15))
	_put("cone", pos + Vector3(0, 1.5 + h * 0.3, 0), Vector3(h * 0.5, h * 0.6, h * 0.5), c)
	_put("cone", pos + Vector3(0, 1.5 + h * 0.65, 0), Vector3(h * 0.38, h * 0.55, h * 0.38), c.lightened(0.06))


func _horizon() -> void:
	var sph := SphereMesh.new()
	sph.radial_segments = 16
	sph.rings = 8
	for i in 12:
		var a := i * TAU / 12.0 + _r(-0.15, 0.15)
		var dist := _r(112, 130)
		var rx := _r(35, 55)
		var ry := _r(14, 28)
		var mat := _mat(Color(0.35, 0.58, 0.4).lerp(Color(0.5, 0.62, 0.72), _r(0.2, 0.7)), 1.0)
		var mi := MeshInstance3D.new()
		mi.mesh = sph
		mi.material_override = mat
		mi.position = Vector3(cos(a) * dist, -ry * 0.25, sin(a) * dist + 14.0)
		mi.scale = Vector3(rx * 2, ry * 2, rx * 2)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
