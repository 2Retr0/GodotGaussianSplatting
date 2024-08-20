shader_type spatial;
render_mode unshaded, fog_disabled;

uniform sampler2D render_texture : source_color, filter_linear_mipmap_anisotropic;

// Source: https://gamedev.stackexchange.com/a/148088
vec3 srgb_to_linear(vec3 x) {
    vec3 higher = pow((x + 0.055) / 1.055, vec3(2.4));
    vec3 lower = x / 12.92;
	return mix(higher, lower, lessThan(x, vec3(0.04045)));
}

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	ALBEDO = srgb_to_linear(texture(render_texture, SCREEN_UV).rgb);
}
