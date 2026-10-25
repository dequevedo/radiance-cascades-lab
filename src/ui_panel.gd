extends CanvasLayer
## The lab's control panel, in tabs: View, GI, Quality, Scene, Object, Stats. The quote key (above Tab) frees the mouse to use it;
## press it again to give the mouse back to the camera. No control keeps the keyboard focus, so WASD and Space keep moving the
## camera. Also draws the split-view line (drag it) and the hint at the top of the screen.

const BG := Color(0.05, 0.06, 0.08, 0.92)
const ACCENT := Color(0.95, 0.65, 0.2)
const DIM := Color(0.62, 0.66, 0.72)
# The key that frees the mouse has its own colour everywhere it is shown, so it is never missed.
const KEY_COLOR := Color(0.2, 0.85, 1.0)
const FREE_COLOR := Color(0.35, 0.95, 0.45)
const FONT := 12
const WIDTH := 340.0
const LABEL_W := 128.0

var main: Node3D
var effect: Object
var shop: Object
var picker: Node3D
var tabs: TabContainer

var _root: Control
var _panel: PanelContainer
var _readout: Label
var _hint: Label
var _hint_box: PanelContainer
var _hint_style: StyleBoxFlat
var _help: PanelContainer
var _help_speed: Label
var _status: Label
var _heat_legend: Control
var _controls: Array = [] # {widget, kind, default, setter}
var _sliders := {}
var _mode_buttons := {}
var _pending := {"voxel": 0.125, "spacing": 0.5, "cascades": 4}
var _pending_default := {}
var _voxel_option: OptionButton
var _spacing_option: OptionButton
var _cascade_option: OptionButton
var _voxel_values := [0.25, 0.1667, 0.125, 0.1, 0.0833]
var _spacing_values := [1.0, 0.7, 0.5, 0.35, 0.25]
var _cascade_values := [3, 4, 5]
# Split view
var _split_check: CheckButton
var _split_line: ColorRect
var _split_handle: Control
var _split_labels: Array[Label] = []
var _split_dragging := false
# Object tab
var _obj_name: Label
var _obj_info: Label
var _obj_yaw: HSlider
var _obj_color: ColorPickerButton
var _obj_box: Control
# Stats tab
var _stats_rows := {} # pass name -> [value label, bar]
var _stats_box: VBoxContainer
var _stats_extra: Label
var _pass_ms := {}
var _stats_t := 0.0


func setup(m: Node3D) -> void:
	main = m
	effect = m.effect_world
	shop = m.shop
	picker = m.picker
	layer = 20
	_pending = {"voxel": effect.voxel_size, "spacing": effect.probe_spacing, "cascades": effect.cascades}
	_pending_default = _pending.duplicate()

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	theme.default_font_size = FONT
	_root.theme = theme
	add_child(_root)
	_build_split_overlay()

	_panel = PanelContainer.new()
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 8
	_panel.offset_top = 8
	_panel.offset_bottom = -8
	_panel.offset_right = 8 + WIDTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	_panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_panel.add_child(col)
	_build_header(col)

	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", FONT)
	col.add_child(tabs)
	_build_view(_tab(tabs, "View"))
	_build_gi(_tab(tabs, "GI"))
	_build_quality(_tab(tabs, "Quality"))
	if shop != null:
		_build_scene(_tab(tabs, "Scene"))
	if picker != null:
		_build_object(_tab(tabs, "Object"))
	_build_stats(_tab(tabs, "Stats"))
	_no_focus(_root)

	# The hint at the top of the screen: a coloured badge that says which key frees the mouse (cyan) or that it is free (green).
	_hint_box = PanelContainer.new()
	_hint_box.position = Vector2(WIDTH + 24, 10)
	_hint_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_style = StyleBoxFlat.new()
	_hint_style.bg_color = KEY_COLOR
	_hint_style.set_corner_radius_all(6)
	_hint_style.content_margin_left = 12
	_hint_style.content_margin_right = 12
	_hint_style.content_margin_top = 5
	_hint_style.content_margin_bottom = 5
	_hint_box.add_theme_stylebox_override("panel", _hint_style)
	_root.add_child(_hint_box)
	_build_help()
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", Color(0.02, 0.05, 0.08))
	_hint_box.add_child(_hint)


## The controls, always on screen at the bottom right (H hides them).
func _build_help() -> void:
	_help = PanelContainer.new()
	_help.anchor_left = 1.0
	_help.anchor_right = 1.0
	_help.anchor_top = 1.0
	_help.anchor_bottom = 1.0
	_help.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_help.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_help.offset_right = -10
	_help.offset_bottom = -10
	_help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.8)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	_help.add_theme_stylebox_override("panel", sb)
	_root.add_child(_help)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 1)
	var col := VBoxContainer.new()
	col.add_child(grid)
	_help.add_child(col)
	var rows := [
		["'  (quote, above Tab)", "look mode on / off", KEY_COLOR],
		["Right mouse (hold)", "look around", Color.WHITE],
		["W A S D,  Q / E", "fly,  down / up", Color.WHITE],
		["Shift,  mouse wheel", "faster,  fly speed", Color.WHITE],
		["Left click", "select a prop", Color.WHITE],
		["Drag the prop / an arrow", "move it on the floor / on one axis", Color.WHITE],
		["F,  Esc", "frame the prop,  deselect", Color.WHITE],
		["1 2 3 4 5", "Godot, + bounce, bounce only, heat map, screen-space", Color.WHITE],
		["Space", "pause the moving dolly", Color.WHITE],
		["H", "hide this list", Color.WHITE]]
	for r in rows:
		var k := Label.new()
		k.text = r[0]
		k.add_theme_color_override("font_color", r[2] if r[2] != Color.WHITE else ACCENT)
		grid.add_child(k)
		var v := Label.new()
		v.text = r[1]
		grid.add_child(v)
	_help_speed = Label.new()
	_help_speed.add_theme_color_override("font_color", DIM)
	col.add_child(_help_speed)


func toggle_help() -> void:
	_help.visible = not _help.visible


# --- builders ---------------------------------------------------------------------------------------

## A scrolling tab page; returns the VBox its content goes in.
func _tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 3)
	scroll.add_child(body)
	return body


func _no_focus(n: Node) -> void:
	if n is Control:
		(n as Control).focus_mode = Control.FOCUS_NONE
	for c in n.get_children():
		_no_focus(c)


func _label(parent: Control, text: String, color := Color.WHITE, size := 0, wrap := true) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l


func _heading(parent: Control, text: String) -> void:
	var l := _label(parent, text, ACCENT)
	l.add_theme_constant_override("line_spacing", 0)


func _button(parent: Control, text: String, cb: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _grid(parent: Control, columns: int) -> GridContainer:
	var g := GridContainer.new()
	g.columns = columns
	g.add_theme_constant_override("h_separation", 3)
	g.add_theme_constant_override("v_separation", 3)
	parent.add_child(g)
	return g


## One row: name on the left, a switch on the right.
func _check(parent: Control, text: String, value: bool, setter: Callable, tip := "") -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.tooltip_text = tip
	c.button_pressed = value
	c.toggled.connect(setter)
	parent.add_child(c)
	_controls.append({"widget": c, "kind": "check", "default": value})
	return c


## One row: name, slider, value.
func _slider(parent: Control, text: String, lo: float, hi: float, step: float, value: float, setter: Callable, tip := "", fmt := "%.2f") -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.tooltip_text = tip
	var name_l := Label.new()
	name_l.text = text
	name_l.custom_minimum_size.x = LABEL_W
	name_l.clip_text = true
	name_l.tooltip_text = tip
	name_l.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(name_l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.tooltip_text = tip
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(s)
	var val_l := Label.new()
	val_l.custom_minimum_size.x = 46
	val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_l.add_theme_color_override("font_color", ACCENT)
	row.add_child(val_l)
	parent.add_child(row)
	s.value_changed.connect(func(v: float):
		val_l.text = fmt % v
		setter.call(v))
	s.set_value_no_signal(value)
	val_l.text = fmt % value
	_controls.append({"widget": s, "kind": "slider", "default": value})
	_sliders[text] = s
	return s


func _option(parent: Control, text: String, values: Array, current: float, setter: Callable, tip: String) -> OptionButton:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = LABEL_W
	row.add_child(l)
	var o := OptionButton.new()
	o.tooltip_text = tip
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sel := 0
	for i in values.size():
		o.add_item(str(values[i]))
		if absf(float(values[i]) - current) < 0.001:
			sel = i
	o.select(sel)
	o.item_selected.connect(func(i: int): setter.call(values[i]))
	row.add_child(o)
	parent.add_child(row)
	return o


func _build_header(col: VBoxContainer) -> void:
	var top := HBoxContainer.new()
	col.add_child(top)
	var title := _label(top, "Radiance Cascades Lab", Color.WHITE, 15, false)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var reset := Button.new()
	reset.text = "Reset all"
	reset.tooltip_text = "Every slider, switch and quality option back to how the lab starts."
	reset.pressed.connect(reset_all)
	top.add_child(reset)
	var key_box := PanelContainer.new()
	var ks := StyleBoxFlat.new()
	ks.bg_color = KEY_COLOR
	ks.set_corner_radius_all(4)
	ks.set_content_margin_all(4)
	key_box.add_theme_stylebox_override("panel", ks)
	col.add_child(key_box)
	var key_l := Label.new()
	key_l.text = "'  (quote key, above Tab) = look mode on / off"
	key_l.add_theme_color_override("font_color", Color(0.02, 0.05, 0.08))
	key_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_box.add_child(key_l)
	_readout = _label(col, "", Color(0.85, 0.95, 1.0), 0, false)
	_status = _label(col, "", ACCENT, 0, false)


func _build_view(body: VBoxContainer) -> void:
	var grid := _grid(body, 2)
	var group := ButtonGroup.new()
	var modes := [
		["off", "Godot only  1", "Godot's own light and shadows. No bounce light at all."],
		["world", "+ Bounce  2", "Godot light plus the world-space bounce (the effect)."],
		["world_gi", "Bounce only  3", "Only the bounce light of the effect, brightened by 'Bounce-only gain'."],
		["world_heat", "Heat map  4", "The bounce light as colours on a log scale: dark blue = almost none, white = a lot."],
		["ss", "+ Screen-space  5", "The older screen-space version (only sees what is on screen)."],
		["ss_gi", "Screen-space only", "Only the bounce of the screen-space version."]]
	for m in modes:
		var b := Button.new()
		b.text = m[1]
		b.tooltip_text = m[2]
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var key: String = m[0]
		b.pressed.connect(func(): main.set_live_mode(key))
		var on := StyleBoxFlat.new()
		on.bg_color = ACCENT.darkened(0.35)
		on.set_corner_radius_all(3)
		b.add_theme_stylebox_override("pressed", on)
		grid.add_child(b)
		_mode_buttons[key] = b
	_heat_legend = VBoxContainer.new()
	var bar := TextureRect.new()
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.2, 0.4, 0.6, 0.8, 1.0])
	grad.colors = PackedColorArray([Color(0.02, 0.02, 0.15), Color(0.1, 0.2, 0.8), Color(0.1, 0.8, 0.8), Color(0.9, 0.9, 0.2), Color(1.0, 0.35, 0.05), Color(1, 1, 1)])
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	gt.width = 256
	bar.texture = gt
	bar.custom_minimum_size = Vector2(0, 10)
	bar.stretch_mode = TextureRect.STRETCH_SCALE
	_heat_legend.add_child(bar)
	var legend_row := HBoxContainer.new()
	var lo := _label(legend_row, "0.0003", DIM, 0, false)
	lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label(legend_row, "3 (log)", DIM, 0, false)
	_heat_legend.add_child(legend_row)
	body.add_child(_heat_legend)
	_heat_legend.visible = false
	_split_check = _check(body, "Split view (drag the line)", false, func(v): set_split(0.5 if v else -1.0),
		"Left of the line: Godot alone. Right: with the bounce light. Drag the line with the mouse.")
	_slider(body, "Bounce-only gain", 1.0, 40.0, 0.5, main.view_gain, func(v): main.view_gain = v; main.refresh_mode(),
		"Brightness boost of the 'Bounce only' view, to see weak light far from a lamp.", "x%.1f")
	_heading(body, "Go to")
	var tp := _grid(body, 3)
	for pose_name in main.poses.keys():
		var pn: String = pose_name
		_button(tp, pn.replace("_", " ").capitalize(), func(): main.teleport(pn))


func _build_gi(body: VBoxContainer) -> void:
	_slider(body, "Bounce strength", 0.0, 3.0, 0.05, main.gi_strength, func(v): main.gi_strength = v; main.refresh_mode(),
		"How much bounce light is added. 1 = physically about right.")
	_check(body, "Per-pixel near field", effect.final_gather, func(v): effect.final_gather = v,
		"Every pixel traces its own short rays (removes the round blobs of the probes). Off = probes only.")
	_slider(body, "Near-field range (m)", 0.2, 1.5, 0.05, effect.near_range, func(v): effect.near_range = v,
		"How far the per-pixel rays look before the probes take over.")
	_slider(body, "Directions per pixel tile", 4, 10, 2, effect.near_dirs, func(v): effect.near_dirs = int(v),
		"Each pixel looks in one of tile x tile directions; more = less noise, a wider blur. 6 = 36 directions.", "%d")
	_slider(body, "Cascade interval (m)", 0.2, 1.5, 0.05, effect.interval0, func(v): effect.interval0 = v,
		"Length of the first cascade's rays (each next one is 4x longer).")
	_check(body, "Temporal smoothing", effect.temporal, func(v): effect.temporal = v,
		"Blends with the previous frame (reprojected). Removes noise and flicker; adds a little lag.")
	_slider(body, "Weight of the new frame", 0.05, 1.0, 0.01, effect.temporal_alpha, func(v): effect.temporal_alpha = v,
		"Lower = smoother but slower to follow a moving light. 1 = no smoothing.")
	_slider(body, "Follow changes faster", 0.0, 3.0, 0.1, effect.temporal_adaptive, func(v): effect.temporal_adaptive = v,
		"Where the new frame differs a lot from the history (a shadow moving), take more of it. 0 = off.")
	_slider(body, "Brightness clamp", 2.0, 64.0, 1.0, effect.max_radiance, func(v): effect.max_radiance = v,
		"A surface counts as at most this bright when it lights others (stops fireflies from the lamps).", "%.0f")
	_slider(body, "Probe lookup offset (m)", 0.05, 0.8, 0.05, effect.gather_bias, func(v): effect.gather_bias = v,
		"How far from the surface the probes are read. Larger = fewer leaks near walls, softer corners.")
	_slider(body, "More bounces", 0.0, 1.0, 0.05, effect.bounce, func(v): effect.bounce = v,
		"Light keeps bouncing: last frame's probe light is added to every lit surface. 0 = a single bounce (corners and corridors go dark).")
	_heading(body, "Image quality")
	_check(body, "Jittered rays", effect.jitter, func(v): effect.jitter = v,
		"Each pixel starts its rays at a random point every frame: the straight lines of the voxel and probe grids turn into noise that the temporal blend removes.")
	_check(body, "Clean object edges", effect.edge_fix, func(v): effect.edge_fix = v,
		"At an object's edge, gather the rays from a window twice as wide, so no dashed line appears along the silhouette. About 0.5 ms at 1080p.")
	_check(body, "Edge-aware filter", effect.denoise, func(v): effect.denoise = v,
		"Smooths the bounce light over 7 x 7 pixels of the same surface (removes the fine grid of the per-pixel directions). About 0.4 ms at 1080p.")
	_heading(body, "Performance")
	_check(body, "Re-light only what changed", effect.inject_partial, func(v): effect.inject_partial = v,
		"Direct light is injected again only around lights that changed and around moving objects. Off = the whole volume, every frame.")
	_slider(body, "Far cascades every N frames", 1, 4, 1, effect.far_every, func(v): effect.far_every = int(v),
		"The far cascades change slowly: trace them every Nth frame and reuse them in between. 1 = every frame.", "%d")
	_check(body, "Update moving objects", effect.dynamic, func(v): effect.dynamic = v,
		"Off freezes the light volume: the light goes stale around anything that moves.")
	_check(body, "Colour from a G-buffer render", effect.use_albedo_texture, func(v): effect.use_albedo_texture = v,
		"On: exact colour per pixel from an unlit second render. Off: colour of the voxel under the pixel (blocky).")


func _build_quality(body: VBoxContainer) -> void:
	var row := _grid(body, 3)
	_button(row, "Low", func(): apply_preset("low"), "Cheaper: 25 cm voxels, probes 1 m apart, 16 directions per pixel tile.")
	_button(row, "Default", reset_all, "Back to the settings the lab starts with (the High preset).")
	_button(row, "High", func(): apply_preset("high"), "Finer: 10 cm voxels, probes 0.35 m apart, 64 directions per pixel tile. Costs more.")
	_label(body, "These change the size of the volumes: press Apply to voxelize again.", DIM)
	_voxel_option = _option(body, "Voxel size (m)", _voxel_values, effect.voxel_size, func(v): _pending["voxel"] = v,
		"Smaller voxels = finer geometry for the light, much more memory and time.")
	_spacing_option = _option(body, "Probe spacing (m)", _spacing_values, effect.probe_spacing, func(v): _pending["spacing"] = v,
		"Distance between probes. Smaller = smoother light far from objects, more rays.")
	_cascade_option = _option(body, "Cascades", _cascade_values, effect.cascades, func(v): _pending["cascades"] = int(v),
		"How many ray ranges. The last one must reach across the volume; fewer = cheaper, farther light is lost.")
	_button(body, "Apply and rebuild", apply_quality, "Voxelize the scene again with these settings.")
	var aa_keys := ["off", "fxaa", "smaa", "taa", "msaa"]
	var aa_row := HBoxContainer.new()
	var aa_l := Label.new()
	aa_l.text = "Anti-aliasing"
	aa_l.custom_minimum_size.x = LABEL_W
	aa_row.add_child(aa_l)
	var aa := OptionButton.new()
	aa.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	aa.tooltip_text = "Smooths the jagged edges of the geometry. SMAA: sharp and cheap. TAA: smoothest, a little blur in motion. MSAA 4x: exact edges, costs the most."
	for t in ["Off", "FXAA", "SMAA", "TAA", "MSAA 4x"]:
		aa.add_item(t)
	aa.select(aa_keys.find(main.aa_mode))
	aa.item_selected.connect(func(i: int): main.set_aa(aa_keys[i]))
	aa_row.add_child(aa)
	body.add_child(aa_row)


func _build_scene(body: VBoxContainer) -> void:
	_slider(body, "Exposure", 0.2, 4.0, 0.05, main.world_env.environment.tonemap_exposure, func(v): main.world_env.environment.tonemap_exposure = v,
		"The camera's brightness (Godot's tone mapping).")
	_slider(body, "Ceiling lights", 0.0, 3.0, 0.05, shop.ceiling_scale, func(v): shop.ceiling_scale = v,
		"The six fluorescents. 0 = the store is lit only by the street lamp.")
	_slider(body, "Street lamp", 0.0, 150.0, 1.0, shop.street_energy, func(v): shop.street_energy = v,
		"Sodium lamp outside the windows.", "%.0f")
	_slider(body, "Corridor lamp", 0.0, 30.0, 0.5, shop.corridor_lamp_energy, func(v): shop.corridor_lamp_energy = v,
		"A lamp at the bend of the corridor (off by default): see light travel back towards the store.", "%.1f")
	_slider(body, "Sun", 0.0, 10.0, 0.1, main.sun_value, func(v): main.set_sun(v),
		"Daylight: a sun and a sky through the windows.", "%.1f")
	_slider(body, "Glowing surfaces", 0.0, 4.0, 0.1, effect.emission_scale, func(v): effect.emission_scale = v,
		"How much the TV screen and the neon sign in the corridor light the scene (they have no lamp: only the bounce carries their light).")
	_slider(body, "Dolly lamp", 0.0, 20.0, 0.5, shop.dolly_lamp.light_energy, func(v): shop.dolly_lamp.light_energy = v,
		"The work lamp on the rolling dolly.", "%.1f")
	_check(body, "Dolly rolls", main.anim_auto, func(v): main.anim_auto = v,
		"The dolly with cartons moves along the central aisle (Z / X move it by hand when stopped).")
	_label(body, "Space pauses the dolly; with 'Dolly rolls' off, Z / X move it by hand.", DIM)


func _build_object(body: VBoxContainer) -> void:
	_label(body, "Click a prop to select it. Drag it to move it over the floor, or drag an arrow to move it along one axis. F frames it, Esc deselects.", DIM)
	_obj_name = _label(body, "", Color.WHITE, 14, false)
	_obj_info = _label(body, "", DIM, 0, false)
	_obj_box = VBoxContainer.new()
	body.add_child(_obj_box)
	_obj_yaw = _slider(_obj_box, "Rotation (deg)", -180.0, 180.0, 1.0, 0.0, func(v): picker.set_selected_yaw(v), "Turns the prop around its vertical axis.", "%.0f")
	_controls.pop_back() # not part of "Reset all": it follows the selected prop
	var row := HBoxContainer.new()
	_obj_box.add_child(row)
	var l := _label(row, "Colour", Color.WHITE, 0, false)
	l.custom_minimum_size.x = LABEL_W
	_obj_color = ColorPickerButton.new()
	_obj_color.edit_alpha = false
	_obj_color.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_obj_color.color_changed.connect(func(c: Color): picker.set_selected_color(c))
	row.add_child(_obj_color)
	var buttons := _grid(_obj_box, 2)
	_button(buttons, "Reset object", func():
		picker.reset_selected()
		_sync_object(), "Back to where and how this prop was before you moved it.")
	_button(buttons, "Deselect", func(): picker.select(null), "Esc does the same.")


func _build_stats(body: VBoxContainer) -> void:
	_label(body, "GPU time of each pass of the effect (ms), averaged.", DIM)
	_stats_box = VBoxContainer.new()
	_stats_box.add_theme_constant_override("separation", 2)
	body.add_child(_stats_box)
	_stats_extra = _label(body, "", DIM)


func _build_split_overlay() -> void:
	_split_line = ColorRect.new()
	_split_line.color = Color(1, 1, 1, 0.85)
	_split_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_split_line.visible = false
	_root.add_child(_split_line)
	_split_handle = Control.new()
	_split_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	_split_handle.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_split_handle.visible = false
	_split_handle.gui_input.connect(_on_split_input)
	_root.add_child(_split_handle)
	for t in ["Godot only", "+ RC bounce"]:
		var l := Label.new()
		l.text = t
		l.add_theme_font_size_override("font_size", 14)
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 6)
		l.visible = false
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(l)
		_split_labels.append(l)


func _on_split_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_split_dragging = (event as InputEventMouseButton).pressed
	elif event is InputEventMouseMotion and _split_dragging:
		var w := _root.get_viewport_rect().size.x
		set_split(clampf(_root.get_global_mouse_position().x / w, 0.05, 0.95))


## Split view at a fraction of the screen width (< 0 = off).
func set_split(f: float) -> void:
	effect.split = f
	if _split_check != null:
		_split_check.set_pressed_no_signal(f >= 0.0)


# --- state ------------------------------------------------------------------------------------------

func reset_all() -> void:
	for c in _controls:
		match c["kind"]:
			"slider":
				var s: HSlider = c["widget"]
				s.value = c["default"] # emits value_changed -> the setter
			"check":
				var b: CheckButton = c["widget"]
				b.button_pressed = c["default"]
	set_split(-1.0)
	_pending = _pending_default.duplicate()
	_sync_options()
	main.set_live_mode("world")
	if _differs_from_applied():
		apply_quality()


func apply_preset(name: String) -> void:
	var p := {}
	match name:
		"low":
			p = {"voxel": 0.25, "spacing": 1.0, "cascades": 4, "dirs": 4, "alpha": 0.35}
		"high":
			p = {"voxel": 0.1, "spacing": 0.35, "cascades": 4, "dirs": 8, "alpha": 0.2}
	_pending = {"voxel": p["voxel"], "spacing": p["spacing"], "cascades": p["cascades"]}
	_sync_options()
	(_sliders["Directions per pixel tile"] as HSlider).value = p["dirs"]
	(_sliders["Weight of the new frame"] as HSlider).value = p["alpha"]
	apply_quality()


func _sync_options() -> void:
	_select_value(_voxel_option, _voxel_values, _pending["voxel"])
	_select_value(_spacing_option, _spacing_values, _pending["spacing"])
	_select_value(_cascade_option, _cascade_values, _pending["cascades"])


func _select_value(o: OptionButton, values: Array, v: float) -> void:
	for i in values.size():
		if absf(float(values[i]) - v) < 0.001:
			o.select(i)


func _differs_from_applied() -> bool:
	return absf(effect.voxel_size - _pending["voxel"]) > 0.0005 or absf(effect.probe_spacing - _pending["spacing"]) > 0.0005 or effect.cascades != int(_pending["cascades"])


func apply_quality() -> void:
	effect.voxel_size = _pending["voxel"]
	effect.probe_spacing = _pending["spacing"]
	effect.cascades = int(_pending["cascades"])
	var size: Vector3 = main.volume_size()
	effect.dims = Vector3i(ceili(size.x / effect.voxel_size), ceili(size.y / effect.voxel_size), ceili(size.z / effect.voxel_size))
	effect.volume_ready = false
	RenderingServer.call_on_render_thread(effect.rebuild)


var _shown_selected: Node3D


func _sync_object() -> void:
	var sel: Node3D = picker.selected
	_obj_box.visible = sel != null
	if sel == null:
		_obj_name.text = "Nothing selected"
		_obj_info.text = ""
		return
	_obj_name.text = String(sel.name)
	var b: AABB = picker._bounds(sel)
	var p := sel.global_position
	_obj_info.text = "position %.2f, %.2f, %.2f m\nsize %.2f x %.2f x %.2f m" % [p.x, p.y, p.z, b.size.x, b.size.y, b.size.z]
	if sel != _shown_selected:
		_obj_yaw.set_value_no_signal(wrapf(rad_to_deg(sel.rotation.y), -180.0, 180.0))
		var parts: Array = picker._parts(sel)
		if not parts.is_empty():
			_obj_color.color = (parts[0].material_override as StandardMaterial3D).albedo_color
	_shown_selected = sel


func _refresh_stats(delta: float) -> void:
	var t: Dictionary = effect.collect_timings()
	for k in t:
		_pass_ms[k] = lerpf(_pass_ms.get(k, t[k]), t[k], 0.1)
	_stats_t += delta
	if _stats_t < 0.25:
		return
	_stats_t = 0.0
	var total := 0.0
	for k in _pass_ms:
		total += _pass_ms[k]
	for k in _pass_ms:
		if not _stats_rows.has(k):
			var row := HBoxContainer.new()
			var name_l := Label.new()
			name_l.text = String(k).trim_prefix("RC ")
			name_l.custom_minimum_size.x = 150
			row.add_child(name_l)
			var bar := ProgressBar.new()
			bar.show_percentage = false
			bar.custom_minimum_size = Vector2(0, 8)
			bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(bar)
			var val := Label.new()
			val.custom_minimum_size.x = 50
			val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			val.add_theme_color_override("font_color", ACCENT)
			row.add_child(val)
			_stats_box.add_child(row)
			_stats_rows[k] = [val, bar]
		var r: Array = _stats_rows[k]
		(r[0] as Label).text = "%.3f" % _pass_ms[k]
		(r[1] as ProgressBar).value = 100.0 * _pass_ms[k] / maxf(total, 1e-6)
	var lines := PackedStringArray()
	lines.append("Total of the effect: %.2f ms" % total)
	lines.append("Re-lit last frame: %.0f%% of the volume" % (effect.inject_fraction * 100.0))
	lines.append("Far cascades: %s" % ("reused (not traced this frame)" if effect.last_far_skipped else "traced this frame"))
	lines.append("Static scene: %d triangles in %s voxels" % [effect._tri_count, str(effect.dims)])
	if picker != null and picker.revoxelize_count > 0:
		lines.append("Re-voxelized %d times; last gather %.1f ms (CPU)" % [picker.revoxelize_count, picker.last_collect_ms])
	_stats_extra.text = "\n".join(lines)


func refresh(delta := 0.016) -> void:
	var fps := Engine.get_frames_per_second()
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(main.get_viewport().get_viewport_rid())
	_readout.text = "%d FPS  |  %.1f ms  |  GPU %.1f ms\n%s" % [fps, 1000.0 / maxf(fps, 1.0), gpu, main.mode_text()]
	_status.text = "" if effect.volume_ready else "Rebuilding the voxel volume..."
	_status.visible = not effect.volume_ready
	for k in _mode_buttons:
		(_mode_buttons[k] as Button).set_pressed_no_signal(k == main.live_mode)
	_heat_legend.visible = main.live_mode == "world_heat"
	var free: bool = main.mouse_is_free()
	_panel.modulate.a = 1.0 if free else 0.6
	if main.look_mode:
		_hint.text = "LOOK MODE: the mouse turns the camera.   Press  '  (quote, above Tab) or Esc for the cursor."
		_hint_style.bg_color = FREE_COLOR
	elif not free:
		_hint.text = "Looking around (right mouse button held)"
		_hint_style.bg_color = FREE_COLOR
	else:
		_hint.text = "CURSOR MODE: click a prop, use the panel.   Hold RIGHT MOUSE to look.   Press  '  (quote, above Tab) for look mode."
		_hint_style.bg_color = KEY_COLOR
	_help_speed.text = "Fly speed: %.1f m/s (mouse wheel)" % main.fly_speed
	if picker != null:
		_sync_object()
	_refresh_stats(delta)
	# Split line
	var on: bool = effect.split >= 0.0 and main.live_mode.begins_with("world")
	var vs := _root.get_viewport_rect().size
	var x: float = effect.split * vs.x
	_split_line.visible = on
	_split_handle.visible = on
	_split_line.position = Vector2(x - 1.0, 0.0)
	_split_line.size = Vector2(2.0, vs.y)
	_split_handle.position = Vector2(x - 8.0, 0.0)
	_split_handle.size = Vector2(16.0, vs.y)
	for i in 2:
		var l := _split_labels[i]
		l.visible = on
		l.position = Vector2(x - l.size.x - 12.0 if i == 0 else x + 12.0, vs.y - 40.0)
