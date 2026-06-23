shader_type spatial;

uniform vec4 base_color : source_color = vec4(0.3, 0.3, 0.3, 1.0);
uniform vec4 line_color : source_color = vec4(0.0, 0.0, 0.0, 0.35);
uniform float grid_size : hint_range(0.1, 10.0) = 1.0;
uniform float line_width : hint_range(0.001, 0.5) = 0.03;

vec2 _grid(vec3 p, vec2 fw) {
	vec2 g = abs(fract(p.xy - 0.5) - 0.5);
	return g / fw;
}

void fragment() {
	vec3 pos = VERTEX * grid_size;
	vec3 fw_vec = fwidth(pos);
	vec2 g1 = _grid(pos, fw_vec.xy);
	vec2 g2 = _grid(pos.yzx, fw_vec.yz);
	vec2 g3 = _grid(pos.zxy, fw_vec.zx);
	float m1 = min(g1.x, g1.y);
	float m2 = min(g2.x, g2.y);
	float m3 = min(g3.x, g3.y);
	float line = max(m1, max(m2, m3));
	float alpha = 1.0 - smoothstep(0.0, 1.0, line * 4.0);
	vec3 col = mix(base_color.rgb, line_color.rgb, alpha * line_color.a);
	ALBEDO = col;
}
