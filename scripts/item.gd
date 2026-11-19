extends RigidBody3D
## A physical object. Exactly one of three states:
##   loose     simulated by the host; clients keep it frozen and follow the host's transforms
##   held      glued to a player's hand (holder = peer id)
##   attached  mounted in a slot of another item (parent = item id), e.g. GPU on a server
## It may also have a power and a network cable plugged into a provider (item id > 0, fixture id < 0).

const Catalog = preload("res://scripts/catalog.gd")

var id := 0
var kind := ""
var def: Dictionary = {}
var label := ""
var provides := ""      # "power" | "net" | "" — what others can plug into this
var sockets := 0
var holder := 0
var parent := 0
var slot := 0
var pinned := false     # placed deliberately: stays exactly put (no physics) until grabbed or unsupported
var power_to := 0
var net_to := 0
var coolant_to := 0     # what this item's coolant hose is plugged into
var routes: Dictionary = {}   # link type -> [Vector3]: where that cable is pinned on its way to the provider
var worn := 0           # heat suit: peer id wearing it
var opened := false     # machines: the lid is off, parts can go in and out
var status := -1        # bit 0 powered, bit 1 online, bit 2 ruined; set by the host's simulation
var contains := ""      # parcels: the item kind inside
var broken := false     # ruined by rain; set through status bit 2 so every peer shows it
var wet := 0.0          # host only: seconds of rain soaked up so far
var dead := false       # host only: will be reported as ruined (burnt out, or a dud from the start)
var burning := false    # host only: on fire; reaches other peers as status bit 3
var burn := 0.0         # host only: seconds it has been burning
var cooked := false     # host only: server in thermal shutdown
var sketchy := false    # host only: second-hand server whose thermal protection is broken
var draining := false   # host only: pump is sucking its hoses empty
# generators only (the host simulates these and replicates them twice a second)
var running := false    # fuel generators and pumps: switched on
var fuel := 0.0         # 0..1 how full: fuel tank, coolant reservoir or bucket
var hose := 0.0         # 0..1 how full of coolant this item's own hose is
var heat := 0.0         # degrees C: a server's chips, or the coolant leaving a pump
var rider := 0          # bike generator: peer id pedalling it
var load := 0.0         # watts currently drawn from it

var _world: Node3D
var _leds: Array = []
var _light: OmniLight3D   # lamps only
var _lid: MeshInstance3D            # machines only
var _lid_shape: CollisionShape3D
var _screen: Node3D       # ops screens only
var _fire: Node3D         # flames and their glow, while burning
var _shell: MeshInstance3D   # heat suit only: the silver shell shown while it is worn
var _target_pos := Vector3.ZERO
var _target_rot := Quaternion.IDENTITY
var _has_target := false
var _pin_xf := Transform3D.IDENTITY


## `p_contains` is only for kind "parcel": the item kind boxed up inside.
func setup(p_id: int, p_kind: String, p_contains := "") -> void:
	id = p_id
	kind = p_kind
	contains = p_contains
	def = Catalog.parcel(contains) if kind == "parcel" else Catalog.ITEMS[kind]
	label = def["label"]
	provides = def.get("provides", "")
	sockets = def.get("sockets", 0)
	mass = def["mass"]
	if def.get("gen", {}).get("kind", "") == "fuel":
		fuel = 0.3   # sold with a splash in the tank
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	continuous_cd = true
	for s: Array in def.get("shapes", [[def["size"], Vector3.ZERO]]):
		var box := BoxShape3D.new()
		box.size = s[0]
		var shape := CollisionShape3D.new()
		shape.shape = box
		shape.position = s[1]
		add_child(shape)
	for tagged: Array in Catalog.build_parts(self, def["parts"]):
		_leds.append(tagged[1])
	if def.has("lid_box"):   # the lid is its own mesh and collider, so it can come off
		var lid: Array = def["lid_box"]
		var lid_shape := BoxShape3D.new()
		lid_shape.size = lid[0]
		_lid_shape = CollisionShape3D.new()
		_lid_shape.shape = lid_shape
		_lid_shape.position = lid[1]
		add_child(_lid_shape)
		var lid_mat := StandardMaterial3D.new()
		lid_mat.albedo_color = lid[2]
		lid_mat.roughness = 0.45
		lid_mat.metallic = 0.4
		_lid = Catalog.Shapes.instance(Catalog.Shapes.rounded_box(lid[0], 0.006, 1), lid_mat, lid[1])
		add_child(_lid)
	if kind == "parcel":   # say what is inside, on the front and the back of the box
		var size: Vector3 = def["size"]
		for side: float in [-1.0, 1.0]:
			var text := Label3D.new()
			text.text = Catalog.ITEMS[contains]["label"]
			text.font_size = 36
			text.pixel_size = 0.0018
			text.width = size.x * 0.85 / text.pixel_size
			text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			text.modulate = Color(0.2, 0.14, 0.08)
			text.outline_size = 0
			text.position = Vector3(size.x * -0.2 * side, size.y * 0.2, (size.z * 0.5 + 0.006) * side)
			text.rotation.y = 0.0 if side > 0.0 else PI
			add_child(text)
	if def.get("light", false):
		_light = OmniLight3D.new()
		_light.position.y = def["size"].y * 0.4
		_light.light_color = Color(1.0, 0.9, 0.75)
		_light.light_energy = 2.2
		_light.omni_range = 9.0
		_light.distance_fade_enabled = true
		_light.distance_fade_begin = 30.0
		_light.distance_fade_length = 10.0
		add_child(_light)
	set_status(0)


func _ready() -> void:
	_world = get_parent().get_parent()
	set_open(opened)
	if def.get("screen", false):   # an ops screen you can hang anywhere; dark without power
		_screen = preload("res://scripts/ops_screen.gd").new()
		_screen.setup(_world.board, def["size"].x - 0.08, false)
		_screen.position.z = -def["size"].z * 0.5
		_screen.visible = false
		add_child(_screen)
	apply_mode()


## Take a machine's lid off or put it back.
func set_open(open: bool) -> void:
	opened = open
	if _lid:
		_lid.visible = not open
		_lid_shape.set_deferred("disabled", open)


func is_loose() -> bool:
	return holder == 0 and parent == 0 and worn == 0


func link(type: String) -> int:
	return power_to if type == "power" else (net_to if type == "net" else coolant_to)


func set_link(type: String, to: int) -> void:
	match type:
		"power":
			power_to = to
		"net":
			net_to = to
		_:
			coolant_to = to


## Where this item's own cable of the given type leaves it (world space).
func port_pos(type: String) -> Vector3:
	var size: Vector3 = def["size"]
	var side: float = {"power": -0.3, "net": 0.3}.get(type, 0.0)
	return global_transform * Vector3(size.x * side, 0, size.z * 0.5)


## Heat suit: show the folded bundle, or a silver shell around whoever wears it.
func _show_worn() -> void:
	var on := worn != 0
	if on and _shell == null:
		var foil := StandardMaterial3D.new()
		foil.albedo_color = Color(0.82, 0.84, 0.88, 0.55)
		foil.metallic = 0.8
		foil.roughness = 0.25
		foil.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var body := CapsuleMesh.new()
		body.radius = 0.46
		body.height = 1.75
		body.material = foil
		_shell = MeshInstance3D.new()
		_shell.mesh = body
		_shell.position.y = 0.875
		add_child(_shell)
	for child: Node in get_children():
		if child is MeshInstance3D:
			child.visible = (child == _shell) == on
	if _shell and on:
		_shell.visible = worn != multiplayer.get_unique_id()   # do not blind the wearer


func set_status(bits: int) -> void:
	if bits == status:
		return
	status = bits
	if bits & 4 and not broken:
		_ruin()
	_show_fire(bits & 8 != 0)
	var power := bits & 3
	if _light:
		_light.visible = power == 3
	if _screen:
		_screen.visible = power == 3
	for mat: StandardMaterial3D in _leds:
		Catalog.set_light(mat, 2 if power == 3 else (1 if power == 1 else 0))


func on_fire() -> bool:
	return _fire != null


func _show_fire(on: bool) -> void:
	if on == (_fire != null):
		return
	if not on:
		_fire.queue_free()
		_fire = null
		return
	var size: Vector3 = def["size"]
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.vertex_color_use_as_albedo = true
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var puff := SphereMesh.new()
	puff.radius = 0.11
	puff.height = 0.22
	puff.radial_segments = 8
	puff.rings = 4
	puff.material = glow
	var fade := Gradient.new()
	fade.set_color(0, Color(1.0, 0.9, 0.3, 0.95))
	fade.set_color(1, Color(0.9, 0.15, 0.0, 0.0))
	var flames := CPUParticles3D.new()
	flames.mesh = puff
	flames.amount = 36
	flames.lifetime = 0.8
	flames.local_coords = false
	flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	flames.emission_box_extents = Vector3(size.x, size.y, size.z) * 0.4
	flames.direction = Vector3.UP
	flames.spread = 25.0
	flames.gravity = Vector3(0, 2.5, 0)
	flames.initial_velocity_min = 0.5
	flames.initial_velocity_max = 1.4
	flames.scale_amount_min = 0.6
	flames.scale_amount_max = 1.6
	flames.color_ramp = fade
	var flicker := OmniLight3D.new()
	flicker.light_color = Color(1.0, 0.5, 0.15)
	flicker.light_energy = 2.5
	flicker.omni_range = 5.0
	flicker.position.y = size.y * 0.5 + 0.3
	_fire = Node3D.new()
	_fire.add_child(flames)
	_fire.add_child(flicker)
	add_child(_fire)


## Rained on: dead for good. It still exists as scorched junk you can carry around.
func _ruin() -> void:
	broken = true
	label = "Ruined %s" % def["label"].to_lower()
	for child: Node in get_children():
		var mesh := child as MeshInstance3D
		if mesh and mesh.material_override is StandardMaterial3D:
			var mat: StandardMaterial3D = mesh.material_override
			mat.albedo_color = mat.albedo_color.darkened(0.6).lerp(Color(0.25, 0.2, 0.15), 0.4)
			mat.roughness = 1.0


func release(xf: Transform3D, vel: Vector3, pin := false) -> void:
	holder = 0
	parent = 0
	worn = 0
	pinned = pin
	_pin_xf = xf
	global_transform = xf
	apply_mode()
	# Tell the physics engine directly as well: a body that was being carried a moment ago
	# otherwise gets its old hand position written back over the new one.
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	if not freeze:
		linear_velocity = vel
		angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4)) \
				* clampf(vel.length() / 6.0, 0.0, 1.0)
		sleeping = false


func net_target(pos: Vector3, rot: Quaternion) -> void:
	_target_pos = pos
	_target_rot = rot
	_has_target = true


## Call after changing holder/parent. Layer 2 = loose, layer 4 = attached (ray-only), 0 = held.
## Loose items collide with the world and each other (mask 3), never with players.
func apply_mode() -> void:
	_has_target = false
	if def.get("wear", false):
		_show_worn()
	freeze = not is_loose() or pinned or not multiplayer.is_server()
	var loose_layer := 2 | (16 if def.get("solid", false) else 0)   # 16 = players cannot walk through
	collision_layer = loose_layer if is_loose() else (4 if holder == 0 and worn == 0 else 0)
	collision_mask = 3 if is_loose() else 0


func _process(dt: float) -> void:
	if worn != 0:
		var wearer: Node3D = _world.player(worn)
		if wearer:
			global_transform = wearer.global_transform
	elif holder != 0:
		var p: Node3D = _world.player(holder)
		if p:
			global_transform = p.hand.global_transform
	elif parent != 0:
		var par: Node3D = _world.items.get(parent)
		if par:
			global_transform = par.global_transform * (par.def["slots"][slot]["xf"] as Transform3D)
	elif pinned:
		if not global_transform.is_equal_approx(_pin_xf):
			global_transform = _pin_xf
	elif freeze and _has_target:
		var k := 1.0 - exp(-20.0 * dt)
		position = position.lerp(_target_pos, k)
		quaternion = quaternion.slerp(_target_rot, k)
