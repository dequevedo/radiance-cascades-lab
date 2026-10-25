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
@export var sky_radiance := Color(0.02, 0.03, 0.06)
@export var debug_mode := 0 # 0 composite, 1 indirect only, 2 voxel albedo under the pixel
@export var use_albedo_texture := true # per-pixel albedo from a second, unshaded render (a stand-in for a G-buffer)
@export var final_gather := true # per-pixel short rays + 4x4 gather for the near field (probes only start past near_range)
@export var near_range := 0.5 # metres covered by the per-pixel rays
@export var near_dirs := 6 # directions per axis of the per-pixel tile (6 -> 36 directions, one per pixel of a 6x6 block)
@export var temporal := true # blend with the reprojected previous frame (the tile of directions shifts every frame)
@export var temporal_adaptive := 1.2 # extra weight of the new frame where it differs a lot from the history (0 = fixed alpha)
@export var temporal_alpha := 0.25 # weight of the new frame (lower = smoother but slower to follow changes)
@export var dynamic := false # per frame: reset to the static voxels, add dynamic triangles, re-inject the lights
@export var inject_partial := true # re-light only the part of the volume that a changed light or a moving object can affect
@export var far_every := 2 # the far cascades (far_from and up) are traced every Nth frame; 1 = every frame
@export var far_from := 2
@export var split := -1.0 # split view: fraction of the screen width, left of it shows no bounce light; < 0 = off

const MAX_DYN_BOXES := 64

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
var _vert_buf := RID()
var _idx_buf := RID()
# Far cascades kept between frames.
var _probe_keep := RID()
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


## Every visible mesh surface under root, for the GPU voxelizer: world-space vertices (one native multiply per surface, no
## per-triangle work in GDScript), indices as they are, and one record per surface. Same skip rules as collect_triangles.
static var _surface_cache := {}


static func collect_meshes(root: Node) -> Dictionary:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var surf := PackedFloat32Array()
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
				cached = [cv, ci]
				_surface_cache[key] = cached
			var v: PackedVector3Array = cached[0]
			var ii: PackedInt32Array = cached[1]
			surf.append_array([ii.size() / 3, idx.size(), verts.size(), 0.0, albedo.r, albedo.g, albedo.b, 0.0])
			verts.append_array(xf * v)
			idx.append_array(ii)
	return {"verts": verts, "idx": idx, "surf": surf, "tris": idx.size() / 3}


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
		out.append_array([c.x, c.y, c.z, 0.0, ax.x, ax.y, ax.z, 0.0, ay.x, ay.y, ay.z, 0.0, az.x, az.y, az.z, 0.0,
			albedo.r, albedo.g, albedo.b, 0.0])
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
		if omni != null and omni.visible:
			var c := omni.light_color.srgb_to_linear() * omni.light_energy
			var p := omni.global_position
			out.append_array([p.x, p.y, p.z, omni.omni_range, c.r, c.g, c.b, 0.0, 0.0, 0.0, 0.0, omni.omni_attenuation])
		var sun := node as DirectionalLight3D
		if sun != null and sun.visible:
			var c2 := sun.light_color.srgb_to_linear() * sun.light_energy
			var d := sun.global_transform.basis.z
			out.append_array([0.0, 0.0, 0.0, 0.0, c2.r, c2.g, c2.b, 1.0, d.x, d.y, d.z, 0.0])
	return out


## Per-frame input for dynamic scenes (call on the render thread): the moving boxes (see collect_boxes) and all lights.
func update_dynamic(boxes: PackedFloat32Array, lights: PackedFloat32Array) -> void:
	_dyn_boxes = boxes
	_dyn_count = mini(boxes.size() / 20, MAX_DYN_BOXES)
	# Bounds of everything that moves (plus a margin): inside them shadows are marched softly.
	if _dyn_count > 0:
		_dyn_min = Vector3(INF, INF, INF)
		_dyn_max = Vector3(-INF, -INF, -INF)
		for i in _dyn_count:
			var o := i * 20
			var c := Vector3(boxes[o], boxes[o + 1], boxes[o + 2])
			var ext := Vector3.ZERO
			for k in 3:
				var ax := Vector3(boxes[o + 4 + k * 4], boxes[o + 5 + k * 4], boxes[o + 6 + k * 4])
				ext += Vector3(absf(ax.x), absf(ax.y), absf(ax.z))
			_dyn_min = _dyn_min.min(c - ext - Vector3.ONE * 0.3)
			_dyn_max = _dyn_max.max(c + ext + Vector3.ONE * 0.3)
	_lights = lights
	_light_count = mini(lights.size() / 12, 16)


func set_scene(tris: PackedFloat32Array, lights: PackedFloat32Array) -> void:
	_tris = tris
	_tri_count = tris.size() / 16
	_mesh_surf = PackedFloat32Array()
	_lights = lights
	_light_count = mini(lights.size() / 12, 16)


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
	_tri_count = meshes["tris"]
	_tris = PackedFloat32Array()
	_lights = lights
	_light_count = mini(lights.size() / 12, 16)


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
	for n in ["voxelize", "voxelize_mesh", "voxelize_boxes", "inject", "cascade3d", "gather3d", "nearfield", "final", "probe_weights"]:
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
	_ubo = rd.uniform_buffer_create(400)


func free_resources() -> void:
	if rd == null:
		return
	gi_enabled = false
	volume_ready = false
	_free_volume()
	for r in _pipe.values() + _shader.values() + [_sampler, _sampler_lin, _ubo, _near_tex, _nrm[0], _nrm[1], _hist[0], _hist[1]]:
		if (r as RID).is_valid():
			rd.free_rid(r)
	_pipe.clear()
	_shader.clear()


func _free_volume() -> void:
	for r in [_tri_buf, _light_buf, _dyn_buf, _vox_static, _vox_dyn, _vox_albedo, _vox_rad, _pw_lo, _pw_hi, _probe[0], _probe[1],
			_probe_keep, _vert_buf, _idx_buf]:
		if (r as RID).is_valid():
			rd.free_rid(r)
	_probe_keep = RID()
	_vert_buf = RID()
	_idx_buf = RID()
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
	p.append_array([size.x, size.y, split, 0.0])
	p.append_array([volume_min.x, volume_min.y, volume_min.z, voxel_size])
	p.append_array([dims.x, dims.y, dims.z, _light_count])
	p.append_array([intensity, albedo_luma, max_radiance, float(debug_mode)])
	p.append_array([sky_radiance.r, sky_radiance.g, sky_radiance.b, 0.0])
	p.append_array([probe_spacing, interval0, gather_bias, 1.0 if use_albedo_tex else 0.0])
	p.append_array([near, 1.0 if hist_valid else 0.0, alpha, temporal_adaptive])
	_pack_mat(prev_vp, p)
	p.append_array([_dyn_min.x, _dyn_min.y, _dyn_min.z, 1.0 if (dynamic and _dyn_count > 0) else 0.0])
	p.append_array([_dyn_max.x, _dyn_max.y, _dyn_max.z, 0.0])
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
	var g0 := _grid(probe_spacing)
	_pw_lo = _tex3d(g0, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_pw_hi = _tex3d(g0, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var lights := _lights.duplicate()
	lights.resize(16 * 12)
	var lb := lights.to_byte_array()
	_light_buf = rd.storage_buffer_create(lb.size(), lb)
	_write_ubo(Projection.IDENTITY, Projection.IDENTITY, Vector2i(1, 1))
	var dyn_bytes := PackedFloat32Array()
	dyn_bytes.resize(MAX_DYN_BOXES * 20)
	var db := dyn_bytes.to_byte_array()
	_dyn_buf = rd.storage_buffer_create(db.size(), db)
	_voxelize_static()
	var cl := rd.compute_list_begin()
	_inject(cl, Vector3i.ZERO, dims)
	rd.compute_list_end()
	volume_ready = true


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
	if _mesh_surf.size() > 0 and _pipe.has("voxelize_mesh"):
		for r in [_vert_buf, _idx_buf]:
			if (r as RID).is_valid():
				rd.free_rid(r)
		var vb := _mesh_verts.to_byte_array()
		_vert_buf = rd.storage_buffer_create(vb.size(), vb)
		var ib := _mesh_idx.to_byte_array()
		_idx_buf = rd.storage_buffer_create(ib.size(), ib)
		var set_m := UniformSetCacheRD.get_cache(_shader["voxelize_mesh"], 0,
			[_ubo_u(), _img(1, _vox_static), _u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [_vert_buf]),
			 _u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 6, [_idx_buf])])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _pipe["voxelize_mesh"])
		rd.compute_list_bind_uniform_set(cl, set_m, 0)
		for k in _mesh_surf.size() / 8:
			var o := k * 8
			var tris := int(_mesh_surf[o])
			if tris == 0:
				continue
			rd.compute_list_set_push_constant(cl, _mesh_surf.slice(o, o + 8).to_byte_array(), 32)
			rd.compute_list_dispatch(cl, ceili(tris / 64.0), 1, 1)
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
		 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 16, [_sampler_lin, _vox_dyn]), _img(21, _vox_dyn)])
	rd.compute_list_bind_uniform_set(cl, set_i, 0)
	var pc := PackedFloat32Array([lo.x, lo.y, lo.z, 0.0])
	rd.compute_list_set_push_constant(cl, pc.to_byte_array(), 16)
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
				 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 16, [_sampler_lin, _vox_dyn])])
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
	rd.compute_list_end()
	_cframe += 1
	rd.capture_timestamp("RC cascades")

	if use_final:
		var shift_x := int(fposmod(_frame * 0.7548776662, 1.0) * near_dirs)
		var shift_y := int(fposmod(_frame * 0.5698402910, 1.0) * near_dirs)
		var cur := _pp
		cl = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, _pipe["nearfield"])
		var near_set := UniformSetCacheRD.get_cache(_shader["nearfield"], 0,
			[_ubo_u(), _img(1, _vox_albedo), depth_u, _img(10, inp), _img(12, _near_tex), _img(13, _nrm[cur]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 14, [_sampler_lin, _vox_albedo]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 15, [_sampler_lin, _vox_rad]),
			 _u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 16, [_sampler_lin, _vox_dyn])])
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
			 _img(17, _hist[1 - cur]), _img(18, _hist[cur])])
		rd.compute_list_bind_uniform_set(cl, final_set, 0)
		rd.compute_list_set_push_constant(cl, npc.to_byte_array(), 16)
		rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		rd.compute_list_end()
		rd.capture_timestamp("RC final gather")
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
	for r in [_near_tex, _nrm[0], _nrm[1], _hist[0], _hist[1]]:
		if (r as RID).is_valid():
			rd.free_rid(r)
	var f := RDTextureFormat.new()
	f.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	f.width = size.x
	f.height = size.y
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_near_tex = rd.texture_create(f, RDTextureView.new(), [])
	for i in 2:
		_nrm[i] = rd.texture_create(f, RDTextureView.new(), [])
		_hist[i] = rd.texture_create(f, RDTextureView.new(), [])
		rd.texture_clear(_nrm[i], Color(0, 0, 0, 0), 0, 1, 0, 1)
		rd.texture_clear(_hist[i], Color(0, 0, 0, 0), 0, 1, 0, 1)
	_screen_tex_size = size
	_hist_valid = false


## Per frame: the moving objects voxelized again (when they moved), then the direct light injected again, but only into the part of
## the volume that can have changed: the reach of every light that changed, and of every light that reaches a moving object.
func _update_dynamic_volume() -> void:
	var lights := _lights.duplicate()
	lights.resize(16 * 12)
	var lb := lights.to_byte_array()
	rd.buffer_update(_light_buf, 0, lb.size(), lb)
	var boxes := _dyn_boxes.slice(0, _dyn_count * 20)
	var boxes_moved := _rad_full or _dyn_count != _prev_dyn_count or boxes != _prev_boxes
	var cl := rd.compute_list_begin()
	if boxes_moved:
		rd.compute_list_end()
		rd.texture_clear(_vox_dyn, Color(0, 0, 0, 0), 0, 1, 0, 1)
		if _dyn_count > 0:
			var tb := boxes.to_byte_array()
			rd.buffer_update(_dyn_buf, 0, tb.size(), tb)
		cl = rd.compute_list_begin()
	if boxes_moved and _dyn_count > 0:
		rd.compute_list_bind_compute_pipeline(cl, _pipe["voxelize_boxes"])
		var set_v := UniformSetCacheRD.get_cache(_shader["voxelize_boxes"], 0,
			[_ubo_u(), _img(1, _vox_dyn), _u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [_dyn_buf])])
		rd.compute_list_bind_uniform_set(cl, set_v, 0)
		for i in _dyn_count:
			var o := i * 20
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
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var count := maxi(_lights.size(), _prev_lights.size()) / 12
	for i in count:
		var o := i * 12
		var now := _lights.slice(o, o + 12)
		var was := _prev_lights.slice(o, o + 12)
		if now == was:
			continue
		for rec in [now, was]:
			if rec.size() < 12:
				continue
			if rec[7] > 0.5: # a directional light changed: its shadows can move anywhere
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
			for i in _lights.size() / 12:
				var o := i * 12
				if _lights[o + 7] > 0.5:
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
