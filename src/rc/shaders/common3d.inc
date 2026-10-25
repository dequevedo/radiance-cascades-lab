// Shared by the world-space passes. "#version 450" is prepended by rc_world_effect.gd.

layout(set = 0, binding = 0, std140) uniform Params {
	mat4 proj;         // view -> clip (reverse-Z)
	mat4 inv_proj;
	mat4 cam_to_world; // view -> world
	vec4 screen;       // W, H, 0, 0
	vec4 vol_min;      // xyz = world min, w = voxel size
	vec4 vol_dims;     // xyz = dims in voxels, w = light count
	vec4 tune;         // intensity, fallback albedo luma, max radiance, debug mode
	vec4 sky;          // sky radiance rgb, w = temporal minimum change (absolute)
	vec4 misc;         // c0 spacing, c0 interval length, gather bias (m), use albedo texture
	vec4 extra;        // near range (m): per-pixel rays cover [0, near], probes start there; history valid; temporal alpha; adaptive gain
	mat4 prev_vp;      // world -> previous frame clip (for reprojecting the history)
	vec4 dyn_min;      // bounds of the moving objects (xyz), w = 1 when there are any
	vec4 dyn_max;      // w = temporal noise floor
	vec4 glass_min;    // bounds of the see-through surfaces (xyz), w = 1 when there are any
	vec4 glass_max;
	vec4 sky_horizon;  // the sky at the horizon (rgb); P.sky.rgb is the zenith
	vec4 sky_ground;   // below the horizon
} P;

const float SKY_DEPTH = 1e-6;
const float PI = 3.14159265;
// How fast the soft ray march absorbs: occupancy is a trilinear ramp over about a voxel at the edge of a wall, and a thin wall
// must still be opaque however the samples fall on it. 1 = linear ramp (leaks), higher = firmer.
const float OCC_GAIN = 2.5;

// Octahedral grid over the whole sphere: texel (ij) of an a x a block -> point on the octahedron.
vec3 oct_vec(ivec2 ij, int a) {
	vec2 e = (vec2(ij) + 0.5) / float(a) * 2.0 - 1.0;
	vec3 v = vec3(e, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) {
		v.xy = (1.0 - abs(v.yx)) * sign(v.xy);
	}
	return v;
}

ivec3 grid_of(float spacing) {
	return ivec3(ceil(P.vol_dims.xyz * P.vol_min.w / spacing - 1e-4));
}

// Texel (ij) of an a x a octahedral grid that contains the unit direction d (inverse of oct_vec).
ivec2 oct_texel(vec3 d, int a) {
	vec2 q = d.xy / (abs(d.x) + abs(d.y) + abs(d.z));
	if (d.z < 0.0) {
		q = (1.0 - abs(q.yx)) * sign(q.xy);
	}
	return clamp(ivec2((q * 0.5 + 0.5) * float(a)), ivec2(0), ivec2(a - 1));
}
