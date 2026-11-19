extends RefCounted
## The sound recipes. Every sound is built from code (see synth.gd) and baked at its final loudness:
## the peak of each one is chosen here, so playing at 0 dB is already the intended level and nothing
## passes about -6 dBFS before the master limiter. Loops are seamless by construction (whole periods or a
## crossfaded fold). Names listed first are built first.

const S = preload("res://scripts/synth.gd")

const BPM := 80.0

## Build order matters: whatever is needed first (UI, hands, footsteps) comes first, the long beds last.
const NAMES: Array[String] = [
	"ui_hover", "ui_press", "ui_tab", "ui_open", "ui_close", "ui_buy", "ui_deny", "ui_toast", "ui_money", "ui_type_0", "ui_type_1", "ui_type_2",
	"music_menu",
	"pick_light", "pick_heavy", "pick_parcel", "put_light", "put_heavy", "put_parcel", "thud_big", "throw", "snap_light", "snap_heavy",
	"screw_open", "screw_close", "unpack", "crack", "cash", "dumpster", "lamp_tick",
	"step_concrete_0", "step_concrete_1", "step_concrete_2", "step_paving_0", "step_paving_1", "step_paving_2",
	"step_grass_0", "step_grass_1", "step_grass_2", "step_wood_0", "step_wood_1", "step_wood_2",
	"jump", "rust_0", "rust_1", "rust_2", "stumble", "faint",
	"cable_pull", "plug_power", "plug_net", "plug_hose", "pin_click", "plug_drop", "cable_roll",
	"breaker_trip", "breaker_reset", "fizz", "beep", "splash", "spray", "hiss", "engine_start", "engine_stop", "engine_cough",
	"door_roll", "door_wood", "crash", "ui_launch", "ui_fanfare", "bird_0", "bird_1", "bird_2", "thunder",
	"loop_server", "loop_bike", "loop_mower", "loop_diesel", "loop_pump", "loop_boxfan", "loop_aircon", "loop_strip", "loop_fire",
	"rain_out", "rain_roof", "amb_out", "amb_in",
]

const LOOPS: Array[String] = ["music_menu", "loop_server", "loop_bike", "loop_mower", "loop_diesel", "loop_pump", "loop_boxfan",
	"loop_aircon", "loop_strip", "loop_fire", "rain_out", "rain_roof", "amb_out", "amb_in"]


static func is_loop(name: String) -> bool:
	return LOOPS.has(name)


## Builds one sound by name; returns an empty buffer for an unknown name.
static func make(name: String) -> PackedFloat32Array:
	S.seed_with(name)
	var b: PackedFloat32Array
	match name:
		"ui_hover": b = _ui_hover()
		"ui_press": b = _ui_press()
		"ui_tab": b = _ui_tab()
		"ui_open": b = _ui_open(true)
		"ui_close": b = _ui_open(false)
		"ui_buy": b = _ui_buy()
		"ui_deny": b = _ui_deny()
		"ui_toast": b = _ui_toast()
		"ui_money": b = _ui_money()
		"ui_type_0": b = _ui_type(1200.0)
		"ui_type_1": b = _ui_type(1500.0)
		"ui_type_2": b = _ui_type(1800.0)
		"ui_launch": b = _ui_launch()
		"ui_fanfare": b = _ui_fanfare()
		"music_menu": b = _music_menu()
		"pick_light": b = _pick_light()
		"pick_heavy": b = _pick_heavy()
		"pick_parcel": b = _pick_parcel()
		"put_light": b = _put_light()
		"put_heavy": b = _put_heavy()
		"put_parcel": b = _put_parcel()
		"thud_big": b = _thud_big()
		"throw": b = _throw()
		"snap_light": b = _snap_light()
		"snap_heavy": b = _snap_heavy()
		"screw_open": b = _screw(true)
		"screw_close": b = _screw(false)
		"unpack": b = _unpack()
		"crack": b = _crack()
		"cash": b = _cash()
		"dumpster": b = _dumpster()
		"lamp_tick": b = _lamp_tick()
		"jump": b = _jump()
		"stumble": b = _stumble()
		"faint": b = _faint()
		"cable_pull": b = _cable_pull()
		"plug_power": b = _plug_power()
		"plug_net": b = _plug_net()
		"plug_hose": b = _plug_hose()
		"pin_click": b = _pin_click()
		"plug_drop": b = _plug_drop()
		"cable_roll": b = _cable_roll()
		"breaker_trip": b = _breaker_trip()
		"breaker_reset": b = _breaker_reset()
		"fizz": b = _fizz()
		"beep": b = _beep()
		"splash": b = _splash()
		"spray": b = _spray()
		"hiss": b = _hiss()
		"engine_start": b = _engine_start()
		"engine_stop": b = _engine_stop(false)
		"engine_cough": b = _engine_stop(true)
		"door_roll": b = _door_roll()
		"door_wood": b = _door_wood()
		"crash": b = _crash()
		"thunder": b = _thunder()
		"loop_server": b = _loop_server()
		"loop_bike": b = _loop_bike()
		"loop_mower": b = _loop_engine(16.0, 62.0, 500.0, 96.0, -20.0)
		"loop_diesel": b = _loop_engine(10.0, 40.0, 300.0, 80.0, -17.0)
		"loop_pump": b = _loop_pump()
		"loop_boxfan": b = _loop_boxfan()
		"loop_aircon": b = _loop_aircon()
		"loop_strip": b = _loop_strip()
		"loop_fire": b = _loop_fire()
		"rain_out": b = _rain(false)
		"rain_roof": b = _rain(true)
		"amb_out": b = _amb_out()
		"amb_in": b = _amb_in()
		_:
			if name.begins_with("step_"):
				b = _step(name.get_slice("_", 1))
			elif name.begins_with("rust_"):
				b = _rust()
			elif name.begins_with("bird_"):
				b = _bird(name.get_slice("_", 1).to_int())
			else:
				return PackedFloat32Array()
	return b


# --- helpers ---------------------------------------------------------------------------------

## Peak-normalised layer mixed in at t0 with gain g.
static func _put(dst: PackedFloat32Array, layer: PackedFloat32Array, t0: float, g: float) -> void:
	S.normalize(layer, 0.0)
	S.mix(dst, layer, t0, g)


## A filtered noise click.
static func _tick(dst: PackedFloat32Array, t0: float, f: float, g: float, decay := 0.004, kind := S.BP, q := 0.9) -> void:
	_put(dst, S.burst(decay * 7.0 + 0.004, kind, f, q, 0.0003, decay), t0, g)


## Finishes a one-shot: soft edges and the final peak.
static func _done(b: PackedFloat32Array, peak_db: float) -> PackedFloat32Array:
	S.remove_dc(b)
	S.fade_edges(b, 0.002, 0.012)
	S.normalize(b, peak_db)
	return b


static func _mtof(m: float) -> float:
	return 440.0 * pow(2.0, (m - 69.0) / 12.0)


# --- UI ----------------------------------------------------------------------------------------

static func _ui_hover() -> PackedFloat32Array:
	var b := S.silence(0.06)
	S.tone(b, 0, 0.05, 1900.0, 1900.0, 1.0, S.SINE, 0.001, 0.009, 0.01)
	S.tone(b, 0, 0.05, 3800.0, 3800.0, 0.2, S.SINE, 0.001, 0.005, 0.01)
	return _done(b, -26.0)


static func _ui_press() -> PackedFloat32Array:
	var b := S.silence(0.16)
	S.tone(b, 0, 0.14, 760.0, 520.0, 1.0, S.SINE, 0.002, 0.04, 0.02)
	S.tone(b, 0, 0.1, 1520.0, 1040.0, 0.25, S.TRI, 0.002, 0.02, 0.02)
	return _done(b, -17.0)


static func _ui_tab() -> PackedFloat32Array:
	var b := S.silence(0.3)
	S.mallet(b, 0, 988.0, 1.0, 0.06)
	_tick(b, 0, 2500.0, 0.15, 0.003)
	return _done(b, -17.0)


static func _ui_open(up: bool) -> PackedFloat32Array:
	var b := S.silence(0.75)
	var lo := 659.0
	var hi := 988.0
	if up:
		S.mallet(b, 0.0, lo, 0.8, 0.1)
		S.mallet(b, 0.08, hi, 1.0, 0.14)
	else:
		S.mallet(b, 0.0, hi, 0.8, 0.08)
		S.mallet(b, 0.08, lo, 0.9, 0.1)
	S.reverb(b, 0.18, 0.7, 0.6)
	return _done(b, -15.0)


static func _ui_buy() -> PackedFloat32Array:
	var b := S.silence(1.0)
	var notes := [1047.0, 1319.0, 1568.0]
	for i in notes.size():
		S.bell(b, i * 0.06, notes[i], 0.7 + 0.15 * i, 0.22, 2.0, 1.0)
	S.reverb(b, 0.22, 0.72, 0.7)
	return _done(b, -13.0)


static func _ui_deny() -> PackedFloat32Array:
	var b := S.silence(0.4)
	S.tone(b, 0.0, 0.11, 330.0, 320.0, 1.0, S.TRI, 0.005, 0.05, 0.03)
	S.tone(b, 0.12, 0.2, 262.0, 240.0, 1.0, S.TRI, 0.005, 0.07, 0.05)
	S.biquad(b, S.LP, 1100.0, 0.7)
	return _done(b, -16.0)


static func _ui_toast() -> PackedFloat32Array:
	var b := S.silence(0.7)
	S.bell(b, 0, 1319.0, 1.0, 0.18, 2.0, 0.8)
	S.reverb(b, 0.15, 0.7, 0.6)
	return _done(b, -21.0)


static func _ui_money() -> PackedFloat32Array:
	var b := S.silence(0.4)
	S.bell(b, 0.0, 1568.0, 0.9, 0.09, 2.0, 0.9)
	S.bell(b, 0.05, 2093.0, 1.0, 0.1, 2.0, 0.9)
	return _done(b, -17.0)


static func _ui_type(f: float) -> PackedFloat32Array:
	var b := S.silence(0.04)
	_tick(b, 0, 1800.0, 0.5, 0.003, S.HP, 0.7)
	S.tone(b, 0, 0.03, f, f * 0.9, 0.8, S.SINE, 0.0005, 0.006, 0.008)
	return _done(b, -27.0)


static func _ui_launch() -> PackedFloat32Array:
	var b := S.silence(2.0)
	var notes := [523.25, 659.25, 783.99, 1046.5, 1318.5]
	for i in notes.size():
		S.mallet(b, i * 0.09, notes[i], 0.7 + 0.08 * i, 0.22)
		S.bell(b, i * 0.09, notes[i] * 2.0, 0.1, 0.2, 2.0, 0.6)
	S.reverb(b, 0.3, 0.8, 0.9)
	return _done(b, -11.0)


static func _ui_fanfare() -> PackedFloat32Array:
	var b := S.silence(3.2)
	var pad := S.silence(3.2)
	# a short rising call, then a held major chord with a lydian sparkle on top
	var call := [392.0, 523.25, 659.25]
	for i in call.size():
		S.mallet(b, i * 0.14, call[i], 0.8, 0.22)
	var chord := [523.25, 659.25, 783.99, 1046.5]
	for f: float in chord:
		S.mallet(b, 0.46, f, 0.55, 0.5)
		S.pad(pad, 0.42, 1.8, f * 0.5, 0.35, 0.12, 1.0)
	S.biquad(pad, S.LP, 1400.0, 0.6)
	S.mix(b, pad, 0.0, 0.9)
	for i in 4:
		S.bell(b, 0.62 + i * 0.07, [1568.0, 1864.7, 2093.0, 2637.0][i], 0.2, 0.3, 2.0, 0.8)
	S.reverb(b, 0.32, 0.82, 1.0)
	return _done(b, -9.0)


# --- music -------------------------------------------------------------------------------------

## Four bars in C lydian (Cmaj7 - D - Em7 - Gmaj7), electric piano arpeggio, soft mallet melody, bass and a
## filtered pad. Everything wraps round the end, so the loop has no seam and the tails ring into the start.
static func _music_menu() -> PackedFloat32Array:
	var beat := 60.0 / BPM
	var bar := beat * 4.0
	var total := bar * 4.0
	var b := S.silence(total)
	var n := b.size()
	var chords: Array = [[64, 67, 71, 74], [66, 69, 74, 76], [67, 71, 74, 76], [67, 71, 74, 78]]
	var roots: Array = [48, 50, 52, 43]
	var pads: Array = [[55, 59, 64], [57, 62, 66], [59, 62, 67], [59, 62, 66]]
	var pattern: Array = [0, 1, 2, 3, 2, 1, 2, 1]
	var amps: Array = [1.0, 0.55, 0.7, 0.6, 0.85, 0.5, 0.65, 0.5]
	var arp := S.silence(total)
	var wrap := PackedFloat32Array()
	for bar_i in 4:
		var voicing: Array = chords[bar_i]
		for step in 8:
			if bar_i == 1 and step == 5:
				continue   # a breath
			var t := bar_i * bar + step * beat * 0.5
			var note := S.silence(2.8)
			S.epiano(note, 0.0, _mtof(voicing[pattern[step]]), 0.2 * amps[step], 0.5)
			S.mix_wrap(arp, note, t, 1.0)
	S.mix(b, arp, 0.0, 1.0)
	var melody: Array = [
		[0, 0.0, 76], [0, 1.5, 79], [0, 2.5, 83],
		[1, 0.0, 78], [1, 1.0, 81], [1, 2.5, 78],
		[2, 0.5, 79], [2, 2.0, 83], [2, 3.0, 81],
		[3, 0.0, 79], [3, 1.5, 78], [3, 2.5, 74], [3, 3.5, 76]]
	var lead := S.silence(total)
	for m: Array in melody:
		var note := S.silence(3.0)
		S.mallet(note, 0.0, _mtof(m[2]), 0.3, 0.45)
		S.mix_wrap(lead, note, m[0] * bar + m[1] * beat, 1.0)
	S.mix(b, lead, 0.0, 1.0)
	var low := S.silence(total)
	for bar_i in 4:
		for beat_i: float in [0.0, 2.0]:
			var note := S.silence(1.6)
			S.mallet(note, 0.0, _mtof(roots[bar_i]), 0.5 if beat_i == 0.0 else 0.35, 0.4)
			S.mix_wrap(low, note, bar_i * bar + beat_i * beat, 1.0)
	S.mix(b, low, 0.0, 1.0)
	var bed := S.silence(total)
	for bar_i in 4:
		for m: int in pads[bar_i]:
			var f := _mtof(m)
			var note := S.silence(bar + 1.6)
			for d: float in [-0.003, 0.003]:
				S.tone(note, 0.0, bar + 1.0, f * (1.0 + d), f * (1.0 + d), 0.1, S.SINE, 0.6, 1e9, 1.0)
				S.tone(note, 0.0, bar + 1.0, f * 2.0 * (1.0 + d), f * 2.0 * (1.0 + d), 0.03, S.SINE, 0.6, 1e9, 1.0)
			S.mix_wrap(bed, note, bar_i * bar - 0.3 + (total if bar_i == 0 else 0.0), 1.0)
	S.mix(b, bed, 0.0, 0.8)
	S.reverb_loop(b, 0.3, 0.8, 1.2)
	S.biquad_loop(b, S.LP, 5200.0, 0.6)
	S.remove_dc(b)
	S.normalize(b, -13.0)
	return b


# --- hands -------------------------------------------------------------------------------------

static func _pick_light() -> PackedFloat32Array:
	var b := S.silence(0.12)
	_tick(b, 0, 2200.0, 0.8, 0.012, S.BP, 1.0)
	S.tone(b, 0, 0.05, 700.0, 900.0, 0.4, S.SINE, 0.002, 0.012, 0.01)
	return _done(b, -14.0)


static func _pick_heavy() -> PackedFloat32Array:
	var b := S.silence(0.22)
	_put(b, S.burst(0.12, S.LP, 600.0, 0.7, 0.003, 0.03), 0, 0.8)
	S.tone(b, 0, 0.15, 140.0, 100.0, 1.0, S.SINE, 0.003, 0.05, 0.03)
	_tick(b, 0.01, 1500.0, 0.3, 0.005)
	return _done(b, -11.0)


static func _pick_parcel() -> PackedFloat32Array:
	var b := S.silence(0.28)
	_put(b, S.burst(0.2, S.BP, 900.0, 0.6, 0.015, 0.06, S.PINK), 0, 1.0)
	_put(b, S.burst(0.1, S.LP, 200.0, 0.7, 0.002, 0.04), 0.01, 0.6)
	return _done(b, -13.0)


static func _put_light() -> PackedFloat32Array:
	var b := S.silence(0.2)
	S.tone(b, 0, 0.1, 1100.0, 900.0, 0.8, S.SINE, 0.001, 0.02, 0.01)
	_tick(b, 0, 3000.0, 0.5, 0.004)
	S.tone(b, 0.045, 0.08, 1300.0, 1100.0, 0.25, S.SINE, 0.001, 0.015, 0.01)
	return _done(b, -12.0)


static func _put_heavy() -> PackedFloat32Array:
	var b := S.silence(0.45)
	S.tone(b, 0, 0.3, 80.0, 52.0, 1.0, S.SINE, 0.002, 0.09, 0.05)
	_put(b, S.burst(0.2, S.LP, 400.0, 0.7, 0.002, 0.05), 0, 0.7)
	_tick(b, 0.13, 900.0, 0.12, 0.01)
	return _done(b, -7.0)


static func _put_parcel() -> PackedFloat32Array:
	var b := S.silence(0.4)
	_put(b, S.burst(0.25, S.LP, 500.0, 0.7, 0.003, 0.06, S.PINK), 0, 0.8)
	S.tone(b, 0, 0.2, 110.0, 80.0, 1.0, S.SINE, 0.003, 0.07, 0.04)
	_put(b, S.burst(0.12, S.BP, 1400.0, 0.7, 0.01, 0.03), 0.05, 0.25)
	return _done(b, -9.0)


static func _thud_big() -> PackedFloat32Array:
	var b := S.silence(0.8)
	S.tone(b, 0, 0.6, 54.0, 36.0, 1.0, S.SINE, 0.003, 0.2, 0.1)
	_put(b, S.burst(0.4, S.LP, 250.0, 0.7, 0.002, 0.12), 0, 0.8)
	S.fm(b, 0.0, 0.3, 180.0, 2.76, 1.5, 0.03, 0.12, 0.001, 0.06)
	return _done(b, -6.0)


static func _throw() -> PackedFloat32Array:
	var b := S.silence(0.5)
	var n := S.noise(0.42, S.PINK, 0.12, 0.12, 0.15)
	S.biquad(n, S.BP, 400.0, 1.2, 1600.0)
	_put(b, n, 0, 1.0)
	return _done(b, -14.0)


static func _snap_light() -> PackedFloat32Array:
	var b := S.silence(0.2)
	_tick(b, 0, 3200.0, 0.8, 0.004)
	S.tone(b, 0, 0.05, 520.0, 500.0, 0.5, S.SINE, 0.001, 0.012, 0.01)
	_tick(b, 0.04, 2400.0, 0.6, 0.004)
	S.tone(b, 0.04, 0.05, 380.0, 360.0, 0.4, S.SINE, 0.001, 0.012, 0.01)
	return _done(b, -11.0)


static func _snap_heavy() -> PackedFloat32Array:
	var b := S.silence(0.4)
	S.fm(b, 0.0, 0.2, 180.0, 2.76, 2.5, 0.02, 1.0, 0.001, 0.05, 0.02)
	_put(b, S.burst(0.12, S.LP, 500.0, 0.7, 0.001, 0.03), 0, 0.6)
	S.fm(b, 0.07, 0.2, 240.0, 2.76, 2.0, 0.02, 0.7, 0.001, 0.04, 0.02)
	_tick(b, 0.07, 2000.0, 0.3, 0.004)
	return _done(b, -9.0)


static func _screw(open: bool) -> PackedFloat32Array:
	var b := S.silence(0.9)
	var t := 0.02
	var gap := 0.045 if open else 0.07
	for i in 8:
		var f := 2600.0 + (i * 90.0 if not open else -i * 90.0)
		_tick(b, t, f, 0.8, 0.003)
		S.tone(b, t, 0.01, 1500.0, 1500.0, 0.3, S.SINE, 0.0005, 0.004, 0.004)
		_put(b, S.burst(gap * 0.8, S.BP, 700.0, 0.8, 0.004, gap * 0.4), t + 0.004, 0.1)
		t += gap * (1.0 + (0.06 * i if open else -0.04 * i))
	if open:   # the lid comes loose
		S.fm(b, t + 0.03, 0.4, 1100.0, 2.1, 1.2, 0.05, 0.3, 0.001, 0.1, 0.04)
	else:   # and thunks home
		S.tone(b, t + 0.02, 0.12, 170.0, 120.0, 0.9, S.SINE, 0.002, 0.04, 0.02)
		_tick(b, t + 0.02, 1400.0, 0.4, 0.005)
	return _done(b, -12.0)


static func _unpack() -> PackedFloat32Array:
	var b := S.silence(1.1)
	var rip := S.silence(0.4)
	for i in 18:
		_put(rip, S.burst(0.02, S.HP, 1800.0 + S.rnd() * 1500.0, 0.7, 0.0005, 0.006), i * 0.02 + S.rnd() * 0.01, 0.4 + S.rnd() * 0.6)
	var bed := S.noise(0.4, S.WHITE, 0.05, 1e9, 0.1)
	S.biquad(bed, S.BP, 3200.0, 0.7, 2200.0)
	_put(rip, bed, 0, 0.5)
	S.mix(b, rip, 0.0, 1.0)
	_put(b, S.burst(0.25, S.BP, 700.0, 0.6, 0.01, 0.06, S.PINK), 0.48, 0.7)
	_put(b, S.burst(0.25, S.BP, 600.0, 0.6, 0.01, 0.06, S.PINK), 0.66, 0.55)
	return _done(b, -9.0)


static func _crack() -> PackedFloat32Array:
	var b := S.silence(0.5)
	_tick(b, 0, 2600.0, 1.0, 0.006, S.HP, 0.7)
	S.fm(b, 0.0, 0.2, 3200.0, 1.41, 2.0, 0.02, 0.25, 0.0005, 0.04, 0.02)
	_put(b, S.burst(0.1, S.LP, 1500.0, 0.7, 0.001, 0.02), 0, 0.7)
	for t: float in [0.07, 0.12, 0.2]:
		_tick(b, t, 2200.0 + S.rnd() * 1500.0, 0.3 + S.rnd() * 0.3, 0.004, S.BP, 1.5)
	S.biquad(b, S.LP, 6000.0, 0.7)
	return _done(b, -9.0)


static func _cash() -> PackedFloat32Array:
	var b := S.silence(1.8)
	S.tone(b, 0, 0.2, 160.0, 90.0, 0.8, S.SINE, 0.002, 0.05, 0.03)
	_put(b, S.burst(0.1, S.LP, 700.0, 0.7, 0.001, 0.02), 0, 0.6)
	_tick(b, 0.01, 2500.0, 0.3, 0.004)
	S.bell(b, 0.1, 2093.0, 1.0, 0.45, 2.01, 1.6)
	S.bell(b, 0.18, 2794.0, 0.7, 0.4, 2.01, 1.4)
	for i in 5:
		S.bell(b, 0.42 + i * 0.05 + S.rnd() * 0.03, 2500.0 + S.rnd() * 1800.0, 0.14, 0.08, 3.0, 1.0)
	S.reverb(b, 0.18, 0.7, 0.7)
	return _done(b, -8.0)


static func _dumpster() -> PackedFloat32Array:
	var b := S.silence(2.4)
	var rumble := S.noise(1.6, S.WHITE, 0.15, 1e9, 0.6)
	S.biquad(rumble, S.LP, 900.0, 0.8, 500.0)
	S.am(rumble, 11.0, 0.6)
	_put(b, rumble, 0.0, 0.8)
	for t: float in [0.08, 0.3, 0.55, 0.8]:
		S.fm(b, t, 0.5, 190.0 + S.rnd() * 70.0, 2.4, 2.5, 0.08, 0.5, 0.001, 0.2, 0.05)
	var air := S.noise(0.8, S.WHITE, 0.2, 1e9, 0.4)
	S.biquad(air, S.HP, 3000.0, 0.7)
	_put(b, air, 1.2, 0.2)
	S.biquad(b, S.LP, 6000.0, 0.7)
	return _done(b, -8.0)


static func _lamp_tick() -> PackedFloat32Array:
	var b := S.silence(0.12)
	S.tone(b, 0, 0.03, 2200.0, 2100.0, 0.6, S.SINE, 0.0005, 0.005, 0.005)
	_tick(b, 0, 4000.0, 0.5, 0.002, S.HP, 0.7)
	S.tone(b, 0.03, 0.06, 400.0, 360.0, 0.5, S.SINE, 0.001, 0.012, 0.01)
	return _done(b, -16.0)


# --- feet and body ---------------------------------------------------------------------------------

static func _step(surface_and_variant: String) -> PackedFloat32Array:
	# called with e.g. "concrete" (the variant is only a seed: the name was hashed into the generator)
	var b := S.silence(0.22)
	match surface_and_variant:
		"concrete":
			S.tone(b, 0, 0.1, 150.0 + S.rnd() * 20.0, 100.0, 1.0, S.SINE, 0.001, 0.02, 0.02)
			_tick(b, 0, 1900.0 + S.rnd() * 400.0, 1.3, 0.012, S.BP, 0.8)
			S.biquad(b, S.LP, 5000.0, 0.7)
			return _done(b, -17.0)
		"paving":
			S.tone(b, 0, 0.1, 180.0 + S.rnd() * 30.0, 120.0, 0.9, S.SINE, 0.001, 0.02, 0.02)
			_tick(b, 0, 2600.0 + S.rnd() * 500.0, 1.5, 0.01, S.BP, 0.8)
			S.biquad(b, S.LP, 5500.0, 0.7)
			return _done(b, -16.0)
		"grass":
			var swish := S.burst(0.2, S.BP, 1500.0 + S.rnd() * 300.0, 0.5, 0.02, 0.04, S.PINK)
			S.biquad(swish, S.LP, 2500.0, 0.7)
			_put(b, swish, 0, 1.0)
			S.tone(b, 0.01, 0.08, 90.0, 70.0, 0.5, S.SINE, 0.004, 0.03, 0.02)
			return _done(b, -20.0)
		_:   # wood
			var f := 125.0 + S.rnd() * 20.0
			S.tone(b, 0, 0.16, f, f * 0.9, 1.0, S.SINE, 0.001, 0.035, 0.03)
			S.tone(b, 0, 0.1, f * 2.0, f * 1.9, 0.4, S.SINE, 0.001, 0.025, 0.02)
			S.tone(b, 0, 0.08, f * 3.1, f * 3.0, 0.2, S.SINE, 0.001, 0.02, 0.02)
			_tick(b, 0, 1200.0, 0.4, 0.008)
			return _done(b, -15.0)


static func _rust() -> PackedFloat32Array:
	var b := S.silence(0.2)
	for i in 14:
		_put(b, S.burst(0.012, S.HP, 3500.0 + S.rnd() * 2000.0, 0.7, 0.0003, 0.003), S.rnd() * 0.15, 0.2 + S.rnd() * 0.8)
	S.biquad(b, S.LP, 4500.0, 0.7)
	return _done(b, -25.0)


static func _jump() -> PackedFloat32Array:
	var b := S.silence(0.3)
	var n := S.noise(0.22, S.PINK, 0.05, 0.06, 0.06)
	S.biquad(n, S.BP, 500.0, 1.0, 1200.0)
	_put(b, n, 0, 0.7)
	S.tone(b, 0.0, 0.1, 220.0, 330.0, 0.3, S.SINE, 0.005, 0.03, 0.03)
	return _done(b, -18.0)


static func _stumble() -> PackedFloat32Array:
	var b := S.silence(0.5)
	_put(b, S.burst(0.3, S.LP, 700.0, 0.7, 0.01, 0.07, S.PINK), 0, 0.8)
	S.tone(b, 0, 0.25, 140.0, 70.0, 1.0, S.SINE, 0.005, 0.08, 0.05)
	for i in 8:
		_put(b, S.burst(0.012, S.HP, 3500.0, 0.7, 0.0003, 0.003), 0.03 + S.rnd() * 0.2, 0.15)
	return _done(b, -9.0)


static func _faint() -> PackedFloat32Array:
	var b := S.silence(2.2)
	S.tone(b, 0.0, 1.5, 420.0, 150.0, 0.8, S.SINE, 0.05, 0.9, 0.2, 0.04, 6.5)
	S.tone(b, 0.0, 1.5, 840.0, 300.0, 0.15, S.TRI, 0.05, 0.6, 0.2, 0.04, 6.5)
	S.biquad(b, S.LP, 1500.0, 0.7)
	S.tone(b, 1.35, 0.4, 70.0, 45.0, 1.0, S.SINE, 0.003, 0.1, 0.1)
	_put(b, S.burst(0.3, S.LP, 400.0, 0.7, 0.003, 0.06), 1.35, 0.6)
	return _done(b, -11.0)


# --- cables --------------------------------------------------------------------------------------

static func _cable_pull() -> PackedFloat32Array:
	var b := S.silence(0.3)
	var n := S.noise(0.2, S.WHITE, 0.05, 0.06, 0.06)
	S.biquad(n, S.BP, 700.0, 1.0, 2800.0)
	_put(b, n, 0, 0.7)
	S.tone(b, 0.15, 0.06, 400.0, 300.0, 0.5, S.SINE, 0.001, 0.012, 0.01)
	_tick(b, 0.15, 1800.0, 0.3, 0.004)
	return _done(b, -16.0)


static func _plug_power() -> PackedFloat32Array:
	var b := S.silence(0.25)
	S.tone(b, 0, 0.12, 190.0, 150.0, 1.0, S.SINE, 0.001, 0.03, 0.02)
	S.tone(b, 0, 0.08, 380.0, 340.0, 0.4, S.TRI, 0.001, 0.02, 0.02)
	_tick(b, 0, 2500.0, 0.5, 0.004)
	_tick(b, 0.035, 1800.0, 0.2, 0.004)
	return _done(b, -10.0)


static func _plug_net() -> PackedFloat32Array:
	var b := S.silence(0.18)
	_tick(b, 0.0, 3500.0, 0.9, 0.003, S.BP, 1.5)
	_tick(b, 0.028, 2600.0, 0.7, 0.004, S.BP, 1.5)
	S.tone(b, 0.028, 0.04, 1800.0, 1700.0, 0.35, S.SINE, 0.0005, 0.006, 0.008)
	return _done(b, -14.0)


static func _plug_hose() -> PackedFloat32Array:
	var b := S.silence(0.4)
	S.tone(b, 0, 0.2, 160.0, 80.0, 1.0, S.SINE, 0.002, 0.07, 0.04)
	_put(b, S.burst(0.15, S.LP, 500.0, 0.7, 0.002, 0.04), 0, 0.6)
	S.tone(b, 0.02, 0.07, 350.0, 900.0, 0.4, S.SINE, 0.004, 0.03, 0.02)
	S.tone(b, 0.08, 0.07, 800.0, 400.0, 0.25, S.SINE, 0.004, 0.03, 0.02)
	return _done(b, -9.0)


static func _pin_click() -> PackedFloat32Array:
	var b := S.silence(0.1)
	S.tone(b, 0, 0.04, 900.0, 700.0, 0.8, S.SINE, 0.001, 0.008, 0.01)
	_tick(b, 0, 2000.0, 0.5, 0.003)
	return _done(b, -18.0)


static func _plug_drop() -> PackedFloat32Array:
	var b := S.silence(0.6)
	var times := [0.0, 0.09, 0.15, 0.185]
	var amps := [1.0, 0.5, 0.25, 0.1]
	for i in times.size():
		S.fm(b, times[i], 0.12, 1100.0 - i * 80.0, 1.6, 1.5, 0.015, amps[i], 0.0005, 0.02, 0.01)
		_tick(b, times[i], 1800.0, amps[i] * 0.5, 0.006)
	S.biquad(b, S.LP, 5000.0, 0.7)
	return _done(b, -12.0)


static func _cable_roll() -> PackedFloat32Array:
	var b := S.silence(0.6)
	var n := S.noise(0.4, S.WHITE, 0.03, 1e9, 0.1)
	S.biquad(n, S.BP, 600.0, 1.0, 2500.0)
	_put(b, n, 0, 0.7)
	for i in 8:
		_tick(b, 0.02 + i * 0.045, 2200.0 + i * 100.0, 0.4, 0.003)
	return _done(b, -16.0)


# --- trouble -------------------------------------------------------------------------------------

static func _breaker_trip() -> PackedFloat32Array:
	var b := S.silence(2.0)
	_tick(b, 0, 1800.0, 1.0, 0.004)
	S.tone(b, 0, 0.12, 110.0, 80.0, 0.9, S.SINE, 0.001, 0.04, 0.03)
	S.fm(b, 0, 0.12, 260.0, 1.5, 1.5, 0.02, 0.4, 0.001, 0.03, 0.02)
	var down := S.silence(1.8)
	S.tone(down, 0.05, 1.6, 120.0, 28.0, 1.0, S.SAW, 0.03, 0.5, 0.2)
	S.biquad(down, S.LP, 400.0, 0.7, 150.0)
	_put(b, down, 0.0, 0.45)
	return _done(b, -9.0)


static func _breaker_reset() -> PackedFloat32Array:
	var b := S.silence(0.4)
	S.tone(b, 0, 0.15, 140.0, 110.0, 1.0, S.SINE, 0.001, 0.03, 0.02)
	_tick(b, 0, 1500.0, 0.6, 0.005)
	_tick(b, 0.09, 2000.0, 0.4, 0.004)
	S.tone(b, 0.09, 0.08, 220.0, 200.0, 0.5, S.SINE, 0.001, 0.02, 0.02)
	return _done(b, -11.0)


static func _fizz() -> PackedFloat32Array:
	var b := S.silence(1.0)
	for i in 44:
		var t := pow(S.rnd(), 1.6) * 0.75   # denser at first
		_put(b, S.burst(0.014, S.HP, 3000.0 + S.rnd() * 2500.0, 0.7, 0.0003, 0.003), t, 0.2 + S.rnd() * 0.8)
	var buzz := S.silence(0.8)
	S.tone(buzz, 0, 0.7, 100.0, 60.0, 1.0, S.SAW, 0.01, 0.25, 0.1)
	S.biquad(buzz, S.LP, 1500.0, 0.7)
	_put(b, buzz, 0, 0.3)
	S.biquad(b, S.LP, 6500.0, 0.7)
	return _done(b, -11.0)


static func _beep() -> PackedFloat32Array:
	var b := S.silence(0.6)
	for i in 3:
		S.tone(b, i * 0.16, 0.1, 880.0, 880.0, 1.0, S.SINE, 0.006, 1e9, 0.025)
		S.tone(b, i * 0.16, 0.1, 1760.0, 1760.0, 0.12, S.SINE, 0.006, 1e9, 0.025)
	return _done(b, -16.0)


static func _splash() -> PackedFloat32Array:
	var b := S.silence(1.0)
	var body := S.noise(0.6, S.WHITE, 0.01, 0.12, 0.2)
	S.biquad(body, S.LP, 1800.0, 0.7)
	_put(b, body, 0, 1.0)
	for i in 7:
		var t := 0.04 + S.rnd() * 0.5
		var f := 400.0 + S.rnd() * 800.0
		S.tone(b, t, 0.05, f, f * 2.2, 0.35, S.SINE, 0.003, 0.02, 0.02)
	S.biquad(b, S.LP, 4500.0, 0.7)
	return _done(b, -10.0)


static func _spray() -> PackedFloat32Array:
	var b := S.silence(2.0)
	var n := S.noise(1.8, S.WHITE, 0.1, 1e9, 0.6)
	S.biquad(n, S.BP, 2800.0, 0.6)
	S.modulate(n, S.wander(1.8, 9.0), 0.4)
	_put(b, n, 0, 1.0)
	_put(b, S.burst(1.4, S.LP, 700.0, 0.7, 0.1, 1e9), 0.1, 0.3)
	return _done(b, -13.0)


static func _hiss() -> PackedFloat32Array:
	var b := S.silence(2.0)
	var n := S.noise(1.9, S.WHITE, 0.05, 1e9, 0.7)
	S.biquad(n, S.HP, 1500.0, 0.7)
	S.biquad(n, S.LP, 5500.0, 0.7)
	S.modulate(n, S.wander(1.9, 8.0), 0.35)
	_put(b, n, 0, 1.0)
	return _done(b, -13.0)


static func _puff(b: PackedFloat32Array, t: float, f: float, g: float) -> void:
	S.tone(b, t, 0.09, f, f * 0.7, g, S.SINE, 0.002, 0.02, 0.02)
	_put(b, S.burst(0.07, S.LP, 450.0, 0.7, 0.001, 0.015), t, g * 0.6)


static func _engine_start() -> PackedFloat32Array:
	var b := S.silence(1.9)
	var t := 0.0
	var gap := 0.2
	var i := 0
	while t < 1.35:   # cranking, faster and faster, until it catches
		_puff(b, t, 55.0 + i * 1.5, 0.5 + 0.06 * i)
		if i % 2 == 0:
			_tick(b, t, 1800.0, 0.12, 0.003)
		t += gap
		gap = maxf(gap * 0.86, 0.0625)
		i += 1
	return _done(b, -14.0)


static func _engine_stop(cough: bool) -> PackedFloat32Array:
	var b := S.silence(1.5)
	var t := 0.0
	var gap := 0.07
	for i in 9:
		var g := 1.0 - i * 0.09
		_puff(b, t, 62.0 - i * 2.5, g)
		t += gap
		gap *= 1.27
		if cough and i == 3:
			_put(b, S.burst(0.2, S.BP, 400.0, 0.7, 0.02, 0.05, S.PINK), t, 0.5)
	return _done(b, -15.0)


static func _door_roll() -> PackedFloat32Array:
	var b := S.silence(2.2)
	var n := S.noise(1.9, S.WHITE, 0.15, 1e9, 0.25)
	S.biquad(n, S.LP, 900.0, 0.8, 600.0)
	S.am(n, 19.0, 0.5)
	_put(b, n, 0.0, 0.8)
	for i in 36:
		_tick(b, 0.05 + i * 0.05, 1300.0, 0.15 + 0.1 * S.rnd(), 0.004, S.BP, 1.5)
	_tick(b, 1.95, 800.0, 0.6, 0.01, S.LP, 0.7)
	S.tone(b, 1.95, 0.2, 90.0, 60.0, 0.6, S.SINE, 0.002, 0.05, 0.05)
	return _done(b, -13.0)


static func _door_wood() -> PackedFloat32Array:
	var b := S.silence(1.0)
	S.tone(b, 0.0, 0.6, 180.0, 250.0, 0.5, S.SAW, 0.05, 0.35, 0.2, 0.05, 11.0)
	S.biquad(b, S.LP, 700.0, 1.2, 1100.0)
	_tick(b, 0.62, 1000.0, 0.8, 0.006)
	S.tone(b, 0.62, 0.15, 220.0, 160.0, 0.9, S.SINE, 0.001, 0.03, 0.03)
	return _done(b, -12.0)


static func _crash() -> PackedFloat32Array:
	var b := S.silence(3.0)
	S.tone(b, 0, 1.2, 60.0, 34.0, 1.0, S.SINE, 0.003, 0.3, 0.2)
	_put(b, S.burst(1.8, S.LP, 2200.0, 0.7, 0.003, 0.4, S.PINK), 0, 0.9)
	for i in 30:
		_tick(b, 0.1 + S.rnd() * 1.6, 600.0 + S.rnd() * 2400.0, 0.1 + S.rnd() * 0.4, 0.008)
	S.fm(b, 0.05, 0.8, 170.0, 2.4, 2.5, 0.1, 0.3, 0.001, 0.25, 0.1)
	return _done(b, -6.0)


static func _thunder() -> PackedFloat32Array:
	var b := S.silence(6.0)
	var n := S.noise(5.6, S.BROWN, 0.7, 1.4, 0.8)
	S.biquad(n, S.LP, 500.0, 0.7, 70.0)
	_put(b, n, 0, 1.0)
	var roll := S.noise(3.0, S.BROWN, 0.5, 0.9, 0.6)
	S.biquad(roll, S.LP, 400.0, 0.7, 60.0)
	_put(b, roll, 1.9, 0.6)
	return _done(b, -8.0)


# --- birds -------------------------------------------------------------------------------------------

static func _bird(kind: int) -> PackedFloat32Array:
	var b := S.silence(0.8)
	var t := 0.02
	var notes := 3 + kind
	var base := 2600.0 + kind * 350.0 + S.rnd() * 200.0
	for i in notes:
		var f0 := base * (1.0 + 0.1 * i * (1 if kind != 1 else -1))
		var dur := 0.05 + S.rnd() * 0.05
		S.tone(b, t, dur, f0, f0 * (1.35 if kind != 2 else 0.8), 0.8, S.SINE, 0.005, 1e9, 0.02, 0.02, 30.0)
		S.tone(b, t, dur, f0 * 2.0, f0 * 2.5, 0.08, S.SINE, 0.005, 1e9, 0.02)
		t += dur + 0.03 + S.rnd() * 0.04
	S.reverb(b, 0.15, 0.6, 0.6)
	return _done(b, -26.0)


# --- loops: machines ---------------------------------------------------------------------------------

static func _loop_server() -> PackedFloat32Array:
	var l := 2.0
	var b := S.silence(l)
	for p: Array in [[118.0, 1.0], [236.0, 0.35], [354.0, 0.15], [472.0, 0.06]]:
		var f := S.snap(p[0], l)
		S.tone(b, 0, l, f, f, p[1], S.SINE, 0.0, 1e9, 0.0)
	var n := S.noise(l + 0.25, S.PINK)
	S.biquad(n, S.BP, 900.0, 0.7)
	var loop := S.loop_fold(n, 0.25)
	S.normalize(loop, 0.0)
	S.am(loop, S.snap(26.0, l), 0.3)
	S.mix(b, loop, 0, 0.9)
	S.remove_dc(b)
	S.normalize(b, -26.0)
	return b


static func _loop_bike() -> PackedFloat32Array:
	var l := 2.0
	var b := S.silence(l)
	for p: Array in [[160.0, 1.0], [320.0, 0.4], [480.0, 0.15]]:
		var f := S.snap(p[0], l)
		S.tone(b, 0, l, f, f, p[1], S.SINE, 0.0, 1e9, 0.0)
	var n := S.noise(l + 0.25, S.WHITE)
	S.biquad(n, S.HP, 1000.0, 0.7)
	S.biquad(n, S.LP, 4000.0, 0.7)
	var loop := S.loop_fold(n, 0.25)
	S.normalize(loop, 0.0)
	S.mix(b, loop, 0, 0.12)
	var ticks := S.silence(l)
	for i in 12:
		S.mix_wrap(ticks, S.burst(0.03, S.BP, 1500.0, 1.0, 0.0005, 0.004), i * l / 12.0, 1.0)
	S.normalize(ticks, 0.0)
	S.mix(b, ticks, 0, 0.35)
	S.remove_dc(b)
	S.normalize(b, -24.0)
	return b


## A putt-putt engine: `rate` firing pulses a second (a whole number of them fits the loop).
static func _loop_engine(rate: float, thump: float, rumble: float, buzz: float, peak_db: float) -> PackedFloat32Array:
	var l := 2.0
	var b := S.silence(l)
	var count := int(rate * l)
	for i in count:
		var g := 0.75 + 0.25 * S.rnd()
		var puff := S.silence(0.12)
		S.tone(puff, 0, 0.1, thump, thump * 0.75, g, S.SINE, 0.002, 0.022, 0.02)
		_put(puff, S.burst(0.08, S.LP, rumble, 0.7, 0.001, 0.016), 0, g * 0.6)
		_put(puff, S.burst(0.03, S.BP, 1200.0, 0.8, 0.0005, 0.004), 0, g * 0.15)
		S.mix_wrap(b, puff, i * l / count, 1.0)
	var f := S.snap(buzz, l)
	var saw := S.silence(l)
	S.tone(saw, 0, l, f, f, 1.0, S.SAW, 0.0, 1e9, 0.0)
	S.biquad_loop(saw, S.LP, 700.0, 0.7)
	S.mix(b, saw, 0, 0.12)
	S.remove_dc(b)
	S.normalize(b, peak_db)
	return b


static func _loop_pump() -> PackedFloat32Array:
	var l := 2.0
	var b := S.silence(l)
	for p: Array in [[100.0, 1.0], [200.0, 0.3], [300.0, 0.1]]:
		var f := S.snap(p[0], l)
		S.tone(b, 0, l, f, f, p[1], S.SINE, 0.0, 1e9, 0.0)
	var n := S.noise(l + 0.25, S.PINK)
	S.biquad(n, S.BP, 500.0, 0.8)
	var loop := S.loop_fold(n, 0.25)
	S.normalize(loop, 0.0)
	S.am(loop, S.snap(7.0, l), 0.5)
	S.mix(b, loop, 0, 0.5)
	S.remove_dc(b)
	S.normalize(b, -26.0)
	return b


static func _loop_boxfan() -> PackedFloat32Array:
	var l := 2.0
	var n := S.noise(l + 0.25, S.WHITE)
	S.biquad(n, S.BP, 700.0, 0.5)
	S.biquad(n, S.HP, 200.0, 0.7)
	var b := S.loop_fold(n, 0.25)
	S.normalize(b, 0.0)
	S.am(b, S.snap(22.0, l), 0.25)
	var hum := S.silence(l)
	var f := S.snap(88.0, l)
	S.tone(hum, 0, l, f, f, 1.0, S.SINE, 0.0, 1e9, 0.0)
	S.mix(b, hum, 0, 0.15)
	S.remove_dc(b)
	S.normalize(b, -24.0)
	return b


static func _loop_aircon() -> PackedFloat32Array:
	var l := 2.0
	var b := S.silence(l)
	var f := S.snap(110.0, l)
	S.tone(b, 0, l, f, f, 0.5, S.TRI, 0.0, 1e9, 0.0)
	S.tone(b, 0, l, f * 2.0, f * 2.0, 0.2, S.SINE, 0.0, 1e9, 0.0)
	var n := S.noise(l + 0.25, S.PINK)
	S.biquad(n, S.BP, 700.0, 0.5)
	var loop := S.loop_fold(n, 0.25)
	S.normalize(loop, 0.0)
	S.mix(b, loop, 0, 0.7)
	S.am(b, 1.0 / l, 0.12)
	S.remove_dc(b)
	S.normalize(b, -24.0)
	return b


static func _loop_strip() -> PackedFloat32Array:
	var l := 1.0
	var b := S.silence(l)
	for p: Array in [[50.0, 1.0], [100.0, 0.5], [150.0, 0.35], [250.0, 0.12]]:
		S.tone(b, 0, l, p[0], p[0], p[1], S.SINE, 0.0, 1e9, 0.0)
	S.normalize(b, -32.0)
	return b


static func _loop_fire() -> PackedFloat32Array:
	var l := 3.0
	var n := S.noise(l + 0.3, S.BROWN)
	S.biquad(n, S.LP, 600.0, 0.7)
	S.modulate(n, S.wander(l + 0.3, 3.0), 0.5)
	var crackles := S.silence(l + 0.3)
	for i in 120:
		var g := 0.15 + pow(S.rnd(), 3.0) * 0.85
		_put(crackles, S.burst(0.02, S.HP, 1500.0 + S.rnd() * 2500.0, 0.7, 0.0003, 0.002 + S.rnd() * 0.006), S.rnd() * l, g)
	S.normalize(n, 0.0)
	S.mix(n, crackles, 0, 0.7)
	var b := S.loop_fold(n, 0.3)
	S.remove_dc(b)
	S.normalize(b, -18.0)
	return b


# --- loops: weather and ambience -----------------------------------------------------------------------

static func _rain(roof: bool) -> PackedFloat32Array:
	var l := 3.0
	var n := S.noise(l + 0.4, S.PINK)
	if roof:
		S.biquad(n, S.HP, 150.0, 0.7)
		S.biquad(n, S.LP, 1300.0, 0.7)
	else:
		S.biquad(n, S.HP, 500.0, 0.7)
		S.biquad(n, S.LP, 7000.0, 0.7)
	S.normalize(n, 0.0)
	var patter := S.silence(l + 0.4)
	var drops := 90 if roof else 220
	for i in drops:
		var g := 0.2 + S.rnd() * 0.8
		var t := S.rnd() * l
		if roof:
			S.tone(patter, t, 0.03, 700.0 + S.rnd() * 900.0, 600.0, g * 0.6, S.SINE, 0.0005, 0.006, 0.005)
		else:
			_put(patter, S.burst(0.012, S.BP, 3000.0 + S.rnd() * 3000.0, 1.5, 0.0003, 0.003), t, g * 0.5)
	S.mix(n, patter, 0, 0.5)
	var b := S.loop_fold(n, 0.4)
	S.remove_dc(b)
	S.normalize(b, -18.0)
	return b


static func _amb_out() -> PackedFloat32Array:
	var l := 6.0
	var n := S.noise(l + 0.6, S.BROWN)
	S.biquad(n, S.LP, 380.0, 0.7)
	S.normalize(n, 0.0)
	var leaves := S.noise(l + 0.6, S.PINK)
	S.biquad(leaves, S.BP, 900.0, 0.6)
	S.normalize(leaves, 0.0)
	S.modulate(leaves, S.wander(l + 0.6, 0.35), 0.8)
	S.mix(n, leaves, 0, 0.4)
	S.modulate(n, S.wander(l + 0.6, 0.25), 0.4)
	var b := S.loop_fold(n, 0.6)
	S.remove_dc(b)
	S.normalize(b, -25.0)
	return b


static func _amb_in() -> PackedFloat32Array:
	var l := 4.0
	var n := S.noise(l + 0.5, S.BROWN)
	S.biquad(n, S.LP, 220.0, 0.7)
	S.normalize(n, 0.0)
	var b := S.loop_fold(n, 0.5)
	var hum := S.silence(l)
	S.tone(hum, 0, l, 56.0, 56.0, 1.0, S.SINE, 0.0, 1e9, 0.0)
	S.tone(hum, 0, l, 112.0, 112.0, 0.35, S.SINE, 0.0, 1e9, 0.0)
	S.mix(b, hum, 0, 0.5)
	S.remove_dc(b)
	S.normalize(b, -28.0)
	return b
