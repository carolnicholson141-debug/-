shader_type canvas_item;
uniform vec4 accent : source_color = vec4(0.3, 0.8, 1.0, 1.0);
void fragment() {
	vec4 pixel = texture(TEXTURE, UV);
	float brightness = max(pixel.r, max(pixel.g, pixel.b));
	float chroma = brightness - min(pixel.r, min(pixel.g, pixel.b));
	vec3 tint = mix(vec3(brightness), accent.rgb * brightness, smoothstep(0.03, 0.22, chroma));
	COLOR *= vec4(tint, pixel.a);
}
