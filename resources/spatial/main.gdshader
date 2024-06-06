shader_type spatial;
render_mode unshaded;

uniform sampler2D render_texture : source_color;

void vertex() {
	POSITION = vec4(VERTEX, 1.0);
}

void fragment() {
	vec4 col = texture(render_texture, SCREEN_UV);
	col.rgb = mix(pow((col.rgb + 0.055) * (1.0 / (1.0 + 0.055)), vec3(2.4)), col.rgb * (1.0 / 12.92), lessThan(col.rgb, vec3(0.04045)));
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
