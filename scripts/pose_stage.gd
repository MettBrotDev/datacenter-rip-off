extends Node3D
## Test only (`--pose=N`): a row of dummy characters on the driveway, each in one situation, so a
## single screenshot judges the whole animation set. `--pose_t=SECONDS` freezes them at that moment.
## Stand at about --pos=0,0,13.5 --yaw=0 to look at them.

const Blob = preload("res://scripts/blob.gd")

var _dummies: Array[Dictionary] = []
var _t := 0.0
var _until := 0.0
var _yaw := PI
var _live := true


func setup(set_id: int, freeze_at: float, yaw_deg: float, pick := "") -> void:
	_until = freeze_at
	_yaw = deg_to_rad(yaw_deg)
	position = Vector3(0, 0, 8)
	var gpu := {"size": Vector3(0.3, 0.05, 0.13), "mass": 1.0}
	var server := {"size": Vector3(0.48, 0.12, 0.6), "mass": 6.0}
	var rack := {"size": Vector3(0.6, 1.8, 0.75), "mass": 25.0}
	var sofa := {"size": Vector3(2.0, 0.8, 0.9), "mass": 40.0}
	var diesel := {"size": Vector3(0.8, 0.9, 1.4), "mass": 90.0}
	var sets: Dictionary = {
		1: [["idle", {}], ["walk", {"speed": 4.0}], ["sprint", {"speed": 6.5}], ["jump", {"jump": 0.0}],
			["landing", {"jump": 0.55}], ["trip", {"trip": true, "speed": 3.0}]],
		2: [["gpu", {"held": gpu, "speed": 3.5}], ["server", {"held": server, "speed": 3.5}],
			["rack", {"held": rack, "speed": 3.0}], ["sofa", {"held": sofa}], ["diesel", {"held": diesel, "speed": 2.5}],
			["cable", {"cable": true}]],
		3: [["pedal", {"ride": 0.7}], ["warm", {"exposure": 0.5, "speed": 3.0}], ["overheated", {"exposure": 1.0, "speed": 2.0}],
			["suit", {"suit": true, "speed": 3.0}], ["look up", {"pitch": 1.1}], ["look down", {"pitch": -1.1}]],
		4: [["npc 0", {"npc": 4}], ["npc 1", {"npc": 5}], ["npc 2", {"npc": 6}], ["npc 3", {"npc": 7}],
			["reach", {"poke": true}], ["idle", {}]],
	}
	var colors: Array[Color] = [Color(0.15, 0.85, 0.25), Color(0.1, 0.6, 1.0), Color(1.0, 0.2, 0.5),
			Color(1.0, 0.85, 0.1), Color(1.0, 0.5, 0.1), Color(0.65, 0.35, 1.0)]
	var row: Array = sets.get(set_id, sets[1])
	if pick != "":   # --pose_pick=0,2: only these entries of the set
		var chosen: Array = []
		for k in pick.split(","):
			chosen.append(row[int(k)])
		row = chosen
	var item_mat := StandardMaterial3D.new()
	item_mat.albedo_color = Color(0.45, 0.5, 0.6)
	item_mat.roughness = 0.6
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = Color(0.85, 0.2, 0.2)
	for i in row.size():
		var spec: Dictionary = row[i][1]
		var holder := Node3D.new()
		holder.position = Vector3((i - (row.size() - 1) * 0.5) * (2.4 if pick != "" else 1.75), 0, 0)
		holder.rotation.y = _yaw
		add_child(holder)
		var blob: Node3D = Blob.new()
		holder.add_child(blob)
		blob.setup(colors[i % colors.size()], spec.get("npc", 0))
		var d := {"holder": holder, "blob": blob, "spec": spec, "item": null}
		if spec.has("held"):
			var box := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = spec["held"]["size"]
			box.mesh = bm
			box.material_override = item_mat
			holder.add_child(box)
			d["item"] = box
		if spec.has("ride"):
			holder.position.y = 0.6   # the rider's origin sits on the bike, like in the game
			for part: Array in [[Vector3(0.5, 0.06, 1.1), Vector3(0, -0.47, 0)], [Vector3(0.08, 0.7, 0.08), Vector3(0, -0.1, 0.25)],
					[Vector3(0.26, 0.06, 0.3), Vector3(0, 0.28, 0.25)], [Vector3(0.08, 0.9, 0.08), Vector3(0, 0.0, -0.35)],
					[Vector3(0.5, 0.05, 0.05), Vector3(0, 0.45, -0.35)], [Vector3(0.06, 0.5, 0.5), Vector3(0, -0.2, -0.1)]]:
				var m := MeshInstance3D.new()
				var pm := BoxMesh.new()
				pm.size = part[0]
				m.mesh = pm
				m.material_override = bar_mat
				m.position = part[1] + Vector3(0, -0.1, 0)
				holder.add_child(m)
		var tag := Label3D.new()
		tag.text = row[i][0]
		tag.position = Vector3(0, 2.2, 0)
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.font_size = 40
		tag.pixel_size = 0.0025
		holder.add_child(tag)
		_dummies.append(d)
	print("POSE triangles per character: ", _dummies[0]["blob"].triangle_count())
	if _until > 0.0:
		while _t < _until:
			_step(1.0 / 60.0)
		_live = false


func _process(dt: float) -> void:
	if _live:
		_step(dt)


func _step(dt: float) -> void:
	_t += dt
	var cam := get_viewport().get_camera_3d()
	for d: Dictionary in _dummies:
		var spec: Dictionary = d["spec"]
		var holder: Node3D = d["holder"]
		var blob: Node3D = d["blob"]
		var fwd := -holder.global_basis.z
		var speed: float = spec.get("speed", 0.0)
		var st := {"speed": speed, "vel": fwd * speed, "pitch": spec.get("pitch", 0.0),
				"exposure": spec.get("exposure", 0.0), "suit": spec.get("suit", false), "cable": spec.get("cable", false),
				"npc": spec.has("npc")}
		if spec.has("held"):
			st["held"] = spec["held"]
		if spec.has("npc") and cam:
			st["look_at"] = cam.global_position if spec["npc"] != 6 else null
		if spec.has("ride"):
			st["ride"] = spec["ride"]
			st["ride_yaw"] = 0.0
			st["speed"] = 0.0
		if spec.has("trip"):
			st["stumble"] = 1.0 if fmod(_t, 2.2) < 0.45 else 0.0
		if spec.has("jump"):
			var u := fmod(_t + float(spec["jump"]), 1.4)
			if u < 0.8:
				st["air"] = true
				st["vy"] = 4.6 - 13.0 * u
				holder.position.y = maxf(0.0, 4.6 * u - 6.5 * u * u)
			else:
				holder.position.y = 0.0
		if spec.has("poke") and fmod(_t, 2.0) < dt:
			blob.poke()
		blob.animate(dt, st)
		var item: Node3D = d["item"]
		if item:
			item.transform = Transform3D(blob.carry_xf().basis, blob.carry_xf().origin)
