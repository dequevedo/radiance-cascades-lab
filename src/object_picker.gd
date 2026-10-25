extends Node3D
## Select and move the props of the shop with the mouse (free it with the quote key first).
## Hover = yellow highlight, click = select (blue highlight + a move gizmo with three arrows), drag an arrow = move the prop along
## that axis. While a prop moves, and once more when it stops, the static scene is voxelized again on the GPU, so its light and
## shadow in the bounce follow it.

const AXES: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const AXIS_COLORS: Array[Color] = [Color(0.95, 0.3, 0.3), Color(0.35, 0.9, 0.35), Color(0.35, 0.55, 1.0)]
const ARROW_PICK_PX := 12.0 # how close (pixels) the mouse must be to an arrow to grab it
const REVOXELIZE_EVERY := 0.1 # seconds between re-voxelizations while dragging

var main: Node3D
var selectables: Array = []
var hovered: Node3D
var selected: Node3D
var hovered_axis := -1
var revoxelize_count := 0
var last_collect_ms := 0.0 # CPU time to gather the meshes for the last re-voxelization

var _hover_mat: StandardMaterial3D
var _select_mat: StandardMaterial3D
var _gizmo: Node3D
var _arrows: Array[Node3D] = []
var _arrow_mats: Array[StandardMaterial3D] = []
var _drag_axis := -1
var _dirty := false
var _since_revoxelize := 0.0
var _originals := {} # node -> {"xf": Transform3D, "colors": Array[Color]}


func setup(m: Node3D, nodes: Array) -> void:
	main = m
	selectables = nodes
	_hover_mat = _overlay(Color(1.0, 0.85, 0.3, 0.25))
	_select_mat = _overlay(Color(0.35, 0.75, 1.0, 0.3))
	_build_gizmo()


func _overlay(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	return m


func _build_gizmo() -> void:
	_gizmo = Node3D.new()
	_gizmo.name = "MoveGizmo"
	_gizmo.visible = false
	add_child(_gizmo)
	for i in 3:
		var arm := Node3D.new()
		_gizmo.add_child(arm)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true # always drawn on top
		mat.render_priority = 10
		mat.albedo_color = AXIS_COLORS[i]
		var ax: Vector3 = AXES[i]
		for part in [[ax * 0.32, Vector3.ONE * 0.035 + ax * 0.6], [ax * 0.68, Vector3.ONE * 0.11]]:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = part[1]
			mi.mesh = bm
			mi.material_override = mat
			mi.position = part[0]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.set_meta("rc_skip", true)
			arm.add_child(mi)
		_arrows.append(arm)
		_arrow_mats.append(mat)


func _process(delta: float) -> void:
	if selected != null:
		_gizmo.global_position = selected.global_position + Vector3(0, _bounds(selected).size.y * 0.5, 0)
		# The same size on screen at any distance.
		_gizmo.scale = Vector3.ONE * maxf(main.cam.global_position.distance_to(_gizmo.global_position) * 0.16, 0.05)
	for i in 3:
		_arrow_mats[i].albedo_color = AXIS_COLORS[i].lightened(0.5) if (i == hovered_axis or i == _drag_axis) else AXIS_COLORS[i]
	_since_revoxelize += delta
	if _dirty and _since_revoxelize >= REVOXELIZE_EVERY:
		revoxelize()


## Mouse input while the mouse is free (main.gd calls this). Returns true when the event was used.
func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag_axis >= 0:
			_drag(mm.relative)
			return true
		hover_at(mm.position)
		return false
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if selected != null and hovered_axis >= 0:
				_drag_axis = hovered_axis
				return true
			select(pick(mb.position))
			return true
		if _drag_axis >= 0:
			_drag_axis = -1
			if _dirty:
				revoxelize()
			return true
	if event is InputEventKey and event.pressed and (event as InputEventKey).physical_keycode == KEY_ESCAPE:
		select(null)
		return true
	return false


## Updates the hover highlight (prop or gizmo arrow) for the mouse at screen position p.
func hover_at(p: Vector2) -> void:
	hovered_axis = _arrow_at(p) if selected != null else -1
	set_hovered(null if hovered_axis >= 0 else pick(p))


func set_hovered(n: Node3D) -> void:
	if n == hovered:
		return
	if hovered != null and hovered != selected:
		_set_overlay(hovered, null)
	hovered = n
	if hovered != null and hovered != selected:
		_set_overlay(hovered, _hover_mat)


func select(n: Node3D) -> void:
	if selected != null:
		_set_overlay(selected, null)
	selected = n
	if selected != null:
		_set_overlay(selected, _select_mat)
		if not _originals.has(selected):
			_originals[selected] = {"xf": selected.transform, "colors": _colors(selected)}
	_gizmo.visible = selected != null
	hovered_axis = -1


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


func _drag(rel: Vector2) -> void:
	# Mouse motion projected on the arrow as it appears on screen, converted to metres along the axis.
	var cam: Camera3D = main.cam
	var p := _gizmo.global_position
	var ax: Vector3 = AXES[_drag_axis]
	var s := cam.unproject_position(p + ax) - cam.unproject_position(p)
	if s.length_squared() < 1.0:
		return
	move_selected(ax * rel.dot(s) / s.length_squared())


func _arrow_at(p: Vector2) -> int:
	var cam: Camera3D = main.cam
	var best := -1
	var best_d := ARROW_PICK_PX
	for i in 3:
		if cam.is_position_behind(_gizmo.global_position):
			return -1
		var a := cam.unproject_position(_gizmo.global_position)
		var b := cam.unproject_position(_gizmo.global_position + AXES[i] * 0.75 * _gizmo.scale.x)
		var d := p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))
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


func _set_overlay(n: Node3D, mat: Material) -> void:
	for mi in _parts(n):
		mi.material_overlay = mat


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
