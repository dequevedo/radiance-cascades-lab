// Needs `depth_tex` (sampler2D, reverse-Z) declared first.

vec3 view_pos(ivec2 p, float d) {
	vec2 uv = (vec2(p) + 0.5) / P.screen.xy;
	vec4 v = P.inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return v.xyz / v.w;
}

vec3 pos_at(ivec2 p) {
	ivec2 q = clamp(p, ivec2(0), ivec2(P.screen.xy) - 1);
	return view_pos(q, texelFetch(depth_tex, q, 0).r);
}

vec3 normal_view(ivec2 p, vec3 c) {
	vec3 xp = pos_at(p + ivec2(1, 0));
	vec3 xm = pos_at(p - ivec2(1, 0));
	vec3 yp = pos_at(p + ivec2(0, 1));
	vec3 ym = pos_at(p - ivec2(0, 1));
	vec3 dx = abs(xp.z - c.z) < abs(xm.z - c.z) ? xp - c : c - xm;
	vec3 dy = abs(yp.z - c.z) < abs(ym.z - c.z) ? yp - c : c - ym;
	vec3 n = normalize(cross(dx, dy));
	return dot(n, c) > 0.0 ? -n : n;
}
