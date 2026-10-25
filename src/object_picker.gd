extends Node3D
## Select and move the props of the store with the mouse.
##   hover            a yellow outline (2 px)
##   click            select: an orange outline (3 px) and a move gizmo (three arrows)
## The outlines are drawn in screen space, pixel exact (src/outline.gdshader): the hovered and the selected prop are each drawn
## alone into a mask the size of the window, and a full-screen pass draws the pixels around the mask.
##   drag the prop    move it over the floor (horizontal plane)
##   drag an arrow    move it along that axis only (red X, green Y, blue Z)
##   Esc / click empty space   deselect;  F   frame the selected prop
## While a prop moves, and once more when it stops, the static scene is voxelized again on the GPU, so its light and shadow in the
## bounce follow it.

const AXES: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const AXIS_COLORS: Array[Color] = [Color(0.95, 0.27, 0.27), Color(0.35, 0.9, 0.35), Color(0.3, 0.55, 1.0)]
const HOVER_COLOR := Color(1.0, 0.9, 0.35)
const SELECT_COLOR := Color(1.0, 0.55, 0.1)
const ARROW_LEN := 0.8 # in gizmo units (the gizmo is scaled to a constant size on screen)
const ARROW_PICK_PX := 14.0 # how close (pixels) the mouse must be to an arrow to grab it
const REVOXELIZE_EVERY := 0.1 # seconds between re-voxelizations while dragging
const PLANE_DRAG := 3 # drag mode: the prop over the floor
const DRAG_START_PX := 5.0 # the mouse must move this far with the button down before a prop starts to move (a click never moves it)
const SELECT_LAYER := 1 << 19 # visual layers the masks render (the main camera sees every layer)
const HOVER_LAYER := 1 << 18

var main: Node3D
var selectables: Array = []
var hovered: Node3D
var selected: Node3D
var hovered_axis := -1
var dragging := false
var revoxelize_count := 0
var last_collect_ms := 0.0 # CPU time to gather the meshes for the last re-voxelization

var _masks: Array[SubViewport] = [] # [selected, hovered]
var _mask_cams: Array[Camera3D] = []
var _outline_mat: ShaderMaterial
var _gizmo: Node3D
var _arrow_mats: Array[StandardMaterial3D] = []
var _drag_axis := -1
var _pending_axis := -1 # pressed, not yet moved far enough to drag
var _press_pos := Vector2.ZERO
var _drag_plane_y := 0.0
var _drag_last_hit := Vector3.ZERO
var _dirty := false
var _since_revoxelize := 0.0
var _originals := {} # node -> {"xf": Transform3D, "colors": Array[Color]}


func setup(m: Node3D, nodes: Array) -> void:
	main = m
	selectables = nodes
	_build_gizmo()
	_build_outline()


## Two mask views (the selected and the hovered prop, each alone, flat, on a transparent background) and the full-screen pass.
func _build_outline() -> void:
	for layer in [SELECT_LAYER, HOVER_LAYER]:
		var vp := SubViewport.new()
		vp.transparent_bg = true
		vp.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		vp.positional_shadow_atlas_size = 0
		add_child(vp)
		var cam := Camera3D.new()
		cam.cull_mask = layer
		var env := Environment.new()
		env.background_mode = Environment.BG_CLEAR_COLOR
		cam.environment = env
		vp.add_child(cam)
		_masks.append(vp)
		_mask_cams.append(cam)
	var layer_node := CanvasLayer.new()
	layer_node.layer = 5 # over the scene, under the control panel
	add_child(layer_node)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outline_mat = ShaderMaterial.new()
	_outline_mat.shader = load("res://src/outline.gdshader")
	_outline_mat.set_shader_parameter("sel_mask", _masks[0].get_texture())
	_outline_mat.set_shader_parameter("hov_mask", _masks[1].get_texture())
	_outline_mat.set_shader_parameter("sel_color", SELECT_COLOR)
	_outline_mat.set_shader_parameter("hov_color", HOVER_COLOR)
	rect.material = _outline_mat
	layer_node.add_child(rect)


## Keeps the mask cameras on the main camera, the masks at the window's size, and renders a mask only while it has a prop in it.
func _update_outline() -> void:
	var size := Vector2i(get_viewport().get_visible_rect().size)
	var has := [selected != null, hovered != null and hovered != selected]
	for i in 2:
		var vp := _masks[i]
		if vp.size != size:
			vp.size = size
		var cam := _mask_cams[i]
		cam.global_transform = main.cam.global_transform
		cam.fov = main.cam.fov
		cam.near = main.cam.near
		cam.far = main.cam.far
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if has[i] else SubViewport.UPDATE_DISABLED
	_outline_mat.set_shader_parameter("sel_on", has[0])
	_outline_mat.set_shader_parameter("hov_on", has[1])


func _flat(c: Color, on_top := true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.no_depth_test = on_top
	m.render_priority = 10
	return m


func _build_gizmo() -> void:
	_gizmo = Node3D.new()
	_gizmo.name = "MoveGizmo"
	_gizmo.visible = false
	add_child(_gizmo)
	var centre := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.05
	sm.height = 0.1
	centre.mesh = sm
	centre.material_override = _flat(Color(0.95, 0.95, 0.95))
	_gizmo.add_child(centre)
	for i in 3:
		var mat := _flat(AXIS_COLORS[i])
		_arrow_mats.append(mat)
		var arm := Node3D.new()
		# The arrow is built along +Y and turned onto its axis.
		if i == 0:
			arm.rotation = Vector3(0, 0, -PI * 0.5)
		elif i == 2:
			arm.rotation = Vector3(PI * 0.5, 0, 0)
		_gizmo.add_child(arm)
		var shaft := CylinderMesh.new()
		shaft.top_radius = 0.016
		shaft.bottom_radius = 0.016
		shaft.height = ARROW_LEN - 0.18
		shaft.radial_segments = 12
		var tip := CylinderMesh.new()
		tip.top_radius = 0.0
		tip.bottom_radius = 0.06
		tip.height = 0.18
		tip.radial_segments = 16
		for part in [[shaft, (ARROW_LEN - 0.18) * 0.5], [tip, ARROW_LEN - 0.09]]:
			var mi := MeshInstance3D.new()
			mi.mesh = part[0]
			mi.material_override = mat
			mi.position = Vector3(0, part[1], 0)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			arm.add_child(mi)
	for n in _gizmo.find_children("*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).set_meta("rc_skip", true)
		(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _process(delta: float) -> void:
	_update_outline()
	# The left button released over the panel never reaches us: end a drag from the real button state.
	if (_drag_axis >= 0 or _pending_axis >= 0) and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end_drag()
	if selected != null:
		_gizmo.global_position = _bounds(selected).get_center()
		# The same size on screen at any distance.
		_gizmo.scale = Vector3.ONE * maxf(main.cam.global_position.distance_to(_gizmo.global_position) * 0.2, 0.05)
	for i in 3:
		var hot := i == hovered_axis or i == _drag_axis
		_arrow_mats[i].albedo_color = AXIS_COLORS[i].lightened(0.55) if hot else AXIS_COLORS[i]
	_since_revoxelize += delta
	if _dirty and _since_revoxelize >= REVOXELIZE_EVERY:
		revoxelize()


## Mouse input while the cursor is free (main.gd calls this). Returns true when the event was used.
func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _pending_axis >= 0:
			if mm.position.distance_to(_press_pos) < DRAG_START_PX:
				return true
			_drag_axis = _pending_axis
			_pending_axis = -1
			dragging = true
			if _drag_axis == PLANE_DRAG:
				_drag_last_hit = _plane_hit(_press_pos, _drag_plane_y)
		if _drag_axis == PLANE_DRAG:
			_drag_on_plane(mm.position)
			return true
		if _drag_axis >= 0:
			_drag_along_axis(mm.relative)
			return true
		hover_at(mm.position)
		return false
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_press_pos = mb.position
			if selected != null and hovered_axis >= 0:
				_pending_axis = hovered_axis
				return true
			var hit := pick(mb.position)
			select(hit)
			if hit != null: # click and drag a prop: it moves over the floor
				_pending_axis = PLANE_DRAG
				_drag_plane_y = hit.global_position.y
			return true
		if _drag_axis >= 0 or _pending_axis >= 0:
			_end_drag()
			return true
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).physical_keycode:
			KEY_ESCAPE:
				if selected != null:
					select(null)
					return true
			KEY_F:
				if selected != null:
					frame_selected()
					return true
	return false


func _end_drag() -> void:
	_drag_axis = -1
	_pending_axis = -1
	dragging = false
	if _dirty:
		revoxelize()


## No hover while the mouse is over the panel or is turning the camera.
func clear_hover() -> void:
	hovered_axis = -1
	set_hovered(null)


## Updates the hover highlight (prop or gizmo arrow) for the mouse at screen position p.
func hover_at(p: Vector2) -> void:
	hovered_axis = _arrow_at(p) if selected != null else -1
	set_hovered(null if hovered_axis >= 0 else pick(p))


func set_hovered(n: Node3D) -> void:
	if n == hovered:
		return
	if hovered != null and hovered != selected:
		_set_outline(hovered, 0)
	hovered = n
	if hovered != null and hovered != selected:
		_set_outline(hovered, HOVER_LAYER)


func select(n: Node3D) -> void:
	if selected != null:
		_set_outline(selected, 0)
	selected = n
	if selected != null:
		_set_outline(selected, SELECT_LAYER)
		if not _originals.has(selected):
			_originals[selected] = {"xf": selected.transform, "colors": _colors(selected)}
	if hovered != null and hovered != selected:
		_set_outline(hovered, HOVER_LAYER)
	_gizmo.visible = selected != null
	hovered_axis = -1


## Moves the camera to look at the selected prop from a little way off.
func frame_selected() -> void:
	if selected == null:
		return
	var b := _bounds(selected)
	var cam: Camera3D = main.cam
	var back := -cam.global_transform.basis.z
	cam.global_position = b.get_center() - back * maxf(b.size.length() * 1.6, 1.5)
	cam.look_at(b.get_center())
	main.sync_camera_angles()


## The selectable prop under screen position p (nearest along the camera ray), or null.
func pick(p: Vector2) -> Node3D:
	var cam: Camera3D = main.cam
	var o := cam.project_ray_origin(p)
	var d := cam.project_ray_normal(p)
	var best: Node3D = null
	var best_t := INF
	for n in selectables:
		var t := _ray_box(o, d, _bounds(n))
		if t >= 0.0 and t < best_t:
			best_t = t
			best = n
	return best


func move_selected(by: Vector3) -> void:
	if selected == null:
		return
	selected.global_position += by
	_dirty = true


func set_selected_yaw(degrees: float) -> void:
	if selected == null:
		return
	selected.rotation.y = deg_to_rad(degrees)
	_dirty = true


func set_selected_color(c: Color) -> void:
	if selected == null:
		return
	for mi in _parts(selected):
		(mi.material_override as StandardMaterial3D).albedo_color = c
	_dirty = true


## Back to where and how the selected prop was before it was first touched.
func reset_selected() -> void:
	if selected == null or not _originals.has(selected):
		return
	var orig: Dictionary = _originals[selected]
	selected.transform = orig["xf"]
	var parts := _parts(selected)
	for i in parts.size():
		(parts[i].material_override as StandardMaterial3D).albedo_color = orig["colors"][i]
	_dirty = true


## Gathers the static meshes again and has the effect voxelize them on the GPU (the bounce follows the moved prop).
func revoxelize() -> void:
	var fx = main.effect_world
	var t0 := Time.get_ticks_usec()
	var meshes: Dictionary = fx.collect_meshes(main.static_root)
	last_collect_ms = (Time.get_ticks_usec() - t0) / 1000.0
	fx.set_static_meshes(meshes)
	RenderingServer.call_on_render_thread(fx.revoxelize_static)
	revoxelize_count += 1
	_dirty = false
	_since_revoxelize = 0.0


func _drag_along_axis(rel: Vector2) -> void:
	# Mouse motion projected on the arrow as it appears on screen, converted to metres along the axis.
	var cam: Camera3D = main.cam
	var p := _gizmo.global_position
	var ax: Vector3 = AXES[_drag_axis]
	var s := cam.unproject_position(p + ax) - cam.unproject_position(p)
	if s.length_squared() < 1.0:
		return
	move_selected(ax * rel.dot(s) / s.length_squared())


func _drag_on_plane(p: Vector2) -> void:
	var hit := _plane_hit(p, _drag_plane_y)
	if hit.is_finite() and _drag_last_hit.is_finite():
		var d := hit - _drag_last_hit
		d.y = 0.0
		if d.length() < 5.0: # ignore jumps when the ray grazes the plane
			move_selected(d)
	_drag_last_hit = hit


## Where the camera ray through screen point p meets the horizontal plane at height y (INF when it does not).
func _plane_hit(p: Vector2, y: float) -> Vector3:
	var cam: Camera3D = main.cam
	var o := cam.project_ray_origin(p)
	var d := cam.project_ray_normal(p)
	if absf(d.y) < 1e-4:
		return Vector3.INF
	var t := (y - o.y) / d.y
	return o + d * t if t > 0.0 else Vector3.INF


func _arrow_at(p: Vector2) -> int:
	var cam: Camera3D = main.cam
	if cam.is_position_behind(_gizmo.global_position):
		return -1
	var best := -1
	var best_d := ARROW_PICK_PX
	var a := cam.unproject_position(_gizmo.global_position)
	for i in 3:
		var b := cam.unproject_position(_gizmo.global_position + AXES[i] * ARROW_LEN * _gizmo.scale.x)
		var d := p.distance_to(Geometry2D.get_closest_point_to_segment(p, a.lerp(b, 0.15), b))
		if d < best_d:
			best_d = d
			best = i
	return best


func _parts(n: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
	return out


func _colors(n: Node3D) -> Array[Color]:
	var out: Array[Color] = []
	for mi in _parts(n):
		out.append((mi.material_override as StandardMaterial3D).albedo_color)
	return out


## Puts the parts of a prop on one outline mask layer (0 = on none).
func _set_outline(n: Node3D, layer: int) -> void:
	for mi in _parts(n):
		mi.layers = 1 | layer


## World bounding box of a prop (all its parts).
func _bounds(n: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in _parts(n):
		var b := mi.global_transform * mi.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out


## Distance along the ray to the box, or -1 when it misses.
static func _ray_box(o: Vector3, d: Vector3, b: AABB) -> float:
	var t_min := 0.0
	var t_max := INF
	for k in 3:
		if absf(d[k]) < 1e-8:
			if o[k] < b.position[k] or o[k] > b.end[k]:
				return -1.0
			continue
		var t1 := (b.position[k] - o[k]) / d[k]
		var t2 := (b.end[k] - o[k]) / d[k]
		t_min = maxf(t_min, minf(t1, t2))
		t_max = minf(t_max, maxf(t1, t2))
		if t_min > t_max:
			return -1.0
	return t_min
