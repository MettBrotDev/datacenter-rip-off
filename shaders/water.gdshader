shader_type spatial;
// Pond and fountain water: the instance colour gives the shallow tint, the middle of every
// disc is deeper, tiny wind ripples drift across it and the sky shows in it at grazing angles.

#include "res://shaders/noise.gdshaderinc"

uniform float ripple = 1.0;
varying vec3 wp;
varying vec3 lp;

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	lp = VERTEX;
}

float waves(vec2 p, float t) {
	float a = vnoise(p * 3.1 + vec2(t * 0.35, t * 0.2));
	float b = vnoise(p * 6.7 - vec2(t * 0.28, -t * 0.4) + 4.0);
	float c = sin(p.x * 2.3 + p.y * 1.7 + t * 1.3) * 0.5 + 0.5;
	return a * 0.5 + b * 0.3 + c * 0.2;
}

void fragment() {
	vec3 shallow = srgb_to_lin(COLOR.rgb);
	float r = clamp(length(lp.xz) / 0.5, 0.0, 1.0);
	float depth = 1.0 - smoothstep(0.55, 1.0, r);
	float flat_top = step(0.7, normalize(mat3(INV_VIEW_MATRIX) * NORMAL).y);
	vec3 deep = shallow * vec3(0.35, 0.55, 0.75);
	vec3 col = mix(shallow, deep, depth * 0.85 * flat_top);
	float h = waves(wp.xz, TIME) * 0.012 * ripple;
	NORMAL = bump_normal(NORMAL, VERTEX, h, 1.0);
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	ALBEDO = col;
	ROUGHNESS = mix(0.06, 0.02, fres);
	SPECULAR = 0.9;
	EMISSION = col * 0.04;
}
