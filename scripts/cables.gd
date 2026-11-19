extends Node3D
## Draws every plugged-in cable as a sagging chain of segments, plus the cable end the
## local player is currently carrying. Purely visual; the data lives on the items.

const SEGMENTS := 10
const HOSE_EMPTY := Color(0.55, 0.57, 0.6)   # a dry hose
const HOSE_FULL := Color(0.1, 0.45, 1.0)     # one full of coolant

var world: Node3D

var _pool: Dictionary = {}     # key -> {"node", "a", "b", "points": the bends, "link": [item id, type]}
var _mesh: CylinderMesh
var _mats: Dictionary = {}


func _ready() -> void:
	_mesh = CylinderMesh.new()
	_mesh.top_radius = 1.0
	_mesh.bottom_radius = 1.0
	_mesh.height = 1.0
	_mesh.radial_segments = 6
	_mesh.rings = 0
	_mats["power"] = _mat(Color(0.07, 0.07, 0.08))
	_mats["net"] = _mat(Color(0.1, 0.75, 0.35))
	_mats["coolant"] = _mat(HOSE_EMPTY)


func _process(_dt: float) -> void:
	var seen := {}
	for it: Node3D in world.items.values():
		for type: String in ["power", "net", "coolant"]:
			var to: int = it.link(type)
			var target: Node3D = world.provider(to) if to != 0 else null
			if target:
				var key := "%d%s" % [it.id, type]
				seen[key] = true
				_draw(key, type, it.port_pos(type), _socket_pos(target, it.id))
				_pool[key]["link"] = [it.id, type]
				if type == "coolant":   # grey when empty, blue when full
					_pool[key]["mat"].albedo_color = HOSE_EMPTY.lerp(HOSE_FULL, it.hose)
	if not world.preview.is_empty():
		var src: Node3D = world.items.get(world.preview["id"])
		var me: Node3D = world.player(multiplayer.get_unique_id())
		if src and me:
			seen["preview"] = true
			_draw("preview", world.preview["type"], src.port_pos(world.preview["type"]), me.hand.global_position)
	for key: String in _pool.keys():
		if not seen.has(key):
			_pool[key]["node"].queue_free()
			_pool.erase(key)


## The cable lying across this spot at ankle height, as [item id, type], or [] if there is none.
func tripped_by(pos: Vector3, reach := 0.28) -> Array:
	var foot := Vector2(pos.x, pos.z)
	for entry: Dictionary in _pool.values():
		if not entry.has("link"):
			continue
		var points: Array = entry["points"]
		for i in points.size() - 1:
			var p: Vector3 = points[i]
			var q: Vector3 = points[i + 1]
			if minf(p.y, q.y) > pos.y + 0.3:
				continue   # hanging above the feet
			var closest := Geometry2D.get_closest_point_to_segment(foot, Vector2(p.x, p.z), Vector2(q.x, q.z))
			if closest.distance_to(foot) < reach:
				return entry["link"]
	return []


## Spread plugs a little so several cables into one provider do not overlap exactly.
func _socket_pos(target: Node3D, plug_id: int) -> Vector3:
	var spread := (float(plug_id % 4) - 1.5) * 0.04
	return target.global_transform * Vector3(spread, 0.02, 0.03)


func _draw(key: String, type: String, a: Vector3, b: Vector3) -> void:
	var entry: Dictionary = _pool.get(key, {})
	if entry.is_empty():
		var node := Node3D.new()
		add_child(node)
		var mat: StandardMaterial3D = _mats[type]
		if type == "coolant":
			mat = mat.duplicate()   # every hose has its own colour
		for i in SEGMENTS:
			var seg := MeshInstance3D.new()
			seg.mesh = _mesh
			seg.material_override = mat
			node.add_child(seg)
		entry = {"node": node, "a": Vector3.INF, "b": Vector3.INF, "points": [], "mat": mat}
		_pool[key] = entry
	if entry["a"].is_equal_approx(a) and entry["b"].is_equal_approx(b):
		return
	entry["a"] = a
	entry["b"] = b
	var radius: float = {"power": 0.014, "coolant": 0.022}.get(type, 0.01)
	var sag := 0.2 + a.distance_to(b) * 0.15
	var low := minf(0.02, minf(a.y, b.y))
	var prev := a
	var points := [a]
	entry["points"] = points
	for i in SEGMENTS:
		var t := float(i + 1) / SEGMENTS
		var p := a.lerp(b, t)
		p.y = maxf(p.y - sag * 4.0 * t * (1.0 - t), low)
		var d := p - prev
		var length := maxf(d.length(), 0.001)
		var y := d / length
		var x := y.cross(Vector3.FORWARD)
		if x.length() < 0.01:
			x = y.cross(Vector3.RIGHT)
		x = x.normalized()
		var seg: MeshInstance3D = entry["node"].get_child(i)
		seg.transform = Transform3D(Basis(x * radius, y * length, x.cross(y) * radius), (prev + p) * 0.5)
		prev = p
		points.append(p)


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.4
	m.clearcoat_enabled = true
	m.clearcoat = 0.3
	m.clearcoat_roughness = 0.35
	return m
