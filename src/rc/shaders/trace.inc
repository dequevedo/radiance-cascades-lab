// Voxel helpers. The including shader declares `vox_albedo` (rgba8 image3D, alpha = solid) first.

bool in_vol(ivec3 c) {
	return all(greaterThanEqual(c, ivec3(0))) && all(lessThan(c, ivec3(P.vol_dims.xyz)));
}

bool solid_cell(ivec3 c) {
	return imageLoad(vox_albedo, c).a > 0.5;
}

ivec3 cell_of(vec3 w) {
	return ivec3(floor((w - P.vol_min.xyz) / P.vol_min.w));
}

bool solid_at(vec3 w) {
	ivec3 c = cell_of(w);
	return in_vol(c) && solid_cell(c);
}

// Walks the segment o + d * t, t in [t0, t1] (world units, d unit length), through the voxel grid.
// True on the first solid voxel. left_volume: the segment ends beyond the volume boundary.
bool dda_t(vec3 o, vec3 d, float t0, float t1, out ivec3 hit_cell, out bool left_volume, out float t_hit) {
	float vs = P.vol_min.w;
	vec3 dims = P.vol_dims.xyz;
	vec3 p0 = (o - P.vol_min.xyz) / vs;
	vec3 invd = 1.0 / (d + vec3(equal(d, vec3(0.0))) * 1e-8);
	vec3 ta = (vec3(0.0) - p0) * invd;
	vec3 tb = (dims - p0) * invd;
	vec3 tlo = min(ta, tb);
	vec3 thi = max(ta, tb);
	float tmin = max(max(tlo.x, tlo.y), tlo.z);
	float tmax = min(min(thi.x, thi.y), thi.z);
	float ts = max(t0 / vs, tmin);
	float te = min(t1 / vs, tmax);
	hit_cell = ivec3(-1);
	t_hit = t1;
	left_volume = tmax < t1 / vs;
	if (ts >= te) {
		return false;
	}
	vec3 pos = p0 + d * (ts + 1e-3);
	ivec3 cell = clamp(ivec3(floor(pos)), ivec3(0), ivec3(dims) - 1);
	ivec3 stp = ivec3(sign(d));
	vec3 tdelta = abs(invd);
	vec3 nextb = vec3(cell) + vec3(greaterThan(d, vec3(0.0)));
	vec3 tm3 = (nextb - p0) * invd;
	float t_cur = ts;
	for (int i = 0; i < 1536; i++) {
		if (solid_cell(cell)) {
			hit_cell = cell;
			t_hit = t_cur * vs;
			return true;
		}
		float tm = min(min(tm3.x, tm3.y), tm3.z);
		if (tm > te) {
			break;
		}
		t_cur = tm;
		if (tm3.x <= tm3.y && tm3.x <= tm3.z) {
			cell.x += stp.x;
			tm3.x += tdelta.x;
		} else if (tm3.y <= tm3.z) {
			cell.y += stp.y;
			tm3.y += tdelta.y;
		} else {
			cell.z += stp.z;
			tm3.z += tdelta.z;
		}
		if (!in_vol(cell)) {
			break;
		}
	}
	return false;
}

bool dda(vec3 o, vec3 d, float t0, float t1, out ivec3 hit_cell, out bool left_volume) {
	float t;
	return dda_t(o, d, t0, t1, hit_cell, left_volume, t);
}
