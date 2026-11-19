shader_type spatial;
// Procedural brick wall, mapped in world space so every box lines up. Bricks are slightly
// domed, the mortar is recessed (real depth through bump mapping), every brick has its own tone
// and the whole wall carries soft dirt. Far away it fades to its average colour instead of
// shimmering.

#include "res://shaders/noise.gdshaderinc"

uniform vec3 brick_color : source_color = vec3(0.42, 0.15, 0.10);
uniform vec3 mortar_color : source_color = vec3(0.46, 0.42, 0.38);
uniform vec2 brick_size = vec2(0.26, 0.085);
uniform float mortar = 0.012;
varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	vec3 n = abs(wnrm);
	vec2 uv = n.x > 0.5 ? wpos.zy : (n.z > 0.5 ? wpos.xy : wpos.xz);
	vec2 g = uv / brick_size;
	g.x += mod(floor(g.y), 2.0) * 0.5;
	vec2 id = floor(g);
	vec2 f = fract(g);
	float lod = smoothstep(0.07, 0.24, max(fwidth(g.x), fwidth(g.y)));
	// distance to the nearest brick edge, in metres
	vec2 e = min(f, 1.0 - f) * brick_size;
	float edge = min(e.x, e.y);
	float body = smoothstep(mortar * 0.5, mortar * 0.5 + 0.007, edge);   // 0 in the joint, 1 on the brick
	float tone = h21(id);
	vec3 col = brick_color * (0.72 + 0.5 * tone);
	col = mix(col, col * vec3(1.15, 0.95, 0.85), step(0.85, h21(id + 7.0)) * 0.6);   // the odd burnt brick
	vec2 q = uv * 38.0;
	float pits = vnoise(q + id * 5.0);
	col *= 0.86 + 0.28 * pits;
	float dirt = fbm3(uv * 1.7 + 3.0);
	col *= 0.78 + 0.34 * dirt;
	col *= mix(0.7, 1.0, smoothstep(0.0, 0.55, wpos.y));   // damp and splash at the foot of the wall
	vec3 mort = mortar_color * (0.82 + 0.3 * vnoise(uv * 90.0)) * (0.8 + 0.3 * dirt);
	vec3 avg = mix(mortar_color * 0.8, col, 0.86);
	vec3 shaded = mix(mort, col * mix(0.82, 1.0, smoothstep(0.0, 0.012, edge)), body);
	ALBEDO = mix(shaded, avg, lod);
	float dome = smoothstep(0.0, 0.03, edge);
	float h = body * (0.004 + 0.003 * dome + 0.0015 * pits);
	float dist = length(VERTEX);
	NORMAL = bump_normal(NORMAL, VERTEX, h, (1.0 - lod) * (1.0 - smoothstep(10.0, 30.0, dist)));
	ROUGHNESS = mix(0.97, 0.84 - 0.1 * pits, body);
	SPECULAR = 0.35;
}
