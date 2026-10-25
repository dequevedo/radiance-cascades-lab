extends CompositorEffect
## Screen-space Radiance Cascades GI: cascades traced through the depth buffer, merged top-down,
## gathered per pixel. Prototype: single bounce, no temporal reuse, albedo guessed from scene colour.

const A0 := 4          # directions per axis in cascade 0 (a_n = A0 << n, probe spacing = a_n GI pixels)
const R0_PX := 8.0     # cascade 0 interval length in screen pixels (each next one is 4x longer)

@export var gi_enabled := true
@export var cascades := 5
@export var gi_scale := 2
@export var intensity := 1.0
@export var albedo_luma := 0.6
@export var thickness := 0.4
@export var bias_px := 2.0
@export var max_radiance := 16.0
@export var max_steps := 40
@export var sky_radiance := Color(0.5, 0.7, 1.0)
@export var offscreen_fill := 0.0
@export var debug_mode := 0 # 0 = composite, 1 = indirect light only

var rd: RenderingDevice
var _cascade_shader := RID()
var _cascade_pipe := RID()
var _gather_shader := RID()
var _gather_pipe := RID()
var _sampler := RID()
var _ubo := RID()
var _tex: Array[RID] = [RID(), RID()]
var _tex_size := Vector2i.ZERO
var rays_per_frame := 0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_init_rd)


func _compile(body_path: String) -> RID:
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = "#version 450\n" \
		+ FileAccess.get_file_as_string("res://src/rc/shaders/common.inc") + "\n" \
		+ FileAccess.get_file_as_string(body_path)
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("Shader %s: %s" % [body_path, spirv.compile_error_compute])
		return RID()
	return rd.shader_create_from_spirv(spirv)


func _init_rd() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return
	_cascade_shader = _compile("res://src/rc/shaders/cascade.comp")
	_gather_shader = _compile("res://src/rc/shaders/gather.comp")
	if _cascade_shader.is_valid():
		_cascade_pipe = rd.compute_pipeline_create(_cascade_shader)
	if _gather_shader.is_valid():
		_gather_pipe = rd.compute_pipeline_create(_gather_shader)
	_sampler = rd.sampler_create(RDSamplerState.new())
	_ubo = rd.uniform_buffer_create(192)


## Call on the render thread before the effect is dropped.
func free_resources() -> void:
	if rd == null:
		return
	gi_enabled = false
	for r in [_cascade_pipe, _gather_pipe, _cascade_shader, _gather_shader, _sampler, _ubo, _tex[0], _tex[1]]:
		if r.is_valid():
			rd.free_rid(r)
	_cascade_pipe = RID()
	_gather_pipe = RID()


func _make_textures(size: Vector2i) -> void:
	for i in 2:
		if _tex[i].is_valid():
			rd.free_rid(_tex[i])
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = size.x
	fmt.height = size.y
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	for i in 2:
		_tex[i] = rd.texture_create(fmt, RDTextureView.new(), [])
	_tex_size = size


static func _pack_mat(m: Projection, out: PackedFloat32Array) -> void:
	for col in [m.x, m.y, m.z, m.w]:
		out.append(col.x)
		out.append(col.y)
		out.append(col.z)
		out.append(col.w)


func _image(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u


func _render_callback(_type: int, render_data: RenderData) -> void:
	if not gi_enabled or rd == null or not _cascade_pipe.is_valid() or not _gather_pipe.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data() as RenderSceneDataRD
	if buffers == null or scene_data == null:
		return

	var size := buffers.get_internal_size()
	var align := A0 << (cascades - 1)
	var gi_size := Vector2i(
		int(ceil(float(size.x) / gi_scale / align)) * align,
		int(ceil(float(size.y) / gi_scale / align)) * align)
	if gi_size != _tex_size:
		_make_textures(gi_size)
	rays_per_frame = cascades * gi_size.x * gi_size.y

	var proj := scene_data.get_view_projection(0)
	var params := PackedFloat32Array()
	_pack_mat(proj, params)
	_pack_mat(proj.inverse(), params)
	params.append_array([size.x, size.y, gi_size.x, gi_size.y])
	params.append_array([gi_scale, thickness, bias_px, 0.0])
	params.append_array([sky_radiance.r, sky_radiance.g, sky_radiance.b, offscreen_fill])
	params.append_array([intensity, albedo_luma, max_radiance, float(debug_mode)])
	var bytes := params.to_byte_array()
	rd.buffer_update(_ubo, 0, bytes.size(), bytes)

	var ubo_u := RDUniform.new()
	ubo_u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	ubo_u.binding = 0
	ubo_u.add_id(_ubo)
	var depth_u := RDUniform.new()
	depth_u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth_u.binding = 1
	depth_u.add_id(_sampler)
	depth_u.add_id(buffers.get_depth_layer(0))
	var color_u := _image(2, buffers.get_color_layer(0))

	var gx := ceili(gi_size.x / 8.0)
	var gy := ceili(gi_size.y / 8.0)
	rd.capture_timestamp("RC begin")
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _cascade_pipe)
	var src := 0
	for n in range(cascades - 1, -1, -1):
		var upper := _tex[src]
		var out := _tex[1 - src]
		var set_rid := UniformSetCacheRD.get_cache(_cascade_shader, 0,
			[ubo_u, depth_u, color_u, _image(3, upper), _image(4, out)])
		var start := R0_PX * (pow(4.0, n) - 1.0) / 3.0
		var end := start + R0_PX * pow(4.0, n)
		var pc := PackedFloat32Array([n, A0 << n, start, end, 1.0 if n == cascades - 1 else 0.0, max_steps, 0.0, 0.0])
		rd.compute_list_bind_uniform_set(cl, set_rid, 0)
		rd.compute_list_set_push_constant(cl, pc.to_byte_array(), pc.size() * 4)
		rd.compute_list_dispatch(cl, gx, gy, 1)
		rd.compute_list_add_barrier(cl)
		src = 1 - src
	# cascade 0 landed in _tex[src]
	rd.compute_list_end()
	rd.capture_timestamp("RC cascades")

	cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _gather_pipe)
	var gather_set := UniformSetCacheRD.get_cache(_gather_shader, 0,
		[ubo_u, depth_u, color_u, _image(3, _tex[src])])
	var gpc := PackedFloat32Array([A0, 0.0, 0.0, 0.0])
	rd.compute_list_bind_uniform_set(cl, gather_set, 0)
	rd.compute_list_set_push_constant(cl, gpc.to_byte_array(), gpc.size() * 4)
	rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	rd.compute_list_end()
	rd.capture_timestamp("RC gather")


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
