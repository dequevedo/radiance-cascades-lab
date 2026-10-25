// Needs `vox_rad` (rgba16f image3D, alpha = surface voxel) declared and trace.inc included first.

// Radiance of the surface at a hit point, filtered over the 8 surrounding surface voxels instead of read from the
// single voxel that was hit: a voxel is 12.5 cm, and reading it directly puts a 12.5 cm square on everything it lights.
vec3 hit_radiance(vec3 hp, ivec3 cell) {
	vec3 g = (hp - P.vol_min.xyz) / P.vol_min.w - 0.5;
	ivec3 b = ivec3(floor(g));
	vec3 f = g - vec3(b);
	vec3 acc = vec3(0.0);
	float ws = 0.0;
	for (int k = 0; k < 8; k++) {
		ivec3 o = ivec3(k & 1, (k >> 1) & 1, k >> 2);
		ivec3 c = b + o;
		if (!in_vol(c)) {
			continue;
		}
		vec4 r = imageLoad(vox_rad, c);
		if (r.a < 0.5) {
			continue;
		}
		float w = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y) * (o.z == 1 ? f.z : 1.0 - f.z);
		acc += w * r.rgb;
		ws += w;
	}
	return ws > 1e-4 ? acc / ws : imageLoad(vox_rad, cell).rgb;
}
