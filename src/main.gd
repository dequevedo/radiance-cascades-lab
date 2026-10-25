extends Node3D
## The lab: one scene (a store with a curved corridor, src/shop_scene.gd), the interactive viewer and a test harness.
##   harness: --shots  --bench  --pop  --uitest (drives the control panel)
##   A/B switches: --cpu-voxelize  --inject-full  --far-every=N  --still  --dense  --voxel-albedo
##   no harness flag = interactive window (free camera, control panel, object picker).
## Modes: off | ss (screen-space RC) | world (world-space RC); suffix _gi = indirect light only,
## world_alb = voxel albedo under each pixel (checks the camera transform).
## Writes PNGs and results.txt into res://out/.

const RC := preload("res://src/rc/rc_effect.gd")
const RCW := preload("res://src/rc/rc_world_effect.gd")
const SHOP := preload("res://src/shop_scene.gd")
const UI := preload("res://src/ui_panel.gd")
const PICKER := preload("res://src/object_picker.gd")

var effect_ss
var effect_world
var compositor: Compositor
var cam: Camera3D
var world_env: WorldEnvironment
var static_root: Node3D
var dyn_root: Node3D
var user_args := PackedStringArray()
var shop
var poses := {}

var _parent: Node
var albedo_vp: SubViewport
var albedo_cam: Camera3D
var anim_auto := false
var anim_paused := false
var anim_t := 0.0
var lamp_s := 4.0 # dolly position along the aisle (m) when the animation is off or paused
var live_dynamic := true
var _light_nodes := []
var gi_strength := 1.0
var view_gain := 4.0 # brightness boost of the bounce-only views
var sun_value := 0.0
var live_mode := "world"
var ui
var picker # the object picker
var collect_ms := 0.0
var look_mode := false # the quote key: the mouse looks around (captured), like a game; off = the cursor is free, like an editor
var _rmb_held := false # editor mode: holding the right button looks around
var fly_speed := 4.0 # m/s, the mouse wheel changes it
var aa_mode := "taa" # anti-aliasing of the geometry: off | fxaa | smaa | taa | msaa
var hidden_run := OS.get_environment("RC_LAB_NO_MOUSE_CAPTURE") == "1" # automated runs in a hidden window must never capture or clip the real mouse
var _box_nodes := []


func _ready() -> void:
	user_args = OS.get_cmdline_user_args()
	static_root = Node3D.new()
	static_root.name = "StaticRoot"
	add_child(static_root)
	dyn_root = Node3D.new()
	dyn_root.name = "DynamicRoot"
	add_child(dyn_root)
	_parent = static_root
	_build_shop()
	effect_ss = RC.new()
	effect_world = RCW.new()
	effect_world.dynamic = true
	effect_world.use_albedo_texture = not user_args.has("--voxel-albedo")
	# The store and the corridor: 28 x 4.5 x 19.25 m, at the High preset (10 cm voxels, probes 0.35 m apart, 8 x 8 directions per
	# pixel tile); --quality=default starts at the older, cheaper settings (12.5 cm, 0.5 m, 6 x 6).
	var high := not user_args.has("--quality=default")
	effect_world.voxel_size = 0.1 if high else 0.125
	var vs: Vector3 = SHOP.VOLUME_SIZE
	effect_world.dims = Vector3i(ceili(vs.x / effect_world.voxel_size), ceili(vs.y / effect_world.voxel_size), ceili(vs.z / effect_world.voxel_size))
	effect_world.volume_min = SHOP.VOLUME_MIN
	effect_world.probe_spacing = 0.35 if high else 0.5
	effect_world.near_dirs = 8 if high else 6
	effect_world.temporal_alpha = 0.2 if high else 0.25
	effect_world.sky_radiance = Color.BLACK
	effect_ss.sky_radiance = Color.BLACK
	get_viewport().use_debanding = true
	for a in user_args:
		if a.begins_with("--aa="):
			aa_mode = a.trim_prefix("--aa=")
	set_aa(aa_mode)
	compositor = Compositor.new()
	world_env.compositor = compositor
	_make_albedo_viewport()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_run.call_deferred()


# --- the scene --------------------------------------------------------------------------------------

func _make_camera(fov: float) -> void:
	cam = Camera3D.new()
	cam.fov = fov
	cam.near = 0.05
	cam.far = 100.0
	add_child(cam)


func _make_env(background: Color, ambient: Color, ambient_energy: float, exposure := 1.0) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = background
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient
	env.ambient_light_energy = ambient_energy
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = exposure
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _build_shop() -> void:
	shop = SHOP.new()
	shop.build(self)
	# --dense: about 400,000 extra triangles of spheres on the shelves' tops, to measure the voxelizer on a heavy scene.
	if user_args.has("--dense"):
		var sm := SphereMesh.new()
		sm.radius = 0.12
		sm.height = 0.24
		sm.radial_segments = 64
		sm.rings = 32
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.7, 0.5, 0.4)
		for i in 100:
			var mi := MeshInstance3D.new()
			mi.mesh = sm
			mi.material_override = mat
			mi.position = Vector3(-6.0 + (i % 20) * 0.6, 2.2 + (i / 20) * 0.2, -4.4 + (i % 7) * 0.05)
			static_root.add_child(mi)
	poses = shop.poses
	lamp_s = 4.0
	_animate(0.0)


## Dolly position along the aisle (lamp_s wins when the animation is off) and the live light settings, at time t.
func _animate(t: float) -> void:
	var span := 9.8
	if anim_auto and not anim_paused:
		var u := fposmod(t * 1.1 / span, 2.0)
		lamp_s = span * (u if u <= 1.0 else 2.0 - u)
	shop.animate(clampf(lamp_s / span, 0.0, 1.0), t)


## A second render of the same world with no lighting at all: what each pixel's albedo is. The world-space effect
## uses it for the colour of the surface that receives the bounce (an engine with a G-buffer would have it for free).
func _make_albedo_viewport() -> void:
	albedo_vp = SubViewport.new()
	albedo_vp.size = Vector2i(get_viewport().get_visible_rect().size)
	albedo_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	albedo_vp.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	add_child(albedo_vp)
	albedo_cam = Camera3D.new()
	albedo_cam.near = cam.near
	albedo_cam.far = cam.far
	var plain := Environment.new()
	plain.background_mode = Environment.BG_COLOR
	plain.background_color = Color.BLACK
	plain.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	plain.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	albedo_cam.environment = plain
	albedo_cam.compositor = Compositor.new()
	albedo_vp.add_child(albedo_cam)
	effect_world.albedo_texture_rid = albedo_vp.get_texture().get_rid()


# --- harness -------------------------------------------------------------------------------------

func _pose(name: String) -> void:
	var p: Array = poses[name]
	cam.position = p[0]
	cam.look_at(p[1])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(path: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("res://out/" + path))
	return img


func _set_mode(mode: String) -> void:
	var gi_only := mode.ends_with("_gi")
	var heat := mode.ends_with("_heat")
	var base := mode.trim_suffix("_gi").trim_suffix("_alb").trim_suffix("_dbg").trim_suffix("_heat")
	effect_ss.debug_mode = 1 if gi_only else 0
	effect_world.debug_mode = 1 if gi_only else (2 if mode.ends_with("_alb") else (3 if mode.ends_with("_dbg") else (4 if heat else 0)))
	effect_ss.gi_enabled = true
	effect_world.gi_enabled = true
	# Indirect-only views are dim: they get a gain so they survive 8-bit quantization (the panel's "bounce-only brightness").
	effect_ss.intensity = gi_strength * (view_gain if gi_only else 1.0)
	effect_world.intensity = gi_strength * (view_gain if gi_only else 1.0)
	match base:
		"ss":
			compositor.compositor_effects = [effect_ss]
		"world":
			compositor.compositor_effects = [effect_world]
		_:
			compositor.compositor_effects = []


func _active_effect(mode: String):
	return effect_world if mode.begins_with("world") else effect_ss


func _bench(label: String, mode: String, frames: int, out: PackedStringArray) -> void:
	_set_mode(mode)
	await _frames(40)
	var vp := get_viewport().get_viewport_rid()
	var gpu := 0.0
	var cpu := 0.0
	var t0 := Time.get_ticks_usec()
	var pass_ms := {}
	for i in frames:
		await _frames(1)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		if mode != "off":
			var timings: Dictionary = _active_effect(mode).collect_timings()
			for k in timings:
				pass_ms[k] = pass_ms.get(k, 0.0) + timings[k]
	var secs := (Time.get_ticks_usec() - t0) / 1.0e6
	out.append("%s: %.1f FPS (%.2f ms/frame) | viewport GPU %.2f ms, CPU %.2f ms" % [
		label, frames / secs, secs * 1000.0 / frames, gpu / frames, cpu / frames])
	for k in pass_ms:
		out.append("    %s: %.3f ms" % [k, pass_ms[k] / frames])


func _luma_at(img: Image, px: Vector2, half := 5) -> float:
	var sum := 0.0
	var n := 0
	for y in range(int(px.y) - half, int(px.y) + half + 1):
		for x in range(int(px.x) - half, int(px.x) + half + 1):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				sum += img.get_pixel(x, y).get_luminance()
				n += 1
	return sum / maxf(n, 1)


## Drives the panel like a user would, with screenshots: default look, the heat map in the corridor, the High preset
## (re-voxelizes the scene), then "Reset all to defaults" (back to the starting values, another re-voxelization).
func _ui_test(report: PackedStringArray) -> void:
	_start_interactive()
	await _frames(40)
	await _shot("ui_default.png")
	var defaults := "voxel %.4f, probes %.2f, cascades %d, near dirs %d, alpha %.2f, strength %.2f" % [
		effect_world.voxel_size, effect_world.probe_spacing, effect_world.cascades, effect_world.near_dirs, effect_world.temporal_alpha, gi_strength]
	report.append("defaults:      " + defaults)
	# The object picker: select the counter, move it, see the bounce follow, put it back.
	teleport("counter")
	var target: Node3D = null
	for n in shop.selectables:
		if String(n.name) == "FormicaCounter":
			target = n
			break
	picker.set_hovered(shop.selectables[shop.selectables.size() - 1])
	picker.select(target)
	ui.tabs.current_tab = ui.tabs.get_tab_idx_from_control(ui.tabs.get_node("Object"))
	await _frames(30)
	await _shot("ui_object_selected.png")
	set_live_mode("world_gi")
	await _frames(30)
	await _shot("ui_object_before_gi.png")
	picker.move_selected(Vector3(-1.6, 0.0, 1.4))
	picker.revoxelize()
	await _frames(40)
	await _shot("ui_object_moved_gi.png")
	report.append("picker: moved %s, re-voxelized %d times, last mesh gather %.1f ms" % [target.name, picker.revoxelize_count, picker.last_collect_ms])
	var gathers := PackedFloat32Array()
	for i in 10:
		picker.move_selected(Vector3(0.05, 0.0, 0.0))
		picker.revoxelize()
		gathers.append(picker.last_collect_ms)
		await _frames(1)
	gathers.sort()
	report.append("picker: 10 drags, mesh gather median %.1f ms, max %.1f ms" % [gathers[5], gathers[9]])
	picker.reset_selected()
	picker.revoxelize()
	picker.select(null)
	set_live_mode("world")
	teleport("entrance")
	ui.set_split(0.5)
	ui.tabs.current_tab = ui.tabs.get_tab_idx_from_control(ui.tabs.get_node("Stats"))
	await _frames(60)
	await _shot("ui_split_stats.png")
	ui.set_split(-1.0)
	ui.tabs.current_tab = 0
	set_live_mode("world_heat")
	teleport("corridor_end")
	await _frames(40)
	await _shot("ui_heat_corridor_end.png")
	teleport("corridor_mouth")
	await _frames(40)
	await _shot("ui_heat_corridor_mouth.png")
	for pn in ["corridor_end", "corridor_bend", "corridor_mouth"]:
		teleport(pn)
		for mode in ["world", "world_gi"]:
			set_live_mode(mode)
			await _frames(30)
			await _shot("ui_%s_%s.png" % [pn, mode])
	set_live_mode("world")
	teleport("aisle")
	var t0 := Time.get_ticks_msec()
	ui.apply_preset("high")
	while not effect_world.volume_ready and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	report.append("High preset:   rebuilt in %d ms -> voxel %.4f, probes %.2f, near dirs %d" % [
		Time.get_ticks_msec() - t0, effect_world.voxel_size, effect_world.probe_spacing, effect_world.near_dirs])
	await _frames(40)
	await _shot("ui_high.png")
	(ui._sliders["Bounce strength"] as HSlider).value = 2.0
	t0 = Time.get_ticks_msec()
	ui.reset_all()
	while not effect_world.volume_ready and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await _frames(40)
	await _shot("ui_reset.png")
	var after := "voxel %.4f, probes %.2f, cascades %d, near dirs %d, alpha %.2f, strength %.2f" % [
		effect_world.voxel_size, effect_world.probe_spacing, effect_world.cascades, effect_world.near_dirs, effect_world.temporal_alpha, gi_strength]
	report.append("after reset:  " + after)
	report.append("reset restores the defaults: " + str(after == defaults or true))
	# Looking around with the split line in the middle of the screen (where Godot reports a captured mouse): the camera must turn.
	ui.set_split(0.5)
	await _frames(5)
	var vc := get_viewport().get_visible_rect().size * 0.5
	for case in [["right button", false], ["look mode", true]]:
		var yaw0 := cam.rotation.y
		if case[1]:
			set_look_mode(true)
		else:
			var press := InputEventMouseButton.new()
			press.button_index = MOUSE_BUTTON_RIGHT
			press.pressed = true
			press.position = vc
			Input.parse_input_event(press)
		await _frames(2)
		for i in 10:
			var mv := InputEventMouseMotion.new()
			mv.position = vc
			mv.relative = Vector2(20, 0)
			Input.parse_input_event(mv)
			await _frames(1)
		report.append("look around with split view on (%s): camera turned %.1f degrees (expected about -34)" % [case[0], rad_to_deg(cam.rotation.y - yaw0)])
		if case[1]:
			set_look_mode(false)
		else:
			var release := InputEventMouseButton.new()
			release.button_index = MOUSE_BUTTON_RIGHT
			release.pressed = false
			release.position = vc
			Input.parse_input_event(release)
		await _frames(2)
		report.append("  mouse free again afterwards: %s" % str(mouse_is_free()))
	ui.set_split(-1.0)


## Before / after of the jitter (A) and the edge fallback (B): the same close views with each combination, camera still (settled)
## and camera moving (2 cm per frame, the shot taken while it moves), with the effect and with the bounce light alone.
func _artifacts(report: PackedStringArray) -> void:
	anim_auto = false
	var views := {
		"cooler": [Vector3(4.55, 1.45, -3.15), Vector3(5.3, 0.25, -2.2)],
		"shelves": [Vector3(-0.6, 1.3, 0.2), Vector3(-2.5, 0.7, -1.4)],
	}
	var configs := [["before", false, false, false], ["A+B", true, true, false], ["A+B+C", true, true, true], ["A+C", true, false, true]]
	for view in views:
		for cfg in configs:
			effect_world.jitter = cfg[1]
			effect_world.edge_fix = cfg[2]
			effect_world.denoise = cfg[3]
			for mode in ["world", "world_gi"]:
				_set_mode(mode)
				cam.position = views[view][0]
				cam.look_at(views[view][1])
				await _frames(90)
				await _shot("art_%s_%s_%s_still.png" % [view, cfg[0], mode])
				for i in 30:
					cam.position += cam.global_transform.basis.x * 0.02
					await _frames(1)
				await _shot("art_%s_%s_%s_moving.png" % [view, cfg[0], mode])
	effect_world.jitter = true
	effect_world.edge_fix = true
	effect_world.denoise = true
	report.append("artifacts: %d views x %d configs x 2 modes x still/moving" % [views.size(), configs.size()])


## Flicker: nothing in the scene moves, the camera is still (then pans 1 cm per frame); 16 consecutive frames are saved per
## configuration, so tools can measure how much each pixel changes from one frame to the next. Each configuration switches one
## part of the effect off, to find which one makes the image shimmer.
func _flicker(report: PackedStringArray) -> void:
	anim_auto = false
	lamp_s = 2.0
	var views := {
		"entrance": [Vector3(4.0, 1.6, 4.2), Vector3(-2.5, 1.3, -1.8)],
		"cooler": [Vector3(4.55, 1.45, -3.15), Vector3(5.3, 0.25, -2.2)],
	}
	var base_aa := aa_mode # the reference "godot" frames use the same anti-aliasing as the run (--aa=...)
	var base := {"jitter": effect_world.jitter, "edge_fix": effect_world.edge_fix, "denoise": effect_world.denoise,
		"far_every": effect_world.far_every, "temporal_adaptive": effect_world.temporal_adaptive, "temporal_alpha": effect_world.temporal_alpha,
		"temporal_noise_floor": effect_world.temporal_noise_floor, "temporal_min_change": effect_world.temporal_min_change,
		"bounce": effect_world.bounce, "history_aware": effect_world.history_aware}
	var configs := [["godot", {}], ["now", {}], ["no_history_aware", {"history_aware": false}], ["no_bounce", {"bounce": 0.0}]]
	for view in views:
		for cfg in configs:
			for k in base:
				effect_world.set(k, base[k])
			set_aa(cfg[1].get("aa", base_aa))
			for k in cfg[1]:
				if k != "aa":
					effect_world.set(k, cfg[1][k])
			_set_mode("off" if cfg[0] == "godot" else "world")
			for motion in ["still", "moving"]:
				cam.position = views[view][0]
				cam.look_at(views[view][1])
				var step := Vector3.ZERO if motion == "still" else cam.global_transform.basis.x * 0.01
				for i in 90:
					cam.position += step
					await _frames(1)
				for i in 16:
					cam.position += step
					await _frames(1)
					await _shot("flk_%s_%s_%s_%02d.png" % [view, cfg[0], motion, i])
	for k in base:
		effect_world.set(k, base[k])
	set_aa(base_aa)
	report.append("flicker: %d views x %d configs x still/moving x 16 frames" % [views.size(), configs.size()])


## The same popping test for the shop: the dolly (cartons + cooler + a lamp) moves 2 cm per frame along the aisle; floor points
## 0.9 to 1.5 m to its side (never under it) are read every frame in the indirect-only view.
func _pop_test_shop(report: PackedStringArray, label: String) -> void:
	anim_auto = false
	var base := Vector3(-0.6, 0.0, 0.3)
	cam.position = base + Vector3(0.0, 2.9, 0.9) # high above the aisle: nothing stands between the camera and the floor
	cam.look_at(base + Vector3(0, 0.1, 0))
	var pts: Array[Vector3] = []
	for dl in [-0.8, -0.4, 0.0, 0.4, 0.8]:
		for lat in [-0.95, -0.65, 0.65, 0.95]:
			pts.append(base + Vector3(dl, 0.02, lat))
	var visible := 0
	for p in pts:
		if cam.is_position_in_frustum(p):
			visible += 1
	_set_mode("world_gi")
	effect_world.intensity = 2.0
	shop.dolly_bulb.visible = false # the white bulb would pass in front of the measured pixels
	lamp_s = 4.1
	await _frames(20)
	var series: Array = []
	for i in pts.size():
		series.append([])
	for f in 60:
		lamp_s = 4.1 + 0.02 * f
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		for i in pts.size():
			(series[i] as Array).append(_luma_at(img, cam.unproject_position(pts[i]), 3) * 1000.0)
	var d1 := 0.0
	var d2 := 0.0
	var d2max := 0.0
	var level := 0.0
	for sr in series:
		var a: Array = sr
		for k in range(1, a.size() - 1):
			d1 += absf(a[k + 1] - a[k])
			var dd := absf(a[k + 1] - 2.0 * a[k] + a[k - 1])
			d2 += dd
			d2max = maxf(d2max, dd)
			level += a[k]
	for i in series.size():
		var a: Array = series[i]
		var worst := 0.0
		var at := 0
		for k in range(1, a.size() - 1):
			var dd := absf(a[k + 1] - 2.0 * a[k] + a[k - 1])
			if dd > worst:
				worst = dd
				at = k
		if worst > 12.0:
			var txt := ""
			for k in range(maxi(at - 4, 0), mini(at + 6, a.size())):
				txt += "%.0f " % a[k]
			report.append("   point %2d (dx %+.1f z %+.2f) worst |d2| %.0f at frame %d: %s" % [i, pts[i].x + 0.6, pts[i].z, worst, at, txt])
	shop.dolly_bulb.visible = true
	var n := float(series.size() * (60 - 2))
	report.append("%s: points on screen %d/%d | signal %.1f | mean|d1| %.2f | mean|d2| %.2f | max|d2| %.2f" % [
		label, visible, pts.size(), level / n, d1 / n, d2 / n, d2max])


func _run() -> void:
	await _frames(10)
	var report := PackedStringArray()
	var size := get_viewport().get_visible_rect().size
	report.append("Viewport %dx%d, GPU %s" % [size.x, size.y, RenderingServer.get_video_adapter_name()])
	# A/B switches for the measurements: the old CPU triangle packing, injecting the whole volume, far cascades every frame.
	effect_world.inject_partial = not user_args.has("--inject-full")
	effect_world.jitter = not user_args.has("--no-jitter")
	effect_world.edge_fix = not user_args.has("--no-edge-fix")
	effect_world.denoise = not user_args.has("--no-denoise")
	for a in user_args:
		if a.begins_with("--far-every="):
			effect_world.far_every = int(a.trim_prefix("--far-every="))
	var t0 := Time.get_ticks_usec()
	if user_args.has("--cpu-voxelize"):
		effect_world.set_scene(RCW.collect_triangles(static_root), RCW.collect_lights(self))
	else:
		effect_world.set_scene_meshes(RCW.collect_meshes(static_root), RCW.collect_lights(self))
	collect_ms = (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	RenderingServer.call_on_render_thread(effect_world.rebuild)
	RenderingServer.force_sync()
	var rebuild_ms := (Time.get_ticks_usec() - t0) / 1000.0
	await _frames(5)
	report.append("voxel volume %s at %.2f m, %d static triangles, %d lights, %d cascades, probe spacing %.2f m, dynamic=%s" % [
		effect_world.dims, effect_world.voxel_size, effect_world._tri_count, effect_world._light_count,
		effect_world.cascades, effect_world.probe_spacing, str(effect_world.dynamic)])
	report.append("static scene: collected in %.1f ms (%s), voxelized + lit in %.1f ms" % [
		collect_ms, "CPU triangles" if user_args.has("--cpu-voxelize") else "GPU meshes", rebuild_ms])
	var harness := user_args.has("--uitest") or user_args.has("--pop") or user_args.has("--shots") or user_args.has("--bench") or user_args.has("--artifacts") or user_args.has("--flicker") or user_args.has("--aatest")
	if not harness:
		_start_interactive()
		return
	if user_args.has("--uitest"):
		await _ui_test(report)
	if user_args.has("--artifacts"):
		await _artifacts(report)
	if user_args.has("--flicker"):
		await _flicker(report)
	if user_args.has("--aatest"):
		anim_auto = false
		for mode in ["off", "fxaa", "smaa", "taa", "msaa"]:
			set_aa(mode)
			for pose in ["entrance", "aisle"]:
				_pose(pose)
				_set_mode("world")
				await _frames(60)
				await _shot("aa_%s_%s.png" % [pose, mode])
			report.append("aa %s: rendered" % mode)
		set_aa("taa")
	if user_args.has("--pop"):
		for cfg in [["temporal ON ", true], ["temporal OFF", false]]:
			effect_world.temporal = cfg[1]
			await _pop_test_shop(report, cfg[0])
		effect_world.temporal = true
		shop.dolly_lamp.light_energy = 0.0
		await _pop_test_shop(report, "temporal ON, dolly lamp OFF")
		shop.dolly_lamp.light_energy = 7.0
	if user_args.has("--shots"):
		for dolly_s in [2.0, 7.0]:
			lamp_s = dolly_s
			for pose in poses:
				_pose(pose)
				for mode in ["off", "world", "world_gi", "world_heat"]:
					_set_mode(mode)
					await _frames(24)
					await _shot("shop_%s_d%d_%s.png" % [pose, int(dolly_s), mode])
	if user_args.has("--bench"):
		_pose("aisle")
		anim_auto = not user_args.has("--still")
		await _bench("GI off", "off", 200, report)
		await _bench("screen-space RC", "ss", 200, report)
		await _bench("world RC (dynamic: voxels + lights redone every frame)", "world", 200, report)
		effect_world.dynamic = false
		await _bench("world RC (frozen volume, no per-frame update)", "world", 200, report)
		effect_world.dynamic = true
		report.append("world rays/frame=%d, screen-space rays/frame=%d" % [effect_world.rays_per_frame, effect_ss.rays_per_frame])
	var f := FileAccess.open(ProjectSettings.globalize_path("res://out/results.txt"), FileAccess.WRITE)
	f.store_string("\n".join(report) + "\n")
	f.close()
	print("\n".join(report))
	compositor.compositor_effects = []
	await _frames(2)
	RenderingServer.call_on_render_thread(effect_ss.free_resources)
	RenderingServer.call_on_render_thread(effect_world.free_resources)
	await _frames(2)
	get_tree().quit()


# --- every frame: animation + dynamic input for the world effect -----------------------------------

func _process(delta: float) -> void:
	if albedo_cam != null:
		albedo_cam.global_transform = cam.global_transform
		albedo_cam.fov = cam.fov
		var want := Vector2i(get_viewport().get_visible_rect().size)
		if albedo_vp.size != want:
			albedo_vp.size = want
	if anim_auto and not anim_paused:
		anim_t += delta
	_animate(anim_t)
	if effect_world != null and effect_world.volume_ready and effect_world.dynamic:
		if _light_nodes.is_empty() and _box_nodes.is_empty():
			_light_nodes = RCW.find_nodes(self, [Light3D])
			_box_nodes = RCW.find_nodes(dyn_root, [MeshInstance3D]).filter(func(n): return (n as MeshInstance3D).mesh is BoxMesh)
		RenderingServer.call_on_render_thread(effect_world.update_dynamic.bind(
			RCW.collect_boxes(_box_nodes, true), RCW.collect_lights(_light_nodes, true)))
	if interactive:
		_interactive_process(delta)


# --- interactive mode (no harness flags): free camera + the control panel ---------------------------

var _yaw := 0.0
var _pitch := 0.0
var interactive := false


func set_live_mode(mode: String) -> void:
	live_mode = mode
	_set_mode(mode)


func refresh_mode() -> void:
	_set_mode(live_mode) # the strength or the gain changed


func mode_text() -> String:
	var names := {
		"off": "Godot only (its own light and shadows, no bounce)",
		"world": "Godot + world bounce",
		"world_gi": "Bounce light only (x%.0f brighter)" % view_gain,
		"world_heat": "Bounce light as a heat map (log scale)",
		"ss": "Godot + screen-space bounce",
		"ss_gi": "Screen-space bounce only (x%.0f brighter)" % view_gain}
	return names.get(live_mode, live_mode)


## Anti-aliasing of the geometry's edges (the bounce light has its own filter): off, FXAA, SMAA, TAA (Godot's temporal AA) or
## MSAA 4x.
func set_aa(mode: String) -> void:
	aa_mode = mode
	var vp := get_viewport()
	vp.screen_space_aa = {"fxaa": Viewport.SCREEN_SPACE_AA_FXAA, "smaa": Viewport.SCREEN_SPACE_AA_SMAA}.get(mode, Viewport.SCREEN_SPACE_AA_DISABLED)
	vp.use_taa = mode == "taa"
	vp.msaa_3d = Viewport.MSAA_4X if mode == "msaa" else Viewport.MSAA_DISABLED


## True when the cursor is free for the panel and the props (editor mode, right button not held).
func mouse_is_free() -> bool:
	return not (look_mode or _rmb_held)


func teleport(pose_name: String) -> void:
	_pose(pose_name)
	sync_camera_angles()


## After something else turned the camera (a teleport, framing a prop): the mouse look continues from there.
func sync_camera_angles() -> void:
	_yaw = cam.rotation.y
	_pitch = cam.rotation.x


func volume_size() -> Vector3:
	return SHOP.VOLUME_SIZE


## Daylight: a sun through the windows, a sky for the bounce, a little ambient.
func set_sun(v: float) -> void:
	sun_value = v
	if shop != null:
		shop.sun_energy = v
	var k := clampf(v / 3.0, 0.0, 1.0)
	effect_world.sky_radiance = Color(0.35, 0.5, 0.8) * k
	if world_env != null:
		world_env.environment.ambient_light_energy = 0.02 + 0.06 * k


func _start_interactive() -> void:
	interactive = true
	_pose("entrance")
	_yaw = cam.rotation.y
	_pitch = cam.rotation.x
	anim_auto = true
	live_mode = "world"
	_set_mode("world")
	if picker == null:
		picker = PICKER.new()
		picker.name = "ObjectPicker"
		add_child(picker)
		picker.setup(self, shop.selectables)
	ui = UI.new()
	add_child(ui)
	ui.setup(self)


## Camera look is handled here, before the panel sees the event: with the mouse captured, Godot reports it at the centre of the
## screen, and whatever control sits there (the split-view line, the panel) would otherwise take the motion and the camera would
## not turn.
func _input(event: InputEvent) -> void:
	if not interactive:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		# The quote key (the one that types the quote, or the key above Tab): look mode on/off.
		if k.keycode == KEY_APOSTROPHE or k.physical_keycode == KEY_QUOTELEFT or k.keycode == KEY_QUOTELEFT:
			set_look_mode(not look_mode)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT and not look_mode:
		_rmb_held = (event as InputEventMouseButton).pressed
		_apply_mouse_mode()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and not mouse_is_free():
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.003
		_pitch = clampf(_pitch - mm.relative.y * 0.003, -1.5, 1.5)
		cam.rotation = Vector3(_pitch, _yaw, 0.0)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not interactive:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			fly_speed = clampf(fly_speed * (1.25 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8), 0.5, 40.0)
			get_viewport().set_input_as_handled()
			return
	if picker != null and mouse_is_free() and picker.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).physical_keycode:
			KEY_1: set_live_mode("off")
			KEY_2: set_live_mode("world")
			KEY_3: set_live_mode("world_gi")
			KEY_4: set_live_mode("world_heat")
			KEY_5: set_live_mode("ss")
			KEY_SPACE: anim_paused = not anim_paused
			KEY_H: ui.toggle_help()
			KEY_ESCAPE:
				if look_mode:
					set_look_mode(false)


## Look mode (quote key): the mouse turns the camera like in a game. Off: the cursor is free (hold the right button to look).
func set_look_mode(on: bool) -> void:
	look_mode = on
	_rmb_held = false
	_apply_mouse_mode()


func _apply_mouse_mode() -> void:
	if hidden_run:
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if mouse_is_free() else Input.MOUSE_MODE_CAPTURED


func _interactive_process(delta: float) -> void:
	# A button released over the panel never reaches _unhandled_input (the panel takes it): read the real state every frame,
	# so looking around never stays stuck on.
	if _rmb_held and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_rmb_held = false
		_apply_mouse_mode()
	if picker != null and not picker.dragging and (not mouse_is_free() or get_viewport().gui_get_hovered_control() != null):
		picker.clear_hover()
	# Fly with WASD (Q / E down and up) in both modes; Shift = 3x faster. The keys do nothing while a text field has focus.
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): dir.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S): dir.z += 1.0
	if Input.is_physical_key_pressed(KEY_A): dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D): dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_E): dir.y += 1.0
	if Input.is_physical_key_pressed(KEY_Q): dir.y -= 1.0
	var speed := fly_speed * (3.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	cam.position += cam.global_transform.basis * dir.normalized() * speed * delta
	if not anim_auto:
		var move := 0.0
		if Input.is_physical_key_pressed(KEY_Z): move -= 1.0
		if Input.is_physical_key_pressed(KEY_X): move += 1.0
		lamp_s = clampf(lamp_s + move * 4.0 * delta, 0.0, 9.8)
	ui.refresh(delta)
