extends Node3D
## Draws every plugged-in cable, plus the cable end the local player is carrying.
## Purely visual; the data lives on the items (`Item.link`, `Item.routes`).
##
## A cable with no pins is a slack line: it sags, lies on the floor in lazy curves and can be
## tripped over. Pins (`Item.routes[type]`, set while carrying the cable) clip it to walls, floors
## and ceilings: between two pins it runs dead straight and nobody trips over it. Only the two
## ends, from the device to the first pin and from the last pin to the socket, hang loose.

const LOOSE_STEPS := 20
const HOSE_EMPTY := Color(0.55, 0.57, 0.6)   # a dry hose
const HOSE_FULL := Color(0.1, 0.45, 1.0)     # one full of coolant
const RADIUS := {"power": 0.014, "net": 0.01, "coolant": 0.022}

var world: Node3D

var _pool: Dictionary = {}     # key -> {"node", "path", "points", "loose", "mat", "link": [item id, type]}
var _mesh: CylinderMesh
var _clip: BoxMesh
var _clip_mat: StandardMaterial3D
var _mats: Dictionary = {}


func _ready() -> void:
	_mesh = CylinderMesh.new()
	_mesh.top_radius = 1.0
	_mesh.bottom_radius = 1.0
	_mesh.height = 1.0
	_mesh.radial_segments = 6
	_mesh.rings = 0
	_clip = BoxMesh.new()
	_clip.size = Vector3.ONE
	_clip_mat = _mat(Color(0.85, 0.72, 0.15))
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
				var path: Array = [it.port_pos(type)]
				path.append_array(it.routes.get(type, []))
				path.append(_socket_pos(target, it.id))
				_draw(key, type, path)
				_pool[key]["link"] = [it.id, type]
				if type == "coolant":   # grey when empty, blue when full
					_pool[key]["mat"].albedo_color = HOSE_EMPTY.lerp(HOSE_FULL, it.hose)
	if not world.preview.is_empty():
		var src: Node3D = world.items.get(world.preview["id"])
		var me: Node3D = world.player(multiplayer.get_unique_id())
		if src and me:
			seen["preview"] = true
			var path: Array = [src.port_pos(world.preview["type"])]
			path.append_array(world.preview.get("pins", []))
			path.append(me.hand.global_position)
			_draw("preview", world.preview["type"], path)
	for key: String in _pool.keys():
		if not seen.has(key):
			_pool[key]["node"].queue_free()
			_pool.erase(key)


## The cable lying across this spot at ankle height, as [item id, type], or [] if there is none.
## Only slack cable counts: a stretch clipped down between two pins is safe to run over.
func tripped_by(pos: Vector3, reach := 0.28) -> Array:
	var foot := Vector2(pos.x, pos.z)
	for entry: Dictionary in _pool.values():
		if not entry.has("link"):
			continue
		var points: Array = entry["points"]
		var loose: Array = entry["loose"]
		for i in points.size() - 1:
			if not loose[i]:
				continue
			var p: Vector3 = points[i]
			var q: Vector3 = points[i + 1]
			if minf(p.y, q.y) > pos.y + 0.3 or maxf(p.y, q.y) < pos.y - 0.5:
				continue   # hanging above the feet, or on another floor
			var closest := Geometry2D.get_closest_point_to_segment(foot, Vector2(p.x, p.z), Vector2(q.x, q.z))
			if closest.distance_to(foot) < reach:
				return entry["link"]
	return []


## Spread plugs a little so several cables into one provider do not overlap exactly.
func _socket_pos(target: Node3D, plug_id: int) -> Vector3:
	var spread := (float(plug_id % 4) - 1.5) * 0.04
	return target.global_transform * Vector3(spread, 0.02, 0.03)


## `path` = where it leaves the device, every pin, where it ends.
func _draw(key: String, type: String, path: Array) -> void:
	var entry: Dictionary = _pool.get(key, {})
	if entry.is_empty():
		var node := Node3D.new()
		add_child(node)
		var mat: StandardMaterial3D = _mats[type]
		if type == "coolant":
			mat = mat.duplicate()   # every hose has its own colour
		entry = {"node": node, "path": [], "points": [], "loose": [], "mat": mat, "clips": []}
		_pool[key] = entry
	var old: Array = entry["path"]
	if old.size() == path.size():
		var same := true
		for i in path.size():
			same = same and (old[i] as Vector3).is_equal_approx(path[i])
		if same:
			return
	entry["path"] = path.duplicate()

	# The line the cable follows, and which stretches of it hang loose.
	var points: Array = [path[0]]
	var loose: Array = []
	var last := path.size() - 2
	for leg in path.size() - 1:
		var a: Vector3 = path[leg]
		var b: Vector3 = path[leg + 1]
		if leg > 0 and leg < last:   # pin to pin: clipped down, dead straight
			points.append(b)
			loose.append(false)
			continue
		var slack := path.size() == 2   # no pins at all: the whole thing lies wherever it fell
		var length := a.distance_to(b)
		var sag := (0.2 + length * 0.15) if slack else (0.06 + length * 0.1)
		var low := minf(0.02, minf(a.y, b.y))
		var side := Vector3(b.z - a.z, 0, a.x - b.x).normalized()
		var wobble := hash(key) % 1000 / 1000.0
		for i in LOOSE_STEPS:
			var t := float(i + 1) / LOOSE_STEPS
			var p := a.lerp(b, t)
			var hang := p.y - sag * 4.0 * t * (1.0 - t)
			if hang < low:   # the part resting on the floor snakes about: more slack, more mess
				var on_floor := clampf((low - hang) / sag * 2.0, 0.0, 1.0)
				var wave := sin(t * TAU * (1.0 + wobble) + wobble * 9.0) + 0.5 * sin(t * TAU * 2.7 + wobble * 31.0)
				p += side * wave * on_floor * (0.05 + length * 0.035) * (1.0 if slack else 0.4)
			p.y = maxf(hang, low)
			points.append(p)
			loose.append(true)
	entry["points"] = points
	entry["loose"] = loose

	var node: Node3D = entry["node"]
	var radius: float = RADIUS[type]
	var segs := points.size() - 1
	var clips: Array = entry["clips"]
	while node.get_child_count() - clips.size() < segs:
		var seg := MeshInstance3D.new()
		seg.mesh = _mesh
		seg.material_override = entry["mat"]
		node.add_child(seg)
		node.move_child(seg, node.get_child_count() - clips.size() - 1)   # segments first, clips after
	var have := node.get_child_count() - clips.size()
	for i in have:
		var seg: MeshInstance3D = node.get_child(i)
		seg.visible = i < segs
		if i >= segs:
			continue
		var d: Vector3 = points[i + 1] - points[i]
		var length := maxf(d.length(), 0.001)
		var y := d / length
		var x := y.cross(Vector3.FORWARD)
		if x.length() < 0.01:
			x = y.cross(Vector3.RIGHT)
		x = x.normalized()
		# a touch longer than the gap, so bends do not show cracks
		seg.transform = Transform3D(Basis(x * radius, y * (length + radius), x.cross(y) * radius), (points[i] + points[i + 1]) * 0.5)

	# one clip per pin
	var pins := path.size() - 2
	while clips.size() < pins:
		var clip := MeshInstance3D.new()
		clip.mesh = _clip
		clip.material_override = _clip_mat
		node.add_child(clip)
		clips.append(clip)
	for i in clips.size():
		var clip: MeshInstance3D = clips[i]
		clip.visible = i < pins
		if i < pins:
			clip.transform = Transform3D(Basis().scaled(Vector3.ONE * radius * 3.2), path[i + 1])


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.4
	m.clearcoat_enabled = true
	m.clearcoat = 0.3
	m.clearcoat_roughness = 0.35
	return m
