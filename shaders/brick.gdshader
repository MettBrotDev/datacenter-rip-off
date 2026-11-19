shader_type spatial;
// Procedural brick wall, mapped in world space so every box lines up.
uniform vec3 brick_color : source_color = vec3(0.42, 0.15, 0.10);
uniform vec3 mortar_color : source_color = vec3(0.46, 0.42, 0.38);
uniform vec2 brick_size = vec2(0.26, 0.085);
uniform float mortar = 0.012;
varying vec3 wpos;
varying vec3 wnrm;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

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
	vec2 m = vec2(mortar) / brick_size;
	float b = step(m.x, f.x) * step(f.x, 1.0 - m.x) * step(m.y, f.y) * step(f.y, 1.0 - m.y);
	vec3 col = brick_color * (0.78 + 0.44 * hash(id));
	ALBEDO = mix(mortar_color, col, b);
	ROUGHNESS = 0.92;
}
