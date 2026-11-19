shader_type spatial;
// Window glass: slightly tinted, nearly clear head-on and mirror-like at grazing angles.
render_mode blend_mix, depth_draw_opaque, cull_back;

#include "res://shaders/noise.gdshaderinc"

uniform vec4 tint : source_color = vec4(0.7, 0.86, 0.95, 0.3);
uniform bool use_instance_color = false;

void fragment() {
	vec4 c = tint;
	if (use_instance_color) {
		c = vec4(srgb_to_lin(COLOR.rgb), COLOR.a);
	}
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	ALBEDO = c.rgb;
	ALPHA = clamp(c.a + fres * 0.6, 0.0, 0.95);
	ROUGHNESS = 0.02;
	SPECULAR = 1.0;
	METALLIC = 0.0;
}
