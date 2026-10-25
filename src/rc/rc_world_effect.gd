extends CompositorEffect
## World-space Radiance Cascades GI. The scene is voxelized once (static), lit by its lights into a
## radiance volume, and cascades of 3D probes trace that volume. Off-screen geometry counts.
## Per frame: cascade passes (top to bottom) + per-pixel gather. Prototype: static scene, one bounce.

const A0 := 4 # directions per axis in cascade 0 (a_n = A0 << n); probe spacing doubles per level

@export var gi_enabled := true
@export var cascades := 4
@export var voxel_size := 0.25
@export var dims := Vector3i(128, 48, 128)
@export var volume_min := Vector3(-16.0, -0.5, -16.0)
@export var probe_spacing := 1.0
@export var interval0 := 0.5 # cascade 0 interval length (m); each next one is 4x longer
@export var intensity := 1.0
@export var albedo_luma := 0.6
@export var max_radiance := 16.0
@export var gather_bias := 0.35
@export var sky_radiance := Color(0.02, 0.03, 0.06) # the sky overhead (what rays that leave the volume upwards see)
@export var sky_horizon := Color(0.02, 0.03, 0.06) # towards the horizon
@export var sky_ground := Color(0.01, 0.01, 0.01) # below the horizon
@export var debug_mode := 0 # 0 composite, 1 indirect only, 2 voxel albedo under the pixel
@export var use_albedo_texture := true # per-pixel albedo from a second, unshaded render (a stand-in for a G-buffer)
@export var final_gather := true # per-pixel short rays + 4x4 gather for the near field (probes only start past near_range)
@export var near_range := 0.5 # metres covered by the per-pixel rays
@export var near_dirs := 6 # directions per axis of the per-pixel tile (6 -> 36 directions, one per pixel of a 6x6 block)
@export var temporal := true # blend with the reprojected previous frame (the tile of directions shifts every frame)
@export var temporal_adaptive := 1.2 # extra weight of the new frame where it differs a lot from the history (0 = fixed alpha)
@export var temporal_noise_floor := 0.45 # differences below this (relative) are noise, not change: they never speed the blend up
@export var temporal_min_change := 0.03 # nor do differences below this (absolute radiance): in dim light a tiny change looks big in relative terms
@export var temporal_alpha := 0.25 # weight of the new frame (lower = smoother but slower to follow changes)
@export var dynamic := false # per frame: reset to the static voxels, add dynamic triangles, re-inject the lights
@export var inject_partial := true # re-light only the part of the volume that a changed light or a moving object can affect
@export var far_every := 2 # the far cascades (far_from and up) are traced every Nth frame; 1 = every frame
@export var far_from := 2
@export var jitter := true # A: random ray start and probe lookup per pixel and frame (turns grid lines into noise the temporal blend removes)
@export var edge_fix := true # B: at object edges, gather from a window two tiles wide when most of the tile was rejected
@export var denoise := true # C: edge-aware 7x7 filter of the bounce light before it is added
@export var history_aware := true # pixels with a short history (just uncovered) are filtered wider and averaged over their frames so far
@export var bounce := 0.8 # more bounces: last frame's probe light added to every lit voxel, times this (0 = a single bounce)
@export var bounce_full_every := 4 # with more bounces on, the whole volume is lit again every Nth frame (the light keeps bouncing)
@export var directional := true # the bounce light keeps the direction it comes from, so normal maps react to it
@export var pixel_roughness := true # roughness per pixel from Godot's normal_roughness buffer (roughness textures: puddles)
@export var voxel_reflections := true # where the picture does not hold the reflection, trace it through the voxels
@export var sharp_reflections := true # shiny surfaces first look for their reflection in the picture itself
@export var glass_tint := true # light through see-through surfaces takes their colour
@export var facing := true # a voxel shows its light only to rays coming from the side its surface faces
@export var solid_fill := true # fill the inside of closed meshes (else objects are hollow shells and probes inside them leak)
@export var spec_strength := 1.0 # glossy reflections from the probes (Fresnel-weighted, blurred)
@export var emission_scale := 1.0 # emissive surfaces light the scene, times this
@export var fog := false # a height fog that scatters the bounce light (glows round neon signs and lit windows)
@export var fog_density := 0.03 # per metre, at fog_base
@export var fog_height := 6.0 # the density halves every ~0.7 x this many metres above fog_base
@export var fog_base := 0.0
@export var fog_distance := 60.0 # the fog is marched up to this far
@export var fog_steps := 24
@export var fog_brightness := 1.0
@export var follow_step := 0.0 # > 0: the volume follows the camera, moving in steps of this many metres
var recentres := 0 # how many times the volume has moved
var recentre_ms := 0.0 # CPU time of the last move (recording the GPU work)
var _follow_target := Vector3.INF
@export var split := -1.0 # split view: fraction of the screen width, left of it shows no bounce light; < 0 = off

const MAX_DYN_BOXES := 64
## Per light: (position, range), (colour x energy, type: 0 omni, 1 directional, 2 spot), (direction the light travels, decay),
## (cosine of the spot angle, spot attenuation, 0, 0).
const LIGHT_FLOATS := 16
const MAX_LIGHTS := 64 # per frame; with more in the scene, the ones that reach the volume, nearest to its centre first
const BOX_FLOATS := 24 # per moving box: centre, three half-extent vectors, albedo, emission (6 vec4)

var rd: RenderingDevice
var _shader := {}
var _pipe := {}
var _sampler := RID()
var _sampler_lin := RID()
var _ubo := RID()
var _tri_buf := RID()
var _light_buf := RID()
var _vox_albedo := RID()
var _vox_static := RID()
var _vox_dyn := RID()
var _dyn_buf := RID()
var _dyn_boxes := PackedFloat32Array()
var _dyn_min := Vector3.ZERO
var _dyn_max := Vector3.ZERO
var _dyn_count := 0
var _vox_rad := RID()
var _pw_lo := RID()
var _pw_hi := RID()
var _probe: Array[RID] = [RID(), RID()]
var _probe_dim := Vector3i.ZERO
var _tris := PackedFloat32Array()
var _tri_count := 0
var _lights := PackedFloat32Array()
var _light_count := 0
var volume_ready := false
var rays_per_frame := 0
var _near_tex := RID()
var _nrm: Array[RID] = [RID(), RID()]
var _hist: Array[RID] = [RID(), RID()]
var _spec_hist: Array[RID] = [RID(), RID()] # the reflections blended in time
var _dir: Array[RID] = [RID(), RID()] # per pixel: where the bounce light comes from (brightness-weighted mean direction)
var _pp := 0
var _frame := 0
var _hist_valid := false
var _prev_vp := Projection.IDENTITY
var _screen_tex_size := Vector2i.ZERO
var albedo_texture_rid := RID() # ViewportTexture RID of the unshaded albedo render, set by the scene
var voxelize_ms := 0.0
# Static geometry as meshes for the GPU voxelizer: world-space vertices, indices, and per surface
# (triangle count, first index, first vertex, 0, albedo rgb, 0).
var _mesh_verts := PackedVector3Array()
var _mesh_idx := PackedInt32Array()
var _mesh_surf := PackedFloat32Array()
var _mesh_cols := PackedColorArray()
var _mesh_aabb := PackedFloat32Array()
var _mesh_dirty := true # the mesh buffers on the GPU are rebuilt only when the scene changed
var _col_buf := RID()
var voxelized_surfaces := 0 # how many surfaces the last voxelization drew (the others were outside the volume)
var _vert_buf := RID()
var _idx_buf := RID()
# Far cascades kept between frames.
var _probe_keep := RID()
var _amb := RID()
var _amb_iso := RID() # per probe of cascade 0: the average light arriving there (for the fog) # ambient cube per probe of cascade 0 (6 faces side by side in x)
var _vox_emit := RID()
var _vox_mat := RID() # per voxel: metallic, roughness
var _vox_base := RID() # per voxel: base colour (metals reflect with it)
var _has_nr := false # Godot gave us its normal_roughness buffer this frame
var _prev_color := RID() # last frame's finished picture (sharp reflections read it: a metal in it already shows its reflection)
var _prev_color_valid := false
var _prev_color_size := Vector2i.ZERO
var _dyn_mask := RID() # coarse cells (about 2 m) that a moving object touches: rays read the moving objects' volume only there
var _mask_k := 8 # voxels per mask cell along each axis
var _mask_dims := Vector3i.ONE
var _vox_tint := RID() # per voxel: the colour a see-through surface lets through (rgb), a = 1 where there is one
var _has_glass := false
var _glass_min := Vector3.ZERO
var _glass_max := Vector3.ZERO
var _vox_nrm := RID() # per voxel: surface normal (written by inject.comp with the light)
var _vox_emit_w := RID() # per voxel: coverage of the glowing triangles that touch it (fill_solid.comp scales the emission)
var _vox_wind := RID() # per voxel: winding-number steps of the closed meshes along +x (filled in by fill_solid.comp)
var _vox_dyn_emit := RID() # emission of the moving objects
var _spec_tex := RID() # per pixel: glossy reflection, metallic
var _keep_valid := false
var _cframe := 0
var last_far_skipped := false
# What was injected last time, to find what changed.
var _rad_full := true
var _prev_lights := PackedFloat32Array()
var _prev_boxes := PackedFloat32Array()
var _prev_dyn_min := Vector3.ZERO
var _prev_dyn_max := Vector3.ZERO
var _prev_dyn_count := 0
var inject_fraction := 1.0 # share of the volume re-lit in the last frame (0 = nothing changed)


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_normal_roughness = true # the smooth (interpolated) normals, for reflections: the depth buffer only gives flat facets
	RenderingServer.call_on_render_thread(_init_rd)


# --- scene input (main thread) -------------------------------------------------------------------

static var _albedo_cache := {}


## Average albedo of a material in linear space: albedo colour times the mean of its albedo texture.
static func _material_albedo(mat: Material) -> Color:
	var sm := mat as StandardMaterial3D
	if sm == null:
		return Color(0.6, 0.6, 0.6).srgb_to_linear()
	var key := sm.get_instance_id()
	if _albedo_cache.has(key):
		return _albedo_cache[key]
	var c := sm.albedo_color
	if sm.albedo_texture != null:
		var img := sm.albedo_texture.get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			if not img.is_compressed() and img.get_width() > 0:
				img.resize(64, 64, Image.INTERPOLATE_BILINEAR)
				img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
				var t := img.get_pixel(0, 0)
				c = Color(c.r * t.r, c.g * t.g, c.b * t.b)
	var lin := c.srgb_to_linear()
	_albedo_cache[key] = lin
	return lin


## Triangles of every MeshInstance3D under root, as world-space (a, b, c, albedo) vec4 records, one albedo per surface.
## meta "rc_albedo" overrides the albedo of a node, "rc_skip" leaves it out. Hidden nodes are left out.
static func collect_triangles(root: Node) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible or mi.has_meta("rc_skip") or mi.has_meta("rc_proxy"):
			continue
		var xf := mi.global_transform
		for si in mi.mesh.get_surface_count():
			var mat: Material = mi.get_surface_override_material(si)
			if mat == null:
				mat = mi.material_override
			if mat == null:
				mat = mi.mesh.surface_get_material(si)
			var albedo := _material_albedo(mat)
			if mi.has_meta("rc_albedo"):
				albedo = (mi.get_meta("rc_albedo") as Color).srgb_to_linear()
			var arr := mi.mesh.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx = arr[Mesh.ARRAY_INDEX]
			var wv := PackedVector3Array()
			wv.resize(v.size())
			for i in v.size():
				wv[i] = xf * v[i]
			var has_idx: bool = idx != null and (idx as PackedInt32Array).size() > 0
			var count: int = (idx as PackedInt32Array).size() if has_idx else v.size()
			var tris := count / 3
			var base := out.size()
			out.resize(base + tris * 16)
			for t in tris:
				var i0: int = idx[t * 3] if has_idx else t * 3
				var i1: int = idx[t * 3 + 1] if has_idx else t * 3 + 1
				var i2: int = idx[t * 3 + 2] if has_idx else t * 3 + 2
				var o := base + t * 16
				var a0 := wv[i0]
				var a1 := wv[i1]
				var a2 := wv[i2]
				out[o] = a0.x
				out[o + 1] = a0.y
				out[o + 2] = a0.z
				out[o + 4] = a1.x
				out[o + 5] = a1.y
				out[o + 6] = a1.z
				out[o + 8] = a2.x
				out[o + 9] = a2.y
				out[o + 10] = a2.z
				out[o + 12] = albedo.r
				out[o + 13] = albedo.g
				out[o + 14] = albedo.b
				out[o + 15] = 1.0
	return out


## Emission of a material in linear space (colour x energy), black when it does not glow.
static func _material_emission(mat: Material) -> Color:
	var sm := mat as StandardMaterial3D
	if sm == null or not sm.emission_enabled:
		return Color.BLACK
	return sm.emission.srgb_to_linear() * sm.emission_energy_multiplier


## Metallic, roughness and whether a material is see-through (glass).
static func _material_params(mat: Material) -> Vector3:
	var sm := mat as StandardMaterial3D
	if sm == null:
		return Vector3(0.0, 1.0, 0.0)
	var see_through := sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and sm.albedo_color.a < 0.95
	return Vector3(sm.metallic, sm.roughness, 1.0 if see_through else 0.0)


## Every visible mesh surface under root, for the GPU voxelizer: world-space vertices (one native multiply per surface, no
## per-triangle work in GDScript), indices as they are, and one record per surface. Same skip rules as collect_triangles.
static var _surface_cache := {}


## True when every edge of the surface (vertices welded by position) is shared by exactly two triangles: a closed mesh, whose
## inside can be filled. A plane, or a mesh with a hole, is voxelized as a shell only.
static func _is_closed(v: PackedVector3Array, ii: PackedInt32Array) -> bool:
	var weld := {}
	var ids := PackedInt32Array()
	ids.resize(v.size())
	for k in v.size():
		var q := v[k].snapped(Vector3.ONE * 1e-4)
		if not weld.has(q):
			weld[q] = weld.size()
		ids[k] = weld[q]
	var edges := {}
	for t in ii.size() / 3:
		var a := ids[ii[t * 3]]
		var b := ids[ii[t * 3 + 1]]
		var c := ids[ii[t * 3 + 2]]
		if a == b or b == c or a == c:
			continue # degenerate (the pole of a sphere)
		for e in [Vector2i(mini(a, b), maxi(a, b)), Vector2i(mini(b, c), maxi(b, c)), Vector2i(mini(a, c), maxi(a, c))]:
			edges[e] = edges.get(e, 0) + 1
	if edges.is_empty():
		return false
	for n in edges.values():
		if n != 2:
			return false
	return true


static func collect_meshes(root: Node) -> Dictionary:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var surf := PackedFloat32Array()
	var cols := PackedColorArray() # vertex colours of the surfaces whose material uses them as albedo (linear)
	var aabbs := PackedFloat32Array() # per surface: world bounds (min xyz, max xyz), to voxelize only what is in the volume
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible or mi.has_meta("rc_skip") or mi.has_meta("rc_proxy"):
			continue
		var xf := mi.global_transform
		for si in mi.mesh.get_surface_count():
			if mi.mesh is ArrayMesh and (mi.mesh as ArrayMesh).surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var mat: Material = mi.get_surface_override_material(si)
			if mat == null:
				mat = mi.material_override
			if mat == null:
				mat = mi.mesh.surface_get_material(si)
			var albedo := _material_albedo(mat)
			if mi.has_meta("rc_albedo"):
				albedo = (mi.get_meta("rc_albedo") as Color).srgb_to_linear()
			# A mesh's local arrays are read once (reading a primitive mesh builds them every time) and kept for the next gather.
			var key := "%d:%d" % [mi.mesh.get_instance_id(), si]
			var cached: Array = _surface_cache.get(key, [])
			if cached.is_empty():
				var arr := mi.mesh.surface_get_arrays(si)
				var cv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var ci := PackedInt32Array()
				if arr[Mesh.ARRAY_INDEX] != null and (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() > 0:
					ci = arr[Mesh.ARRAY_INDEX]
				else:
					ci.resize(cv.size())
					for k in cv.size():
						ci[k] = k
				var cc := PackedColorArray()
				if arr[Mesh.ARRAY_COLOR] != null:
					cc = arr[Mesh.ARRAY_COLOR]
				cached = [cv, ci, _is_closed(cv, ci), cc]
				_surface_cache[key] = cached
			var v: PackedVector3Array = cached[0]
			var ii: PackedInt32Array = cached[1]
			var em := _material_emission(mat)
			if mi.has_meta("rc_emission"):
				em = mi.get_meta("rc_emission")
			var mp := _material_params(mat)
			# Vertex colours (one merged mesh for many objects of different colours): a.w = first colour + 1, 0 = none.
			var cbase := 0.0
			var sm := mat as StandardMaterial3D
			var vc: PackedColorArray = cached[3]
			if sm != null and sm.vertex_color_use_as_albedo and vc.size() == v.size():
				cbase = cols.size() + 1.0
				cols.append_array(vc)
			surf.append_array([ii.size() / 3, idx.size(), verts.size(), cbase, albedo.r, albedo.g, albedo.b, 0.0, em.r, em.g, em.b, 0.0,
				mp.x, mp.y, mp.z, 1.0 if cached[2] else 0.0])
			var box := xf * mi.mesh.get_aabb()
			aabbs.append_array([box.position.x, box.position.y, box.position.z, box.end.x, box.end.y, box.end.z])
			verts.append_array(xf * v)
			idx.append_array(ii)
	return {"verts": verts, "idx": idx, "surf": surf, "tris": idx.size() / 3, "cols": cols, "aabbs": aabbs}


## Boxes (BoxMesh) under root as (centre, half-extent vector x, y, z, albedo) vec4 records, for objects that move: they are
## voxelized every frame with fractional coverage instead of as triangles.
static func collect_boxes(root, flat := false) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var stack: Array = [root] if not flat else (root as Array).duplicate()
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if not flat:
			stack.append_array(node.get_children())
		var mi := node as MeshInstance3D
		if mi == null or not (mi.mesh is BoxMesh) or not (mi.visible or mi.has_meta("rc_proxy")) or mi.has_meta("rc_skip"):
			continue
		var albedo := Color(0.7, 0.7, 0.7)
		var mat := mi.material_override as StandardMaterial3D
		if mat != null:
			albedo = mat.albedo_color
		albedo = albedo.srgb_to_linear()
		var half := (mi.mesh as BoxMesh).size * 0.5
		var xf := mi.global_transform
		var ax := xf.basis.x * half.x
		var ay := xf.basis.y * half.y
		var az := xf.basis.z * half.z
		var c := xf.origin
		var em := _material_emission(mat) if mat != null else Color.BLACK
		out.append_array([c.x, c.y, c.z, 0.0, ax.x, ax.y, ax.z, 0.0, ay.x, ay.y, ay.z, 0.0, az.x, az.y, az.z, 0.0,
			albedo.r, albedo.g, albedo.b, 0.0, em.r, em.g, em.b, 0.0])
	return out


## Light3D nodes and moving-box nodes under root, found once so that the per-frame collection does not walk the whole tree.
static func find_nodes(root: Node, kinds: Array) -> Array:
	var out := []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		for k in kinds:
			if is_instance_of(node, k):
				out.append(node)
	return out


## (pos, range), (color * energy, type), (direction to light, decay) per light, from Light3D nodes under root.
static func collect_lights(root, flat := false) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var stack: Array = [root] if not flat else (root as Array).duplicate()
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if not flat:
			stack.append_array(node.get_children())
		var omni := node as OmniLight3D
		if omni != null and omni.visible and omni.light_energy > 0.0:
			var c := omni.light_color.srgb_to_linear() * omni.light_energy
			var p := omni.global_position
			out.append_array([p.x, p.y, p.z, omni.omni_range, c.r, c.g, c.b, 0.0, 0.0, 0.0, 0.0, omni.omni_attenuation, 0.0, 0.0, 0.0, 0.0])
		var spot := node as SpotLight3D
		if spot != null and spot.visible and spot.light_energy > 0.0:
			var c3 := spot.light_color.srgb_to_linear() * spot.light_energy
			var p3 := spot.global_position
			var d3 := -spot.global_transform.basis.z.normalized() # a spot shines along its -Z
			out.append_array([p3.x, p3.y, p3.z, spot.spot_range, c3.r, c3.g, c3.b, 2.0, d3.x, d3.y, d3.z, spot.spot_attenuation,
				cos(deg_to_rad(spot.spot_angle)), spot.spot_angle_attenuation, 0.0, 0.0])
		var sun := node as DirectionalLight3D
		if sun != null and sun.visible:
			var c2 := sun.light_color.srgb_to_linear() * sun.light_energy
			var d := sun.global_transform.basis.z
			out.append_array([0.0, 0.0, 0.0, 0.0, c2.r, c2.g, c2.b, 1.0, d.x, d.y, d.z, 0.0, 0.0, 0.0, 0.0, 0.0])
	return out


## At most MAX_LIGHTS: the directional ones, then the others whose reach touches the volume, nearest to its centre first.
func _select_lights(lights: PackedFloat32Array) -> PackedFloat32Array:
	var n := lights.size() / LIGHT_FLOATS
	if n <= MAX_LIGHTS:
		return lights
	var vmin := volume_min
	var vmax := volume_min + Vector3(dims) * voxel_size
	var centre := (vmin + vmax) * 0.5
	var picks := []
	for i in n:
		var o := i * LIGHT_FLOATS
		if lights[o + 7] > 0.5 and lights[o + 7] < 1.5:
			picks.append([-1.0, i])
			continue
		var p := Vector3(lights[o], lights[o + 1], lights[o + 2])
		if p.clamp(vmin, vmax).distance_to(p) > lights[o + 3]:
			continue
		picks.append([p.distance_to(centre), i])
	picks.sort_custom(func(a, b): return a[0] < b[0])
	var out := PackedFloat32Array()
	for k in mini(picks.size(), MAX_LIGHTS):
		var o: int = picks[k][1] * LIGHT_FLOATS
		out.append_array(lights.slice(o, o + LIGHT_FLOATS))
	return out


## Per-frame input for dynamic scenes (call on the render thread): the moving boxes (see collect_boxes) and all lights.
func update_dynamic(boxes: PackedFloat32Array, lights: PackedFloat32Array) -> void:
	# Only what moves near the volume counts (in a city, most cars are far from it).
	var vmin := volume_min - Vector3.ONE * 3.0
	var vmax := volume_min + Vector3(dims) * voxel_size + Vector3.ONE * 3.0
	var near := PackedFloat32Array()
	for i in boxes.size() / BOX_FLOATS:
		var o := i * BOX_FLOATS
		var c := Vector3(boxes[o], boxes[o + 1], boxes[o + 2])
		if c.x > vmin.x and c.x < vmax.x and c.y > vmin.y and c.y < vmax.y and c.z > vmin.z and c.z < vmax.z:
			near.append_array(boxes.slice(o, o + BOX_FLOATS))
	boxes = near
	_dyn_boxes = boxes
	_dyn_count = mini(boxes.size() / BOX_FLOATS, MAX_DYN_BOXES)
	# Bounds of everything that moves (plus a margin): inside them shadows are marched softly.
	if _dyn_count > 0:
		_dyn_min = Vector3(INF, INF, INF)
		_dyn_max = Vector3(-INF, -INF, -INF)
		for i in _dyn_count:
			var o := i * BOX_FLOATS
			var c := Vector3(boxes[o], boxes[o + 1], boxes[o + 2])
			var ext := Vector3.ZERO
			for k in 3:
				var ax := Vector3(boxes[o + 4 + k * 4], boxes[o + 5 + k * 4], boxes[o + 6 + k * 4])
				ext += Vector3(absf(ax.x), absf(ax.y), absf(ax.z))
			_dyn_min = _dyn_min.min(c - ext - Vector3.ONE * 0.3)
			_dyn_max = _dyn_max.max(c + ext + Vector3.ONE * 0.3)
	_update_dyn_mask(boxes)
	_lights = _select_lights(lights)
	_light_count = mini(_lights.size() / LIGHT_FLOATS, MAX_LIGHTS)


## Marks the coarse cells every moving box touches (with a voxel of margin for the trilinear reads). Render thread.
var _mask_bytes := PackedByteArray()


func _update_dyn_mask(boxes: PackedFloat32Array) -> void:
	if rd == null or not _dyn_mask.is_valid():
		return
	var n := _mask_dims.x * _mask_dims.y * _mask_dims.z
	if _mask_bytes.size() != n:
		_mask_bytes.resize(n)
	_mask_bytes.fill(0)
	var cell := voxel_size * _mask_k
	for i in mini(boxes.size() / BOX_FLOATS, MAX_DYN_BOXES):
		var o := i * BOX_FLOATS
		var c := Vector3(boxes[o], boxes[o + 1], boxes[o + 2])
		var ext := Vector3.ONE * (voxel_size + 0.3)
		for k in 3:
			var ax := Vector3(boxes[o + 4 + k * 4], boxes[o + 5 + k * 4], boxes[o + 6 + k * 4])
			ext += Vector3(absf(ax.x), absf(ax.y), absf(ax.z))
		var lo := Vector3i(((c - ext - volume_min) / cell).floor().clamp(Vector3.ZERO, Vector3(_mask_dims - Vector3i.ONE)))
		var hi := Vector3i(((c + ext - volume_min) / cell).floor().clamp(Vector3.ZERO, Vector3(_mask_dims - Vector3i.ONE)))
		for z in range(lo.z, hi.z + 1):
			for y in range(lo.y, hi.y + 1):
				for x in range(lo.x, hi.x + 1):
					_mask_bytes[(z * _mask_dims.y + y) * _mask_dims.x + x] = 255
	rd.texture_update(_dyn_mask, 0, _mask_bytes)


func set_scene(tris: PackedFloat32Array, lights: PackedFloat32Array) -> void:
	_tris = tris
	_tri_count = tris.size() / 16
	_mesh_surf = PackedFloat32Array()
	_lights = _select_lights(lights)
	_light_count = mini(_lights.size() / LIGHT_FLOATS, MAX_LIGHTS)


## New static meshes only (a prop was moved): call revoxelize_static() on the render thread after it.
func set_static_meshes(meshes: Dictionary) -> void:
	_mesh_verts = meshes["verts"]
	_mesh_idx = meshes["idx"]
	_mesh_surf = meshes["surf"]
	_tri_count = meshes["tris"]


## Like set_scene, with the meshes from collect_meshes (voxelized on the GPU).
func set_scene_meshes(meshes: Dictionary, lights: PackedFloat32Array) -> void:
	_mesh_verts = meshes["verts"]
	_mesh_idx = meshes["idx"]
	_mesh_surf = meshes["surf"]
	_mesh_cols = meshes.get("cols", PackedColorArray())
	_mesh_aabb = meshes.get("aabbs", PackedFloat32Array())
	_mesh_dirty = true
	_tri_count = meshes["tris"]
	_tris = PackedFloat32Array()
	_lights = _select_lights(lights)
	_light_count = mini(_lights.size() / LIGHT_FLOATS, MAX_LIGHTS)
	# Bounds of the see-through surfaces: rays look up the glass colour only inside them.
	_has_glass = false
	for k in _mesh_surf.size() / 16:
		var o := k * 16
		if _mesh_surf[o + 14] < 0.5:
			continue
		var ib := int(_mesh_surf[o + 1])
		var vb := int(_mesh_surf[o + 2])
		for t in int(_mesh_surf[o]) * 3:
			var v: Vector3 = _mesh_verts[vb + _mesh_idx[ib + t]]
			if not _has_glass:
				_glass_min = v
				_glass_max = v
				_has_glass = true
			_glass_min = _glass_min.min(v)
			_glass_max = _glass_max.max(v)
	_glass_min -= Vector3.ONE * voxel_size * 1.5
	_glass_max += Vector3.ONE * voxel_size * 1.5


# --- render thread -------------------------------------------------------------------------------

func _compile(shader_name: String) -> RID:
	var body := FileAccess.get_file_as_string("res://src/rc/shaders/%s.comp" % shader_name)
	for inc in ["trace", "radiance", "screen"]:
		body = body.replace("//#include %s.inc" % inc, FileAccess.get_file_as_string("res://src/rc/shaders/%s.inc" % inc))
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = "#version 450\n" + FileAccess.get_file_as_string("res://src/rc/shaders/common3d.inc") + "\n" + body
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("Shader %s: %s" % [shader_name, spirv.compile_error_compute])
		return RID()
	return rd.shader_create_from_spirv(spirv)


func _init_rd() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return
	for n in ["voxelize", "voxelize_mesh", "fill_solid", "copy_color", "fog", "voxelize_boxes", "inject", "ambient", "cascade3d", "gather3d", "nearfield", "final", "probe_weights"]:
		_shader[n] = _compile(n)
		if (_shader[n] as RID).is_valid():
			_pipe[n] = rd.compute_pipeline_create(_shader[n])
	_sampler = rd.sampler_create(RDSamplerState.new())
	var lin := RDSamplerState.new()
	lin.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lin.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lin.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	lin.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	lin.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler_lin = rd.sampler_create(lin)
	_ubo = rd.uniform_buffer_create(480)


func free_resources() -> void:
	if rd == null:
		return
	gi_enabled = false
	volume_ready = false
	_free_volume()
	for r in _pipe.values() + _shader.values() + [_sampler, _sampler_lin, _ubo, _near_tex, _nrm[0], _nrm[1], _hist[0], _hist[1], _spec_tex, _prev_color, _dir[0], _dir[1], _spec_hist[0], _spec_hist[1]]:
		if (r as RID).is_valid():
			rd.free_rid(r)
	_prev_color = RID()
	_pipe.clear()
	_shader.clear()


func _free_volume() -> void:
	for r in [_tri_buf, _light_buf, _dyn_buf, _vox_static, _vox_dyn, _vox_albedo, _vox_rad, _pw_lo, _pw_hi, _probe[0], _probe[1],
			_probe_keep, _vert_buf, _idx_buf, _col_buf, _amb, _amb_iso, _vox_emit, _vox_mat, _vox_dyn_emit, _vox_base, _vox_wind, _vox_nrm, _vox_tint, _vox_emit_w, _dyn_mask]:
		if (r as RID).is_valid():
			rd.free_rid(r)
	_probe_keep = RID()
	_amb = RID()
	_amb_iso = RID()
	_vox_emit = RID()
	_vox_mat = RID()
	_vox_base = RID()
	_vox_wind = RID()
	_vox_emit_w = RID()
	_dyn_mask = RID()
	_vox_nrm = RID()
	_vox_tint = RID()
	_vox_dyn_emit = RID()
	_vert_buf = RID()
	_idx_buf = RID()
	_col_buf = RID()
	_mesh_dirty = true
	_keep_valid = false
	_rad_full = true
	_tri_buf = RID()
	_light_buf = RID()
	_dyn_buf = RID()
	_vox_static = RID()
	_vox_dyn = RID()
	_vox_albedo = RID()
	_vox_rad = RID()
	_pw_lo = RID()
	_pw_hi = RID()
	_probe = [RID(), RID()]


func _tex3d(size: Vector3i, format: int) -> RID:
	var f := RDTextureFormat.new()
	f.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	f.format = format
	f.width = size.x
	f.height = size.y
	f.depth = size.z
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var t := rd.texture_create(f, RDTextureView.new(), [])
	rd.texture_clear(t, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return t


func _grid(spacing: float) -> Vector3i:
	return Vector3i(
		ceili(dims.x * voxel_size / spacing - 1e-4),
		ceili(dims.y * voxel_size / spacing - 1e-4),
		ceili(dims.z * voxel_size / spacing - 1e-4))


static func _pack_mat(m: Projection, out: PackedFloat32Array) -> void:
	for col in [m.x, m.y, m.z, m.w]:
		out.append_array([col.x, col.y, col.z, col.w])


func _write_ubo(proj: Projection, cam_to_world: Projection, size: Vector2i, use_albedo_tex := false, near := 0.0, hist_valid := false, alpha := 1.0, prev_vp := Projection.IDENTITY) -> void:
	var p := PackedFloat32Array()
	_pack_mat(proj, p)
	_pack_mat(proj.inverse(), p)
	_pack_mat(cam_to_world, p)
	p.append_array([size.x, size.y, split, float((1 if jitter else 0) | (2 if edge_fix else 0) | (4 if denoise else 0) | (8 if history_aware else 0) | (16 if facing else 0) | (32 if sharp_reflections else 0) | (64 if _prev_color_valid else 0) | (128 if directional else 0) | (256 if follow_step > 0.0 else 0) | (512 if (pixel_roughness and _has_nr) else 0) | (1024 if voxel_reflections else 0))])
	p.append_array([volume_min.x, volume_min.y, volume_min.z, voxel_size])
	p.append_array([dims.x, dims.y, dims.z, _light_count])
	p.append_array([intensity, albedo_luma, max_radiance, float(debug_mode)])
	p.append_array([sky_radiance.r, sky_radiance.g, sky_radiance.b, temporal_min_change])
	p.append_array([probe_spacing, interval0, gather_bias, 1.0 if use_albedo_tex else 0.0])
	p.append_array([near, 1.0 if hist_valid else 0.0, alpha, temporal_adaptive])
	_pack_mat(prev_vp, p)
	p.append_array([_dyn_min.x, _dyn_min.y, _dyn_min.z, 1.0 if (dynamic and _dyn_count > 0) else 0.0])
	p.append_array([_dyn_max.x, _dyn_max.y, _dyn_max.z, temporal_noise_floor])
	p.append_array([_glass_min.x, _glass_min.y, _glass_min.z, 1.0 if (glass_tint and _has_glass) else 0.0])
	p.append_array([_glass_max.x, _glass_max.y, _glass_max.z, voxel_size * _mask_k])
	p.append_array([sky_horizon.r, sky_horizon.g, sky_horizon.b, 0.0])
	p.append_array([sky_ground.r, sky_ground.g, sky_ground.b, 0.0])
	var bytes := p.to_byte_array()
	rd.buffer_update(_ubo, 0, bytes.size(), bytes)


func _u(type: int, binding: int, ids: Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids:
		u.add_id(id)
	return u


func _img(binding: int, rid: RID) -> RDUniform:
	return _u(RenderingDevice.UNIFORM_TYPE_IMAGE, binding, [rid])


func _ubo_u() -> RDUniform:
	return _u(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 0, [_ubo])


## Voxelizes the scene and injects the direct light. Call on the render thread after set_scene() or set_scene_meshes().
func rebuild() -> void:
	if rd == null or _tri_count == 0 or not (_pipe.has("voxelize") and _pipe.has("inject")):
		return
	_free_volume()
	volume_ready = false
	_follow_target = Vector3.INF
	_vox_static = _tex3d(dims, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	_vox_dyn = _tex3d(dims, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	_vox_albedo = _tex3d(dims, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	_vox_rad = _tex3d(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var pd := Vector3i.ZERO
	for n in cascades:
		var g := _grid(probe_spacing * pow(2.0, n))
		var a := A0 << n
		pd = Vector3i(maxi(pd.x, g.x * a), maxi(pd.y, g.y * a), maxi(pd.z, g.z))
	_probe_dim = pd
	_probe = [_tex3d(pd, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT), _tex3d(pd, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)]
	_probe_keep = _tex3d(pd, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_vox_emit = _tex3d(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_vox_mat = _tex3d(dims, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	_vox_base = _tex3d(dims, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	_vox_wind = _tex3d(dims, RenderingDevice.DATA_FORMAT_R32_SINT)
	_vox_emit_w = _tex3d(dims, RenderingDevice.DATA_FORMAT_R32_UINT)
	_mask_k = maxi(roundi(2.0 / voxel_size), 1)
	_mask_dims = Vector3i(ceili(dims.x / float(_mask_k)), ceili(dims.y / float(_mask_k)), ceili(dims.z / float(_mask_k)))
	_dyn_mask = _tex3d(_mask_dims, RenderingDevice.DATA_FORMAT_R8_UNORM)
	_vox_nrm = _tex3d(dims, RenderingDevice.DATA_FORMAT_R8G8B8A8_SNORM)
	_vox_tint = _tex3d(dims, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	_vox_dyn_emit = _tex3d(dims, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var g0 := _grid(probe_spacing)
	_amb = _tex3d(Vector3i(g0.x * 6, g0.y, g0.z), RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_amb_iso = _tex3d(g0, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_pw_lo = _tex3d(g0, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_pw_hi = _tex3d(g0, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var lights := _lights.duplicate()
	lights.resize(MAX_LIGHTS * LIGHT_FLOATS)
	var lb := lights.to_byte_array()
	_light_buf = rd.storage_buffer_create(lb.size(), lb)
	_write_ubo(Projection.IDENTITY, Projection.IDENTITY, Vector2i(1, 1))
	var dyn_bytes := PackedFloat32Array()
	dyn_bytes.resize(MAX_DYN_BOXES * BOX_FLOATS)
	var db := dyn_bytes.to_byte_array()
	_dyn_buf = rd.storage_buffer_create(db.size(), db)
	_voxelize_static()
	var cl := rd.compute_list_begin()
	_inject(cl, Vector3i.ZERO, dims)
	rd.compute_list_end()
	volume_ready = true


## Debug (render thread, slow): how many voxels of the static volume are solid.
var debug_solid_count := -1


func debug_count_solid() -> void:
	var data := rd.texture_get_data(_vox_static, 0)
	var n := 0
	for k in range(3, data.size(), 4):
		if data[k] > 127:
			n += 1
	debug_solid_count = n


## Main thread, every frame: when the camera has moved more than follow_step from the volume's centre (sideways), the volume is
## moved under it, snapped to follow_step (the spacing of the top cascade's probes, so every probe grid stays on its grid).
func follow(cam_pos: Vector3, cam_forward := Vector3.ZERO) -> void:
	if follow_step <= 0.0 or not volume_ready:
		return
	var size := Vector3(dims) * voxel_size
	# Centre the volume a quarter of its width ahead of the camera: what is behind it is not seen.
	var fwd := Vector3(cam_forward.x, 0.0, cam_forward.z)
	if fwd.length() > 0.01:
		cam_pos += fwd.normalized() * size.x * 0.25
	# The step is a whole number of the top cascade's probe spacings (every finer grid divides it), so after a move every probe
	# grid lies where it lay before; follow_step is only the wish.
	var quantum := probe_spacing * pow(2.0, cascades - 1)
	var step := maxf(ceilf(follow_step / quantum - 0.001), 1.0) * quantum
	var base: Vector3 = _follow_target if _follow_target != Vector3.INF else volume_min
	var centre := base + size * 0.5
	if absf(cam_pos.x - centre.x) <= step and absf(cam_pos.z - centre.z) <= step:
		return
	var want := Vector3(snappedf(cam_pos.x - size.x * 0.5, step), base.y, snappedf(cam_pos.z - size.z * 0.5, step))
	if want == base:
		return
	_follow_target = want
	RenderingServer.call_on_render_thread(_recentre.bind(want))


## Render thread: the volume moves to new_min. Its voxels are made again from the meshes that reach it and lit from scratch; the
## probe light kept between frames is dropped (the bounce builds up again over a few frames).
func _recentre(new_min: Vector3) -> void:
	if rd == null or not volume_ready:
		return
	var t0 := Time.get_ticks_usec()
	volume_min = new_min
	_write_ubo(Projection.IDENTITY, Projection.IDENTITY, Vector2i(1, 1))
	_voxelize_static()
	rd.texture_clear(_amb, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(_amb_iso, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(_vox_dyn, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(_vox_dyn_emit, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_keep_valid = false
	_prev_dyn_count = 0
	var cl := rd.compute_list_begin()
	_inject(cl, Vector3i.ZERO, dims)
	rd.compute_list_end()
	recentres += 1
	recentre_ms = (Time.get_ticks_usec() - t0) / 1000.0


## Voxelizes the static scene again (after a prop was moved or recoloured): same volume, new contents. Render thread.
func revoxelize_static() -> void:
	if rd == null or not volume_ready:
		return
	_write_ubo(Projection.IDENTITY, Projection.IDENTITY, Vector2i(1, 1))
	_voxelize_static()
	if not dynamic:
		var cl := rd.compute_list_begin()
		_inject(cl, Vector3i.ZERO, dims)
		rd.compute_list_end()


## Static geometry -> _vox_static -> _vox_albedo. From the meshes (GPU) when there are any, else from the packed triangles.
func _voxelize_static() -> void:
	var t0 := Time.get_ticks_usec()
	rd.texture_clear(_vox_static, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(_vox_emit, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(_vox_mat, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(_vox_base, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(_vox_wind, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(_vox_emit_w, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(_vox_tint, Color(0, 0, 0, 0), 0, 1, 0, 1)
	if _mesh_surf.size() > 0 and _pipe.has("voxelize_mesh"):
		if _mesh_dirty or not _vert_buf.is_valid():
			for r in [_vert_buf, _idx_buf, _col_buf]:
				if (r as RID).is_valid():
					rd.free_rid(r)
			var vb := _mesh_verts.to_byte_array()
			_vert_buf = rd.storage_buffer_create(vb.size(), vb)
			var ib := _mesh_idx.to_byte_array()
			_idx_buf = rd.storage_buffer_create(ib.size(), ib)
			var cb := _mesh_cols.to_byte_array() if _mesh_cols.size() > 0 else PackedFloat32Array([0, 0, 0, 0]).to_byte_array()
			_col_buf = rd.storage_buffer_create(cb.size(), cb)
			_mesh_dirty = false
		var set_m := UniformSetCacheRD.get_cache(_shader["voxelize_mesh"], 0,
			[_ubo_u(), _img(1, _vox_static), _img(2, _vox_emit), _img(3, _vox_mat), _img(4, _vox_base), _img(7, _vox_wind), _img(8, _vox_tint), _img(10, _vox_emit_w), _u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [_vert_buf]),
			 _u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 6, [_idx_buf]), _u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 9, [_col_buf])])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _pipe["voxelize_mesh"])
		rd.compute_list_bind_uniform_set(cl, set_m, 0)
		var vmin := volume_min - Vector3.ONE * voxel_size
		var vmax := volume_min + Vector3(dims) * voxel_size + Vector3.ONE * voxel_size
		var has_aabb := _mesh_aabb.size() == _mesh_surf.size() / 16 * 6
		voxelized_surfaces = 0
		for k in _mesh_surf.size() / 16:
			var o := k * 16
			var tris := int(_mesh_surf[o])
			if tris == 0:
				continue
			if has_aabb:
				var a := k * 6
				if _mesh_aabb[a + 3] < vmin.x or _mesh_aabb[a] > vmax.x or _mesh_aabb[a + 4] < vmin.y or _mesh_aabb[a + 1] > vmax.y \
						or _mesh_aabb[a + 5] < vmin.z or _mesh_aabb[a + 2] > vmax.z:
					continue # nothing of it is in the volume
			voxelized_surfaces += 1
			rd.compute_list_set_push_constant(cl, _mesh_surf.slice(o, o + 16).to_byte_array(), 64)
			rd.compute_list_dispatch(cl, ceili(tris / 64.0), 1, 1)
		rd.compute_list_end()
		# Solid fill: every voxel whose centre is inside a closed mesh (winding number != 0, summed along +x) becomes solid, so
		# a box is a block and not a shell with an empty inside that probes could sit in and see the inner faces from.
		# The same pass scales every glowing voxel by its coverage (small glowing surfaces in big voxels).
		if _pipe.has("fill_solid"):
			var set_f := UniformSetCacheRD.get_cache(_shader["fill_solid"], 0, [_ubo_u(), _img(1, _vox_static), _img(2, _vox_wind),
				_img(3, _vox_emit), _img(4, _vox_emit_w)])
			cl = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(cl, _pipe["fill_solid"])
			rd.compute_list_bind_uniform_set(cl, set_f, 0)
			rd.compute_list_set_push_constant(cl, PackedFloat32Array([1.0 if solid_fill else 0.0, 0.0, 0.0, 0.0]).to_byte_array(), 16)
			rd.compute_list_dispatch(cl, ceili(dims.y / 8.0), ceili(dims.z / 8.0), 1)
			rd.compute_list_end()
	else:
		if _tri_buf.is_valid():
			rd.free_rid(_tri_buf)
		var tb := _tris.to_byte_array()
		_tri_buf = rd.storage_buffer_create(tb.size(), tb)
		var set_v := UniformSetCacheRD.get_cache(_shader["voxelize"], 0,
			[_ubo_u(), _img(1, _vox_static), _u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [_tri_buf])])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _pipe["voxelize"])
		rd.compute_list_bind_uniform_set(cl, set_v, 0)
		var pc := PackedFloat32Array([_tri_count, 0.0, 0.0, 0.0])
		rd.compute_list_set_push_constant(cl, pc.to_byte_array(), 16)
		rd.compute_list_dispatch(cl, ceili(_tri_count / 64.0), 1, 1)
		rd.compute_list_end()
	rd.texture_copy(_vox_static, _vox_albedo, Vector3.ZERO, Vector3.ZERO, Vector3(dims), 0, 0, 0, 0)
	voxelize_ms = (Time.get_ticks_usec() - t0) / 1000.0 # time to record the work (the GPU runs it after)
	_rad_full = true
	_keep_valid = false


## Direct light into the voxels of one region (first voxel lo, size n) of the volume.
func _inject(cl: int, lo: Vector3i, n: Vector3i) -> void:
	rd.compute_list_bind_compute_pipeline(cl, _pipe["inject"])
	var set_i := UniformSetCacheRD.get_cache(_shader["inject"], 0,
		[_ubo_u(), _img(1, _vox_albedo), _img(3, _vox_rad), _u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [_light_buf]),
		 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 16, [_sampler_lin, _vox_dyn]), _img(21, _vox_dyn),
		 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 14, [_sampler_lin, _vox_albedo]), _img(22, _amb), _img(23, _vox_emit),
		 _img(24, _vox_dyn_emit), _img(25, _vox_nrm), _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 26, [_sampler_lin, _vox_tint])])
	rd.compute_list_bind_uniform_set(cl, set_i, 0)
	var pc := PackedFloat32Array([lo.x, lo.y, lo.z, bounce, emission_scale, 0.0, 0.0, 0.0])
	rd.compute_list_set_push_constant(cl, pc.to_byte_array(), 32)
	rd.compute_list_dispatch(cl, ceili(n.x / 4.0), ceili(n.y / 4.0), ceili(n.z / 4.0))


func _render_callback(_type: int, render_data: RenderData) -> void:
	if not gi_enabled or not volume_ready or rd == null:
		return
	if not (_pipe.has("cascade3d") and _pipe.has("gather3d")):
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data() as RenderSceneDataRD
	if buffers == null or scene_data == null:
		return
	var size := buffers.get_internal_size()
	var albedo_tex := RID()
	if use_albedo_texture and albedo_texture_rid.is_valid():
		albedo_tex = RenderingServer.texture_get_rd_texture(albedo_texture_rid)
	var use_final := final_gather and _pipe.has("nearfield") and _pipe.has("final")
	var near := near_range if use_final else 0.0
	if use_final:
		_ensure_screen_textures(size)
	var view_proj := scene_data.get_view_projection(0)
	var cam_xf := Projection(scene_data.get_cam_transform())
	var use_hist := use_final and temporal and _hist_valid
	_write_ubo(view_proj, cam_xf, size, albedo_tex.is_valid(), near, use_hist, temporal_alpha if temporal else 1.0, _prev_vp)
	var albedo_u := _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 11,
		[_sampler, albedo_tex if albedo_tex.is_valid() else buffers.get_depth_layer(0)])

	var depth_u := _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 8, [_sampler, buffers.get_depth_layer(0)])
	var color_u := _img(9, buffers.get_color_layer(0))

	rays_per_frame = 0
	rd.capture_timestamp("RC begin")
	if dynamic:
		_update_dynamic_volume()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipe["cascade3d"])
	# The far cascades change slowly: on most frames they are not traced again, and the nearer ones merge with the copy kept
	# from the last frame that traced them.
	var keep := far_every > 1 and cascades > far_from
	var skip_far := keep and _keep_valid and _cframe % far_every != 0
	last_far_skipped = skip_far
	var top := far_from - 1 if skip_far else cascades - 1
	var inp: RID = _probe_keep if skip_far else _probe[1]
	var outi := 0
	for n in range(top, -1, -1):
		var out_t: RID = _probe[outi]
		var spacing := probe_spacing * pow(2.0, n)
		var an := A0 << n
		var g := _grid(spacing)
		var tdim := Vector3i(g.x * an, g.y * an, g.z)
		rays_per_frame += tdim.x * tdim.y * tdim.z
		var start := near + interval0 * (pow(4.0, n) - 1.0) / 3.0
		var end := start + interval0 * pow(4.0, n)
		if n < cascades - 1:
			rd.compute_list_bind_compute_pipeline(cl, _pipe["probe_weights"])
			var wset := UniformSetCacheRD.get_cache(_shader["probe_weights"], 0,
				[_ubo_u(), _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 14, [_sampler_lin, _vox_albedo]),
					 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 16, [_sampler_lin, _vox_dyn]), _img(19, _pw_lo), _img(20, _pw_hi)])
			var wpc := PackedFloat32Array([spacing, 0.0, 0.0, 0.0])
			rd.compute_list_bind_uniform_set(cl, wset, 0)
			rd.compute_list_set_push_constant(cl, wpc.to_byte_array(), 16)
			rd.compute_list_dispatch(cl, ceili(g.x / 4.0), ceili(g.y / 4.0), ceili(g.z / 4.0))
			rd.compute_list_add_barrier(cl)
			rd.compute_list_bind_compute_pipeline(cl, _pipe["cascade3d"])
		var set_rid := UniformSetCacheRD.get_cache(_shader["cascade3d"], 0,
			[_ubo_u(), _img(1, _vox_albedo), _img(3, _vox_rad), _img(6, inp), _img(7, out_t), _img(19, _pw_lo), _img(20, _pw_hi),
				 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 14, [_sampler_lin, _vox_albedo]),
				 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 15, [_sampler_lin, _vox_rad]),
				 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 16, [_sampler_lin, _vox_dyn]),
				 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 21, [_sampler_lin, _vox_nrm]),
				 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 23, [_sampler_lin, _vox_tint]),
				 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 25, [_sampler, _dyn_mask])])
		var pc := PackedFloat32Array([n, an, spacing, 1.0 if n == cascades - 1 else 0.0, start, end, 0.0, 0.0])
		rd.compute_list_bind_uniform_set(cl, set_rid, 0)
		rd.compute_list_set_push_constant(cl, pc.to_byte_array(), 32)
		rd.compute_list_dispatch(cl, ceili(tdim.x / 4.0), ceili(tdim.y / 4.0), ceili(tdim.z / 4.0))
		rd.compute_list_add_barrier(cl)
		if keep and not skip_far and n == far_from:
			rd.compute_list_end()
			rd.texture_copy(out_t, _probe_keep, Vector3.ZERO, Vector3.ZERO, Vector3(_probe_dim), 0, 0, 0, 0)
			_keep_valid = true
			cl = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(cl, _pipe["cascade3d"])
		inp = out_t
		outi = 1 - outi
	if (bounce > 0.0 or fog) and _pipe.has("ambient"):
		# Ambient cubes from cascade 0, for the next frame's injection (more bounces) and for the fog.
		rd.compute_list_bind_compute_pipeline(cl, _pipe["ambient"])
		var aset := UniformSetCacheRD.get_cache(_shader["ambient"], 0, [_ubo_u(), _img(10, inp), _img(22, _amb), _img(23, _amb_iso)])
		var g0 := _grid(probe_spacing)
		rd.compute_list_bind_uniform_set(cl, aset, 0)
		rd.compute_list_set_push_constant(cl, PackedFloat32Array([A0, 0.0, 0.0, 0.0]).to_byte_array(), 16)
		rd.compute_list_dispatch(cl, ceili(g0.x / 4.0), ceili(g0.y / 4.0), ceili(g0.z / 4.0))
	rd.compute_list_end()
	_cframe += 1
	rd.capture_timestamp("RC cascades")

	if use_final:
		var shift_x := int(fposmod(_frame * 0.7548776662, 1.0) * near_dirs)
		var shift_y := int(fposmod(_frame * 0.5698402910, 1.0) * near_dirs)
		var cur := _pp
		cl = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _pipe["nearfield"])
		var nr_tex := buffers.get_texture("forward_clustered", "normal_roughness")
		_has_nr = nr_tex.is_valid()
		_ensure_prev_color(size)
		var near_set := UniformSetCacheRD.get_cache(_shader["nearfield"], 0,
			[_ubo_u(), _img(1, _vox_albedo), depth_u, color_u, _img(10, inp), _img(12, _near_tex), _img(13, _nrm[cur]), _img(17, _spec_tex),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 18, [_sampler, _vox_mat]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 19, [_sampler, _vox_base]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 14, [_sampler_lin, _vox_albedo]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 15, [_sampler_lin, _vox_rad]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 16, [_sampler_lin, _vox_dyn]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 21, [_sampler_lin, _vox_nrm]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 23, [_sampler_lin, _vox_tint]), _img(24, _prev_color),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 25, [_sampler, _dyn_mask]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 22, [_sampler, nr_tex if nr_tex.is_valid() else buffers.get_depth_layer(0)])])
		var npc := PackedFloat32Array([A0, near_dirs, shift_x, shift_y])
		rd.compute_list_bind_uniform_set(cl, near_set, 0)
		rd.compute_list_set_push_constant(cl, npc.to_byte_array(), 16)
		rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		rd.compute_list_end()
		rd.capture_timestamp("RC near-field rays")
		cl = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _pipe["final"])
		var final_set := UniformSetCacheRD.get_cache(_shader["final"], 0,
			[_ubo_u(), color_u, albedo_u, depth_u, _img(12, _near_tex), _img(13, _nrm[cur]), _img(16, _nrm[1 - cur]),
			 _img(17, _hist[1 - cur]), _img(18, _hist[cur]), _img(20, _spec_tex), _img(21, _dir[1 - cur]), _img(22, _dir[cur]),
			 _img(26, _spec_hist[1 - cur]), _img(27, _spec_hist[cur]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 23, [_sampler, nr_tex if nr_tex.is_valid() else buffers.get_depth_layer(0)])])
		var fpc := npc.duplicate()
		fpc.append_array([0.0, spec_strength, 0.0, 0.0])
		rd.compute_list_bind_uniform_set(cl, final_set, 0)
		rd.compute_list_set_push_constant(cl, fpc.to_byte_array(), 32)
		rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		if denoise:
			# Pass 1: filter this frame's result (bound as hist_prev) and add it to the image.
			rd.compute_list_add_barrier(cl)
			var filt_set := UniformSetCacheRD.get_cache(_shader["final"], 0,
				[_ubo_u(), color_u, albedo_u, depth_u, _img(12, _near_tex), _img(13, _nrm[cur]), _img(16, _nrm[1 - cur]),
				 _img(17, _hist[cur]), _img(18, _hist[1 - cur]), _img(20, _spec_tex), _img(21, _dir[cur]), _img(22, _dir[1 - cur]),
				 _img(26, _spec_hist[cur]), _img(27, _spec_hist[1 - cur]),
				 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 23, [_sampler, nr_tex if nr_tex.is_valid() else buffers.get_depth_layer(0)])])
			fpc[4] = 1.0
			rd.compute_list_bind_uniform_set(cl, filt_set, 0)
			rd.compute_list_set_push_constant(cl, fpc.to_byte_array(), 32)
			rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		rd.compute_list_end()
		if _prev_color.is_valid() and _pipe.has("copy_color"):
			cl = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(cl, _pipe["copy_color"])
			rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(_shader["copy_color"], 0, [_ubo_u(), color_u, _img(24, _prev_color)]), 0)
			rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
			rd.compute_list_end()
			_prev_color_valid = true
		rd.capture_timestamp("RC final gather")
		if fog and _pipe.has("fog"):
			cl = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(cl, _pipe["fog"])
			rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(_shader["fog"], 0,
				[_ubo_u(), depth_u, color_u, _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 10, [_sampler_lin, _amb_iso])]), 0)
			var fog_pc := PackedFloat32Array([fog_density, fog_height, fog_base, fog_distance, fog_steps, _frame % 1024, fog_brightness, 0.0])
			rd.compute_list_set_push_constant(cl, fog_pc.to_byte_array(), 32)
			rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
			rd.compute_list_end()
			rd.capture_timestamp("RC fog")
		_prev_vp = view_proj * cam_xf.inverse()
		_pp = 1 - _pp
		_frame += 1
		_hist_valid = true
		return

	cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipe["gather3d"])
	var gather_set := UniformSetCacheRD.get_cache(_shader["gather3d"], 0,
		[_ubo_u(), _img(1, _vox_albedo), depth_u, color_u, _img(10, inp), albedo_u])
	var gpc := PackedFloat32Array([A0, 0.0, 0.0, 0.0])
	rd.compute_list_bind_uniform_set(cl, gather_set, 0)
	rd.compute_list_set_push_constant(cl, gpc.to_byte_array(), 16)
	rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	rd.compute_list_end()
	rd.capture_timestamp("RC gather")


func _ensure_screen_textures(size: Vector2i) -> void:
	if size == _screen_tex_size and _near_tex.is_valid():
		return
	for r in [_near_tex, _nrm[0], _nrm[1], _hist[0], _hist[1], _spec_tex, _dir[0], _dir[1], _spec_hist[0], _spec_hist[1]]:
		if (r as RID).is_valid():
			rd.free_rid(r)
	var f := RDTextureFormat.new()
	f.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	f.width = size.x
	f.height = size.y
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_near_tex = rd.texture_create(f, RDTextureView.new(), [])
	_spec_tex = rd.texture_create(f, RDTextureView.new(), [])
	for i in 2:
		_nrm[i] = rd.texture_create(f, RDTextureView.new(), [])
		_hist[i] = rd.texture_create(f, RDTextureView.new(), [])
		_dir[i] = rd.texture_create(f, RDTextureView.new(), [])
		_spec_hist[i] = rd.texture_create(f, RDTextureView.new(), [])
		rd.texture_clear(_spec_hist[i], Color(0, 0, 0, 0), 0, 1, 0, 1)
		rd.texture_clear(_dir[i], Color(0, 0, 0, 0), 0, 1, 0, 1)
		rd.texture_clear(_nrm[i], Color(0, 0, 0, 0), 0, 1, 0, 1)
		rd.texture_clear(_hist[i], Color(0, 0, 0, 0), 0, 1, 0, 1)
	_screen_tex_size = size
	_hist_valid = false


## A copy of the finished picture, same format as Godot's colour buffer, for the next frame's sharp reflections.
func _ensure_prev_color(size: Vector2i) -> void:
	if _prev_color.is_valid() and _prev_color_size == size:
		return
	if _prev_color.is_valid():
		rd.free_rid(_prev_color)
	var nf := RDTextureFormat.new()
	nf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	nf.width = size.x
	nf.height = size.y
	nf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_prev_color = rd.texture_create(nf, RDTextureView.new(), [])
	rd.texture_clear(_prev_color, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_prev_color_size = size
	_prev_color_valid = false


## Per frame: the moving objects voxelized again (when they moved), then the direct light injected again, but only into the part of
## the volume that can have changed: the reach of every light that changed, and of every light that reaches a moving object.
func _update_dynamic_volume() -> void:
	var lights := _lights.duplicate()
	lights.resize(MAX_LIGHTS * LIGHT_FLOATS)
	var lb := lights.to_byte_array()
	rd.buffer_update(_light_buf, 0, lb.size(), lb)
	var boxes := _dyn_boxes.slice(0, _dyn_count * BOX_FLOATS)
	var boxes_moved := _rad_full or _dyn_count != _prev_dyn_count or boxes != _prev_boxes
	var cl := rd.compute_list_begin()
	if boxes_moved:
		rd.compute_list_end()
		rd.texture_clear(_vox_dyn, Color(0, 0, 0, 0), 0, 1, 0, 1)
		rd.texture_clear(_vox_dyn_emit, Color(0, 0, 0, 0), 0, 1, 0, 1)
		if _dyn_count > 0:
			var tb := boxes.to_byte_array()
			rd.buffer_update(_dyn_buf, 0, tb.size(), tb)
		cl = rd.compute_list_begin()
	if boxes_moved and _dyn_count > 0:
		rd.compute_list_bind_compute_pipeline(cl, _pipe["voxelize_boxes"])
		var set_v := UniformSetCacheRD.get_cache(_shader["voxelize_boxes"], 0,
			[_ubo_u(), _img(1, _vox_dyn), _img(2, _vox_dyn_emit), _u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [_dyn_buf])])
		rd.compute_list_bind_uniform_set(cl, set_v, 0)
		for i in _dyn_count:
			var o := i * BOX_FLOATS
			var c := Vector3(_dyn_boxes[o], _dyn_boxes[o + 1], _dyn_boxes[o + 2])
			var ext := Vector3.ZERO
			for k in 3:
				ext += Vector3(absf(_dyn_boxes[o + 4 + k * 4]), absf(_dyn_boxes[o + 5 + k * 4]), absf(_dyn_boxes[o + 6 + k * 4]))
			var lo := ((c - ext - volume_min) / voxel_size).floor().clamp(Vector3.ZERO, Vector3(dims) - Vector3.ONE)
			var hi := ((c + ext - volume_min) / voxel_size).floor().clamp(Vector3.ZERO, Vector3(dims) - Vector3.ONE)
			var n := (hi - lo) + Vector3.ONE * 2.0 # +1 slack: the shader trims the excess threads
			var pc := PackedFloat32Array([i, 0.0, 0.0, 0.0])
			rd.compute_list_set_push_constant(cl, pc.to_byte_array(), 16)
			rd.compute_list_dispatch(cl, ceili(n.x / 4.0), ceili(n.y / 4.0), ceili(n.z / 4.0))
		rd.compute_list_add_barrier(cl)
	var region := _dirty_region(boxes_moved)
	inject_fraction = 0.0
	if region.size != Vector3i.ZERO:
		_inject(cl, region.position, region.size)
		inject_fraction = float(region.size.x * region.size.y * region.size.z) / float(dims.x * dims.y * dims.z)
	rd.compute_list_end()
	rd.capture_timestamp("RC dynamic voxels + inject")
	_prev_lights = _lights.duplicate()
	_prev_boxes = boxes
	_prev_dyn_count = _dyn_count
	_prev_dyn_min = _dyn_min
	_prev_dyn_max = _dyn_max
	_rad_full = false


## The voxels to light again this frame, as an AABBi (size zero = none).
func _dirty_region(boxes_moved: bool) -> AABBi:
	var whole := AABBi.new(Vector3i.ZERO, dims)
	if _rad_full or not inject_partial:
		return whole
	# With more bounces, the light of every surface depends on the rest of the scene: light everything again now and then.
	if bounce > 0.0 and _cframe % maxi(bounce_full_every, 1) == 0:
		return whole
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var count := maxi(_lights.size(), _prev_lights.size()) / LIGHT_FLOATS
	for i in count:
		var o := i * LIGHT_FLOATS
		var now := _lights.slice(o, o + LIGHT_FLOATS)
		var was := _prev_lights.slice(o, o + LIGHT_FLOATS)
		if now == was:
			continue
		for rec in [now, was]:
			if rec.size() < LIGHT_FLOATS:
				continue
			if rec[7] > 0.5 and rec[7] < 1.5: # a directional light changed: its shadows can move anywhere
				if rec[4] + rec[5] + rec[6] > 0.0:
					return whole
				continue
			var r: Vector3 = Vector3.ONE * float(rec[3])
			var p := Vector3(float(rec[0]), float(rec[1]), float(rec[2]))
			lo = lo.min(p - r)
			hi = hi.max(p + r)
	if boxes_moved:
		var b_lo := _dyn_min if _dyn_count > 0 else Vector3(INF, INF, INF)
		var b_hi := _dyn_max if _dyn_count > 0 else Vector3(-INF, -INF, -INF)
		if _prev_dyn_count > 0:
			b_lo = b_lo.min(_prev_dyn_min)
			b_hi = b_hi.max(_prev_dyn_max)
		if b_lo.x <= b_hi.x:
			lo = lo.min(b_lo)
			hi = hi.max(b_hi)
			# Every light that reaches the moving objects can cast a changed shadow anywhere in its own reach.
			for i in _lights.size() / LIGHT_FLOATS:
				var o := i * LIGHT_FLOATS
				if _lights[o + 7] > 0.5 and _lights[o + 7] < 1.5:
					if _lights[o + 4] + _lights[o + 5] + _lights[o + 6] > 0.0:
						return whole
					continue
				var p := Vector3(_lights[o], _lights[o + 1], _lights[o + 2])
				var r := _lights[o + 3]
				if p.clamp(b_lo, b_hi).distance_to(p) <= r:
					lo = lo.min(p - Vector3.ONE * r)
					hi = hi.max(p + Vector3.ONE * r)
	if lo.x > hi.x:
		return AABBi.new(Vector3i.ZERO, Vector3i.ZERO)
	# A few voxels of margin: the surface normal of a voxel looks two voxels around it.
	var margin := Vector3.ONE * 3.0
	var v_lo := Vector3i(((lo - volume_min) / voxel_size - margin).floor().clamp(Vector3.ZERO, Vector3(dims)))
	var v_hi := Vector3i(((hi - volume_min) / voxel_size + margin).ceil().clamp(Vector3.ZERO, Vector3(dims)))
	var size := v_hi - v_lo
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return AABBi.new(Vector3i.ZERO, Vector3i.ZERO)
	return AABBi.new(v_lo, size)


class AABBi:
	var position: Vector3i
	var size: Vector3i

	func _init(p: Vector3i, s: Vector3i) -> void:
		position = p
		size = s


## GPU time (ms) of the passes captured in the last finished frame, keyed by pass name.
func collect_timings() -> Dictionary:
	var out := {}
	if rd == null:
		return out
	var prev := -1
	for i in rd.get_captured_timestamps_count():
		var name := rd.get_captured_timestamp_name(i)
		if not name.begins_with("RC"):
			continue
		var t := rd.get_captured_timestamp_gpu_time(i)
		if prev >= 0:
			out[name] = (t - prev) / 1.0e6
		prev = t
	return out
