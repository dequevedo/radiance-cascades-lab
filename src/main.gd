extends Node3D
## Test scenes + capture/benchmark harness + interactive viewer.
##   scenes:  --scene=tunnel (default) | street | room | shop
##   harness: --shots  --bench  --sweep (street)  --travel --motion --motionmaps --lag --leak --closeups (tunnel)
##            --pop (tunnel, shop)  --uitest (shop: drives the control panel)
##   no harness flag = interactive window (free camera, keys 1-5 switch the view; the shop has the control panel).
## Modes: off | ss (screen-space RC) | world (world-space RC); suffix _gi = indirect light only,
## world_alb = voxel albedo under each pixel (checks the camera transform).
## Writes PNGs and results.txt into res://out/.

const RC := preload("res://src/rc/rc_effect.gd")
const RCW := preload("res://src/rc/rc_world_effect.gd")
const SHOP := preload("res://src/shop_scene.gd")
const UI := preload("res://src/ui_panel.gd")

const LAMP_COLOR := Color(1.0, 0.62, 0.28)
const CART_LAMP_COLOR := Color(1.0, 0.85, 0.6)

# Tunnel: straight (A) along +x, a left arc, straight (B) along -z. Cross section T_W x T_H.
const T_W := 4.0
const T_H := 3.5
const A_LEN := 8.0
const ARC_R := 8.0
const B_LEN := 14.0
const CART_MIN_S := 3.0
const CART_MAX_S := 30.0
const BLADE_S := 7.0

var effect_ss
var effect_world
var compositor: Compositor
var cam: Camera3D
var world_env: WorldEnvironment
var static_root: Node3D
var dyn_root: Node3D
var user_args := PackedStringArray()
var scene_name := "tunnel"
var shop
var poses := {}

var _parent: Node
var albedo_vp: SubViewport
var albedo_cam: Camera3D
var cart: MeshInstance3D
var cart_lamp: OmniLight3D
var blade: MeshInstance3D
var anim_auto := false
var anim_paused := false
var anim_t := 0.0
var lamp_s := 8.0 # cart position along the tunnel when the animation is off or paused
var live_dynamic := true
var _light_nodes := []
var gi_strength := 1.0
var view_gain := 10.0 # brightness boost of the bounce-only views
var sun_value := 0.0
var live_mode := "world"
var ui
var _ui_sticky := false
var hidden_run := OS.get_environment("RC_LAB_NO_MOUSE_CAPTURE") == "1" # automated runs in a hidden window must never capture or clip the real mouse
var _box_nodes := []


func _ready() -> void:
	user_args = OS.get_cmdline_user_args()
	for a in user_args:
		if a.begins_with("--scene="):
			scene_name = a.get_slice("=", 1)
	static_root = Node3D.new()
	static_root.name = "StaticRoot"
	add_child(static_root)
	dyn_root = Node3D.new()
	dyn_root.name = "DynamicRoot"
	add_child(dyn_root)
	_parent = static_root
	match scene_name:
		"room":
			_build_room()
		"street":
			_build_street()
		"shop":
			_build_shop()
		_:
			_build_tunnel()
	effect_ss = RC.new()
	effect_world = RCW.new()
	effect_world.dynamic = scene_name == "tunnel" or scene_name == "shop"
	effect_world.use_albedo_texture = not user_args.has("--voxel-albedo")
	if scene_name == "tunnel":
		# Finer voxels and probes, volume trimmed to the tunnel (24 x 6 x 27 m).
		effect_world.voxel_size = 0.125
		effect_world.dims = Vector3i(192, 48, 216)
		effect_world.volume_min = Vector3(-16.0, -0.5, -14.0)
		effect_world.probe_spacing = 0.5
	if scene_name == "shop":
		# The store and the corridor: 28 x 4.5 x 19.25 m.
		view_gain = 4.0
		effect_world.voxel_size = 0.125
		var vs: Vector3 = SHOP.VOLUME_SIZE
		effect_world.dims = Vector3i(ceili(vs.x / 0.125), ceili(vs.y / 0.125), ceili(vs.z / 0.125))
		effect_world.volume_min = SHOP.VOLUME_MIN
		effect_world.probe_spacing = 0.5
		effect_world.sky_radiance = Color.BLACK
		effect_ss.sky_radiance = Color.BLACK
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	get_viewport().use_debanding = true
	effect_ss.sky_radiance = Color(0.5, 0.7, 1.0) * 1.5 if scene_name == "room" else Color(0.02, 0.03, 0.06)
	if scene_name == "tunnel":
		effect_ss.sky_radiance = Color.BLACK
		effect_world.sky_radiance = Color.BLACK
	compositor = Compositor.new()
	world_env.compositor = compositor
	_make_albedo_viewport()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_run.call_deferred()


# --- scenes --------------------------------------------------------------------------------------

func _box(pos: Vector3, size: Vector3, color: Color, emissive := 0.0, basis := Basis()) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	if emissive > 0.0:
		mat.emission_enabled = true
		mat.emission = LAMP_COLOR
		mat.emission_energy_multiplier = emissive
	mi.material_override = mat
	mi.basis = basis
	mi.position = pos
	_parent.add_child(mi)
	return mi


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


func _build_room() -> void:
	poses = {
		"down_room": [Vector3(0, 1.7, 5.5), Vector3(0, 1.4, -6)],
		"patch_in_view": [Vector3(-3.5, 1.7, 5.0), Vector3(1.5, 0.2, 0.0)],
		"patch_off_view": [Vector3(-3.5, 1.7, 5.0), Vector3(-5.0, 1.3, -3.0)],
	}
	var white := Color(0.75, 0.75, 0.72)
	_box(Vector3(0, -0.1, 0), Vector3(10.4, 0.2, 12.4), white)
	_box(Vector3(-5.1, 2, 0), Vector3(0.2, 4, 12.4), Color(0.8, 0.12, 0.1))
	_box(Vector3(0, 2, -6.1), Vector3(10.4, 4, 0.2), white)
	_box(Vector3(0, 2, 6.1), Vector3(10.4, 4, 0.2), white)
	_box(Vector3(0, 4.1, 0), Vector3(10.4, 0.2, 12.4), white)
	var green := Color(0.12, 0.7, 0.2)
	_box(Vector3(5.1, 0.5, 0), Vector3(0.2, 1, 12.4), green)
	_box(Vector3(5.1, 3.5, 0), Vector3(0.2, 1, 12.4), green)
	_box(Vector3(5.1, 2, -4.0), Vector3(0.2, 2, 4.0), green)
	_box(Vector3(5.1, 2, 4.0), Vector3(0.2, 2, 4.0), green)
	_box(Vector3(-2.5, 0.75, -2.0), Vector3(1.5, 1.5, 1.5), Color(0.2, 0.3, 0.85))
	_box(Vector3(2.2, 1.5, -4.0), Vector3(0.8, 3.0, 0.8), Color(0.9, 0.75, 0.2))
	_box(Vector3(-1.0, 0.4, 3.0), Vector3(1.2, 0.8, 1.2), white)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30, 90, 0)
	sun.light_energy = 6.0
	sun.shadow_enabled = true
	add_child(sun)
	_make_env(Color(0.5, 0.7, 1.0) * 1.5, Color(1, 1, 1), 0.04)
	_make_camera(70.0)


func _lamp(x: float, side: float) -> void:
	var z0 := side * 5.5
	_box(Vector3(x, 2.75, z0), Vector3(0.15, 5.5, 0.15), Color(0.15, 0.15, 0.16))
	_box(Vector3(x, 5.5, z0 - side * 0.6), Vector3(0.12, 0.12, 1.2), Color(0.15, 0.15, 0.16))
	var bulb_pos := Vector3(x, 5.3, z0 - side * 1.2)
	_box(bulb_pos, Vector3(0.3, 0.12, 0.3), LAMP_COLOR, 4.0)
	var l := OmniLight3D.new()
	l.position = bulb_pos - Vector3(0, 0.15, 0)
	l.light_color = LAMP_COLOR
	l.light_energy = 25.0
	l.omni_range = 12.0
	l.omni_attenuation = 2.0
	l.shadow_enabled = true
	add_child(l)


func _build_street() -> void:
	# Street along x, z -4..4; sidewalks 3 m wide; buildings behind them. Volume: x,z -16..16, y -0.5..11.5.
	_box(Vector3(0, -0.25, 0), Vector3(32, 0.5, 32), Color(0.14, 0.14, 0.15))
	_box(Vector3(0, 0.075, 5.5), Vector3(32, 0.15, 3), Color(0.55, 0.53, 0.5))
	_box(Vector3(0, 0.075, -5.5), Vector3(32, 0.15, 3), Color(0.55, 0.53, 0.5))
	_box(Vector3(-11, 3.5, 11), Vector3(10, 7, 8), Color(0.75, 0.35, 0.45))
	_box(Vector3(-1.5, 4.5, 11), Vector3(9, 9, 8), Color(0.78, 0.62, 0.25))
	_box(Vector3(9.5, 3.0, 11), Vector3(13, 6, 8), Color(0.2, 0.55, 0.55))
	_box(Vector3(-10, 4.0, -11), Vector3(12, 8, 8), Color(0.8, 0.75, 0.6))
	_box(Vector3(0, 3.0, -11), Vector3(8, 6, 8), Color(0.6, 0.25, 0.2))
	_box(Vector3(10, 5.0, -11), Vector3(12, 10, 8), Color(0.25, 0.35, 0.6))
	_lamp(-4.0, -1.0)
	_lamp(4.0, -1.0)
	_lamp(12.0, 1.0)
	_make_env(Color(0.02, 0.03, 0.06), Color(0.5, 0.55, 0.8), 0.03)
	_make_camera(70.0)
	poses = {
		"down_street": [Vector3(-14, 1.7, 0), Vector3(14, 2.0, 0)],
		"view_g": [Vector3(-6, 1.7, 5), Vector3(-13, 0.2, -1)],
		"view_z": [Vector3(-6, 1.7, 5), Vector3(0, 0.5, -4)],
	}


func _build_shop() -> void:
	shop = SHOP.new()
	shop.build(self)
	poses = shop.poses
	lamp_s = 4.0
	_animate(0.0)


## Point and heading of the tunnel centreline at distance s along it.
func path_at(s: float) -> Array:
	var arc_len := ARC_R * PI * 0.5
	s = clampf(s, 0.0, A_LEN + arc_len + B_LEN)
	if s <= A_LEN:
		return [Vector3(-14.0 + s, 0, 10.0), Vector3(1, 0, 0)]
	s -= A_LEN
	if s <= arc_len:
		var th := s / ARC_R
		return [Vector3(-6.0 + ARC_R * sin(th), 0, 2.0 + ARC_R * cos(th)), Vector3(cos(th), 0, -sin(th))]
	s -= arc_len
	return [Vector3(2.0, 0, 2.0 - s), Vector3(0, 0, -1)]


## One mesh per surface (floor, ceiling, left and right wall), built slice by slice along the centreline so the bend
## is smooth and nothing overlaps. Each surface has an inner face (what you see) and an outer one 0.25 m behind it,
## so the voxelized wall is solid. Normals are per slice, so the curved walls shade smoothly.
func _tunnel_strip(color: Color, parts: Array) -> void:
	var total := A_LEN + ARC_R * PI * 0.5 + B_LEN
	var n := int(ceil(total / 0.2))
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for part in parts:
		for i in n:
			var q := []
			for s in [total * i / n, total * (i + 1) / n]:
				var p := path_at(s)
				var c: Vector3 = p[0]
				var r: Vector3 = (p[1] as Vector3).cross(Vector3.UP)
				q.append([part["e0"].call(c, r), part["e1"].call(c, r), part["n"].call(r)])
			var base := verts.size()
			verts.append_array([q[0][0], q[0][1], q[1][1], q[1][0]])
			norms.append_array([q[0][2], q[0][2], q[1][2], q[1][2]])
			var face_n: Vector3 = ((q[0][2] as Vector3) + (q[1][2] as Vector3)).normalized()
			var tri_n := (verts[base + 1] - verts[base]).cross(verts[base + 2] - verts[base])
			# Godot treats clockwise triangles as front faces.
			if tri_n.dot(face_n) < 0.0:
				idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
			else:
				idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mi.material_override = mat
	_parent.add_child(mi)


func _build_tunnel() -> void:
	var hw := T_W * 0.5
	var t := 0.25
	var up := Vector3.UP
	_tunnel_strip(Color(0.45, 0.42, 0.38), [
		{"e0": func(c, r): return c - r * hw, "e1": func(c, r): return c + r * hw, "n": func(_r): return up},
		{"e0": func(c, r): return c - r * (hw + t) - up * t, "e1": func(c, r): return c + r * (hw + t) - up * t, "n": func(_r): return -up}])
	_tunnel_strip(Color(0.72, 0.72, 0.7), [
		{"e0": func(c, r): return c - r * hw + up * T_H, "e1": func(c, r): return c + r * hw + up * T_H, "n": func(_r): return -up},
		{"e0": func(c, r): return c - r * (hw + t) + up * (T_H + t), "e1": func(c, r): return c + r * (hw + t) + up * (T_H + t), "n": func(_r): return up}])
	_tunnel_strip(Color(0.78, 0.3, 0.24), [ # right wall (the outside of the bend)
		{"e0": func(c, r): return c + r * hw, "e1": func(c, r): return c + r * hw + up * T_H, "n": func(r): return -r},
		{"e0": func(c, r): return c + r * (hw + t) - up * t, "e1": func(c, r): return c + r * (hw + t) + up * (T_H + t), "n": func(r): return r}])
	_tunnel_strip(Color(0.2, 0.52, 0.56), [ # left wall (the inside of the bend)
		{"e0": func(c, r): return c - r * hw, "e1": func(c, r): return c - r * hw + up * T_H, "n": func(r): return r},
		{"e0": func(c, r): return c - r * (hw + t) - up * t, "e1": func(c, r): return c - r * (hw + t) + up * (T_H + t), "n": func(r): return -r}])
	var arc_len := ARC_R * PI * 0.5
	# A few static crates in straight B: static shadows.
	var crate_a := path_at(A_LEN + arc_len + 5.0)
	_box(crate_a[0] + Vector3(1.1, 0.5, 0.0), Vector3(1, 1, 1), Color(0.7, 0.55, 0.3))
	var crate_b := path_at(A_LEN + arc_len + 9.0)
	_box(crate_b[0] + Vector3(-1.0, 0.4, 0.0), Vector3(1.2, 0.8, 1.2), Color(0.5, 0.6, 0.35))

	# Dynamic: a cart carrying a lamp that rides along the tunnel, and a spinning blade under the ceiling.
	_parent = dyn_root
	cart = _box(Vector3.ZERO, Vector3(0.9, 0.7, 1.4), Color(0.9, 0.8, 0.2))
	cart_lamp = OmniLight3D.new()
	cart_lamp.light_color = CART_LAMP_COLOR
	cart_lamp.light_energy = 14.0
	cart_lamp.omni_range = 14.0
	cart_lamp.omni_attenuation = 2.0
	cart_lamp.shadow_enabled = true
	cart_lamp.shadow_blur = 1.6
	cart_lamp.omni_shadow_mode = OmniLight3D.SHADOW_CUBE
	dyn_root.add_child(cart_lamp)
	var bulb := _box(Vector3.ZERO, Vector3(0.25, 0.25, 0.25), CART_LAMP_COLOR, 6.0)
	bulb.set_meta("rc_skip", true)
	bulb.name = "CartBulb"
	blade = _box(Vector3.ZERO, Vector3(2.6, 0.08, 0.3), Color(0.55, 0.55, 0.58))
	_parent = static_root

	_make_env(Color(0.0, 0.0, 0.0), Color(0.5, 0.55, 0.8), 0.01, 2.5)
	_make_camera(75.0)
	var p_start := path_at(1.5)
	var p_bend := path_at(14.0)
	var p_exit := path_at(30.0)
	poses = {
		"start": [p_start[0] + Vector3(0, 1.6, 0), path_at(12.0)[0] + Vector3(0, 1.4, 0)],
		"bend": [p_bend[0] + Vector3(0, 1.6, 0), path_at(21.0)[0] + Vector3(0, 1.4, 0)],
		"exit_back": [p_exit[0] + Vector3(0, 1.6, 0), path_at(13.0)[0] + Vector3(0, 1.3, 0)],
	}
	_animate(0.0)


## Cart position (and so the lamp) and blade angle at time t. lamp_s wins when the animation is off.
func _animate(t: float) -> void:
	if scene_name == "shop":
		var span := 9.8
		if anim_auto and not anim_paused:
			var u := fposmod(t * 1.1 / span, 2.0)
			lamp_s = span * (u if u <= 1.0 else 2.0 - u)
		shop.animate(clampf(lamp_s / span, 0.0, 1.0), t)
		return
	if scene_name != "tunnel":
		return
	var s := lamp_s
	if anim_auto and not anim_paused:
		var span := CART_MAX_S - CART_MIN_S
		var u := fposmod(t * 3.0 / span, 2.0)
		s = CART_MIN_S + span * (u if u <= 1.0 else 2.0 - u)
		lamp_s = s
	var p := path_at(s)
	var h: Vector3 = p[1]
	cart.basis = Basis(Vector3.UP, atan2(-h.x, -h.z))
	cart.position = p[0] + Vector3(0, 0.35, 0)
	cart_lamp.position = p[0] + Vector3(0, 1.8, 0)
	dyn_root.get_node("CartBulb").position = cart_lamp.position
	var bp := path_at(BLADE_S)
	blade.position = bp[0] + Vector3(0, 2.9, 0)
	blade.rotation.y = t * 2.0


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


## Street: the lamp-off-screen test. G is a point high on the lit brick facade, Z the lit sidewalk at its foot
## (the main bounce source). The camera pitches up until Z leaves the screen while G stays in view.
func _sweep(report: PackedStringArray) -> void:
	var c := Vector3(0, 1.7, 5.5)
	var g := Vector3(0, 4.0, -7.0)
	var z := Vector3(0, 0.15, -5.5)
	var sky_ss: Color = effect_ss.sky_radiance
	var sky_world: Color = effect_world.sky_radiance
	effect_ss.sky_radiance = Color.BLACK
	effect_world.sky_radiance = Color.BLACK
	report.append("")
	report.append("Lamp-off-screen sweep (indirect light only, x10 gain; luminance after tonemap x1000 at G):")
	report.append("pitch  G on screen  lit sidewalk on screen  screen-space  world-space")
	for pitch in range(0, 46, 5):
		var fwd := Vector3(0, 0, -1).rotated(Vector3.RIGHT, deg_to_rad(pitch))
		cam.position = c
		cam.look_at(c + fwd * 10.0)
		var vals := {}
		for mode in ["ss_gi", "world_gi"]:
			_set_mode(mode)
			await _frames(5)
			var img := await _shot("sweep_%s_%02d.png" % [mode, pitch])
			vals[mode] = _luma_at(img, cam.unproject_position(g)) * 1000.0
		report.append("%3d deg  %-11s  %-22s  %12.1f  %11.1f" % [
			pitch, str(cam.is_position_in_frustum(g)), str(cam.is_position_in_frustum(z)), vals["ss_gi"], vals["world_gi"]])
	effect_ss.sky_radiance = sky_ss
	effect_world.sky_radiance = sky_world


func _wall_point(s: float) -> Vector3:
	var p := path_at(s)
	var right: Vector3 = (p[1] as Vector3).cross(Vector3.UP)
	return p[0] + right * (T_W * 0.5) + Vector3(0, 1.5, 0)


## Tunnel: how far does the cart's light travel round the bend, and how fast does it follow the cart?
func _travel(report: PackedStringArray) -> void:
	anim_auto = false
	lamp_s = 6.0
	await _frames(8)
	report.append("")
	report.append("Light travel with the cart lamp parked at s = 6 m (straight, before the bend). Luminance after tonemap x1000")
	report.append("at a point on the outer wall (1.5 m high); 'direct+ambient' = Godot only, 'indirect' = world-space RC only (x10 gain).")
	report.append("point s   metres from lamp   region    direct+ambient   indirect (world RC)")
	for s in [10.0, 14.0, 18.0, 22.0, 26.0, 30.0]:
		var target := _wall_point(s)
		var cp: Array = path_at(s - 3.0)
		cam.position = cp[0] + Vector3(0, 1.6, 0)
		cam.look_at(target)
		var vals := {}
		for mode in ["off", "world_gi"]:
			_set_mode(mode)
			await _frames(4)
			var img := await _shot("travel_%s_%02d.png" % [mode, int(s)])
			vals[mode] = _luma_at(img, cam.unproject_position(target), 4) * 1000.0
		var region := "straight A" if s <= A_LEN else ("bend" if s <= A_LEN + ARC_R * PI * 0.5 else "straight B")
		report.append("%5.0f      %5.0f              %-10s %10.1f %18.1f" % [s, s - 6.0, region, vals["off"], vals["world_gi"]])

	# Latency: move the lamp and read the same point 0, 1 and 5 frames later.
	report.append("")
	report.append("Response to a light that moves (indirect luminance x1000 at the wall point s = 28, world RC):")
	var tgt := _wall_point(28.0)
	cam.position = (path_at(25.0)[0] as Vector3) + Vector3(0, 1.6, 0)
	cam.look_at(tgt)
	_set_mode("world_gi")
	lamp_s = 20.0
	await _frames(8)
	var base := _luma_at(await _shot("latency_base.png"), cam.unproject_position(tgt), 4) * 1000.0
	lamp_s = 26.0
	var l0 := _luma_at(await _shot("latency_0.png"), cam.unproject_position(tgt), 4) * 1000.0
	await _frames(1)
	var l1 := _luma_at(await _shot("latency_1.png"), cam.unproject_position(tgt), 4) * 1000.0
	await _frames(5)
	var l5 := _luma_at(await _shot("latency_5.png"), cam.unproject_position(tgt), 4) * 1000.0
	report.append("lamp at s=20: %.1f | moved to s=26, first rendered frame: %.1f, +1 frame: %.1f, +5 frames: %.1f" % [base, l0, l1, l5])


## Close-ups of the places that show artifacts: floor/wall corner, a static crate, the moving cart.
func _closeup_poses() -> void:
	lamp_s = 15.0
	_animate(0.0)
	var arc_len := ARC_R * PI * 0.5
	var sb := A_LEN + arc_len
	var pa := path_at(sb + 6.0)
	var right_b: Vector3 = (pa[1] as Vector3).cross(Vector3.UP)
	poses["c_floor_wall"] = [(pa[0] as Vector3) + Vector3(0, 1.0, 0) - right_b * 0.3, (pa[0] as Vector3) + right_b * T_W * 0.5 + (pa[1] as Vector3) * 1.8 + Vector3(0, 0.3, 0)]
	var crate: Vector3 = (path_at(sb + 5.0)[0] as Vector3) + Vector3(1.1, 0.5, 0.0)
	poses["c_crate"] = [crate + Vector3(-1.6, 1.1, 1.9), crate + Vector3(0, 0.4, 0)]
	var cp := path_at(15.0)
	var ch: Vector3 = cp[1]
	var cr: Vector3 = ch.cross(Vector3.UP)
	var corner: Vector3 = cart.global_transform * Vector3(0.45, 0.35, -0.7)
	poses["c_cart_corner"] = [cart.global_transform * Vector3(1.2, 0.8, -1.7), corner]
	# Low and close: the line where the cart meets the floor, and where the floor meets the wall.
	poses["c_contact"] = [cart.global_transform * Vector3(1.0, -0.15, -1.4), cart.global_transform * Vector3(0.45, -0.3, -0.5)]
	var wp := path_at(sb + 3.0)
	var wr: Vector3 = (wp[1] as Vector3).cross(Vector3.UP)
	poses["c_wall_low"] = [(wp[0] as Vector3) + Vector3(0, 0.45, 0) - wr * 0.2, (wp[0] as Vector3) + wr * T_W * 0.5 + (wp[1] as Vector3) * 1.5 + Vector3(0, 0.05, 0)]
	# Outside the tunnel, facing the outer side of the right wall, with the cart lamp just inside: it must stay dark.
	var op := path_at(sb + 8.0)
	var orr: Vector3 = (op[1] as Vector3).cross(Vector3.UP)
	poses["c_outside_wall"] = [(op[0] as Vector3) + orr * (T_W * 0.5 + 0.25 + 2.2) + Vector3(0, 1.5, 0), (op[0] as Vector3) + orr * (T_W * 0.5 + 0.25) + Vector3(0, 1.4, 0)]
	poses["c_cart"] = [(cp[0] as Vector3) - ch * 3.0 + cr * 0.7 + Vector3(0, 1.3, 0), (cp[0] as Vector3) + Vector3(0, 0.35, 0)]


## Light that gets through a wall: the cart lamp sits just inside the tunnel, the camera looks at the OUTER face of the
## wall, which no light should reach. Reports its luminance (indirect-only view, x1000) and writes the images.
func _leak_test(report: PackedStringArray) -> void:
	_closeup_poses()
	anim_auto = false
	lamp_s = 8.0 + ARC_R * PI * 0.5 + 8.0
	_pose("c_outside_wall")
	report.append("")
	report.append("Light through the wall: outer face of the right wall, cart lamp just inside (luminance x1000, centre of the image):")
	for mode in ["off", "world", "world_gi"]:
		_set_mode(mode)
		await _frames(24)
		var img := await _shot("leak_%s.png" % mode)
		var c := Vector2(img.get_width() * 0.5, img.get_height() * 0.5)
		report.append("%-9s %.1f" % [mode, _luma_at(img, c, 20) * 1000.0])


## Popping around the moving cart. The cart drives 2 cm per frame past fixed floor points beside its path (never under it);
## the indirect-only luminance at each point is read every frame. Smooth physics gives a smooth curve; probes that switch on and
## off, or a history that lags, give steps. Reports, averaged over the points: mean |first difference|, mean |second difference|
## (the roughness of the curve) and the largest second difference, all x1000, plus the size of the signal itself.
func _pop_test(report: PackedStringArray, label: String) -> void:
	_closeup_poses()
	anim_auto = false
	var mid := path_at(15.6)
	var h: Vector3 = mid[1]
	var r: Vector3 = h.cross(Vector3.UP)
	var base: Vector3 = mid[0]
	cam.position = base - h * 3.4 + Vector3(0, 2.6, 0) + r * 0.6
	cam.look_at(base + Vector3(0, 0.1, 0))
	var pts: Array[Vector3] = []
	for dl in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		for lat in [-1.0, 1.0, 1.6]:
			pts.append(base + h * dl + r * lat + Vector3(0, 0.02, 0))
	var visible := 0
	for p in pts:
		if cam.is_position_in_frustum(p):
			visible += 1
	_set_mode("world_gi")
	effect_world.intensity = 3.0 # the x10 gain of the indirect-only view saturates the floor here
	lamp_s = 14.9
	await _frames(20)
	var series: Array = []
	for i in pts.size():
		series.append([])
	for f in 60:
		lamp_s = 14.9 + 0.02 * f
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if f == 30:
			img.save_png(ProjectSettings.globalize_path("res://out/pop_%s.png" % label.strip_edges().replace(" ", "_")))
		for i in pts.size():
			(series[i] as Array).append(_luma_at(img, cam.unproject_position(pts[i]), 3) * 1000.0)
	var d1 := 0.0
	var d2 := 0.0
	var d2max := 0.0
	var level := 0.0
	for s in series:
		var a: Array = s
		for k in range(1, a.size() - 1):
			d1 += absf(a[k + 1] - a[k])
			var dd := absf(a[k + 1] - 2.0 * a[k] + a[k - 1])
			d2 += dd
			d2max = maxf(d2max, dd)
			level += a[k]
	# Which points pop, and at which frames (the cart moves 2 cm per frame; a voxel is 12.5 cm = every 6.25 frames).
	for i in series.size():
		var a: Array = series[i]
		var worst := 0.0
		var at := 0
		for k in range(1, a.size() - 1):
			var dd := absf(a[k + 1] - 2.0 * a[k] + a[k - 1])
			if dd > worst:
				worst = dd
				at = k
		var jumps := []
		for k in range(1, a.size() - 1):
			if absf(a[k + 1] - 2.0 * a[k] + a[k - 1]) > 0.35 * worst and worst > 4.0:
				jumps.append(k)
		report.append("   point %2d (along %+.1f lateral %+.1f): level %.0f, worst |d2| %.1f at frame %d, big steps at %s" % [
			i, [-1.0, -0.5, 0.0, 0.5, 1.0][i / 3], [-1.0, 1.0, 1.6][i % 3], a[a.size() / 2], worst, at, str(jumps)])
	for i in [6, 9]:
		var a2: Array = series[i]
		var txt := ""
		for k in range(18, 34):
			txt += "%.0f " % a2[k]
		report.append("   series of point %d, frames 18..33: %s" % [i, txt])
	var n := float(series.size() * (60 - 2))
	report.append("%s: points on screen %d/%d | signal %.1f | mean|d1| %.2f | mean|d2| %.2f | max|d2| %.2f" % [
		label, visible, pts.size(), level / n, d1 / n, d2 / n, d2max])


## Drives the panel like a user would, with screenshots: default look, the heat map in the corridor, the High preset
## (re-voxelizes the scene), then "Reset all to defaults" (back to the starting values, another re-voxelization).
func _ui_test(report: PackedStringArray) -> void:
	_start_interactive()
	await _frames(40)
	await _shot("ui_default.png")
	var defaults := "voxel %.4f, probes %.2f, cascades %d, near dirs %d, alpha %.2f, strength %.2f" % [
		effect_world.voxel_size, effect_world.probe_spacing, effect_world.cascades, effect_world.near_dirs, effect_world.temporal_alpha, gi_strength]
	report.append("defaults:      " + defaults)
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


## How far behind does the temporal smoothing lag a moving cart? The cart moves 5 cm per frame (3 m/s at 60 FPS) past floor points
## 25 cm from its side. The indirect-only luminance is compared against the same frames rendered without temporal smoothing
## (noisy but not delayed): mean |difference| / mean level, in percent. Lower is better; 0 would be "no lag, no noise".
func _lag_test(report: PackedStringArray) -> void:
	_closeup_poses()
	anim_auto = false
	var mid := path_at(15.6)
	var h: Vector3 = mid[1]
	var r: Vector3 = h.cross(Vector3.UP)
	var base: Vector3 = mid[0]
	cam.position = base - h * 3.4 + Vector3(0, 2.6, 0) + r * 0.6
	cam.look_at(base + Vector3(0, 0.1, 0))
	var pts: Array[Vector3] = []
	for dl in [-0.8, -0.4, 0.0, 0.4, 0.8]:
		for lat in [-0.75, 0.75]:
			pts.append(base + h * dl + r * lat + Vector3(0, 0.02, 0))
	var runs := {}
	var configs := [
		["off (reference)", false, 0.2, 0.0],
		["fixed alpha 0.2", true, 0.2, 0.0],
		["adaptive 0.2 + 1.2", true, 0.2, 1.2],
		["adaptive 0.4 + 1.2", true, 0.4, 1.2],
	]
	for cfg in configs:
		effect_world.temporal = cfg[1]
		effect_world.temporal_alpha = cfg[2]
		effect_world.temporal_adaptive = cfg[3]
		_set_mode("world_gi")
		effect_world.intensity = 3.0
		lamp_s = 13.9
		await _frames(24)
		var vals: Array = []
		for f in 30:
			lamp_s = 13.9 + 0.05 * f
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var row: Array = []
			for p in pts:
				row.append(_luma_at(img, cam.unproject_position(p), 4) * 1000.0)
			vals.append(row)
		runs[cfg[0]] = vals
	var ref: Array = runs["off (reference)"]
	report.append("")
	report.append("Lag of the temporal smoothing (cart 5 cm per frame; mean |difference to the un-smoothed frames| / level, percent):")
	for cfg in configs:
		var vals: Array = runs[cfg[0]]
		var diff := 0.0
		var level := 0.0
		for f in vals.size():
			for i in pts.size():
				diff += absf(vals[f][i] - ref[f][i])
				level += ref[f][i]
		report.append("  %-22s %.2f %%" % [cfg[0], 100.0 * diff / maxf(level, 1.0)])
	effect_world.temporal = true
	effect_world.temporal_alpha = 0.2
	effect_world.temporal_adaptive = 1.2


## The cart moves 3 cm per frame past a fixed camera. Reports how much the light on the floor around it changes
## from one frame to the next (voxels are 12.5 cm: snapping would show up as jumps every 4th frame).
func _motion(report: PackedStringArray) -> void:
	_closeup_poses()
	_pose("c_cart_corner")
	anim_auto = false
	_set_mode("world_gi")
	await _frames(6)
	var prev: Image
	var diffs := PackedFloat32Array()
	for i in 17:
		lamp_s = 15.0 + 0.03 * i
		await _frames(2)
		var img := await _shot("motion_%02d.png" % i)
		if i in [0, 8, 16]:
			pass
		if prev != null:
			var sum := 0.0
			var n := 0
			for y in range(0, img.get_height(), 4):
				for x in range(0, img.get_width(), 4):
					sum += absf(img.get_pixel(x, y).get_luminance() - prev.get_pixel(x, y).get_luminance())
					n += 1
			diffs.append(sum / n * 1000.0)
		prev = img
	report.append("")
	report.append("Cart moving 3 cm per frame (indirect-only view, mean |luma change| x1000 between consecutive frames):")
	report.append(", ".join(Array(diffs).map(func(d): return "%.2f" % d)))


## |a - b| per pixel, max over channels, times gain, as a grey image.
func _diff_image(a: Image, b: Image, gain: float) -> Image:
	a.convert(Image.FORMAT_RGBA8)
	b.convert(Image.FORMAT_RGBA8)
	var da := a.get_data()
	var db := b.get_data()
	var out := PackedByteArray()
	out.resize(da.size())
	for i in range(0, da.size(), 4):
		var d := maxi(maxi(absi(da[i] - db[i]), absi(da[i + 1] - db[i + 1])), absi(da[i + 2] - db[i + 2]))
		var v := clampi(int(d * gain), 0, 255)
		out[i] = v
		out[i + 1] = v
		out[i + 2] = v
		out[i + 3] = 255
	return Image.create_from_data(a.get_width(), a.get_height(), false, Image.FORMAT_RGBA8, out)


## Composite image of two consecutive frames with the cart 3 cm apart, and where they differ (x8).
func _motion_maps(report: PackedStringArray) -> void:
	_closeup_poses()
	anim_auto = false
	for pose in ["c_cart_corner", "c_contact"]:
		_pose(pose)
		for mode in ["world", "off"]:
			_set_mode(mode)
			lamp_s = 15.0
			await _frames(6)
			var a := await _shot("mm_%s_%s_a.png" % [pose, mode])
			lamp_s = 15.03
			await _frames(2)
			var b := await _shot("mm_%s_%s_b.png" % [pose, mode])
			_diff_image(a, b, 8.0).save_png(ProjectSettings.globalize_path("res://out/mm_%s_%s_diff.png" % [pose, mode]))


func _run() -> void:
	await _frames(10)
	var report := PackedStringArray()
	var size := get_viewport().get_visible_rect().size
	report.append("Scene %s, viewport %dx%d, GPU %s" % [scene_name, size.x, size.y, RenderingServer.get_video_adapter_name()])
	effect_world.set_scene(RCW.collect_triangles(static_root), RCW.collect_lights(self))
	if scene_name != "room":
		RenderingServer.call_on_render_thread(effect_world.rebuild)
		await _frames(5)
		report.append("voxel volume %s at %.2f m, %d static triangles, %d lights, %d cascades, probe spacing %.2f m, dynamic=%s" % [
			effect_world.dims, effect_world.voxel_size, effect_world._tri_count, effect_world._light_count,
			effect_world.cascades, effect_world.probe_spacing, str(effect_world.dynamic)])
	var harness := user_args.has("--uitest") or user_args.has("--lag") or user_args.has("--pop") or user_args.has("--leak") or user_args.has("--motionmaps") or user_args.has("--motion") or user_args.has("--closeups") or user_args.has("--shots") or user_args.has("--sweep") or user_args.has("--bench") or user_args.has("--travel")
	if not harness:
		_start_interactive()
		return
	if user_args.has("--uitest"):
		await _ui_test(report)
	if user_args.has("--closeups") and scene_name == "tunnel":
		_closeup_poses()
		for pose in ["c_floor_wall", "c_crate", "c_cart", "c_cart_corner", "c_contact", "c_wall_low"]:
			_pose(pose)
			for mode in ["off", "world", "world_gi", "world_alb", "world_dbg"]:
				_set_mode(mode)
				await _frames(24)
				await _shot("%s_%s.png" % [pose, mode])
	if user_args.has("--motion") and scene_name == "tunnel":
		await _motion(report)
	if user_args.has("--lag") and scene_name == "tunnel":
		await _lag_test(report)
	if user_args.has("--pop") and scene_name == "shop":
		for cfg in [["temporal ON ", true], ["temporal OFF", false]]:
			effect_world.temporal = cfg[1]
			await _pop_test_shop(report, cfg[0])
		effect_world.temporal = true
		shop.dolly_lamp.light_energy = 0.0
		await _pop_test_shop(report, "temporal ON, dolly lamp OFF")
		shop.dolly_lamp.light_energy = 7.0
	if user_args.has("--pop") and scene_name == "tunnel":
		for cfg in [["temporal ON ", true], ["temporal OFF", false]]:
			effect_world.temporal = cfg[1]
			await _pop_test(report, cfg[0])
		effect_world.temporal = true
	if user_args.has("--leak") and scene_name == "tunnel":
		await _leak_test(report)
	if user_args.has("--motionmaps") and scene_name == "tunnel":
		await _motion_maps(report)
	if user_args.has("--shots"):
		if scene_name == "shop":
			for dolly_s in [2.0, 7.0]:
				lamp_s = dolly_s
				for pose in poses:
					_pose(pose)
					for mode in ["off", "world", "world_gi", "world_heat"]:
						_set_mode(mode)
						await _frames(24)
						await _shot("shop_%s_d%d_%s.png" % [pose, int(dolly_s), mode])
		elif scene_name == "tunnel":
			for s_lamp in [8.0, 16.0, 24.0]:
				lamp_s = s_lamp
				for pose in poses:
					if s_lamp != 8.0 and pose != "exit_back":
						continue
					_pose(pose)
					var modes := ["off", "ss", "world", "world_gi"] if s_lamp == 8.0 else ["off", "world"]
					for mode in modes:
						_set_mode(mode)
						await _frames(6)
						await _shot("%s_lamp%02d_%s.png" % [pose, int(s_lamp), mode])
		else:
			for pose in poses:
				_pose(pose)
				var modes2 := ["off", "ss", "world", "ss_gi", "world_gi", "world_alb"] if scene_name == "street" else ["off", "ss", "ss_gi"]
				for mode in modes2:
					_set_mode(mode)
					await _frames(6)
					await _shot("%s_%s.png" % [pose, mode])
	if user_args.has("--sweep") and scene_name == "street":
		await _sweep(report)
	if user_args.has("--travel") and scene_name == "tunnel":
		await _travel(report)
	if user_args.has("--bench"):
		var pose_name := "exit_back" if scene_name == "tunnel" else ("aisle" if scene_name == "shop" else ("down_street" if scene_name == "street" else "down_room"))
		_pose(pose_name)
		anim_auto = scene_name == "tunnel" or scene_name == "shop"
		await _bench("GI off", "off", 200, report)
		await _bench("screen-space RC", "ss", 200, report)
		await _bench("world RC (dynamic: voxels + lights redone every frame)", "world", 200, report)
		effect_world.dynamic = false
		await _bench("world RC (frozen volume, no per-frame update)", "world", 200, report)
		effect_world.dynamic = scene_name == "tunnel" or scene_name == "shop"
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
	if (scene_name == "tunnel" or scene_name == "shop") and effect_world != null and effect_world.volume_ready and effect_world.dynamic:
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


func mouse_is_free() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_VISIBLE or hidden_run


func teleport(pose_name: String) -> void:
	_pose(pose_name)
	_yaw = cam.rotation.y
	_pitch = cam.rotation.x


func volume_size() -> Vector3:
	return SHOP.VOLUME_SIZE if scene_name == "shop" else Vector3(24.0, 6.0, 27.0)


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
	var first: String = "start" if scene_name == "tunnel" else ("entrance" if scene_name == "shop" else ("down_street" if scene_name == "street" else "down_room"))
	_pose(first)
	_yaw = cam.rotation.y
	_pitch = cam.rotation.x
	if scene_name == "tunnel" or scene_name == "shop":
		anim_auto = true
	live_mode = "world"
	_set_mode("world")
	ui = UI.new()
	add_child(ui)
	ui.setup(self)
	if not hidden_run:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if not interactive:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# The quote key (the one that types the quote, or the key above Tab) toggles the panel.
		if event.keycode == KEY_APOSTROPHE or event.physical_keycode == KEY_QUOTELEFT or event.keycode == KEY_QUOTELEFT:
			_ui_sticky = not _ui_sticky
			get_viewport().set_input_as_handled()
			return
		match event.physical_keycode:
			KEY_1: set_live_mode("off")
			KEY_2: set_live_mode("world")
			KEY_3: set_live_mode("world_gi")
			KEY_4: set_live_mode("world_heat")
			KEY_5: set_live_mode("ss")
			KEY_SPACE: anim_paused = not anim_paused
			KEY_G: effect_world.final_gather = not effect_world.final_gather
			KEY_T: effect_world.temporal = not effect_world.temporal
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.003
		_pitch = clampf(_pitch - event.relative.y * 0.003, -1.5, 1.5)
		cam.rotation = Vector3(_pitch, _yaw, 0.0)


func _interactive_process(delta: float) -> void:
	# The quote key toggles the panel mode: mouse free to click it; otherwise the mouse looks around.
	var want_free := _ui_sticky
	var wanted := Input.MOUSE_MODE_VISIBLE if want_free else Input.MOUSE_MODE_CAPTURED
	if not hidden_run and Input.mouse_mode != wanted:
		Input.mouse_mode = wanted
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): dir.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S): dir.z += 1.0
	if Input.is_physical_key_pressed(KEY_A): dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D): dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_E): dir.y += 1.0
	if Input.is_physical_key_pressed(KEY_Q): dir.y -= 1.0
	var speed := 12.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 4.0
	cam.position += cam.global_transform.basis * dir * speed * delta
	if not anim_auto:
		var move := 0.0
		if Input.is_physical_key_pressed(KEY_Z): move -= 1.0
		if Input.is_physical_key_pressed(KEY_X): move += 1.0
		lamp_s = clampf(lamp_s + move * 4.0 * delta, 0.0, 9.8 if scene_name == "shop" else A_LEN + ARC_R * PI * 0.5 + B_LEN)
	ui.refresh()
