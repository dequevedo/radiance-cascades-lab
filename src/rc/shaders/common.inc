// Shared by the cascade and gather passes. "#version 450" is prepended by rc_effect.gd.

layout(set = 0, binding = 0, std140) uniform Params {
	mat4 proj;      // view -> clip (reverse-Z)
	mat4 inv_proj;
	vec4 screen;    // full w, full h, gi w, gi h
	vec4 misc;      // gi_scale, thickness (m), bias (px), unused
	vec4 sky;       // sky radiance rgb, off-screen fill radiance
	vec4 tune;      // intensity, albedo luma, max radiance, debug mode
} P;

layout(set = 0, binding = 1) uniform sampler2D depth_tex;

const float SKY_DEPTH = 1e-6;

// Positive distance along the view axis from a reverse-Z depth sample.
float lin_depth(float d) {
	float z = P.inv_proj[2][2] * d + P.inv_proj[3][2];
	float w = P.inv_proj[2][3] * d + P.inv_proj[3][3];
	return -z / w;
}

vec3 view_pos(ivec2 p, float d) {
	vec2 uv = (vec2(p) + 0.5) / P.screen.xy;
	vec4 v = P.inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return v.xyz / v.w;
}

// Octahedral direction grid: texel (ij) of an a x a block -> point on the octahedron.
vec3 oct_vec(ivec2 ij, int a) {
	vec2 e = (vec2(ij) + 0.5) / float(a) * 2.0 - 1.0;
	vec3 v = vec3(e, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) {
		v.xy = (1.0 - abs(v.yx)) * sign(v.xy);
	}
	return v;
}

// Footprint of one pixel in metres at a given view depth.
float pixel_footprint(float depth) {
	return 2.0 * depth / (P.proj[1][1] * P.screen.y);
}
