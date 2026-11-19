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
