extends RefCounted
## Procedural meshes with soft edges. Meshes are cached by their dimensions and shared, so set
## colours with `material_override` on the MeshInstance3D, never on the mesh.

static var _cache: Dictionary = {}


## A box whose edges and corners are rounded off with the given radius.
static func rounded_box(size: Vector3, radius := 0.05, steps := 3) -> ArrayMesh:
	radius = clampf(radius, 0.001, minf(size.x, minf(size.y, size.z)) * 0.5)
	var key := "box %.3v %.3f %d" % [size, radius, steps]
	if _cache.has(key):
		return _cache[key]
	var half := size * 0.5
	var inner := half - Vector3.ONE * radius
	var lines: Array = []   # per axis: where the grid lines sit, denser inside the rounded zones
	for a in 3:
		var line: Array[float] = []
		for k in steps + 1:
			line.append(-half[a] + radius * k / steps)
		for k in steps + 1:
			line.append(inner[a] + radius * k / steps)
		lines.append(line)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for a in 3:
		var u := (a + 1) % 3
		var v := (a + 2) % 3
		var nu: int = lines[u].size()
		var nv: int = lines[v].size()
		for side: float in [-1.0, 1.0]:
			var grid: Array = []   # [position, normal] per grid point of this cube face
			for i in nu:
				for j in nv:
					var p := Vector3.ZERO
					p[a] = side * half[a]
					p[u] = lines[u][i]
					p[v] = lines[v][j]
					var core := p.clamp(-inner, inner)
					var n := (p - core).normalized()
					grid.append([core + n * radius, n])
			for i in nu - 1:
				for j in nv - 1:
					var q00: Array = grid[i * nv + j]
					var q10: Array = grid[(i + 1) * nv + j]
					var q11: Array = grid[(i + 1) * nv + j + 1]
					var q01: Array = grid[i * nv + j + 1]
					_tri(st, q00, q10, q11)
					_tri(st, q00, q11, q01)
	var mesh := st.commit()
	_cache[key] = mesh
	return mesh


## A gabled roof: `size.x` long (the ridge runs along X), `size.z` deep, `size.y` high.
## Origin at the centre of its base.
static func prism(size: Vector3) -> ArrayMesh:
	var key := "prism %.3v" % size
	if _cache.has(key):
		return _cache[key]
	var w := size.x * 0.5
	var d := size.z * 0.5
	var a := Vector3(-w, 0, -d)
	var b := Vector3(w, 0, -d)
	var c := Vector3(w, 0, d)
	var e := Vector3(-w, 0, d)
	var r0 := Vector3(-w, size.y, 0)
	var r1 := Vector3(w, size.y, 0)
	var centre := Vector3(0, size.y / 3.0, 0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face: Array in [[e, c, r1, r0], [b, a, r0, r1], [a, e, r0], [c, b, r1], [a, b, c, e]]:
		var mid := Vector3.ZERO
		for p: Vector3 in face:
			mid += p / face.size()
		var n: Vector3 = (face[1] - face[0]).cross(face[2] - face[0]).normalized()
		if n.dot(mid - centre) < 0.0:
			n = -n
		for k in range(1, face.size() - 1):
			_tri(st, [face[0], n], [face[k], n], [face[k + 1], n])
	var mesh := st.commit()
	_cache[key] = mesh
	return mesh


## A plain box with hard edges: 12 triangles, for tiny or flat parts where a bevel would not show.
static func box(size: Vector3) -> ArrayMesh:
	var key := "flat %.3v" % size
	if _cache.has(key):
		return _cache[key]
	var h := size * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for a in 3:
		var u := (a + 1) % 3
		var v := (a + 2) % 3
		for side: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[a] = side
			var c := [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]
			var q: Array = []
			for k: Array in c:
				var p := Vector3.ZERO
				p[a] = side * h[a]
				p[u] = k[0] * h[u]
				p[v] = k[1] * h[v]
				q.append([p, n])
			_tri(st, q[0], q[1], q[2])
			_tri(st, q[0], q[2], q[3])
	var mesh := st.commit()
	_cache[key] = mesh
	return mesh


## A solid of revolution around Y. `profile` is [Vector2(radius, y)...] walked top -> outside -> bottom
## (so surface normals come out pointing away from the solid). `zscale` squashes it into an ellipse.
## Every profile segment is a hard-edged band, smooth around the axis.
static func lathe(profile: Array, segs: int, zscale := 1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in profile.size() - 1:
		var a: Vector2 = profile[i]
		var b: Vector2 = profile[i + 1]
		var d := b - a
		if d.length() < 1e-6:
			continue
		var n2 := Vector2(-d.y, d.x).normalized()
		for s in segs:
			var t0 := TAU * s / segs
			var t1 := TAU * (s + 1) / segs
			var c0 := Vector2(cos(t0), sin(t0))
			var c1 := Vector2(cos(t1), sin(t1))
			var n0 := Vector3(n2.x * c0.x, n2.y, n2.x * c0.y / zscale).normalized()
			var n1 := Vector3(n2.x * c1.x, n2.y, n2.x * c1.y / zscale).normalized()
			var p00 := [Vector3(a.x * c0.x, a.y, a.x * c0.y * zscale), n0]
			var p10 := [Vector3(b.x * c0.x, b.y, b.x * c0.y * zscale), n0]
			var p11 := [Vector3(b.x * c1.x, b.y, b.x * c1.y * zscale), n1]
			var p01 := [Vector3(a.x * c1.x, a.y, a.x * c1.y * zscale), n1]
			_tri(st, p00, p10, p11)
			_tri(st, p00, p11, p01)
	return st.commit()


## Cylinder along Y: `size` = (diameter, height, diameter). `bevel` chamfers both rims, `hole` is the
## inner diameter as a fraction (0 = solid, 0.8 = a thin tube), `top` the top radius as a fraction (cone).
static func cylinder(size: Vector3, bevel := 0.0, segs := 14, hole := 0.0, top := 1.0) -> ArrayMesh:
	var key := "cyl %.3v %.4f %d %.2f %.2f" % [size, bevel, segs, hole, top]
	if _cache.has(key):
		return _cache[key]
	var r := size.x * 0.5
	var h := size.y * 0.5
	var rt := r * top
	var hr := r * hole
	var b := minf(bevel, minf(r - hr, h) * 0.9)
	var pts: Array = [Vector2(hr, h)]
	if b > 0.0:
		pts.append(Vector2(rt - b, h))
		pts.append(Vector2(rt, h - b))
		pts.append(Vector2(r, -h + b))
		pts.append(Vector2(r - b, -h))
	else:
		pts.append(Vector2(rt, h))
		pts.append(Vector2(r, -h))
	pts.append(Vector2(hr, -h))
	if hr > 0.0:
		pts.append(Vector2(hr, h))
	else:
		pts[0] = Vector2(0, h)
		pts[pts.size() - 1] = Vector2(0, -h)
	var mesh := lathe(pts, segs, size.z / maxf(size.x, 0.0001))
	_cache[key] = mesh
	return mesh


## An ellipsoid (UV sphere with few rings): `size` = the three diameters.
static func sphere(size: Vector3, segs := 12) -> ArrayMesh:
	var key := "sph %.3v %d" % [size, segs]
	if _cache.has(key):
		return _cache[key]
	var pts: Array = []
	var rings := maxi(segs / 2, 3)
	for k in rings + 1:
		var a := PI * k / rings
		pts.append(Vector2(sin(a) * 0.5, cos(a) * 0.5))
	var mesh := lathe(pts, segs)
	# scale the unit sphere to the requested size
	var arr := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	for i in verts.size():
		verts[i] = verts[i] * size
		norms[i] = (norms[i] / size).normalized()
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_cache[key] = out
	return out


## A triangular wedge: full height at the back (-Z), sloping to nothing at the front (+Z).
static func wedge(size: Vector3) -> ArrayMesh:
	var key := "wedge %.3v" % size
	if _cache.has(key):
		return _cache[key]
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var slope := Vector3(0, size.z, size.y).normalized()
	var faces: Array = [
		[Vector3.LEFT, [Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz), Vector3(-hx, hy, -hz)]],
		[Vector3.RIGHT, [Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(hx, hy, -hz)]],
		[Vector3.DOWN, [Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz)]],
		[Vector3.FORWARD, [Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, hy, -hz), Vector3(-hx, hy, -hz)]],
		[slope, [Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz)]],
	]
	for f: Array in faces:
		var c: Array = f[1]
		var q: Array = []
		for p: Vector3 in c:
			q.append([p, f[0]])
		_tri(st, q[0], q[1], q[2])
		if q.size() > 3:
			_tri(st, q[0], q[2], q[3])
	var mesh := st.commit()
	_cache[key] = mesh
	return mesh


## Convenience: a MeshInstance3D for `mesh` with a material, at a position.
static func instance(mesh: Mesh, mat: Material, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	return mi


## Adds one triangle of [position, normal] corners, wound so its front faces along the normals.
static func _tri(st: SurfaceTool, p0: Array, p1: Array, p2: Array) -> void:
	var cross: Vector3 = (p1[0] - p0[0]).cross(p2[0] - p0[0])
	if cross.length_squared() < 1e-12:
		return
	var corners := [p0, p1, p2]
	if cross.dot(p0[1] + p1[1] + p2[1]) > 0.0:   # Godot's front faces are clockwise
		corners = [p0, p2, p1]
	for corner: Array in corners:
		st.set_normal(corner[1])
		st.add_vertex(corner[0])
