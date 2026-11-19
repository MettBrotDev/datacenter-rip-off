extends Node3D
## A house on a town lot: walls with real door and window openings, two rooms, a roof, its own
## wiring (outlets, breaker, internet) and a neighbour standing outside who might sell it.
## Local frame: centred on the footprint, front door facing +Z. Three states:
##   NEIGHBOUR  locked, wiring dead      OURS  door works, wiring live
##   GONE       demolished: a flat building pad, the wiring moved onto a utility board

const Town = preload("res://scripts/town.gd")
const Shapes = preload("res://scripts/shapes.gd")
const Fixture = preload("res://scripts/fixture.gd")
const Blob = preload("res://scripts/blob.gd")

enum { NEIGHBOUR, OURS, GONE }

const HEIGHT := 2.7       # wall height
const THICK := 0.25       # outer wall thickness
const FLOOR_Y := 0.04
const WALL_COLORS: Array[Color] = [Color(0.95, 0.9, 0.75), Color(0.75, 0.86, 0.95), Color(0.93, 0.78, 0.72),
	Color(0.8, 0.92, 0.8), Color(0.96, 0.94, 0.9), Color(0.9, 0.82, 0.92), Color(0.98, 0.86, 0.6)]
const ROOF_COLORS: Array[Color] = [Color(0.55, 0.2, 0.17), Color(0.25, 0.28, 0.36), Color(0.3, 0.4, 0.32),
	Color(0.45, 0.3, 0.22), Color(0.6, 0.35, 0.2)]

var id := 0
var lot: Dictionary
var state := NEIGHBOUR
var door_open := false
var fixtures: Dictionary = {}   # fixture id -> Fixture; the world merges these into its own table

var _w := 0.0
var _d := 0.0
var _px := 0.0                  # x of the wall between living room and bedroom
var _door_x := 0.0              # centre of the front door
var _shell: Node3D              # everything that disappears when the house is demolished
var _solid: StaticBody3D
var _door: Fixture
var _npc_blob: Node3D
var _mats: Dictionary = {}


func setup(p_lot: Dictionary) -> void:
	lot = p_lot
	id = lot["id"]
	position = lot["pos"]
	rotation.y = deg_to_rad(lot["yaw"])
	var footprint: Vector2 = Town.FOOTPRINTS[lot["size"]]
	_w = footprint.x
	_d = footprint.y
	_px = _w * 0.18
	_door_x = -_w * 0.5 + _w * 0.3
	if id == 0:
		state = OURS
	_build_shell()
	_build_fixtures()


## Where the previous owners left their furniture: [[item kind, world transform]].
func furniture() -> Array:
	var hw := _w * 0.5
	var hd := _d * 0.5
	var living_x := (-hw + _px) * 0.5
	var spots := [
		["sofa", Vector3(-hw + 0.75, 0.4, -hd * 0.5 - 0.2), -90.0],
		["table", Vector3(living_x + 0.2, 0.225, -hd * 0.5 - 0.2), 90.0],
		["tv", Vector3(_px - 0.4, 0.45, -hd * 0.5 - 0.2), 90.0],
		["fridge", Vector3(_px - 0.6, 0.9, -hd + 0.65), 180.0],
		["plant", Vector3(-hw + 0.6, 0.45, hd - 0.7), 0.0],
		["bed", Vector3((_px + hw) * 0.5, 0.275, -hd + 1.35), 0.0],
	]
	var out := []
	for spot: Array in spots:
		var local := Transform3D(Basis(Vector3.UP, deg_to_rad(spot[2])), spot[1] + Vector3(0, FLOOR_Y + 0.01, 0))
		out.append([spot[0], global_transform * local])
	return out


func set_state(new_state: int) -> void:
	if new_state == state:
		return
	state = new_state
	var live := state != NEIGHBOUR
	for f: Fixture in fixtures.values():
		if f.kind == "outlet":
			f.provides = "power" if live else ""
		elif f.kind == "router":
			f.provides = "net" if live else ""
			f.set_lamp(2 if live else 0)
	if _npc_blob:   # the neighbour moves out
		var npc: Fixture = fixtures[_fid(1)]
		fixtures.erase(npc.id)
		npc.queue_free()
		_npc_blob = null
	if state == GONE:
		_demolish()


func set_door(open: bool) -> void:
	door_open = open
	if _door:
		create_tween().tween_property(_door, "rotation:y", -1.9 if open else 0.0, 0.5).set_trans(Tween.TRANS_SINE)


func _process(dt: float) -> void:
	if _npc_blob:
		_npc_blob.animate(dt, 0.0, 0.0)


# --- construction -----------------------------------------------------------------

func _build_shell() -> void:
	var hw := _w * 0.5
	var hd := _d * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000 + id
	_mats["wall"] = _mat(WALL_COLORS[rng.randi() % WALL_COLORS.size()], 0.85)
	_mats["roof"] = _mat(ROOF_COLORS[rng.randi() % ROOF_COLORS.size()], 0.7)
	_mats["inner"] = _mat(Color(0.93, 0.91, 0.86), 0.9)
	_mats["floor"] = _mat(Color(0.62, 0.45, 0.3), 0.6)
	_mats["trim"] = _mat(Color(0.97, 0.97, 0.95), 0.6)
	var glass := _mat(Color(0.7, 0.86, 0.95, 0.35), 0.1)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mats["glass"] = glass

	_shell = Node3D.new()
	add_child(_shell)
	_solid = StaticBody3D.new()
	_shell.add_child(_solid)

	_slab(Vector3(_w, 0.3, _d), Vector3(0, FLOOR_Y - 0.15, 0), _mats["floor"])
	_slab(Vector3(_w, 0.15, _d), Vector3(0, HEIGHT + 0.075, 0), _mats["inner"])
	# openings: [distance along the wall, width, bottom, top, has glass]
	_wall(Vector3(-hw, 0, hd), Vector3(hw, 0, hd), [[_w * 0.3, 1.2, 0.0, 2.1, false], [_w * 0.72, 1.8, 0.9, 2.1, true]])
	_wall(Vector3(-hw, 0, -hd), Vector3(hw, 0, -hd), [[_w * 0.25, 1.6, 0.9, 2.1, true], [_w * 0.78, 1.6, 0.9, 2.1, true]])
	_wall(Vector3(-hw, 0, -hd), Vector3(-hw, 0, hd), [[_d * 0.5, 1.6, 0.9, 2.1, true]])
	_wall(Vector3(hw, 0, -hd), Vector3(hw, 0, hd), [[_d * 0.5, 1.6, 0.9, 2.1, true]])
	_wall(Vector3(_px, 0, -hd), Vector3(_px, 0, hd), [[_d * 0.7, 1.1, 0.0, 2.1, false]], 0.14, _mats["inner"])

	var rise: float = 1.5 + lot["size"] * 0.3
	var roof := Shapes.instance(Shapes.prism(Vector3(_w + 0.9, rise, _d + 0.9)), _mats["roof"], Vector3(0, HEIGHT + 0.15, 0))
	_shell.add_child(roof)
	_shell.add_child(Shapes.instance(Shapes.rounded_box(Vector3(0.6, rise + 0.5, 0.6), 0.05), _mats["wall"],
			Vector3(hw * 0.5, HEIGHT + rise * 0.5 + 0.3, -hd * 0.3)))
	# doorstep
	_shell.add_child(Shapes.instance(Shapes.rounded_box(Vector3(1.8, 0.1, 0.9), 0.04), _mats["trim"],
			Vector3(_door_x, -0.01, hd + 0.5)))


func _build_fixtures() -> void:
	var hw := _w * 0.5
	var hd := _d * 0.5
	var inside := THICK * 0.5
	_door = _fixture(0, "hdoor", Vector3(_door_x - 0.6, FLOOR_Y, hd), 0.0)
	_door.label = "Front door"
	_fixture(2, "breaker", Vector3(_door_x + 1.3, 1.45, hd - inside), 180.0)
	_fixture(7, "deed", Vector3(_door_x + 1.95, 1.5, hd - inside), 180.0)
	var router := _fixture(3, "router", Vector3(-hw + 0.75, 1.5, -hd + inside), 0.0)
	_fixture(4, "outlet", Vector3(-hw + _w * 0.25, 0.4, -hd + inside), 0.0)
	_fixture(5, "outlet", Vector3(-hw + inside, 0.4, hd * 0.55), 90.0)
	_fixture(6, "outlet", Vector3(_px + 1.2, 0.4, -hd + inside), 0.0)
	for f: Fixture in fixtures.values():
		f.circuit = id
		if state == NEIGHBOUR and f.kind in ["outlet", "router"]:
			f.provides = ""
	router.set_lamp(0 if state == NEIGHBOUR else 2)
	if state != NEIGHBOUR:
		return
	# the neighbour, standing by their front door
	var npc := _fixture(1, "neighbour", Vector3(_door_x + 1.7, 0, hd + 1.6), 0.0)
	npc.label = lot["name"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 5000 + id
	_npc_blob = Blob.new()
	npc.add_child(_npc_blob)
	_npc_blob.setup(Color.from_hsv(rng.randf(), 0.55, 0.9))
	_npc_blob.rotation.y = PI   # blobs face -Z; the neighbour looks out at the street
	var tag := Label3D.new()
	tag.text = lot["name"].capitalize()
	tag.position.y = 1.95
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 44
	tag.pixel_size = 0.0022
	tag.outline_size = 12
	tag.outline_modulate = Color(0.04, 0.06, 0.12)
	npc.add_child(tag)


func _fixture(slot: int, kind: String, pos: Vector3, yaw: float) -> Fixture:
	var f := Fixture.new()
	f.setup(_fid(slot), kind)
	f.house = id
	f.position = pos
	f.rotation.y = deg_to_rad(yaw)
	add_child(f)
	fixtures[f.id] = f
	return f


func _fid(slot: int) -> int:
	return -(1000 + id * 10 + slot)


## Knock it all down: a flat pad the size of the lot's clear area, with the wiring on a board.
func _demolish() -> void:
	_shell.queue_free()
	for slot: int in [0, 7]:   # front door, deed
		var f: Fixture = fixtures.get(_fid(slot))
		if f:
			fixtures.erase(f.id)
			f.queue_free()
	_door = null
	var pad_size := Vector3(Town.CLEAR_SIZE.x, 0.3, Town.CLEAR_SIZE.y)
	var body := StaticBody3D.new()
	add_child(body)
	var pad_pos := Vector3(0, -0.13, 0)
	add_child(Shapes.instance(Shapes.rounded_box(pad_size, 0.05), _mat(Color(0.62, 0.62, 0.6), 0.9), pad_pos))
	_collider(body, pad_size, pad_pos)
	# utility board in the back-left corner of the pad, facing the pad
	var board := Vector3(-pad_size.x * 0.5 + 1.6, 0, -pad_size.z * 0.5 + 0.4)
	var wood := _mat(Color(0.45, 0.3, 0.18), 0.8)
	add_child(Shapes.instance(Shapes.rounded_box(Vector3(2.6, 1.5, 0.08), 0.03), wood, board + Vector3(0, 1.05, 0)))
	for x: float in [-1.2, 1.2]:
		add_child(Shapes.instance(Shapes.rounded_box(Vector3(0.12, 1.9, 0.12), 0.03), wood, board + Vector3(x, 0.95, -0.02)))
	_collider(body, Vector3(2.6, 1.9, 0.12), board + Vector3(0, 0.95, 0))
	var spots := {2: Vector3(-0.9, 1.4, 0.04), 3: Vector3(-0.2, 1.5, 0.04), 4: Vector3(0.45, 1.3, 0.04),
		5: Vector3(0.75, 1.3, 0.04), 6: Vector3(1.05, 1.3, 0.04)}
	for slot: int in spots:
		var f: Fixture = fixtures[_fid(slot)]
		f.position = board + spots[slot]
		f.rotation.y = 0.0


## A wall from a to b along the ground, split around its openings.
func _wall(a: Vector3, b: Vector3, openings: Array, thick := THICK, mat: Material = null) -> void:
	if mat == null:
		mat = _mats["wall"]
	var length := a.distance_to(b)
	var dir := (b - a) / length
	var cursor := 0.0
	for o: Array in openings:
		var from: float = o[0] - o[1] * 0.5
		var to: float = o[0] + o[1] * 0.5
		_piece(a, dir, cursor, from, 0.0, HEIGHT, thick, mat)
		_piece(a, dir, from, to, o[3], HEIGHT, thick, mat)
		_piece(a, dir, from, to, 0.0, o[2], thick, mat)
		if o[4]:
			_piece(a, dir, from, to, o[2], o[3], 0.04, _mats["glass"])
			_piece(a, dir, from - 0.06, to + 0.06, o[2] - 0.07, o[2], thick + 0.08, _mats["trim"], false)
		cursor = to
	_piece(a, dir, cursor, length, 0.0, HEIGHT, thick, mat)


func _piece(a: Vector3, dir: Vector3, t0: float, t1: float, y0: float, y1: float, thick: float,
		mat: Material, solid := true) -> void:
	if t1 - t0 < 0.01 or y1 - y0 < 0.01:
		return
	var along_x := absf(dir.x) > 0.5
	var size := Vector3(t1 - t0, y1 - y0, thick) if along_x else Vector3(thick, y1 - y0, t1 - t0)
	var pos := a + dir * (t0 + t1) * 0.5 + Vector3(0, (y0 + y1) * 0.5, 0)
	_shell.add_child(Shapes.instance(Shapes.rounded_box(size, 0.02, 1), mat, pos))
	if solid:
		_collider(_solid, size, pos)


func _slab(size: Vector3, pos: Vector3, mat: Material) -> void:
	_shell.add_child(Shapes.instance(Shapes.rounded_box(size, 0.03, 1), mat, pos))
	_collider(_solid, size, pos)


func _collider(body: StaticBody3D, size: Vector3, pos: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = pos
	body.add_child(col)


func _mat(color: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m
