extends Node3D
## The player's body: a glossy, bean-shaped toy with big sleepy eyes, short thick arms, stubby legs,
## a tool belt and a blinking antenna. Everything is procedural (lathed meshes, smooth normals).
## Origin at the feet, facing -Z.
##
## Use: `setup(color, seed)` once, then `animate(dt, state)` every frame. `state` keys (all optional):
##   speed (horizontal m/s), vel (world velocity), vy, air (bool), pitch (look up positive),
##   held ({"size": Vector3, "mass": float} of the carried item, or empty), cable (bool: cable end in hand),
##   ride (-1 not riding, else 0..1 effort), ride_yaw (bike facing relative to this body),
##   stumble (0..1), exposure (0..1), suit (bool), npc (bool), look_at (world Vector3).
## `poke()` plays a quick reach. `carry_xf()` is where a carried item sits (blob space).

const PELVIS := 0.34         # hip height when standing
const HIP_X := 0.165
const LEG := 0.165           # each leg bone
const ANKLE := 0.075
const ARM1 := 0.27
const ARM2 := 0.27
const SHOULDER := Vector3(0.315, 0.68, 0.0)   # relative to the pelvis, in torso space
const DEPTH := 0.9           # the body is a little flatter front to back
const EYE_Y := 0.93
const TOP := 1.27
const EYE_R := 0.115
const WORLD_UP := Vector3.UP
const Shapes = preload("res://scripts/shapes.gd")

static var _cache: Dictionary = {}

var _rig: Node3D
var _pelvis: Node3D
var _torso: Node3D
var _shape: Node3D
var _eyes: Array[Dictionary] = []
var _mouth: MeshInstance3D
var _tongue: MeshInstance3D
var _ant: Node3D
var _tip_mat: StandardMaterial3D
var _arms: Array[Dictionary] = []
var _legs: Array[Dictionary] = []
var _feet: Array[Node3D] = []
var _body_scale := Vector3.ONE

var _rng := RandomNumberGenerator.new()
var _npc_style := 0
var _time := 0.0
var _phase := 0.0
var _pedal := 0.0
var _spd := 0.0
var _w: Dictionary = {"carry": 0.0, "cable": 0.0, "ride": 0.0, "air": 0.0, "suit": 0.0, "trip": 0.0,
		"reach": 0.0, "wave": 0.0, "heat": 0.0, "bulk": 0.0, "heavy": 0.0, "moving": 0.0, "npc": 0.0}
var _s: Dictionary = {}
var _poke_t := 99.0
var _had_held := false
var _was_air := false
var _prev_yaw := 0.0
var _prev_fwd := 0.0
var _prev_side := 0.0
var _vy_prev := 0.0
var _blink := 0.0
var _blink_in := 2.0
var _look := Vector2.ZERO
var _look_goal := Vector2.ZERO
var _look_in := 1.5
var _glance := 0.0
var _glance_dir := 1.0
var _shift := 0.0
var _shift_goal := 0.0
var _shift_in := 3.0
var _wave_t := 99.0
var _wave_cool := 0.0
var _scratch_t := 99.0
var _scratch_in := 6.0
var _carry_c := Vector3(0.0, 1.0, -0.7)
var _carry_roll := 0.0
var _held_info := {"size": Vector3(0.3, 0.3, 0.3), "mass": 1.0}
var _lid_color := Color.WHITE


func setup(color: Color, seed_value := 0) -> void:
	_rng.seed = seed_value * 7919 + 17
	_npc_style = seed_value % 4
	_time = _rng.randf() * 20.0
	_blink_in = 1.0 + _rng.randf() * 3.0
	_scratch_in = 3.0 + _rng.randf() * 8.0
	if seed_value != 0:   # neighbours come in slightly different builds
		_body_scale = Vector3(1.0 + _rng.randf_range(-0.07, 0.1), 1.0 + _rng.randf_range(-0.06, 0.06), 1.0 + _rng.randf_range(-0.05, 0.08))
	var skin := _skin_mat(color)
	var limb := _limb_mat(color)
	_lid_color = color.darkened(0.25).lerp(Color(0.55, 0.3, 0.7), 0.35)
	var lid_mat := _flat(_lid_color, 0.35)
	lid_mat.rim_enabled = true
	lid_mat.rim = 0.3
	var shoe := _shared_flat("shoe", Color(0.14, 0.15, 0.2), 0.35)

	_rig = Node3D.new()
	add_child(_rig)
	_pelvis = Node3D.new()
	_pelvis.position.y = PELVIS
	_rig.add_child(_pelvis)
	_torso = Node3D.new()
	_pelvis.add_child(_torso)
	_shape = Node3D.new()
	_shape.scale = _body_scale
	_torso.add_child(_shape)
	_shape.add_child(_mi(_body_mesh(), skin))

	# eyes: white ball, pupil with a highlight, and a heavy coloured eyelid
	var white := _shared_flat("white", Color(0.98, 0.98, 0.97), 0.12)
	var dark := _shared_flat("pupil", Color(0.025, 0.02, 0.035), 0.08)
	var shine := _shared_flat("shine", Color(1, 1, 1), 0.5)
	shine.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for side: float in [-1.0, 1.0]:
		var ex := 0.138 * side
		var edge := _body_r(EYE_Y) * DEPTH * sqrt(maxf(1.0 - pow(ex / _body_r(EYE_Y), 2.0), 0.05))
		var eye := Node3D.new()
		eye.position = Vector3(ex, EYE_Y, -edge + 0.035)
		eye.rotation.y = -side * 0.28
		eye.rotation.x = -0.05
		_shape.add_child(eye)
		var ball := _mi(_sphere_mesh(EYE_R, 14, 8), white)
		ball.scale = Vector3(1.0, 1.06, 0.95)
		eye.add_child(ball)
		var pupil := _mi(_sphere_mesh(0.062, 12, 6), dark)
		eye.add_child(pupil)
		var glint := _mi(_sphere_mesh(0.016, 8, 4), shine)
		glint.position = Vector3(0.02, 0.022, -0.036)
		pupil.add_child(glint)
		var lid := _mi(_lid_mesh(), lid_mat)
		lid.scale = Vector3.ONE * EYE_R * 1.28
		eye.add_child(lid)
		_eyes.append({"node": eye, "pupil": pupil, "lid": lid, "side": side})

	# face bits: a tiny mouth with a tongue
	var mouth_mat := _shared_flat("mouth", Color(0.22, 0.05, 0.08), 0.5)
	var tongue_mat := _shared_flat("tongue", Color(0.95, 0.4, 0.5), 0.3)
	var mouth_y := 0.66
	var mouth_z := -_body_r(mouth_y) * DEPTH + 0.004
	_mouth = _mi(_sphere_mesh(0.05, 8, 4), mouth_mat)
	_mouth.position = Vector3(0, mouth_y, mouth_z)
	_shape.add_child(_mouth)
	_tongue = _mi(_sphere_mesh(0.04, 10, 5), tongue_mat)
	_tongue.position = Vector3(0, mouth_y - 0.035, mouth_z - 0.004)
	_tongue.visible = false
	_shape.add_child(_tongue)

	# ears
	for side: float in [-1.0, 1.0]:
		var ear := _mi(_sphere_mesh(0.07, 8, 5), limb)
		ear.position = Vector3(side * (_body_r(1.0) - 0.005), 1.0, 0.03)
		ear.scale = Vector3(0.55, 1.0, 0.85)
		_shape.add_child(ear)

	# tool belt with a buckle and a pouch
	var belt_mat := _shared_flat("belt", Color(0.33, 0.2, 0.12), 0.55)
	var brass := _shared_flat("brass", Color(0.9, 0.7, 0.25), 0.25)
	brass.metallic = 0.6
	var tan_mat := _shared_flat("pouch", Color(0.72, 0.52, 0.3), 0.7)
	_shape.add_child(_mi(_belt_mesh(), belt_mat))
	var buckle := Shapes.instance(Shapes.rounded_box(Vector3(0.1, 0.075, 0.03), 0.012, 1), brass,
			Vector3(0.0, 0.2, -_body_r(0.2) * DEPTH - 0.012))
	_shape.add_child(buckle)
	var pouch := Shapes.instance(Shapes.rounded_box(Vector3(0.1, 0.15, 0.085), 0.025, 1), tan_mat,
			Vector3(_body_r(0.18) * 0.86, 0.14, -0.12))
	pouch.rotation = Vector3(0.0, -0.6, -0.12)
	_shape.add_child(pouch)
	var screwdriver := Shapes.instance(Shapes.rounded_box(Vector3(0.028, 0.14, 0.028), 0.01, 1), _shared_flat("tool", Color(0.9, 0.2, 0.15), 0.4),
			Vector3(0.0, 0.1, 0.0))
	screwdriver.position = pouch.position + Vector3(-0.02, 0.1, -0.015)
	screwdriver.rotation = Vector3(0.1, -0.6, -0.12)
	_shape.add_child(screwdriver)

	# antenna with a blinking tip
	_ant = Node3D.new()
	_ant.position = Vector3(0.0, TOP - 0.015, 0.02)
	_shape.add_child(_ant)
	var stalk := _mi(_limb_mesh(0.011, 0.014, 0.17), _shared_flat("stalk", Color(0.6, 0.62, 0.68), 0.3))
	stalk.rotation.x = PI
	_ant.add_child(stalk)
	_tip_mat = StandardMaterial3D.new()
	_tip_mat.albedo_color = Color(1.0, 0.85, 0.25)
	_tip_mat.emission_enabled = true
	_tip_mat.emission = Color(1.0, 0.75, 0.15)
	var tip := _mi(_sphere_mesh(0.042, 12, 6), _tip_mat)
	tip.position.y = 0.195
	_ant.add_child(tip)

	# arms (hang off the torso, not its squash scale) and legs (off the pelvis)
	var upper := _limb_mesh(0.092, 0.104, ARM1)
	var fore := _limb_mesh(0.112, 0.084, ARM2)
	for side: float in [-1.0, 1.0]:
		_arms.append(_chain(_torso, upper, fore, limb, ARM1))
	var thigh := _limb_mesh(0.1, 0.126, LEG)
	var shin := _limb_mesh(0.092, 0.1, LEG)
	for side: float in [-1.0, 1.0]:
		_legs.append(_chain(_pelvis, thigh, shin, limb, LEG))
		var foot := Node3D.new()
		_rig.add_child(foot)
		var shoe_mesh := _mi(_sphere_mesh(0.5, 10, 6), shoe)
		shoe_mesh.scale = Vector3(0.26, 0.17, 0.4)
		shoe_mesh.position = Vector3(0, -ANKLE + 0.085, -0.055)
		foot.add_child(shoe_mesh)
		_feet.append(foot)
	if is_inside_tree():
		animate(0.016, {})


## Quick reach forward and back (picking up, placing, plugging, pressing a button).
func poke() -> void:
	_poke_t = 0.0


## Where the carried item's centre sits and how it is turned, in this node's space.
func carry_xf() -> Transform3D:
	return Transform3D(Basis(Vector3.BACK, _carry_roll), _carry_c)


## Number of triangles in this character (for budgeting).
func triangle_count() -> int:
	var n := 0
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is MeshInstance3D and node.visible and node.mesh:
			n += node.mesh.get_faces().size() / 3
	return n


# --- animation -------------------------------------------------------------------

func animate(dt: float, st: Dictionary) -> void:
	if _pelvis == null:
		return
	dt = clampf(dt, 0.0001, 0.05)
	_time += dt
	var speed: float = st.get("speed", 0.0)
	var pitch: float = st.get("pitch", 0.0)
	var is_air: bool = st.get("air", false)
	var vy: float = st.get("vy", 0.0)
	var held: Dictionary = st.get("held", {})
	var has_cable: bool = st.get("cable", false)
	var ride: float = st.get("ride", -1.0)
	var riding := ride >= 0.0
	var stumble: float = st.get("stumble", 0.0)
	var heat: float = st.get("exposure", 0.0)
	var suited: bool = st.get("suit", false)
	var is_npc: bool = st.get("npc", false)
	var carrying := not held.is_empty() and not riding

	# velocity relative to the body, turn rate
	var vel: Vector3 = st.get("vel", Vector3.ZERO)
	var local_v := Vector3(0, 0, -speed)
	if vel != Vector3.ZERO and is_inside_tree():
		local_v = global_basis.inverse() * vel
	var fwd := -local_v.z
	var side_v := local_v.x
	var yaw := global_rotation.y if is_inside_tree() else rotation.y
	var yaw_rate := wrapf(yaw - _prev_yaw, -PI, PI) / dt
	_prev_yaw = yaw
	var accel_f := (fwd - _prev_fwd) / dt
	var accel_s := (side_v - _prev_side) / dt
	_prev_fwd = fwd
	_prev_side = side_v
	_spd = lerpf(_spd, speed, 1.0 - exp(-9.0 * dt))
	var run := clampf((_spd - 3.6) / 2.6, 0.0, 1.0)
	var amp := clampf(_spd / 3.4, 0.0, 1.0) * (1.0 + 0.3 * run)
	if is_air:
		amp *= 0.4

	# events: picking up / putting down, take off, landing
	if carrying != _had_held:
		poke()
		_had_held = carrying
		if carrying:
			_held_info = held
			_carry_c = Vector3(0.0, 0.95, -0.55)
	if carrying:
		_held_info = held
	if is_air and not _was_air:
		_kick("crouch", -3.0 if vy > 1.0 else 0.0)
		_kick("ax", 1.2)
		Sound.jump(self, vy)
	elif _was_air and not is_air:
		var hit := clampf(-_vy_prev * 0.8, 1.5, 7.0)
		Sound.land(self, hit)
		_kick("crouch", hit)
		_kick("ax", -hit * 0.35)
	_was_air = is_air
	_vy_prev = vy
	_poke_t += dt

	# smoothed blend weights, so no pose ever snaps
	var mass: float = _held_info.get("mass", 1.0)
	var size: Vector3 = _held_info.get("size", Vector3.ONE * 0.3)
	var big := maxf(size.x, maxf(size.y * 0.8, size.z))
	_ease("carry", 1.0 if carrying else 0.0, 9.0, dt)
	_ease("bulk", clampf((big - 0.4) / 1.0, 0.0, 1.0), 6.0, dt)
	_ease("heavy", clampf(mass / 45.0, 0.0, 1.0), 6.0, dt)
	_ease("cable", 1.0 if (has_cable and not carrying and not riding) else 0.0, 8.0, dt)
	_ease("ride", 1.0 if riding else 0.0, 5.0, dt)
	_ease("air", 1.0 if is_air else 0.0, 14.0, dt)
	_ease("suit", 1.0 if suited else 0.0, 4.0, dt)
	_ease("trip", 1.0 if stumble > 0.0 else 0.0, 22.0, dt)
	_ease("heat", heat, 3.0, dt)
	_ease("npc", 1.0 if is_npc else 0.0, 20.0, dt)
	var reach := sin(clampf(_poke_t / 0.4, 0.0, 1.0) * PI)
	_w["reach"] = reach
	var w_carry: float = _w["carry"]
	var w_ride: float = _w["ride"]
	var w_air: float = _w["air"]
	var w_suit: float = _w["suit"]
	var w_trip: float = _w["trip"]
	var w_heat: float = _w["heat"]
	var bulk: float = _w["bulk"]
	var heavy: float = _w["heavy"] * w_carry
	var idle := 1.0 - clampf(_spd * 1.3, 0.0, 1.0)

	# gait: cadence slows with weight, the suit and tiredness
	var cadence := (0.5 * _spd + 0.2) * (1.0 - 0.3 * heavy) * (1.0 - 0.15 * w_suit) * (1.0 - 0.25 * w_heat)
	if _spd > 0.15 and not is_air:
		_phase += TAU * cadence * dt
	var ph := _phase
	Sound.foot(self, ph, _spd, is_air, w_suit, heavy)
	var wad := sin(ph)
	var effort := ride if riding else 0.0
	_pedal += TAU * (0.9 + 1.7 * effort) * dt * w_ride

	_idle_logic(dt, idle, is_npc, st.get("look_at", null), pitch, w_ride)

	# springs: lean, roll, bounce, antenna
	var lean_goal := clampf(fwd * 0.03, -0.1, 0.2) + 0.1 * run + clampf(accel_f * 0.004, -0.12, 0.12)
	var lean := _sp("lean", lean_goal, dt, 90.0, 12.0)
	var roll_goal := clampf(yaw_rate * 0.035, -0.22, 0.22) * clampf(_spd / 3.0, 0.0, 1.0) - clampf(side_v * 0.03 + accel_s * 0.002, -0.15, 0.15)
	var roll := _sp("roll", roll_goal, dt, 90.0, 11.0)
	var crouch := _sp("crouch", 0.0, dt, 200.0, 17.0)
	var trip := _sp("trip", w_trip, dt, 70.0, 7.0)
	var ax := _sp("ax", 0.0, dt, 120.0, 5.0)
	var az := _sp("az", 0.0, dt, 120.0, 5.0)
	_kick("ax", -clampf(accel_f, -40.0, 40.0) * dt * 0.6)
	_kick("az", (clampf(accel_s, -40.0, 40.0) * 0.6 + clampf(yaw_rate, -6.0, 6.0) * 0.3) * dt)
	_shift = lerpf(_shift, _shift_goal, 1.0 - exp(-2.5 * dt))
	var twist := _twist(dt)

	# --- pelvis: bob, waddle, crouch
	var bob := absf(cos(ph)) * 0.034 * amp * (1.0 - 0.5 * heavy) * (1.0 - 0.7 * w_suit)
	var breathe := sin(_time * 2.1)
	var pel_y := PELVIS + bob + breathe * 0.003
	pel_y -= crouch * 0.15 + 0.045 * heavy + 0.04 * w_heat + 0.09 * trip
	var sway_x := wad * 0.028 * amp * (1.0 + 0.8 * heavy) + _shift * 0.035 * idle
	var wob := sin(_time * 3.1) * 0.06 * w_heat * w_heat
	var pel_roll := wad * 0.1 * amp * (1.0 + 0.9 * heavy) * (1.0 - 0.6 * w_suit) - _shift * 0.05 * idle + wob
	var pel_pos := Vector3(sway_x, pel_y, 0.0)
	var pel_yaw := wad * 0.09 * amp * (1.0 - 0.5 * w_suit)

	# --- riding overrides the lower body
	var ride_pos := Vector3.ZERO
	if w_ride > 0.001:
		var pedal_bob := sin(_pedal * 2.0) * 0.012
		pel_pos = pel_pos.lerp(Vector3(sin(_pedal) * 0.02, 0.39 + pedal_bob + 0.03 * effort, 0.0), w_ride)
		pel_roll = lerpf(pel_roll, sin(_pedal) * (0.05 + 0.05 * effort), w_ride)
		pel_yaw = lerpf(pel_yaw, 0.0, w_ride)
		ride_pos = Vector3(0.0, 0.0, 0.14)
	_pelvis.position = pel_pos
	_pelvis.rotation = Vector3(0.0, pel_yaw, pel_roll)
	var ryaw: float = st.get("ride_yaw", 0.0)
	_rig.rotation.y = lerp_angle(_rig.rotation.y, ryaw if riding else 0.0, 1.0 - exp(-8.0 * dt))
	_rig.position = Basis(WORLD_UP, _rig.rotation.y) * ride_pos * w_ride

	# --- torso: lean, look pitch, twist, squash and stretch
	var pitch_eff := clampf(pitch, -1.4, 1.4)
	var tx := -lean + pitch_eff * 0.2 + 0.2 * heavy * (0.4 + 0.6 * bulk) - 0.2 * w_heat - 0.14 * reach * (1.0 - w_carry) - 0.16 * crouch
	tx += -(0.5 + 0.2 * effort) * w_ride - 0.75 * trip
	tx += sin(_time * 2.1) * 0.01
	var tz := roll - pel_roll * 0.55 + az * 0.4
	_torso.rotation = Vector3(tx, twist - pel_yaw * 1.3, tz)
	var sy := 1.0 + breathe * 0.012 + cos(ph * 2.0) * 0.032 * amp - crouch * 0.38 + 0.1 * w_air * (1.0 if vy > 0.0 else 0.5)
	sy -= 0.03 * heavy
	sy += 0.02 * w_ride * sin(_pedal * 2.0)
	var sxz := 1.0 / sqrt(sy)
	_shape.scale = Vector3(_body_scale.x * sxz, _body_scale.y * sy, _body_scale.z * sxz)

	# antenna: lags behind the body
	_ant.rotation = Vector3(ax * 0.9 - tx * 0.35, 0.0, az * 0.9 + roll * 0.5)
	_tip_mat.emission_energy_multiplier = 0.7 + 0.8 * (0.5 + 0.5 * sin(_time * 3.0 + _rng.seed * 0.001))

	_pose_legs(amp, run, ph, pel_pos, is_npc)
	_pose_arms(amp, run, ph)
	_pose_face(dt, pitch_eff, run, tx, effort, carrying, heavy)

	# the carried item follows the body
	if carrying:
		var cy := lerpf(1.0, 0.95, bulk) - 0.14 * heavy
		cy = maxf(cy, size.y * 0.5 + 0.1)
		var near_z := lerpf(0.42, 0.29, bulk)
		var cz := near_z + size.z * 0.5 - 0.1 * reach
		var goal := Vector3(sway_x * 0.8, cy + (pel_y - PELVIS) * 0.9 - tx * 0.12, -cz)
		_carry_c = _carry_c.lerp(goal, 1.0 - exp(-16.0 * dt))
		_carry_roll = pel_roll * 0.6
	else:
		_carry_c = _carry_c.lerp(Vector3(0.0, 0.95, -0.55), 1.0 - exp(-8.0 * dt))


func _idle_logic(dt: float, idle: float, is_npc: bool, look_at: Variant, pitch: float, w_ride: float) -> void:
	# weight shifting
	_shift_in -= dt
	if _shift_in <= 0.0:
		_shift_in = 2.5 + _rng.randf() * 4.0
		_shift_goal = _rng.randf_range(-1.0, 1.0) if absf(_shift_goal) < 0.5 or _rng.randf() < 0.3 else 0.0
	# blinking (sometimes twice)
	_blink_in -= dt
	if _blink_in <= 0.0 and _blink <= 0.0:
		_blink = 1.0
		_blink_in = 1.8 + _rng.randf() * 3.5 if _rng.randf() > 0.2 else 0.25
	_blink = maxf(_blink - dt / 0.16, 0.0)
	# eyes drift around, with the odd glance over the shoulder
	_look_in -= dt
	var moving := 1.0 - idle
	if _look_in <= 0.0:
		_look_in = 0.9 + _rng.randf() * 2.4
		_look_goal = Vector2(_rng.randf_range(-0.6, 0.6), _rng.randf_range(-0.3, 0.3)) * (1.0 - 0.8 * moving)
		if idle > 0.8 and _glance <= 0.0 and _rng.randf() < 0.1 and w_ride < 0.5:
			_glance = 1.8
			_glance_dir = 1.0 if _rng.randf() < 0.5 else -1.0
			_look_goal = Vector2(-_glance_dir * 0.9, 0.0)
	_glance = maxf(_glance - dt, 0.0)
	var attend: Variant = null
	if look_at != null:
		var rel: Vector3 = to_local(look_at)
		if rel.length() < 16.0:
			attend = rel
	if attend != null:
		var rel_v: Vector3 = attend
		var ang := atan2(-rel_v.x, -rel_v.z)
		var elev := atan2(rel_v.y - 1.3, Vector2(rel_v.x, rel_v.z).length())
		_look_goal = Vector2(-clampf(ang - _torso.rotation.y, -1.0, 1.0) * 0.9, clampf(elev, -0.4, 0.4))
		_s["attend"] = [ang, 0.0]
	else:
		_s.erase("attend")
	_look = _look.lerp(_look_goal, 1.0 - exp(-9.0 * dt))
	# NPC fidgets
	if is_npc:
		_wave_cool -= dt
		if attend != null:
			var dist := Vector2(attend.x, attend.z).length()
			if dist < 9.0 and _wave_cool <= 0.0 and _wave_t > 3.0:
				_wave_t = 0.0
				_wave_cool = 25.0
		_scratch_in -= dt
		if _scratch_in <= 0.0:
			_scratch_in = 6.0 + _rng.randf() * 10.0
			_scratch_t = 0.0
	_wave_t += dt
	_scratch_t += dt


## How far the torso is turned: towards a glance or towards whoever the neighbour is watching.
func _twist(dt: float) -> float:
	var goal := 0.0
	if _glance > 0.2:
		goal = _glance_dir * 0.8
	if _s.has("attend"):
		goal = clampf(_s["attend"][0], -1.1, 1.1) * 0.65
	return _sp("twist", goal, dt, 45.0, 10.0)


func _pose_legs(amp: float, run: float, ph: float, pel_pos: Vector3, is_npc: bool) -> void:
	var w_ride: float = _w["ride"]
	var w_air: float = _w["air"]
	var w_trip: float = _w["trip"]
	var w_suit: float = _w["suit"]
	var w_heat: float = _w["heat"]
	var heavy: float = _w["heavy"] * float(_w["carry"])
	var inv := _pelvis.transform.affine_inverse()
	var tap := 0.0
	if is_npc and _npc_style == 3:
		tap = maxf(0.0, sin(_time * 7.0)) * 0.05 * clampf(sin(_time * 0.5) * 3.0, 0.0, 1.0)
	for i in 2:
		var side: float = -1.0 if i == 0 else 1.0
		var p := ph + (0.0 if i == 0 else PI)
		var stride := (0.15 + 0.07 * run) * amp * (1.0 - 0.35 * heavy) * (1.0 - 0.5 * w_suit)
		var lift := (0.075 + 0.03 * run) * amp * (1.0 - 0.4 * heavy - 0.3 * w_suit) * (1.0 - 0.4 * w_heat)
		var foot := Vector3(side * (HIP_X + 0.012 + 0.03 * heavy + 0.02 * w_suit), 0.0, -sin(p) * stride)
		foot.y = maxf(0.0, cos(p)) * lift
		foot.x += pel_pos.x * 0.15
		if i == 1:
			foot.y += tap
		if i == 0 and _shift > 0.4:   # relaxed foot when shifting weight
			foot.z -= 0.03 * (_shift - 0.4)
		# jumping: legs tuck up, one forward
		if w_air > 0.001:
			var tuck := Vector3(side * 0.15, 0.17 + 0.05 * side, -0.05 - 0.09 * side)
			foot = foot.lerp(tuck, w_air)
		# tripping: scrabbling feet
		if w_trip > 0.001:
			var sc := Vector3(side * 0.17, maxf(0.0, cos(_time * 24.0 + i * PI)) * 0.14, -sin(_time * 24.0 + i * PI) * 0.22 - 0.08)
			foot = foot.lerp(sc, w_trip)
		# riding: feet circle on the pedals
		if w_ride > 0.001:
			var a := _pedal + (0.0 if i == 0 else PI)
			var pe := Vector3(side * 0.13, 0.12 + sin(a) * 0.09, -0.26 - cos(a) * 0.12)
			foot = foot.lerp(pe, w_ride)
		var ank := foot + Vector3(0, ANKLE, 0)
		_feet[i].position = foot
		_feet[i].rotation = Vector3(-0.15 * clampf(foot.y * 8.0, 0.0, 1.0) + 0.0, 0.0, 0.0)
		var root := Vector3(side * HIP_X, 0.0, 0.0)
		_solve(_legs[i], root, inv * ank, LEG, LEG, Vector3(side * 0.2, 0.05, -1.0))


func _pose_arms(amp: float, run: float, ph: float) -> void:
	var w_carry: float = _w["carry"]
	var w_cable: float = _w["cable"]
	var w_ride: float = _w["ride"]
	var w_air: float = _w["air"]
	var w_suit: float = _w["suit"]
	var w_trip: float = _w["trip"]
	var w_heat: float = _w["heat"]
	var w_npc: float = _w["npc"]
	var reach: float = _w["reach"]
	var bulk: float = _w["bulk"]
	var heavy: float = _w["heavy"] * w_carry
	var sy: float = _shape.scale.y / _body_scale.y
	var sxz: float = _shape.scale.x / _body_scale.x
	var xf := _pelvis.transform * _torso.transform
	var to_torso := xf.affine_inverse()
	var wave_k := 0.0
	if _wave_t < 2.6:
		wave_k = sin(clampf(_wave_t / 0.3, 0.0, 1.0) * PI * 0.5) * clampf((2.6 - _wave_t) / 0.4, 0.0, 1.0)
	var scratch_k := 0.0
	if _scratch_t < 2.0:
		scratch_k = sin(clampf(_scratch_t / 2.0, 0.0, 1.0) * PI)
	var size: Vector3 = _held_info.get("size", Vector3.ONE * 0.3)
	for i in 2:
		var side: float = -1.0 if i == 0 else 1.0
		var root := Vector3(SHOULDER.x * sxz * side, SHOULDER.y * sy, 0.0)
		var p := ph + (PI if i == 0 else 0.0)
		var swing := sin(p) * 0.3 * amp * (1.0 - 0.55 * w_suit)
		var off := Vector3(side * (0.07 + 0.03 * amp + 0.13 * w_suit), -0.47 + 0.1 * run + 0.03 * w_heat, -swing + 0.01)
		off.y += maxf(0.0, sin(p)) * 0.07 * amp
		off.z += sin(_time * 2.1) * 0.01
		var pole := Vector3(side * 0.5, -0.2, 0.8)
		# neighbours: crossed arms, hands on hips, impatient, scratching, waving
		if w_npc > 0.001:
			var npc_off := off
			var npc_pole := pole
			match _npc_style:
				0:   # arms crossed
					npc_off = Vector3(-side * 0.27, -0.32, -0.27 - 0.03 * i)
					npc_pole = Vector3(side * 0.2, -1.0, 0.0)
				1:   # hands on hips
					npc_off = Vector3(side * 0.09, -0.37, 0.0)
					npc_pole = Vector3(side * 1.0, 0.1, 0.4)
				2:   # hands clasped behind the back
					npc_off = Vector3(-side * 0.04, -0.4, 0.2)
					npc_pole = Vector3(side * 1.0, 0.0, 0.5)
				3:   # one hand on the hip, the other relaxed
					if i == 1:
						npc_off = Vector3(0.09, -0.37, 0.0)
						npc_pole = Vector3(1.0, 0.1, 0.4)
			if i == 1 and scratch_k > 0.0:
				npc_off = npc_off.lerp(Vector3(-0.12 + sin(_time * 12.0) * 0.02, 0.42, -0.1), scratch_k)
				npc_pole = npc_pole.lerp(Vector3(1.0, 0.0, 0.0), scratch_k)
			if i == 1 and wave_k > 0.0:
				npc_off = npc_off.lerp(Vector3(0.2 + sin(_time * 10.0) * 0.1, 0.4, -0.06), wave_k)
				npc_pole = npc_pole.lerp(Vector3(1.0, 0.0, 0.2), wave_k)
			off = off.lerp(npc_off, w_npc)
			pole = pole.lerp(npc_pole, w_npc)
		if w_air > 0.001:
			off = off.lerp(Vector3(side * 0.3, 0.14 + sin(_time * 14.0 + i) * 0.03, -0.12), w_air)
			pole = pole.lerp(Vector3(side * 1.0, -0.3, 0.5), w_air)
		if reach > 0.0 and w_carry < 0.5:
			off = off.lerp(Vector3(side * 0.07, -0.12, -0.5), reach * 0.9)
			pole = pole.lerp(Vector3(side * 0.8, -0.8, 0.0), reach)
		var target := root + off
		# holding a cable end: the right arm stretches out towards it
		if i == 1 and w_cable > 0.001:
			target = target.lerp(root + Vector3(0.12, -0.14, -0.46), w_cable)
			pole = pole.lerp(Vector3(1.0, -0.7, 0.2), w_cable)
		# carrying: both hands on the item, wherever it really is
		if w_carry > 0.001:
			var c := _carry_c
			var hx := minf(size.x * 0.5 + 0.03, 0.4)
			var hz := c.z
			if bulk > 0.2:   # hugging something deep: hands on its near end
				hz = c.z + size.z * 0.5 - minf(size.z * 0.5, 0.2)
			var hy := c.y + clampf(size.y * 0.15, 0.0, 0.18) * bulk
			var hand_world := Vector3(c.x + side * hx, hy, hz)
			var tt: Vector3 = to_torso * hand_world
			target = target.lerp(tt, w_carry)
			pole = pole.lerp(Vector3(side * 1.0, -0.6, 0.35), w_carry)
		# pedalling: hands on the handlebar
		if w_ride > 0.001:
			var bar := Vector3(side * 0.2, 0.36, -0.49)
			target = target.lerp(to_torso * bar, w_ride)
			pole = pole.lerp(Vector3(side * 1.0, -0.5, 0.3), w_ride)
		# tripping: arms flail
		if w_trip > 0.001:
			var fl := root + Vector3(side * 0.33 + sin(_time * 21.0 + i * 2.0) * 0.1, 0.3 + sin(_time * 17.0 + i) * 0.14, -0.15 + cos(_time * 19.0 + i) * 0.2)
			target = target.lerp(fl, w_trip)
			pole = pole.lerp(Vector3(side, -0.2, 0.3), w_trip)
		_solve(_arms[i], root, target, ARM1, ARM2, pole)


func _pose_face(dt: float, pitch: float, run: float, tx: float, effort: float, carrying: bool, heavy: float) -> void:
	var w_air: float = _w["air"]
	var w_heat: float = _w["heat"]
	var trip: float = _w["trip"]
	# eyes lead the head: they look up and down more than the body does, and make up for leaning
	var look := _look + Vector2(0.0, clampf(pitch * 0.55 - tx * 0.4, -0.7, 0.7))
	var droop := w_heat
	var base_open := 0.16 + 0.35 * run + 0.25 * w_air + 0.5 * trip + 0.15 * float(carrying) * heavy - 0.95 * droop * droop - 0.3 * droop
	base_open -= 0.25 * effort
	var a := lerpf(base_open, -1.5, _blink)
	if droop > 0.7:   # nearly out: slow, heavy blinks
		a = lerpf(a, -1.5, 0.5 + 0.5 * sin(_time * 1.6))
	for e in _eyes:
		var side: float = e["side"]
		var d := Vector3(look.x * 0.75 + sin(_time * 0.9 + side) * 0.03 * w_heat * 6.0, look.y * 0.75, -1.0).normalized()
		var pupil: MeshInstance3D = e["pupil"]
		pupil.position = d * (EYE_R * 0.74)
		var ps := 1.0 - 0.3 * trip + 0.15 * w_heat
		pupil.scale = Vector3.ONE * ps
		var lid: MeshInstance3D = e["lid"]
		var lid_a := a + clampf(look.y * 0.3, -0.2, 0.3)
		lid.basis = Basis(Vector3.BACK, -side * 0.14 - side * 0.12 * droop) * Basis(Vector3.RIGHT, lid_a) * Basis.from_scale(Vector3.ONE * EYE_R * 1.28)
	# mouth: a little line that opens when puffing or surprised
	var open := clampf(0.25 * run + 0.5 * effort + 0.5 * trip + 0.3 * w_air + 0.3 * heavy + 0.8 * clampf((w_heat - 0.4) * 2.0, 0.0, 1.0), 0.0, 1.0)
	open = _smooth_to("mouth", open, dt, 10.0)
	_mouth.scale = Vector3(1.0 - 0.25 * open, 0.18 + 0.9 * open, 0.5)
	var tongue := clampf((w_heat - 0.55) * 2.2, 0.0, 1.0)
	_tongue.visible = tongue > 0.02
	_tongue.scale = Vector3(1.0, 0.6 + 1.2 * tongue, 0.7)
	_tongue.position.y = _mouth.position.y - 0.03 - 0.02 * tongue


# --- rig helpers -----------------------------------------------------------------

func _chain(parent: Node3D, upper: Mesh, lower: Mesh, mat: Material, len1: float) -> Dictionary:
	var j1 := Node3D.new()
	parent.add_child(j1)
	j1.add_child(_mi(upper, mat))
	var j2 := Node3D.new()
	j2.position.y = -len1
	j1.add_child(j2)
	j2.add_child(_mi(lower, mat))
	return {"j1": j1, "j2": j2}


## Two-bone solve: puts the chain's root at `root` and its end at (or as near as it gets to) `target`.
func _solve(chain: Dictionary, root: Vector3, target: Vector3, l1: float, l2: float, pole: Vector3) -> void:
	var to := target - root
	var dist_full := to.length()
	var u := to / dist_full if dist_full > 0.0001 else Vector3.DOWN
	var d := clampf(dist_full, absf(l1 - l2) + 0.02, l1 + l2 - 0.004)
	var along := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(l1 * l1 - along * along, 0.0))
	var pv := pole - u * pole.dot(u)
	if pv.length() < 0.001:
		pv = Vector3.BACK - u * Vector3.BACK.dot(u)
	pv = pv.normalized()
	var elbow := root + u * along + pv * h
	var hand := root + u * d
	var j1: Node3D = chain["j1"]
	var j2: Node3D = chain["j2"]
	var b1 := _aim(elbow - root)
	j1.transform = Transform3D(b1, root)
	j2.basis = b1.inverse() * _aim(hand - elbow)


## A basis whose -Y axis points along `dir`.
func _aim(dir: Vector3) -> Basis:
	var y := -dir.normalized()
	var x := y.cross(Vector3.BACK)
	if x.length() < 0.2:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	return Basis(x, y, x.cross(y))


func _ease(key: String, target: float, rate: float, dt: float) -> void:
	_w[key] = lerpf(_w[key], target, 1.0 - exp(-rate * dt))


func _smooth_to(key: String, target: float, dt: float, rate := 20.0) -> float:
	var cur: float = _s.get(key, target)
	cur = lerpf(cur, target, 1.0 - exp(-rate * dt))
	_s[key] = cur
	return cur


## A damped spring chasing `target`; state lives in `_s`.
func _sp(key: String, target: float, dt: float, k: float, damp: float) -> float:
	if not _s.has(key):
		_s[key] = [target, 0.0]
	var st: Array = _s[key]
	var steps := ceili(dt / 0.01)
	var h := dt / steps
	for n in steps:
		st[1] += (k * (target - st[0]) - damp * st[1]) * h
		st[0] += st[1] * h
	return st[0]


func _kick(key: String, dv: float) -> void:
	if not _s.has(key):
		_s[key] = [0.0, 0.0]
	_s[key][1] += dv


# --- meshes and materials ----------------------------------------------------------

func _mi(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return m


static func _flat(color: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m


static func _shared_flat(key: String, color: Color, rough: float) -> StandardMaterial3D:
	var k := "mat " + key
	if not _cache.has(k):
		_cache[k] = _flat(color, rough)
	return _cache[k]


static func _skin_mat(color: Color) -> StandardMaterial3D:
	var k := "skin " + color.to_html()
	if not _cache.has(k):
		var m := StandardMaterial3D.new()
		m.albedo_color = color.lerp(Color.WHITE, 0.08)
		m.vertex_color_use_as_albedo = true
		m.roughness = 0.42
		m.clearcoat_enabled = true
		m.clearcoat = 0.7
		m.clearcoat_roughness = 0.18
		m.rim_enabled = true
		m.rim = 0.45
		m.rim_tint = 0.6
		_cache[k] = m
	return _cache[k]


static func _limb_mat(color: Color) -> StandardMaterial3D:
	var k := "limb " + color.to_html()
	if not _cache.has(k):
		var m := StandardMaterial3D.new()
		m.albedo_color = color.darkened(0.14)
		m.roughness = 0.42
		m.clearcoat_enabled = true
		m.clearcoat = 0.5
		m.clearcoat_roughness = 0.2
		m.rim_enabled = true
		m.rim = 0.35
		m.rim_tint = 0.5
		_cache[k] = m
	return _cache[k]


static func _sphere_mesh(radius: float, radial: int, rings: int) -> SphereMesh:
	var k := "sph %.3f %d %d" % [radius, radial, rings]
	if not _cache.has(k):
		var s := SphereMesh.new()
		s.radius = radius
		s.height = radius * 2.0
		s.radial_segments = radial
		s.rings = rings
		_cache[k] = s
	return _cache[k]


## The body outline as [radius, y] points from the bottom pole to the top pole: wide at the hips,
## gently pinched towards the top.
static func _body_pts() -> Array:
	if _cache.has("bodypts"):
		return _cache["bodypts"]
	var pts: Array = []
	var n := 22
	for i in n + 1:
		var phi := float(i) / n * PI
		var s := (1.0 - cos(phi)) * 0.5
		var y := -0.13 + (TOP + 0.13) * pow(s, 1.3)
		var r := 0.375 * sin(phi) * (1.1 - 0.22 * s)
		pts.append(Vector2(r, y))
	_cache["bodypts"] = pts
	return pts


static func _body_r(y: float) -> float:
	var pts := _body_pts()
	for i in range(1, pts.size()):
		var b: Vector2 = pts[i]
		if b.y >= y:
			var a: Vector2 = pts[i - 1]
			return lerpf(a.x, b.x, inverse_lerp(a.y, b.y, y))
	return 0.0


static func _body_mesh() -> ArrayMesh:
	if not _cache.has("body"):
		_cache["body"] = _lathe(_body_pts(), 24, DEPTH, Callable(_shade_body))
	return _cache["body"]


## Vertex colours multiply the body colour: a lighter belly, darker back and underside.
static func _shade_body(y: float, front: float, _r: float) -> Color:
	var belly := smoothstep(0.1, 0.75, front) * smoothstep(-0.08, 0.12, y) * (1.0 - smoothstep(0.45, 0.8, y))
	var c := (0.8 + 0.2 * belly) * (0.82 + 0.18 * smoothstep(-0.12, 0.3, y))
	c *= 0.93 + 0.07 * smoothstep(0.7, 1.2, y)
	return Color(c, c * (0.98 + 0.02 * belly), c)


static func _belt_mesh() -> ArrayMesh:
	if not _cache.has("belt"):
		var pts: Array = []
		var y0 := 0.12
		var y1 := 0.27
		for i in 6:
			var t := float(i) / 5.0
			var y := lerpf(y0, y1, t)
			var bump := 0.012 * sqrt(sin(t * PI))
			pts.append(Vector2(_body_r(y) + bump, y))
		_cache["belt"] = _lathe(pts, 24, DEPTH, Callable())
	return _cache["belt"]


## Upper half of a unit sphere (pole up) used as an eyelid.
static func _lid_mesh() -> ArrayMesh:
	if not _cache.has("lid"):
		var pts: Array = []
		for i in 6:
			var b := float(i) / 5.0 * PI * 0.5
			pts.append(Vector2(cos(b), sin(b)))
		_cache["lid"] = _lathe(pts, 14, 1.0, Callable())
	return _cache["lid"]


## A limb hanging down from its joint (y = 0): thick end cap at the joint, `r_end` at the far end.
static func _limb_mesh(r_end: float, r_start: float, length: float) -> ArrayMesh:
	var k := "limb %.3f %.3f %.3f" % [r_end, r_start, length]
	if _cache.has(k):
		return _cache[k]
	var pts: Array = []
	for i in 5:
		var a := float(i) / 4.0 * PI * 0.5
		pts.append(Vector2(r_end * sin(a), -length - r_end * cos(a)))
	for i in 1:
		pts.append(Vector2(lerpf(r_end, r_start, 0.5) * 1.02, -length * 0.5))
	for i in 5:
		var b := float(i) / 4.0 * PI * 0.5
		pts.append(Vector2(r_start * cos(b), r_start * sin(b)))
	var mesh := _lathe(pts, 8, 1.0, Callable())
	_cache[k] = mesh
	return mesh


## Revolves `pts` (Vector2(radius, y), ascending y) around Y with smooth normals. The back is
## flattened by `depth`. `shade(y, front, r)` may colour vertices (front = 1 at the very front).
static func _lathe(pts: Array, segs: int, depth: float, shade: Callable) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array = []
	for i in pts.size():
		var p: Vector2 = pts[i]
		var a: Vector2 = pts[maxi(i - 1, 0)]
		var b: Vector2 = pts[mini(i + 1, pts.size() - 1)]
		var t := b - a
		var nr := t.y
		var ny := -t.x
		var ring: Array = []
		for j in segs:
			var th := float(j) / segs * TAU
			var dx := sin(th)
			var dz := -cos(th)
			var n := Vector3(nr * dx, ny, nr * dz / depth).normalized()
			var col := Color.WHITE
			if shade.is_valid():
				col = shade.call(p.y, -dz, p.x)
			ring.append([Vector3(p.x * dx, p.y, p.x * dz * depth), n, col])
		rings.append(ring)
	for i in rings.size() - 1:
		for j in segs:
			var j2 := (j + 1) % segs
			var q00: Array = rings[i][j]
			var q01: Array = rings[i][j2]
			var q10: Array = rings[i + 1][j]
			var q11: Array = rings[i + 1][j2]
			_tri(st, q00, q10, q11)
			_tri(st, q00, q11, q01)
	return st.commit()


static func _tri(st: SurfaceTool, p0: Array, p1: Array, p2: Array) -> void:
	var cross: Vector3 = (p1[0] - p0[0]).cross(p2[0] - p0[0])
	if cross.length_squared() < 1e-12:
		return
	var corners := [p0, p1, p2]
	if cross.dot(p0[1] + p1[1] + p2[1]) > 0.0:   # Godot's front faces are clockwise
		corners = [p0, p2, p1]
	for c: Array in corners:
		st.set_color(c[2])
		st.set_normal(c[1])
		st.add_vertex(c[0])
