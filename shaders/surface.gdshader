shader_type spatial;
// One procedural surface shader for the whole world, switched by `mode`. Everything is mapped
// in world space (the world is built from scaled boxes with no UVs) and nothing reads a
// texture. `use_instance_color` makes it work on the MultiMeshes of outside.gd, where every
// object takes its colour from the per-instance colour.
//
//  0 plain   1 grass   2 asphalt   3 slabs (sidewalk, paving)   4 wood   5 plaster
//  6 roof tiles   7 foliage   8 road paint   9 poured concrete

#include "res://shaders/noise.gdshaderinc"

uniform int mode = 0;
uniform vec4 albedo : source_color = vec4(1.0);
uniform bool use_instance_color = false;
uniform vec3 grain_axis = vec3(0.0, 0.0, 1.0);   // wood: the direction the grain runs along
uniform float plank = 0.0;                        // wood: board width in metres (0 = none)
uniform float detail = 1.0;                       // scales the bump and the colour breakup
uniform float floor_y = 0.0;
global uniform float indoor;   // 0 outside, 1 under a roof (weather.gd)

varying vec3 wp;
varying vec3 wn;
varying vec3 lp;

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wn = normalize(mat3(MODEL_MATRIX) * NORMAL);
	lp = VERTEX;
}

// Picks the planar projection that suits the face this pixel is on.
vec2 tri_uv(vec3 p, vec3 n) {
	vec3 a = abs(n);
	if (a.y > 0.6) {
		return p.xz;
	}
	return a.x > a.z ? vec2(p.z, p.y) : vec2(p.x, p.y);
}

void fragment() {
	vec3 col = albedo.rgb;
	if (use_instance_color) {
		col *= srgb_to_lin(COLOR.rgb);
	}
	float dist = length(VERTEX);
	float fade = (1.0 - smoothstep(10.0, 40.0, dist)) * detail;
	vec2 tp = tri_uv(wp, wn);
	float h = 0.0;
	float bump = 1.0;
	float rough = 0.8;
	float spec = 0.5;
	float up = abs(wn.y);

	if (mode == 0) {
		float n = vnoise(tp * 5.0);
		col *= 0.95 + 0.1 * n * detail;
		col *= mix(0.8, 1.0, smoothstep(0.0, 0.45, wp.y - floor_y));   // grime at the foot of things
		rough = 0.75;
	} else if (mode == 1) {
		vec2 g = wp.xz;
		float macro = fbm3(g * 0.07);
		float mid = vnoise(g * 0.9);
		float fine = vnoise(g * 38.0);
		col *= 0.84 + 0.3 * macro;
		col = mix(col, col * vec3(1.18, 1.04, 0.62), smoothstep(0.58, 0.82, fbm3(g * 0.21 + 9.0)) * 0.7);   // dry patches
		col *= 0.9 + 0.2 * mid;
		col *= 1.0 - fade * 0.16 * (fine - 0.5);
		col *= 1.0 + 0.04 * sin(g.x * 1.3) * smoothstep(0.55, 0.7, macro);   // faint mowing stripes
		h = fine * 0.012 + mid * 0.012;
		bump = fade * 0.5;
		rough = 0.95;
		spec = 0.3;
	} else if (mode == 2) {
		float macro = fbm3(tp * 0.22);
		float grain = h21(floor(tp * 140.0));
		float stones = h21(floor(tp * 45.0) + 3.0);
		col *= 0.88 + 0.22 * macro;
		col *= 1.0 - fade * 0.22 * (grain - 0.5);
		col += fade * 0.05 * step(0.93, stones);   // the odd pale chip of aggregate
		float crack = smoothstep(0.012, 0.0, abs(vnoise(tp * vec2(1.3, 0.9) + 4.0) - 0.5)) * step(0.62, fbm3(tp * 0.11));
		col *= 1.0 - 0.12 * crack;
		h = grain * 0.004;
		bump = fade;
		rough = 0.82 - 0.12 * smoothstep(0.55, 0.9, macro);
		spec = 0.4;
	} else if (mode == 3) {
		float size = 1.5;
		vec2 g = tp / size;
		vec2 id = floor(g);
		vec2 f = fract(g);
		float edge = min(min(f.x, 1.0 - f.x) * size, min(f.y, 1.0 - f.y) * size);
		float joint = 1.0 - smoothstep(0.006, 0.016, edge);
		col *= 0.93 + 0.1 * h21(id);
		col *= 0.9 + 0.2 * fbm3(tp * 0.6);
		col *= 1.0 - 0.1 * fade * (vnoise(tp * 60.0) - 0.5);
		col *= 1.0 - 0.3 * joint;
		h = -joint * 0.004 + vnoise(tp * 60.0) * 0.002;
		bump = 0.6 + 0.4 * fade;
		rough = 0.88;
		spec = 0.35;
	} else if (mode == 4) {
		vec3 ax = normalize(grain_axis);
		vec3 t = normalize(abs(ax.y) < 0.9 ? cross(ax, vec3(0.0, 1.0, 0.0)) : cross(ax, vec3(1.0, 0.0, 0.0)));
		vec3 b = cross(ax, t);
		float a = dot(wp, ax);
		float c1 = dot(wp, t);
		float c2 = dot(wp, b);
		float tilt = abs(dot(wn, t)) > abs(dot(wn, b)) ? c2 : c1;
		float across = tilt + (abs(dot(wn, t)) > abs(dot(wn, b)) ? c1 : c2) * 0.6;
		float seam = 0.0;
		float pid = 0.0;
		if (plank > 0.0) {
			float pc = across / plank;
			pid = floor(pc);
			seam = 1.0 - smoothstep(0.0015, 0.004, min(fract(pc), 1.0 - fract(pc)) * plank);
		}
		float warp = fbm3(vec2(a * 0.9 + pid * 7.0, across * 3.0));
		float rings = sin(across * 70.0 + warp * 9.0 + pid * 3.0);
		float streak = vnoise(vec2(a * 2.0 + pid * 13.0, across * 85.0));
		float tone = 0.86 + 0.28 * h21(vec2(pid, 3.0));
		col *= tone * (0.86 + 0.1 * rings + 0.2 * streak);
		col *= 1.0 - 0.55 * seam;
		h = (rings * 0.0006 + streak * 0.0008) * fade - seam * 0.002;
		bump = 1.0;
		rough = 0.62 - 0.12 * streak;
		spec = 0.45;
	} else if (mode == 5) {
		float macro = fbm3(tp * 1.1);
		float fine = vnoise(tp * 70.0);
		col *= 0.93 + 0.12 * macro;
		col *= mix(0.84, 1.0, smoothstep(0.0, 0.7, wp.y - floor_y));
		col *= 1.0 - fade * 0.04 * (fine - 0.5);
		h = fine * 0.0006;
		bump = fade;
		rough = 0.92;
		spec = 0.3;
	} else if (mode == 6) {
		vec3 hz = normalize(cross(wn, vec3(0.0, 1.0, 0.0)) + vec3(0.0001));
		vec3 dn = cross(hz, wn);
		vec2 g = vec2(dot(wp, hz) / 0.32, dot(wp, dn) / 0.2);
		float row = floor(g.y);
		g.x += mod(row, 2.0) * 0.5;
		vec2 id = vec2(floor(g.x), row);
		vec2 f = fract(g);
		float tone = h21(id);
		float lip = smoothstep(0.0, 0.28, f.y);
		float gap = (1.0 - smoothstep(0.02, 0.07, min(f.x, 1.0 - f.x)));
		col *= (0.82 + 0.3 * tone) * mix(0.55, 1.0, lip) * (1.0 - 0.3 * gap);
		col *= 0.92 + 0.12 * fbm3(wp.xz * 0.5 + wp.y * 0.3);
		h = (lip * 0.03 - gap * 0.01) * 0.5 + tone * 0.004;
		bump = 1.0;
		rough = 0.7;
		spec = 0.4;
	} else if (mode == 7) {
		vec2 q = vec2(wp.x + wp.y * 0.7, wp.z + wp.y * 1.3);
		float big = vnoise(q * 2.2);
		float mid = vnoise(q * 5.5 + 3.0);
		float fine = vnoise(q * 12.0 + 9.0);
		float clump = big * 0.5 + mid * 0.32 + fine * 0.18;
		col *= 0.7 + 0.55 * clump;
		float top = clamp(lp.y + 0.5, 0.0, 1.0);
		col *= mix(0.74, 1.12, top);                         // darker inside the crown, lit tips
		col = mix(col, col * vec3(1.12, 1.08, 0.7), smoothstep(0.6, 0.9, big) * 0.35);   // sun-bleached leaves
		h = (mid * 0.5 + fine * 0.3) * 0.05;
		bump = 0.3 * fade;
		rough = 0.78;
		spec = 0.35;
		RIM = 0.35;
		RIM_TINT = 0.6;
		BACKLIGHT = col * 0.3;
	} else if (mode == 8) {
		float wear = fbm3(tp * 6.0);
		col *= 0.82 + 0.2 * wear;
		col *= 1.0 - fade * 0.25 * step(0.82, h21(floor(tp * 60.0)));   // chipped paint
		h = wear * 0.001;
		bump = fade;
		rough = 0.62;
		spec = 0.5;
	} else {
		float macro = fbm3(tp * 0.45);
		float mid = fbm3(tp * 2.3 + 5.0);
		float sand = h21(floor(tp * 150.0));
		col *= 0.86 + 0.22 * macro;
		float stain = smoothstep(0.62, 0.78, fbm3(tp * 0.8 + 11.0));
		col *= 1.0 - 0.28 * stain;                              // oil and damp
		float trowel = vnoise(vec2(tp.x * 2.2 + tp.y * 0.7, tp.y * 26.0)) * vnoise(vec2(tp.y * 1.9 - tp.x * 0.5, tp.x * 24.0));
		col *= 0.96 + 0.1 * trowel * detail;
		col *= 1.0 - fade * 0.12 * (sand - 0.5);
		vec2 cut = abs(fract(tp / 3.0 + 0.5) - 0.5) * 3.0;     // saw cut control joints every 3 m
		float joint = 1.0 - smoothstep(0.004, 0.012, min(cut.x, cut.y));
		col *= 1.0 - 0.45 * joint;
		h = sand * 0.002 * fade - joint * 0.004 + trowel * 0.0015;
		bump = 1.0;
		rough = clamp(0.62 - 0.3 * stain + 0.3 * (1.0 - mid) - 0.1, 0.28, 0.92);   // sealed, slightly polished patches
		spec = 0.55;
	}

	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = spec * mix(1.0, 0.3, indoor);   // indoors the floor must not mirror the blue sky overhead
	NORMAL = bump_normal(NORMAL, VERTEX, h, bump);   // always runs: derivatives need uniform control flow
}
