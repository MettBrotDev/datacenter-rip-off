extends RefCounted
## DSP toolbox for the synthesised sound bank (see sound_bank.gd and sound.gd).
## Every buffer is a PackedFloat32Array of mono samples at SR. Nothing here touches the audio server,
## so all of it runs headless and on a worker thread.

const SR := 22050
const SINE := 0
const TRI := 1
const SAW := 2
const SQUARE := 3
const WHITE := 0
const PINK := 1
const BROWN := 2
const LP := 0
const HP := 1
const BP := 2

static var _rng := RandomNumberGenerator.new()


# --- randomness ------------------------------------------------------------------------------

static func seed_with(text: String) -> void:
	_rng.seed = hash(text)


static func rnd() -> float:
	return _rng.randf()


static func rnd_range(lo: float, hi: float) -> float:
	return _rng.randf_range(lo, hi)


# --- buffers ---------------------------------------------------------------------------------

static func silence(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(maxi(int(seconds * SR), 1))
	return b


## Adds `src` into `dst` starting at t0 seconds, scaled by `gain`. Anything past the end is dropped.
static func mix(dst: PackedFloat32Array, src: PackedFloat32Array, t0: float, gain := 1.0) -> void:
	var start := int(t0 * SR)
	var n := mini(src.size(), dst.size() - start)
	for i in n:
		dst[start + i] += src[i] * gain


## Same, but whatever runs past the end wraps round to the start: the buffer stays a seamless loop.
static func mix_wrap(dst: PackedFloat32Array, src: PackedFloat32Array, t0: float, gain := 1.0) -> void:
	var size := dst.size()
	var start := int(t0 * SR)
	for i in src.size():
		dst[(start + i) % size] += src[i] * gain


static func gain(b: PackedFloat32Array, g: float) -> void:
	for i in b.size():
		b[i] *= g


static func peak(b: PackedFloat32Array) -> float:
	var p := 0.0
	for i in b.size():
		p = maxf(p, absf(b[i]))
	return p


## Scales the buffer so its peak sits at `db` dBFS.
static func normalize(b: PackedFloat32Array, db: float) -> void:
	var p := peak(b)
	if p > 0.00001:
		gain(b, db_to_linear(db) / p)


static func remove_dc(b: PackedFloat32Array) -> void:
	var sum := 0.0
	for i in b.size():
		sum += b[i]
	var mean := sum / maxf(b.size(), 1.0)
	for i in b.size():
		b[i] -= mean


## Short linear fades so a one-shot never clicks at either end.
static func fade_edges(b: PackedFloat32Array, fade_in := 0.002, fade_out := 0.006) -> void:
	var n := b.size()
	var fi := mini(int(fade_in * SR), n)
	var fo := mini(int(fade_out * SR), n)
	for i in fi:
		b[i] *= float(i) / fi
	for i in fo:
		b[n - 1 - i] *= float(i) / fo


## A snapped frequency has a whole number of cycles in `length` seconds, so a loop of that length is seamless.
static func snap(freq: float, length: float) -> float:
	return maxf(roundf(freq * length), 1.0) / length


## Makes `x` (length L + C samples) into a seamless loop of length L by crossfading the C-sample overhang.
static func loop_fold(x: PackedFloat32Array, fold_seconds: float) -> PackedFloat32Array:
	var c := int(fold_seconds * SR)
	var l := x.size() - c
	var out := PackedFloat32Array()
	out.resize(l)
	for i in l:
		out[i] = x[i]
	for i in c:
		var w := float(i) / c
		var a := cos(w * PI * 0.5)   # equal power
		var b := sin(w * PI * 0.5)
		out[i] = x[i] * b + x[l + i] * a
	return out


# --- oscillators -----------------------------------------------------------------------------

static func _blep(t: float, dt: float) -> float:
	if t < dt:
		var x := t / dt
		return x + x - x * x - 1.0
	if t > 1.0 - dt:
		var x := (t - 1.0) / dt
		return x * x + x + x + 1.0
	return 0.0


## Adds one tone: frequency glides exponentially f0 -> f1 over `dur`. The envelope is a linear attack, an
## exponential decay with time constant `decay` and a linear release over the last `release` seconds.
## `vib` is the vibrato depth as a fraction of the frequency.
static func tone(b: PackedFloat32Array, t0: float, dur: float, f0: float, f1: float, amp := 1.0, wave := SINE,
		attack := 0.003, decay := 1e9, release := 0.01, vib := 0.0, vib_hz := 5.5) -> void:
	var n0 := int(t0 * SR)
	var n := int(dur * SR)
	var size := b.size()
	var ph := 0.0
	var glide := f0 != f1
	var lr := log(f1 / f0) if glide else 0.0
	var dmul := exp(-1.0 / (decay * SR)) if decay < 1e8 else 1.0
	var dec := 1.0
	var a_n := attack * SR
	var r_n := release * SR
	for i in n:
		var idx := n0 + i
		if idx >= size:
			break
		if idx < 0:
			continue
		var f := f0 * exp(lr * float(i) / n) if glide else f0
		if vib != 0.0:
			f *= 1.0 + vib * sin(TAU * vib_hz * float(i) / SR)
		var dt := f / SR
		ph += dt
		if ph >= 1.0:
			ph -= 1.0
		var v := 0.0
		if wave == SINE:
			v = sin(TAU * ph)
		elif wave == TRI:
			v = 1.0 - 4.0 * absf(ph - 0.5)
		elif wave == SAW:
			v = 2.0 * ph - 1.0 - _blep(ph, dt)
		else:
			v = (1.0 if ph < 0.5 else -1.0) + _blep(ph, dt) - _blep(fposmod(ph + 0.5, 1.0), dt)
		var e := dec
		dec *= dmul
		if i < a_n and a_n >= 1.0:
			e *= float(i) / a_n
		var left := n - i
		if left < r_n and r_n >= 1.0:
			e *= float(left) / r_n
		b[idx] += v * e * amp


## Two-operator FM note: carrier fc, modulator fc * ratio, modulation index decaying with time constant `idx_decay`.
static func fm(b: PackedFloat32Array, t0: float, dur: float, fc: float, ratio: float, index: float, idx_decay: float,
		amp := 1.0, attack := 0.002, decay := 0.2, release := 0.01) -> void:
	var n0 := int(t0 * SR)
	var n := int(dur * SR)
	var size := b.size()
	var wc := TAU * fc / SR
	var wm := TAU * fc * ratio / SR
	var dmul := exp(-1.0 / (decay * SR))
	var imul := exp(-1.0 / (idx_decay * SR))
	var dec := 1.0
	var idec := index
	var a_n := attack * SR
	var r_n := release * SR
	for i in n:
		var idx := n0 + i
		if idx >= size:
			break
		var v := sin(wc * i + idec * sin(wm * i))
		var e := dec
		dec *= dmul
		idec *= imul
		if i < a_n and a_n >= 1.0:
			e *= float(i) / a_n
		var left := n - i
		if left < r_n and r_n >= 1.0:
			e *= float(left) / r_n
		b[idx] += v * e * amp


## A marimba-like mallet note: fundamental plus the bar's 4x and 10x partials, each dying faster than the last.
static func mallet(b: PackedFloat32Array, t0: float, f: float, amp := 1.0, decay := 0.25) -> void:
	var dur := decay * 5.0
	tone(b, t0, dur, f, f, amp, SINE, 0.002, decay, 0.02)
	tone(b, t0, dur * 0.5, f * 4.0, f * 4.0, amp * 0.22, SINE, 0.001, decay * 0.3, 0.01)
	tone(b, t0, dur * 0.3, f * 10.0, f * 10.0, amp * 0.05, SINE, 0.001, decay * 0.1, 0.01)


## A soft electric-piano note (FM, tine decaying faster than the body).
static func epiano(b: PackedFloat32Array, t0: float, f: float, amp := 1.0, decay := 0.6) -> void:
	var dur := decay * 4.5
	fm(b, t0, dur, f, 1.0, 1.1, decay * 0.25, amp, 0.004, decay, 0.05)
	fm(b, t0, dur * 0.5, f * 2.0, 14.0, 0.5, decay * 0.04, amp * 0.07, 0.001, decay * 0.25, 0.02)


## A bell: inharmonic FM, a little glassy.
static func bell(b: PackedFloat32Array, t0: float, f: float, amp := 1.0, decay := 0.35, ratio := 3.5, index := 1.6) -> void:
	fm(b, t0, decay * 5.0, f, ratio, index, decay * 0.4, amp, 0.001, decay, 0.02)


## Soft, slightly detuned saw pad note with a one-pole low-pass applied by the caller.
static func pad(b: PackedFloat32Array, t0: float, dur: float, f: float, amp := 1.0, attack := 0.4, release := 0.6) -> void:
	for d: float in [-0.004, 0.0, 0.004]:
		tone(b, t0, dur, f * (1.0 + d), f * (1.0 + d), amp * 0.33, SAW, attack, 1e9, release)
	tone(b, t0, dur, f * 0.5, f * 0.5, amp * 0.3, SINE, attack, 1e9, release)


# --- noise -----------------------------------------------------------------------------------

## `seconds` of noise (peak roughly 1) with an attack and an exponential decay.
static func noise(seconds: float, color := WHITE, attack := 0.001, decay := 1e9, release := 0.004) -> PackedFloat32Array:
	var n := maxi(int(seconds * SR), 1)
	var b := PackedFloat32Array()
	b.resize(n)
	var p0 := 0.0
	var p1 := 0.0
	var p2 := 0.0
	var brown := 0.0
	var dmul := exp(-1.0 / (decay * SR)) if decay < 1e8 else 1.0
	var dec := 1.0
	var a_n := attack * SR
	var r_n := release * SR
	for i in n:
		var w := _rng.randf() * 2.0 - 1.0
		var v := w
		if color == PINK:
			p0 = 0.99765 * p0 + w * 0.099046
			p1 = 0.963 * p1 + w * 0.2965164
			p2 = 0.57 * p2 + w * 1.0526913
			v = (p0 + p1 + p2 + w * 0.1848) * 0.25
		elif color == BROWN:
			brown = (brown + 0.02 * w) / 1.02
			v = brown * 3.5
		var e := dec
		dec *= dmul
		if i < a_n and a_n >= 1.0:
			e *= float(i) / a_n
		var left := n - i
		if left < r_n and r_n >= 1.0:
			e *= float(left) / r_n
		b[i] = v * e
	return b


## A noise burst filtered right away: the building block of clicks, taps and swishes.
static func burst(seconds: float, kind: int, freq: float, q := 0.8, attack := 0.001, decay := 0.01, color := WHITE) -> PackedFloat32Array:
	var b := noise(seconds, color, attack, decay, 0.002)
	biquad(b, kind, freq, q)
	return b


## Slowly wandering control signal in 0..1 (low-passed noise), for flutter and gurgle.
static func wander(seconds: float, rate_hz: float) -> PackedFloat32Array:
	var n := maxi(int(seconds * SR), 1)
	var b := PackedFloat32Array()
	b.resize(n)
	var k := 1.0 - exp(-TAU * rate_hz / SR)
	var y := 0.5
	var z := 0.5
	for i in n:
		y += (_rng.randf() - y) * k
		z += (y - z) * k
		b[i] = z
	# stretch to 0..1
	var lo := 1.0
	var hi := 0.0
	for i in n:
		lo = minf(lo, b[i])
		hi = maxf(hi, b[i])
	var span := maxf(hi - lo, 0.0001)
	for i in n:
		b[i] = (b[i] - lo) / span
	return b


# --- filters ---------------------------------------------------------------------------------

## RBJ biquad. `f1` > 0 sweeps the cutoff exponentially from f0 to f1 over the buffer.
static func biquad(b: PackedFloat32Array, kind: int, f0: float, q := 0.707, f1 := -1.0) -> void:
	var n := b.size()
	var z1 := 0.0
	var z2 := 0.0
	var b0 := 0.0
	var b1 := 0.0
	var b2 := 0.0
	var a1 := 0.0
	var a2 := 0.0
	var sweep := f1 > 0.0 and f1 != f0
	var lr := log(f1 / f0) if sweep else 0.0
	for i in n:
		if i % 16 == 0 or i == 0:
			var f := f0 * exp(lr * float(i) / n) if sweep else f0
			f = clampf(f, 20.0, SR * 0.45)
			var w := TAU * f / SR
			var cw := cos(w)
			var alpha := sin(w) / (2.0 * q)
			var a0 := 1.0 + alpha
			if kind == LP:
				b0 = (1.0 - cw) * 0.5 / a0
				b1 = (1.0 - cw) / a0
				b2 = b0
			elif kind == HP:
				b0 = (1.0 + cw) * 0.5 / a0
				b1 = -(1.0 + cw) / a0
				b2 = b0
			else:
				b0 = alpha / a0
				b1 = 0.0
				b2 = -alpha / a0
			a1 = -2.0 * cw / a0
			a2 = (1.0 - alpha) / a0
		var x := b[i]
		var y := b0 * x + z1
		z1 = b1 * x - a1 * y + z2
		z2 = b2 * x - a2 * y
		b[i] = y


## Same filter for a buffer that loops: runs it round twice and keeps the second pass, so there is no start-up
## transient and the loop point stays seamless.
static func biquad_loop(b: PackedFloat32Array, kind: int, f0: float, q := 0.707) -> void:
	var n := b.size()
	var twice := PackedFloat32Array()
	twice.resize(n * 2)
	for i in n:
		twice[i] = b[i]
		twice[n + i] = b[i]
	biquad(twice, kind, f0, q)
	for i in n:
		b[i] = twice[n + i]


static func lp1(b: PackedFloat32Array, fc: float) -> void:
	var k := 1.0 - exp(-TAU * fc / SR)
	var y := 0.0
	for i in b.size():
		y += (b[i] - y) * k
		b[i] = y


static func hp1(b: PackedFloat32Array, fc: float) -> void:
	var k := 1.0 - exp(-TAU * fc / SR)
	var y := 0.0
	for i in b.size():
		y += (b[i] - y) * k
		b[i] -= y


# --- shaping ---------------------------------------------------------------------------------

## Multiplies by an envelope: linear attack, exponential decay, linear release.
static func shape(b: PackedFloat32Array, attack: float, decay := 1e9, release := 0.005) -> void:
	var n := b.size()
	var dmul := exp(-1.0 / (decay * SR)) if decay < 1e8 else 1.0
	var dec := 1.0
	var a_n := attack * SR
	var r_n := release * SR
	for i in n:
		var e := dec
		dec *= dmul
		if i < a_n and a_n >= 1.0:
			e *= float(i) / a_n
		var left := n - i
		if left < r_n and r_n >= 1.0:
			e *= float(left) / r_n
		b[i] *= e


## Tremolo: amplitude * (1 - depth + depth * (0.5 + 0.5 sin)).
static func am(b: PackedFloat32Array, rate_hz: float, depth: float, phase := 0.0) -> void:
	var w := TAU * rate_hz / SR
	for i in b.size():
		b[i] *= 1.0 - depth + depth * (0.5 + 0.5 * sin(w * i + phase))


static func modulate(b: PackedFloat32Array, control: PackedFloat32Array, depth: float) -> void:
	var m := mini(b.size(), control.size())
	for i in m:
		b[i] *= 1.0 - depth + depth * control[i]


static func softclip(b: PackedFloat32Array, drive: float) -> void:
	var norm := 1.0 / tanh(drive)
	for i in b.size():
		b[i] = tanh(b[i] * drive) * norm


## Pads the buffer with silence (room for a reverb tail).
static func extend(b: PackedFloat32Array, seconds: float) -> void:
	b.resize(b.size() + int(seconds * SR))


## A small Schroeder reverb (four damped combs, two all-passes). `wet` is the share added to the dry sound.
## Extend the buffer first if the tail should ring out.
static func reverb(b: PackedFloat32Array, wet := 0.25, decay := 0.78, size := 1.0, damp := 0.35) -> void:
	var n := b.size()
	var combs := [1116, 1188, 1277, 1356]
	var out := PackedFloat32Array()
	out.resize(n)
	for d: int in combs:
		var delay := maxi(int(d * size * SR / 44100.0), 8)
		var line := PackedFloat32Array()
		line.resize(delay)
		var pos := 0
		var lp := 0.0
		for i in n:
			var y := line[pos]
			lp += (y - lp) * (1.0 - damp)
			line[pos] = b[i] + lp * decay
			pos += 1
			if pos >= delay:
				pos = 0
			out[i] += y * 0.25
	for d: int in [225, 556]:
		var delay := maxi(int(d * size * SR / 44100.0), 4)
		var line := PackedFloat32Array()
		line.resize(delay)
		var pos := 0
		for i in n:
			var buf := line[pos]
			var x := out[i]
			var y := -x + buf
			line[pos] = x + buf * 0.5
			out[i] = y
			pos += 1
			if pos >= delay:
				pos = 0
	for i in n:
		b[i] += out[i] * wet


## Circular version for music loops: runs the signal through twice and keeps the second pass, so the tail
## of the last notes rings into the start of the loop.
static func reverb_loop(b: PackedFloat32Array, wet := 0.25, decay := 0.78, size := 1.0) -> void:
	var n := b.size()
	var twice := PackedFloat32Array()
	twice.resize(n * 2)
	for i in n:
		twice[i] = b[i]
		twice[n + i] = b[i]
	reverb(twice, 1.0, decay, size)
	for i in n:
		b[i] += (twice[n + i] - b[i]) * wet


# --- output ----------------------------------------------------------------------------------

static func to_stream(b: PackedFloat32Array, looped := false) -> AudioStreamWAV:
	var n := b.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, clampi(int(roundf(b[i] * 32767.0)), -32768, 32767))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = SR
	s.stereo = false
	s.data = bytes
	if looped:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = n
	return s


## Reads a stream made by to_stream back into floats (used by the analysis).
static func from_stream(s: AudioStreamWAV) -> PackedFloat32Array:
	var bytes := s.data
	var n := bytes.size() / 2
	var b := PackedFloat32Array()
	b.resize(n)
	for i in n:
		b[i] = bytes.decode_s16(i * 2) / 32768.0
	return b


# --- analysis (soundcheck) -------------------------------------------------------------------

static func rms(b: PackedFloat32Array) -> float:
	var sum := 0.0
	for i in b.size():
		sum += b[i] * b[i]
	return sqrt(sum / maxf(b.size(), 1.0))


static func mean(b: PackedFloat32Array) -> float:
	var sum := 0.0
	for i in b.size():
		sum += b[i]
	return sum / maxf(b.size(), 1.0)


## The jump across the loop point compared with the ordinary sample-to-sample step: <= 1 means inaudible.
static func loop_jump(b: PackedFloat32Array) -> Array:
	var n := b.size()
	var step := 0.0
	for i in n - 1:
		step += absf(b[i + 1] - b[i])
	step /= maxf(n - 1.0, 1.0)
	var jump := absf(b[0] - b[n - 1])
	return [jump, jump / maxf(step, 0.000001)]


## Spectral centroid in Hz over the whole sound (Hann windows of 1024 samples, averaged power).
static func centroid(b: PackedFloat32Array) -> float:
	const N := 1024
	var n := b.size()
	var power := PackedFloat32Array()
	power.resize(N / 2)
	var frames := 0
	var hop := maxi((n - N) / 24, N / 2) if n > N else N
	var start := 0
	while start + N <= n or (start == 0 and n < N):
		var re := PackedFloat32Array()
		var im := PackedFloat32Array()
		re.resize(N)
		im.resize(N)
		for i in N:
			var x := b[start + i] if start + i < n else 0.0
			re[i] = x * (0.5 - 0.5 * cos(TAU * i / N))
		_fft(re, im)
		for k in N / 2:
			power[k] += re[k] * re[k] + im[k] * im[k]
		frames += 1
		start += hop
		if frames >= 28:
			break
	var num := 0.0
	var den := 0.0
	for k in range(2, N / 2):   # skip the lowest bins (DC and rumble leakage)
		var f := float(k) * SR / N
		num += f * power[k]
		den += power[k]
	return num / den if den > 1e-12 else 0.0


static func _fft(re: PackedFloat32Array, im: PackedFloat32Array) -> void:
	var n := re.size()
	var j := 0
	for i in range(1, n):
		var bit := n >> 1
		while j & bit:
			j ^= bit
			bit >>= 1
		j ^= bit
		if i < j:
			var t := re[i]
			re[i] = re[j]
			re[j] = t
			t = im[i]
			im[i] = im[j]
			im[j] = t
	var blk := 2
	while blk <= n:
		var ang := -TAU / blk
		var wr := cos(ang)
		var wi := sin(ang)
		var i := 0
		while i < n:
			var cr := 1.0
			var ci := 0.0
			for k in blk / 2:
				var ur := re[i + k]
				var ui := im[i + k]
				var vr := re[i + k + blk / 2] * cr - im[i + k + blk / 2] * ci
				var vi := re[i + k + blk / 2] * ci + im[i + k + blk / 2] * cr
				re[i + k] = ur + vr
				im[i + k] = ui + vi
				re[i + k + blk / 2] = ur - vr
				im[i + k + blk / 2] = ui - vi
				var nr := cr * wr - ci * wi
				ci = cr * wi + ci * wr
				cr = nr
			i += blk
		blk <<= 1
