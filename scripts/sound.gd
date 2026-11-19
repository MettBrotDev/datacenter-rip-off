extends Node
## Autoload "Sound": all of the game's audio. Every sound is synthesised from code (synth.gd = DSP toolbox,
## sound_bank.gd = the recipes), built on a worker thread at startup and played through pooled players.
##
## Everything here is presentation. The gameplay scripts only call the one-line hooks below, from places that
## already run on EVERY peer (the world's `_r_*` handlers, replicated item state, the blob's walk cycle), so
## host and clients hear the same things. Headless runs (`DisplayServer.get_name() == "headless"`) skip all of
## it: the hooks return at once and no audio bus or player is ever created.
##
## Buses: Master (compressor + hard limiter) <- World (low-pass that closes indoors), UI, Music, Ambience.
## Levels: every sample is baked at its intended loudness (peak <= -6 dBFS), so 0 dB is the normal volume.

const Synth = preload("res://scripts/synth.gd")
const Bank = preload("res://scripts/sound_bank.gd")
const Town = preload("res://scripts/town.gd")
const House = preload("res://scripts/house.gd")

const POOL_3D := 20
const POOL_UI := 8
const POOL_LOOPS := 14
const MAX_LOOP_VOICES := 10        # the nearest ones win; the rest fade out
const MAX_LOOP_DIST := 26.0
const MAX_ONESHOT_DIST := 48.0
const NAME_CAP := {"loop_server": 5, "loop_boxfan": 3, "loop_fire": 3, "loop_strip": 2, "loop_mower": 2, "loop_diesel": 2,
	"loop_aircon": 2, "loop_pump": 2, "loop_bike": 2}
const WIND_DOWN := ["loop_server", "loop_bike", "loop_mower", "loop_diesel", "loop_pump", "loop_boxfan", "loop_aircon"]
const PALLET := Vector3(-4.6, 0.8, 8.2)
const BIN := Vector3(4.9, 1.0, 8.2)
const GARAGE_DOOR := Vector3(0.0, 1.4, 4.4)
const MENUS := ["shop.gd", "offer.gd", "company_menu.gd", "settings_menu.gd"]

var enabled := false
var build_ms := 0
var build_bytes := 0

var _streams: Dictionary = {}
var _mutex := Mutex.new()
var _thread: Thread
var _cancel := false
var _t := 0.0
var _world: Node3D
var _world_t0 := 0.0
var _settings: Node
var _root3d: Node3D
var _pool3d: Array[AudioStreamPlayer3D] = []
var _next3d := 0
var _pool_ui: Array[AudioStreamPlayer] = []
var _next_ui := 0
var _last_play: Dictionary = {}
var _loop_free: Array[AudioStreamPlayer3D] = []
var _wanted: Dictionary = {}     # key -> {owner, name, db, pitch, auto}
var _voices: Dictionary = {}     # key -> {player, owner, name, db, db_t, pitch, pitch_t, stopping}
var _poll_t := 0.0
var _motion_t := 0.0
var _motion: Dictionary = {}     # item id -> [position, peak speed, time of peak]
var _heat_prev: Dictionary = {}
var _run_prev: Dictionary = {}
var _trip_prev: Array = []
var _unpacked_at := Vector3.ZERO
var _unpacked_t := -10.0
var _lowpass: AudioEffectLowPassFilter
var _indoor := 0.0
var _amb: Dictionary = {}        # name -> {"player", "gain"}
var _music: AudioStreamPlayer
var _music_gain := 0.0
var _bird_t := 8.0
var _thunder_t := 40.0
var _cloth_t := 0.0
var _deny_t := -10.0
var _played: Dictionary = {}     # test runs: how often each sound was triggered
var _voices_started := 0


func _ready() -> void:
	enabled = DisplayServer.get_name() != "headless"
	if not enabled:
		set_process(false)
		return
	_settings = get_node_or_null("/root/Settings")
	_setup_buses()
	_make_players()
	if _settings:
		_settings.changed.connect(_apply_volumes)
	_apply_volumes()
	get_tree().node_added.connect(_on_node_added)
	_thread = Thread.new()
	_thread.start(_build_all)


func _exit_tree() -> void:
	_cancel = true
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	if enabled and Net.test_mode:   # what was triggered during a test run, for checking the hooks
		var names: Array = _played.keys()
		names.sort()
		var parts: Array[String] = []
		for n: String in names:
			parts.append("%s=%d" % [n, _played[n]])
		print("SOUNDPLAYED built_in_ms=%d bytes=%d voices_started=%d %s" % [build_ms, build_bytes, _voices_started, " ".join(parts)])


# --- setup -------------------------------------------------------------------------------------

func _setup_buses() -> void:
	for bus_name: String in ["World", "UI", "Music", "Ambience"]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, bus_name)
			AudioServer.set_bus_send(i, "Master")
	var comp := AudioEffectCompressor.new()
	comp.threshold = -16.0
	comp.ratio = 3.0
	comp.attack_us = 15000.0
	comp.release_ms = 300.0
	comp.gain = 1.0
	AudioServer.add_bus_effect(0, comp)
	var limiter: AudioEffect
	if ClassDB.class_exists("AudioEffectHardLimiter"):
		limiter = ClassDB.instantiate("AudioEffectHardLimiter")
		limiter.set("ceiling_db", -1.0)
	else:
		limiter = AudioEffectLimiter.new()
		limiter.set("ceiling_db", -1.0)
	AudioServer.add_bus_effect(0, limiter)
	_lowpass = AudioEffectLowPassFilter.new()
	_lowpass.cutoff_hz = 18000.0
	AudioServer.add_bus_effect(AudioServer.get_bus_index("World"), _lowpass)


func _make_players() -> void:
	_root3d = Node3D.new()
	_root3d.name = "Sounds3D"
	add_child(_root3d)
	for i in POOL_3D + POOL_LOOPS:
		var p := AudioStreamPlayer3D.new()
		p.bus = "World"
		p.unit_size = 4.0 if i < POOL_3D else 3.0
		p.max_distance = MAX_ONESHOT_DIST if i < POOL_3D else MAX_LOOP_DIST + 4.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.attenuation_filter_cutoff_hz = 6500.0
		p.max_polyphony = 1
		p.max_db = 0.0
		_root3d.add_child(p)
		if i < POOL_3D:
			_pool3d.append(p)
		else:
			_loop_free.append(p)
	for i in POOL_UI:
		var p := AudioStreamPlayer.new()
		p.bus = "UI"
		add_child(p)
		_pool_ui.append(p)
	for pair: Array in [["rain_out", "Ambience"], ["rain_roof", "Ambience"], ["amb_out", "Ambience"], ["amb_in", "Ambience"]]:
		var p := AudioStreamPlayer.new()
		p.bus = pair[1]
		p.volume_db = -80.0
		add_child(p)
		_amb[pair[0]] = {"player": p, "gain": 0.0}
	_music = AudioStreamPlayer.new()
	_music.bus = "Music"
	_music.volume_db = -80.0
	add_child(_music)


func _apply_volumes() -> void:
	var sfx_v := 0.8
	var ui_v := 0.8
	var music_v := 0.6
	if _settings:
		sfx_v = _settings.sfx_volume
		ui_v = _settings.ui_volume
		music_v = _settings.music_volume
	_set_bus("World", sfx_v)
	_set_bus("Ambience", sfx_v)
	_set_bus("UI", ui_v)
	_set_bus("Music", music_v)


func _set_bus(bus_name: String, linear: float) -> void:
	var i := AudioServer.get_bus_index(bus_name)
	if i < 0:
		return
	AudioServer.set_bus_mute(i, linear <= 0.001)
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(linear, 0.0001)))


## Worker thread: builds every sound, in priority order, and publishes each as soon as it is ready.
func _build_all() -> void:
	var t0 := Time.get_ticks_msec()
	var bytes := 0
	for sound_name: String in Bank.NAMES:
		if _cancel:
			return
		var stream := Synth.to_stream(Bank.make(sound_name), Bank.is_loop(sound_name))
		bytes += stream.data.size()
		_mutex.lock()
		_streams[sound_name] = stream
		_mutex.unlock()
	build_bytes = bytes
	build_ms = Time.get_ticks_msec() - t0


func stream_of(sound_name: String) -> AudioStreamWAV:
	_mutex.lock()
	var s: AudioStreamWAV = _streams.get(sound_name)
	_mutex.unlock()
	return s


# --- playing -----------------------------------------------------------------------------------

## A flat (not positional) sound on the UI bus.
func ui(sound_name: String, vol := 0.0, pitch := 1.0) -> void:
	_flat(sound_name, vol, pitch, "UI")


## A flat sound on the World bus (heard everywhere: a breaker clack, thunder).
func world_flat(sound_name: String, vol := 0.0, pitch := 1.0) -> void:
	_flat(sound_name, vol, pitch, "World")


func _flat(sound_name: String, vol: float, pitch: float, bus: String) -> void:
	if not enabled:
		return
	var last: float = _last_play.get(sound_name, -10.0)
	if _t - last < 0.035:
		return
	var s := stream_of(sound_name)
	if s == null:
		return
	_last_play[sound_name] = _t
	_played[sound_name] = _played.get(sound_name, 0) + 1
	var p := _pool_ui[_next_ui]
	for k in _pool_ui.size():   # a free one if there is one, else the next in turn
		var c := _pool_ui[(_next_ui + k) % _pool_ui.size()]
		if not c.playing:
			p = c
			break
	_next_ui = (_next_ui + 1) % _pool_ui.size()
	p.bus = bus
	p.stream = s
	p.volume_db = vol + randf_range(-0.8, 0.8)
	p.pitch_scale = pitch * randf_range(0.97, 1.03)
	p.play()


## A one-shot at a place in the world. Pooled; sounds beyond hearing distance are dropped.
func at(sound_name: String, pos: Vector3, vol := 0.0, pitch := 1.0, delay := 0.0) -> void:
	if not enabled:
		return
	if delay > 0.0:
		get_tree().create_timer(delay).timeout.connect(at.bind(sound_name, pos, vol, pitch, 0.0))
		return
	var s := stream_of(sound_name)
	if s == null or _listener().distance_to(pos) > MAX_ONESHOT_DIST:
		return
	var p := _pool3d[_next3d]
	for k in _pool3d.size():
		var c := _pool3d[(_next3d + k) % _pool3d.size()]
		if not c.playing:
			p = c
			break
	_next3d = (_next3d + 1) % _pool3d.size()
	_played[sound_name] = _played.get(sound_name, 0) + 1
	p.stream = s
	p.global_position = pos
	p.volume_db = vol + randf_range(-1.2, 1.2)
	p.pitch_scale = pitch * randf_range(0.96, 1.04)
	p.play()


## Starts (or updates) a looping sound that follows `owner`. Fades in; stays until stop_loop().
func loop(src: Node3D, sound_name: String, vol := 0.0, pitch := 1.0) -> void:
	if enabled and src:
		_want(_wanted, src, sound_name, vol, pitch, false)


func stop_loop(src: Node3D, sound_name: String) -> void:
	_wanted.erase("%d:%s" % [src.get_instance_id(), sound_name])


func _want(into: Dictionary, src: Node3D, sound_name: String, vol: float, pitch: float, auto: bool) -> void:
	into["%d:%s" % [src.get_instance_id(), sound_name]] = {"owner": src, "name": sound_name, "db": vol, "pitch": pitch, "auto": auto}


func _listener() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	return cam.global_position if cam else Vector3.ZERO


func _me() -> Node3D:
	if _world == null:
		return null
	return _world.player(multiplayer.get_unique_id())


# --- the per-frame work ------------------------------------------------------------------------

func _process(dt: float) -> void:
	_t += dt
	if _world == null or not is_instance_valid(_world):
		var scene := get_tree().current_scene
		var w: Node = scene.get_node_or_null("World") if scene else null
		if w != _world:
			_forget_world()
		_world = w as Node3D
		if _world:
			_world_t0 = _t
	_update_voices(dt)
	_poll_t += dt
	if _poll_t >= 0.25:
		_poll_t = 0.0
		_poll_items()
	_motion_t += dt
	if _motion_t >= 0.05:
		_motion_poll(_motion_t)
		_motion_t = 0.0
	_update_indoor(dt)
	_update_ambience(dt)
	_update_music(dt)


func _forget_world() -> void:
	_wanted.clear()
	_motion.clear()
	_heat_prev.clear()
	_run_prev.clear()
	_trip_prev = []
	_cloth_t = 0.0


func _young() -> bool:
	return _world == null or _t - _world_t0 < 3.5


func _update_voices(dt: float) -> void:
	for key: String in _voices.keys():
		var v: Dictionary = _voices[key]
		var src: Node3D = v["owner"] if is_instance_valid(v["owner"]) else null
		if src == null:
			v["stopping"] = true
			v["db_t"] = -60.0
		var p: AudioStreamPlayer3D = v["player"]
		if src:
			p.global_position = src.global_position
		var rate := 45.0 if v["stopping"] else 55.0
		v["db"] = move_toward(v["db"], v["db_t"], dt * rate)
		v["pitch"] += (v["pitch_t"] - v["pitch"]) * (1.0 - exp(-dt * (2.2 if v["stopping"] else 6.0)))
		p.volume_db = v["db"]
		p.pitch_scale = clampf(v["pitch"], 0.2, 3.0)
		if v["stopping"] and v["db"] <= -52.0:
			p.stop()
			_loop_free.append(p)
			_voices.erase(key)


## Chooses which wanted loops get a voice (the nearest ones) and starts, updates or fades each.
func _apply_wanted() -> void:
	var lp := _listener()
	var cands: Array = []
	for key: String in _wanted.keys():
		var spec: Dictionary = _wanted[key]
		if not is_instance_valid(spec["owner"]):
			_wanted.erase(key)
			continue
		var d: float = (spec["owner"] as Node3D).global_position.distance_to(lp)
		if d <= MAX_LOOP_DIST:
			cands.append([d, key])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var chosen: Dictionary = {}
	var per_name: Dictionary = {}
	for c: Array in cands:
		var spec: Dictionary = _wanted[c[1]]
		var count: int = per_name.get(spec["name"], 0)
		if chosen.size() >= MAX_LOOP_VOICES or count >= NAME_CAP.get(spec["name"], 4):
			continue
		chosen[c[1]] = true
		per_name[spec["name"]] = count + 1
	for key: String in chosen:
		var spec: Dictionary = _wanted[key]
		var v: Dictionary = _voices.get(key, {})
		if v.is_empty():
			var s := stream_of(spec["name"])
			if s == null or _loop_free.is_empty():
				continue
			var p: AudioStreamPlayer3D = _loop_free.pop_back()
			p.stream = s
			p.volume_db = -60.0
			p.pitch_scale = spec["pitch"]
			p.global_position = (spec["owner"] as Node3D).global_position
			p.play(randf() * s.get_length())
			v = {"player": p, "owner": spec["owner"], "name": spec["name"], "db": -60.0, "pitch": spec["pitch"]}
			_voices[key] = v
			_voices_started += 1
			_played[spec["name"]] = _played.get(spec["name"], 0) + 1
		v["db_t"] = spec["db"]
		v["pitch_t"] = spec["pitch"]
		v["stopping"] = false
	for key: String in _voices.keys():
		if not chosen.has(key):
			var v: Dictionary = _voices[key]
			if not v["stopping"]:
				v["stopping"] = true
				v["db_t"] = -60.0
				if v["name"] in WIND_DOWN:
					v["pitch_t"] = v["pitch"] * 0.55


## Four times a second: what in the world makes a sound right now.
func _poll_items() -> void:
	if _world == null:
		_apply_wanted()
		return
	var fresh: Dictionary = {}
	var plugged: Dictionary = {}   # power strip id -> estimated watts drawn through it
	var pump_on := false
	for it: Node3D in _world.items.values():
		if it.power_to > 0 and it.status > 0 and (it.status & 1):
			plugged[it.power_to] = plugged.get(it.power_to, 0.0) + float(it.def.get("watts", float(it.def.get("psu", 0)) * 0.6))
		if it.def.has("pump") and it.running:
			pump_on = true
	for it: Node3D in _world.items.values():
		var d: Dictionary = it.def
		if it.on_fire():
			_want(fresh, it, "loop_fire", -2.0, 0.95 + (it.id % 7) * 0.02, true)
		if it.broken or it.holder != 0 and not d.has("gen"):
			continue
		var st: int = it.status
		if d.has("psu") and st > 0 and (st & 1):
			var warm := clampf((it.heat - 30.0) / 60.0, 0.0, 1.0)
			_want(fresh, it, "loop_server", -7.0 + 7.0 * warm, 0.88 + 0.45 * warm, true)
			var prev: float = _heat_prev.get(it.id, 0.0)
			if prev < 100.0 and it.heat >= 100.0 and not _young():
				at("beep", it.global_position, 0.0)
			_heat_prev[it.id] = it.heat
		if d.has("gen"):
			var gen: Dictionary = d["gen"]
			var frac := clampf(it.load / maxf(gen["watts"], 1.0), 0.0, 1.0)
			if gen["kind"] == "pedal":
				if it.rider != 0:
					_want(fresh, it, "loop_bike", -8.0 + 8.0 * frac, 0.7 + 0.9 * frac, true)
			elif gen["kind"] == "fuel":
				if it.running:
					var heavy: bool = gen["watts"] > 2500.0
					_want(fresh, it, "loop_diesel" if heavy else "loop_mower", -6.0 + 6.0 * frac, 0.85 + 0.45 * frac, true)
				var was: bool = _run_prev.get(it.id, it.running)
				if was != it.running and not _young():
					if it.running:
						at("engine_start", it.global_position, 0.0)
					else:
						at("engine_cough" if it.load >= gen["watts"] * 0.9 else "engine_stop", it.global_position, 0.0)
				_run_prev[it.id] = it.running
		if d.has("pump") and it.running:
			_want(fresh, it, "loop_pump", -4.0, 1.0, true)
		if d.has("cool") and st > 0 and (st & 1):
			if d["cool"].has("vent"):
				_want(fresh, it, "loop_boxfan", -3.0, 1.0, true)
			else:
				_want(fresh, it, "loop_aircon", -2.0, 1.0, true)
		if d.has("radiator") and pump_on:
			_want(fresh, it, "loop_boxfan", -10.0, 0.72, true)
		if it.kind == "powerstrip":
			var w: float = plugged.get(it.id, 0.0)
			if w > 1200.0:
				_want(fresh, it, "loop_strip", -8.0 + clampf((w - 1200.0) / 800.0, 0.0, 1.5) * 6.0, 1.0, true)
	for key: String in _wanted.keys():
		if _wanted[key]["auto"] and not fresh.has(key):
			_wanted.erase(key)
	_wanted.merge(fresh, true)
	_apply_wanted()


## Twenty times a second: a loose item that was moving and suddenly is not has landed.
func _motion_poll(dt: float) -> void:
	if _world == null:
		return
	for it: Node3D in _world.items.values():
		if not it.is_loose() or it.pinned or it.parent != 0:
			_motion.erase(it.id)
			continue
		var m: Array = _motion.get(it.id, [it.global_position, 0.0, _t])
		var speed: float = it.global_position.distance_to(m[0]) / dt
		m[0] = it.global_position
		if speed > m[1] or _t - m[2] > 0.7:
			if speed > m[1]:
				m[2] = _t
			m[1] = speed
		elif speed < 0.7 and m[1] > 1.8:
			_impact(it, m[1])
			m[1] = 0.0
		_motion[it.id] = m


func _impact(it: Node3D, speed: float) -> void:
	if _young():
		return
	var vol := clampf(-16.0 + (speed - 1.8) * 2.4, -16.0, 0.0)
	var mass: float = it.mass
	var snd := "put_light"
	var pitch := clampf(1.5 - mass / 30.0, 0.8, 1.5)
	if it.kind == "parcel":
		snd = "put_parcel"
		pitch = 1.0
	elif mass >= 60.0:
		snd = "thud_big"
		pitch = 1.0
	elif mass >= 8.0:
		snd = "put_heavy"
		pitch = clampf(1.3 - mass / 100.0, 0.8, 1.2)
	elif mass >= 2.5:
		snd = "put_heavy"
		pitch = 1.35
		vol -= 3.0
	at(snd, it.global_position, vol, pitch)


# --- ambience, music, indoor filter -----------------------------------------------------------

func _update_indoor(dt: float) -> void:
	var target := 0.0
	if _world:
		var w: Variant = _world.get("_weather")
		if w != null:
			target = w.indoor
	_indoor = lerpf(_indoor, target, 1.0 - exp(-dt * 4.0))
	if _lowpass:
		_lowpass.cutoff_hz = lerpf(18000.0, 9000.0, _indoor)


func _update_ambience(dt: float) -> void:
	var raining := false
	var sunny := false
	if _world:
		raining = _world.weather == 2
		sunny = _world.weather == 0
	var targets := {
		"rain_out": (1.0 - _indoor) if raining else 0.0,
		"rain_roof": _indoor if raining else 0.0,
		"amb_out": (1.0 - _indoor) * (0.0 if (raining or _world == null) else (1.0 if sunny else 0.6)),
		"amb_in": _indoor if _world else 0.0,
	}
	for key: String in _amb:
		var a: Dictionary = _amb[key]
		var p: AudioStreamPlayer = a["player"]
		a["gain"] = lerpf(a["gain"], targets[key], 1.0 - exp(-dt * 1.2))
		if a["gain"] < 0.005 and targets[key] == 0.0:
			if p.playing:
				p.stop()
			continue
		if not p.playing:
			var s := stream_of(key)
			if s == null:
				continue
			p.stream = s
			p.play(randf() * s.get_length())
		p.volume_db = linear_to_db(maxf(a["gain"], 0.0001))
	if _world == null:
		return
	if sunny and _indoor < 0.4:
		_bird_t -= dt
		if _bird_t <= 0.0:
			_bird_t = randf_range(7.0, 19.0)
			var ang := randf() * TAU
			var pos := _listener() + Vector3(cos(ang), 0.0, sin(ang)) * randf_range(10.0, 24.0) + Vector3(0, randf_range(3.0, 8.0), 0)
			at("bird_%d" % (randi() % 3), pos, randf_range(-4.0, 0.0), randf_range(0.9, 1.15))
	if raining:
		_thunder_t -= dt
		if _thunder_t <= 0.0:
			_thunder_t = randf_range(55.0, 150.0)
			world_flat("thunder", randf_range(-5.0, -1.0), randf_range(0.85, 1.1))


func _update_music(dt: float) -> void:
	var want := 0.0
	var in_game := _world != null
	if not in_game:
		want = 1.0
	elif _settings and _settings.music_in_game:
		want = 0.4   # very quietly
	_music_gain = lerpf(_music_gain, want, 1.0 - exp(-dt * 0.8))
	if _music_gain < 0.004 and want == 0.0:
		if _music.playing:
			_music.stop()
		return
	if not _music.playing:
		var s := stream_of("music_menu")
		if s == null:
			return
		_music.stream = s
		_music.play()
	_music.volume_db = linear_to_db(maxf(_music_gain, 0.0001)) - 3.0


# --- UI hooks: every button, slider and text field in the game, without touching their scripts ------

func _on_node_added(n: Node) -> void:
	if n is BaseButton:
		var b := n as BaseButton
		b.mouse_entered.connect(_hover.bind(b))
		if n is OptionButton:
			(n as OptionButton).item_selected.connect(func(_i: int) -> void: ui("ui_press"))
		else:
			b.pressed.connect(_pressed.bind(b))
	elif n is Slider:
		var r := n as Slider
		r.value_changed.connect(_slid.bind(r))
	elif n is LineEdit:
		(n as LineEdit).text_changed.connect(func(_s: String) -> void: ui("ui_type_%d" % (randi() % 3)))
	elif n is Control and n.get_script() != null:
		var path: String = (n.get_script() as Script).resource_path
		if path.get_file() in MENUS:
			var c := n as Control
			c.set_meta("snd_vis", c.is_visible_in_tree())
			c.visibility_changed.connect(_menu_visibility.bind(c))


func _hover(b: BaseButton) -> void:
	if not b.disabled and b.is_visible_in_tree():
		ui("ui_hover")


func _pressed(b: BaseButton) -> void:
	if not b.is_visible_in_tree():
		return
	ui("ui_tab" if b.toggle_mode else "ui_press")


func _slid(value: float, r: Slider) -> void:
	var last: float = r.get_meta("snd_t", -1.0)
	if _t - last < 0.06 or not r.is_visible_in_tree():
		return
	r.set_meta("snd_t", _t)
	var span := maxf(r.max_value - r.min_value, 0.0001)
	ui("ui_hover", 3.0, 0.8 + 0.6 * (value - r.min_value) / span)


func _menu_visibility(c: Control) -> void:
	var now := c.is_visible_in_tree()
	if now == c.get_meta("snd_vis", false):
		return
	c.set_meta("snd_vis", now)
	ui("ui_open" if now else "ui_close")


# --- gameplay hooks (all called from code that runs on every peer) --------------------------------------

func _weight(it: Node3D) -> String:
	if it.kind == "parcel":
		return "parcel"
	return "heavy" if it.mass >= 8.0 else "light"


## world._r_hold: somebody picked an item up (or pulled a part out of a machine).
func hold(it: Node3D) -> void:
	if not enabled or _young():
		return
	if it.parent != 0:
		at("snap_light", it.global_position, -2.0, 0.85)
		return
	match _weight(it):
		"parcel":
			at("pick_parcel", it.global_position)
		"heavy":
			at("pick_heavy", it.global_position, 0.0, clampf(1.3 - it.mass / 90.0, 0.8, 1.2))
		_:
			at("pick_light", it.global_position, 0.0, clampf(1.5 - it.mass / 4.0, 0.8, 1.4))


## world._r_release: let go (a hard throw whooshes; the landing is heard separately).
func released(it: Node3D, vel: Vector3) -> void:
	if not enabled or _young():
		return
	var speed := vel.length()
	if speed > 5.0:
		at("throw", it.global_position, clampf(-10.0 + speed, -8.0, 0.0), 1.0 + (speed - 7.0) * 0.02)


## world._r_place: put down deliberately and pinned in place.
func placed(it: Node3D) -> void:
	if not enabled or _young():
		return
	match _weight(it):
		"parcel":
			at("put_parcel", it.global_position, -5.0)
		"heavy":
			at("put_heavy", it.global_position, -5.0, clampf(1.3 - it.mass / 90.0, 0.8, 1.2))
		_:
			at("put_light", it.global_position, -3.0, clampf(1.5 - it.mass / 4.0, 0.8, 1.4))


## world._r_attach: a part (or a machine in a rack) snapped into place.
func attached(it: Node3D, parent: Node3D) -> void:
	if not enabled or _young():
		return
	var heavy: bool = it.mass >= 8.0
	at("snap_heavy" if heavy else "snap_light", parent.global_position if parent else it.global_position, 0.0)


## world._r_lid: lid unscrewed (open) or screwed on.
func lid(it: Node3D, open: bool) -> void:
	if enabled and not _young():
		at("screw_open" if open else "screw_close", it.global_position)


## world._r_link: BEFORE the change is applied, so the old state is still readable.
func link(it: Node3D, type: String, provider_id: int) -> void:
	if not enabled or _young():
		return
	var pos: Vector3 = it.port_pos(type)
	if provider_id == 0:
		if it.link(type) != 0:
			at("cable_pull", pos, 0.0, 0.9 if type == "coolant" else 1.0)
		return
	match type:
		"power":
			at("plug_power", pos)
		"net":
			at("plug_net", pos)
		_:
			at("plug_hose", pos)


## world._r_dangle: BEFORE the change. A plugged cable that lands on the floor was pulled out (tripped, yanked).
func dangle(it: Node3D, type: String, end: Vector3) -> void:
	if not enabled or _young():
		return
	if it.link(type) != 0:
		at("cable_pull", it.port_pos(type), 0.0)
		at("plug_drop", end, 0.0, 1.0, 0.14)
	else:
		at("plug_drop", end, -6.0, 1.1)


## world._r_spawn: a purchase arriving, or the contents of a parcel just unpacked.
func spawned(it: Node3D) -> void:
	if not enabled or _young() or it.parent != 0:
		return
	if _t - _unpacked_t < 0.3 and it.global_position.distance_to(_unpacked_at) < 1.5 and it.kind != "parcel":
		at("unpack", it.global_position)
	elif it.kind == "parcel":
		at("put_parcel", it.global_position, -2.0)


## world._r_despawn: BEFORE the item goes. A parcel vanishing is (usually) somebody tearing it open.
func despawned(it: Node3D) -> void:
	if enabled and it.kind == "parcel":
		_unpacked_at = it.global_position
		_unpacked_t = _t


## world._r_puddle
func puddle(pos: Vector3, radius: float) -> void:
	if not enabled or _young():
		return
	if radius >= 2.0:
		at("spray", pos + Vector3(0, 0.5, 0), 0.0)
	at("splash", pos, 0.0, 1.0 if radius < 2.0 else 0.85)


## world._r_door: the garage door.
func door(_open: bool) -> void:
	if enabled and not _young():
		at("door_roll", GARAGE_DOOR, 0.0)


## world._r_house_door
func house_door(h: Node3D, _open: bool) -> void:
	if not enabled or _young():
		return
	var pos: Vector3 = h.global_position
	for f: Node3D in h.fixtures.values():
		if f.kind == "hdoor":
			pos = f.global_position
	at("door_wood", pos, 0.0)


## world._r_house: bought (OURS = 1?) or demolished (GONE).
func house(h: Node3D, state: int) -> void:
	if not enabled or _young():
		return
	if state == House.GONE:
		at("crash", h.global_position, 0.0)
		world_flat("thud_big", -6.0, 0.7)
	elif state == House.OURS:
		ui("ui_buy", 0.0)


## world._r_notice (BEFORE its toast): the message is a refusal, so it gets the soft "no" instead of the ding.
func refused() -> void:
	_deny_t = _t


## world._r_offer_reply
func offer_reply(accepted: bool) -> void:
	ui("ui_buy" if accepted else "ui_deny", -2.0)


## item.set_status: BEFORE `status` changes, so `it.status` is the old state.
func status(it: Node3D, bits: int) -> void:
	if not enabled or it.status < 0 or _young():
		return
	var old: int = it.status
	if bits & 4 and not it.broken:
		at("fizz", it.global_position, 0.0)
	if old & 8 and not bits & 8:   # flames out: an extinguisher close by means it was put out, not burnt out
		var items: Array = _world.items.values() if _world else []
		for other: Node3D in items:
			if other.kind == "extinguisher" and other.holder != 0 and other.global_position.distance_to(it.global_position) < 3.5:
				at("hiss", other.global_position + Vector3(0, 0.2, 0), 0.0)
				break
	if it.kind == "lamp" and (old & 3 == 3) != (bits & 3 == 3):
		at("lamp_tick", it.global_position, 0.0)


## world._r_sim (end): breakers.
func sim(w: Node3D) -> void:
	if not enabled:
		return
	var now: Array = w.tripped_circuits
	if not _young():
		for c: Variant in now:
			if not _trip_prev.has(c):
				at("breaker_trip", _breaker_pos(w, c), 3.0)
				world_flat("breaker_trip", -10.0)
		for c: Variant in _trip_prev:
			if not now.has(c):
				at("breaker_reset", _breaker_pos(w, c), 0.0)
	_trip_prev = now.duplicate()


func _breaker_pos(w: Node3D, circuit: Variant) -> Vector3:
	for f: Node3D in w.fixtures.values():
		if f.kind == "breaker" and f.circuit == circuit:
			return f.global_position
	return _listener()


## hud.toast: some events have no replicated state of their own, only a message every peer receives.
func toast(text: String) -> void:
	if not enabled:
		return
	var low := text.to_lower()
	if _t - _deny_t < 0.05:
		ui("ui_deny", -2.0)
	elif low.contains("funding secured"):
		ui("ui_fanfare")
	elif low.contains(" is a hit:") or low.contains(" is live:") or low.contains(" is a flop:") or low.contains("is trained and in use"):
		ui("ui_launch")
	elif low.contains(" sold ") and low.contains(" for $"):
		at("cash", PALLET, 2.0)
		ui("ui_money", -4.0)
	elif low.contains("emptied the dumpster"):
		at("dumpster", BIN, 0.0)
	elif low.contains("tripped over"):
		at("stumble", _who(text), 0.0)
	elif low.contains("passed out from the heat"):
		at("faint", _who(text), 0.0)
	elif low.contains("did not survive") or low.contains("stepped on a") or low.contains("is now ruined"):
		at("crack", _who(text) + Vector3(0, -0.8, 0), 0.0)
	elif low.contains(" bought ") and low.contains("(-$"):
		ui("ui_buy", -1.0)
	else:
		ui("ui_toast")


## The position of the player a toast starts with, else right here.
func _who(text: String) -> Vector3:
	if _world:
		for id: int in Net.players:
			if text.begins_with(Net.players[id]["name"]):
				var p: Node3D = _world.player(id)
				if p:
					return p.global_position + Vector3(0, 0.9, 0)
	return _listener()


# --- the character: footsteps, jumps, landings ----------------------------------------------------------

## What the ground is made of under `pos`: concrete (garage), wood (houses), paving (driveway, streets) or grass.
func surface_at(pos: Vector3) -> String:
	if _world == null:
		return "concrete"
	if not _world.is_outdoors(pos):
		return "concrete" if absf(pos.x) < 5.5 and absf(pos.z) < 4.5 else "wood"
	if absf(pos.x) < 5.8 and pos.z > 4.3 and pos.z < 14.0:
		return "paving"
	var half := Town.STREET_WIDTH * 0.5 + Town.SIDEWALK_WIDTH
	for z: float in Town.STREETS_EW:
		if absf(pos.z - z) < half:
			return "paving"
	for x: float in Town.STREETS_NS:
		if absf(pos.x - x) < half:
			return "paving"
	return "grass"


func _is_player_blob(blob: Node3D) -> bool:
	var p := blob.get_parent()
	return p != null and "peer_id" in p


## blob.animate, once per frame, after the walk phase advanced. A foot lands twice per phase cycle.
func foot(blob: Node3D, phase: float, speed: float, in_air: bool, suit: float, load_heavy: float) -> void:
	if not enabled or _world == null:
		return
	var prev: float = blob.get_meta("snd_phase", phase)
	blob.set_meta("snd_phase", phase)
	var a := floorf((prev - PI * 0.5) / PI)
	var b := floorf((phase - PI * 0.5) / PI)
	if b <= a or in_air or speed < 0.4 or not _is_player_blob(blob):
		return
	var pos := blob.global_position
	var own: bool = blob.get_parent().peer_id == multiplayer.get_unique_id()
	var vol := -3.0 + clampf((speed - 3.0) * 1.2, -4.0, 4.0) + load_heavy * 2.0 - (4.0 if own else 0.0)
	var pitch := 1.0 + clampf((speed - 4.0) * 0.03, -0.1, 0.1) - load_heavy * 0.12
	at("step_%s_%d" % [surface_at(pos), randi() % 3], pos, vol, pitch)
	if suit > 0.5:
		at("rust_%d" % (randi() % 3), pos + Vector3(0, 0.8, 0), 3.0 - (4.0 if own else 0.0))


## blob.animate: left the ground.
func jump(blob: Node3D, vy: float) -> void:
	if enabled and _world and vy > 1.0 and _is_player_blob(blob):
		at("jump", blob.global_position + Vector3(0, 0.6, 0), -2.0)


## blob.animate: back on the ground after a fall of strength `hit` (about 1.5 .. 7).
func land(blob: Node3D, hit: float) -> void:
	if not enabled or _world == null or not _is_player_blob(blob):
		return
	var pos := blob.global_position
	var vol := -8.0 + clampf(hit, 1.5, 7.0) * 1.4
	at("step_%s_%d" % [surface_at(pos), randi() % 3], pos, vol, 0.8)
	if hit > 3.5:
		at("rust_%d" % (randi() % 3), pos + Vector3(0, 0.8, 0), 0.0)


# --- soundcheck (flag --soundcheck[=DIR]): analysis instead of listening -------------------------------------

## Builds the whole bank (synchronously, no audio server needed), prints one SOUND line per sound and a summary,
## and with a directory also writes every sound as a WAV file there.
func soundcheck(dir: String) -> void:
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	var t0 := Time.get_ticks_msec()
	var total := 0
	var samples := 0
	var slowest := ""
	var slowest_ms := 0
	for sound_name: String in Bank.NAMES:
		var t1 := Time.get_ticks_msec()
		var looped := Bank.is_loop(sound_name)
		var stream := Synth.to_stream(Bank.make(sound_name), looped)
		var ms := Time.get_ticks_msec() - t1
		if ms > slowest_ms:
			slowest_ms = ms
			slowest = sound_name
		var b := Synth.from_stream(stream)
		total += stream.data.size()
		samples += b.size()
		var pk := Synth.peak(b)
		var click := "n/a"
		var ratio := "n/a"
		if looped:
			var j: Array = Synth.loop_jump(b)
			click = "%.1f" % (20.0 * log(maxf(j[0], 0.00001)) / log(10.0))
			ratio = "%.2f" % j[1]
		print("SOUND %-16s seconds=%.2f peak_db=%.1f rms_db=%.1f dc=%.5f loop_click_db=%s click_ratio=%s centroid_hz=%d build_ms=%d" % [
			sound_name, b.size() / float(Synth.SR), 20.0 * log(maxf(pk, 0.00001)) / log(10.0),
			20.0 * log(maxf(Synth.rms(b), 0.00001)) / log(10.0), Synth.mean(b), click, ratio, int(Synth.centroid(b)), ms])
		if dir != "":
			stream.save_to_wav("%s/%s.wav" % [dir, sound_name])
	print("SOUNDBANK sounds=%d audio_seconds=%.1f bytes=%d (%.2f MB) build_ms=%d slowest=%s (%d ms)" % [
		Bank.NAMES.size(), samples / float(Synth.SR), total, total / 1048576.0, Time.get_ticks_msec() - t0, slowest, slowest_ms])
