// Shared helpers for the procedural surfaces: cheap noise (pure functions of position, so
// host and clients agree) and a derivative based bump mapper.

float h21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm3(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 3; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + 17.1;
		a *= 0.5;
	}
	return s / 0.875;
}

vec3 srgb_to_lin(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// Perturbs a view space normal by the screen space gradient of a height field `h` (metres).
vec3 bump_normal(vec3 n, vec3 pos, float h, float strength) {
	vec3 dp1 = dFdx(pos);
	vec3 dp2 = dFdy(pos);
	float dh1 = dFdx(h);
	float dh2 = dFdy(h);
	vec3 r1 = cross(dp2, n);
	vec3 r2 = cross(n, dp1);
	float det = dot(dp1, r1);
	vec3 g = sign(det) * (dh1 * r1 + dh2 * r2);
	return normalize(abs(det) * n - strength * g);
}
