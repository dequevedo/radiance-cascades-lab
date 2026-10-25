extends CanvasLayer
## The lab's control panel: buttons, toggles and sliders. The quote key (above Tab) frees the mouse to use it; press it again to give the mouse back to the camera. Every control keeps no keyboard focus, so WASD and
## Space keep moving the camera.

const BG := Color(0.05, 0.06, 0.08, 0.90)
const ACCENT := Color(0.95, 0.65, 0.2)
const DIM := Color(0.62, 0.66, 0.72)

var main: Node3D
var effect: Object
var shop: Object

var _root: Control
var _panel: PanelContainer
var _readout: Label
var _hint: Label
var _status: Label
var _heat_legend: Control
var _controls: Array = [] # {widget, kind, default}
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


func setup(m: Node3D) -> void:
	main = m
	effect = m.effect_world
	shop = m.shop
	layer = 20
	_pending = {"voxel": effect.voxel_size, "spacing": effect.probe_spacing, "cascades": effect.cascades}
	_pending_default = _pending.duplicate()

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	theme.default_font_size = 13
	_root.theme = theme
	add_child(_root)

	_panel = PanelContainer.new()
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 8
	_panel.offset_top = 8
	_panel.offset_bottom = -8
	_panel.offset_right = 392
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.focus_mode = Control.FOCUS_NONE
	_panel.add_child(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	scroll.add_child(col)

	_build_header(col)
	_build_view(col)
	_build_bounce(col)
	_build_quality(col)
	if shop != null:
		_build_lights(col)
	_build_misc(col)
	_no_focus(_root)

	_hint = Label.new()
	_hint.position = Vector2(412, 10)
	_hint.add_theme_color_override("font_color", Color(1, 1, 0.85))
	_hint.add_theme_color_override("font_outline_color", Color.BLACK)
	_hint.add_theme_constant_override("outline_size", 6)
	_root.add_child(_hint)


# --- builders ---------------------------------------------------------------------------------------

func _no_focus(n: Node) -> void:
	if n is Control:
		(n as Control).focus_mode = Control.FOCUS_NONE
	for c in n.get_children():
		_no_focus(c)


func _label(parent: Control, text: String, color := Color.WHITE, size := 0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l


func _button(parent: Control, text: String, cb: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


## A collapsible section: returns the VBox its content goes in.
func _section(parent: Control, title: String, open := true) -> VBoxContainer:
	var head := Button.new()
	head.flat = true
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_color_override("font_color", ACCENT)
	head.add_theme_color_override("font_hover_color", Color.WHITE)
	parent.add_child(head)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 5)
	body.visible = open
	parent.add_child(body)
	var set_title := func(): head.text = ("v  " if body.visible else ">  ") + title
	set_title.call()
	head.pressed.connect(func():
		body.visible = not body.visible
		set_title.call())
	return body


func _check(parent: Control, text: String, value: bool, setter: Callable, tip := "") -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.tooltip_text = tip
	c.button_pressed = value
	c.toggled.connect(setter)
	parent.add_child(c)
	_controls.append({"widget": c, "kind": "check", "default": value})
	return c


func _slider(parent: Control, text: String, lo: float, hi: float, step: float, value: float, setter: Callable, tip := "", fmt := "%.2f") -> HSlider:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var row := HBoxContainer.new()
	var name_l := Label.new()
	name_l.text = text
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_l)
	var val_l := Label.new()
	val_l.add_theme_color_override("font_color", ACCENT)
	row.add_child(val_l)
	box.add_child(row)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.tooltip_text = tip
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size.y = 18
	box.add_child(s)
	parent.add_child(box)
	s.value_changed.connect(func(v: float):
		val_l.text = fmt % v
		setter.call(v))
	s.set_value_no_signal(value)
	val_l.text = fmt % value
	_controls.append({"widget": s, "kind": "slider", "default": value})
	_sliders[text] = s
	return s


func _build_header(col: VBoxContainer) -> void:
	_label(col, "Radiance Cascades Lab", Color.WHITE, 17)
	_label(col, "Press the quote key (above Tab) to use the mouse on this panel; press again to look around.", DIM)
	_readout = _label(col, "", Color(0.85, 0.95, 1.0))
	_status = _label(col, "", ACCENT)
	var row := HBoxContainer.new()
	col.add_child(row)
	_button(row, "Reset all to defaults", reset_all, "Every slider, switch and quality option back to how the lab starts.")
	var row2 := HBoxContainer.new()
	col.add_child(row2)
	_button(row2, "Low", func(): apply_preset("low"), "Cheaper: 25 cm voxels, probes 1 m apart, 16 directions per pixel tile.")
	_button(row2, "Default", reset_all, "The starting settings.")
	_button(row2, "High", func(): apply_preset("high"), "Finer: 10 cm voxels, probes 0.35 m apart, 64 directions per pixel tile. Costs more.")


func _build_view(col: VBoxContainer) -> void:
	var body := _section(col, "View")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	body.add_child(grid)
	var group := ButtonGroup.new()
	var modes := [
		["off", "Godot only", "Godot's own light and shadows. No bounce light at all."],
		["world", "+ World bounce", "Godot light plus the world-space bounce (the effect)."],
		["world_gi", "Bounce only", "Only the bounce light of the effect, brightened by 'Bounce-only brightness'."],
		["world_heat", "Bounce heat map", "The bounce light as colours on a log scale: dark blue = almost none, white = a lot. Shows how far light travels."],
		["ss", "+ Screen-space", "The older screen-space version (only sees what is on screen)."],
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
		on.set_corner_radius_all(4)
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
	bar.custom_minimum_size = Vector2(0, 14)
	bar.stretch_mode = TextureRect.STRETCH_SCALE
	_heat_legend.add_child(bar)
	var legend_row := HBoxContainer.new()
	var lo := Label.new()
	lo.text = "0.0003"
	lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	legend_row.add_child(lo)
	var hi := Label.new()
	hi.text = "3 (log scale)"
	legend_row.add_child(hi)
	_heat_legend.add_child(legend_row)
	body.add_child(_heat_legend)
	_heat_legend.visible = false

	_label(body, "Go to", DIM)
	var tp := GridContainer.new()
	tp.columns = 2
	tp.add_theme_constant_override("h_separation", 4)
	tp.add_theme_constant_override("v_separation", 4)
	body.add_child(tp)
	for pose_name in main.poses.keys():
		var pn: String = pose_name
		_button(tp, pn.replace("_", " ").capitalize(), func(): main.teleport(pn))


func _build_bounce(col: VBoxContainer) -> void:
	var body := _section(col, "Bounce light (live)")
	_slider(body, "Bounce strength", 0.0, 3.0, 0.05, main.gi_strength, func(v): main.gi_strength = v; main.refresh_mode(),
		"How much bounce light is added. 1 = physically about right.")
	_slider(body, "Bounce-only brightness", 1.0, 40.0, 0.5, main.view_gain, func(v): main.view_gain = v; main.refresh_mode(),
		"Brightness boost of the 'Bounce only' view, to see weak light far from a lamp.", "x%.1f")
	_check(body, "Per-pixel near field", effect.final_gather, func(v): effect.final_gather = v,
		"Every pixel traces its own short rays (removes the round blobs of the probes). Off = probes only.")
	_slider(body, "Near-field range (m)", 0.2, 1.5, 0.05, effect.near_range, func(v): effect.near_range = v,
		"How far the per-pixel rays look before the probes take over. Longer = smoother, more detail close to objects, a bit costlier.")
	_slider(body, "Directions per pixel tile", 4, 10, 2, effect.near_dirs, func(v): effect.near_dirs = int(v),
		"Each pixel looks in one of tile x tile directions; more = less noise, a wider blur. 6 = 36 directions.", "%d")
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


func _build_quality(col: VBoxContainer) -> void:
	var body := _section(col, "Quality (press Apply)", false)
	_label(body, "These change the size of the volumes, so the scene is voxelized again when you press Apply.", DIM)
	_voxel_option = _option(body, "Voxel size (m)", _voxel_values, effect.voxel_size, func(v): _pending["voxel"] = v,
		"Smaller voxels = finer geometry for the light, much more memory and time.")
	_spacing_option = _option(body, "Probe spacing (m)", _spacing_values, effect.probe_spacing, func(v): _pending["spacing"] = v,
		"Distance between probes. Smaller = smoother light far from objects, more rays.")
	_cascade_option = _option(body, "Cascades", _cascade_values, effect.cascades, func(v): _pending["cascades"] = int(v),
		"How many ray ranges. The last one must reach across the volume; fewer = cheaper, farther light is lost.")
	_button(body, "Apply and rebuild", apply_quality, "Voxelize the scene again with these settings.")


func _option(parent: Control, text: String, values: Array, current: float, setter: Callable, tip: String) -> OptionButton:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var o := OptionButton.new()
	o.tooltip_text = tip
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


func _build_lights(col: VBoxContainer) -> void:
	var body := _section(col, "Lights and scene")
	_slider(body, "Exposure", 0.2, 4.0, 0.05, main.world_env.environment.tonemap_exposure, func(v): main.world_env.environment.tonemap_exposure = v,
		"The camera's brightness (Godot's tone mapping).")
	_slider(body, "Ceiling lights", 0.0, 3.0, 0.05, shop.ceiling_scale, func(v): shop.ceiling_scale = v,
		"The six fluorescents. 0 = the store is lit only by the street lamp.")
	_check(body, "Flicker one ceiling light", shop.flicker_on, func(v): shop.flicker_on = v,
		"The middle fluorescent dips now and then: a light that changes every frame.")
	_slider(body, "Street lamp outside", 0.0, 150.0, 1.0, shop.street_energy, func(v): shop.street_energy = v,
		"Sodium lamp outside the windows.", "%.0f")
	_slider(body, "Lamp in the corridor", 0.0, 30.0, 0.5, shop.corridor_lamp_energy, func(v): shop.corridor_lamp_energy = v,
		"A lamp at the bend of the corridor (off by default): see light travel back towards the store.", "%.1f")
	_slider(body, "Sun through the windows", 0.0, 10.0, 0.1, main.sun_value, func(v): main.set_sun(v),
		"Daylight: a sun and a sky (also lights the bounce through the windows).", "%.1f")
	_slider(body, "Dolly lamp", 0.0, 20.0, 0.5, shop.dolly_lamp.light_energy, func(v): shop.dolly_lamp.light_energy = v,
		"The work lamp on the rolling dolly.", "%.1f")
	_check(body, "Dolly rolls", main.anim_auto, func(v): main.anim_auto = v,
		"The dolly with cartons moves along the central aisle (Z / X move it by hand when stopped).")


func _build_misc(col: VBoxContainer) -> void:
	var body := _section(col, "Other", false)
	_check(body, "Update moving objects every frame", effect.dynamic, func(v): effect.dynamic = v,
		"Off freezes the light volume: you will see the light go stale around anything that moves.")
	_check(body, "Surface colour from a G-buffer render", effect.use_albedo_texture, func(v): effect.use_albedo_texture = v,
		"On: exact colour per pixel from an unlit second render. Off: colour of the voxel under the pixel (blocky).")
	_label(body, "Keys: WASD QE move, Shift fast, 1-5 modes, G near field, T temporal, Space pause the dolly, Z/X move it.", DIM)


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


func refresh() -> void:
	var fps := Engine.get_frames_per_second()
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(main.get_viewport().get_viewport_rid())
	_readout.text = "%d FPS  |  frame %.1f ms  |  GPU %.1f ms\n%s" % [fps, 1000.0 / maxf(fps, 1.0), gpu, main.mode_text()]
	_status.text = "" if effect.volume_ready else "Rebuilding the voxel volume..."
	for k in _mode_buttons:
		(_mode_buttons[k] as Button).set_pressed_no_signal(k == main.live_mode)
	_heat_legend.visible = main.live_mode == "world_heat"
	var free: bool = main.mouse_is_free()
	_panel.modulate.a = 1.0 if free else 0.6
	_hint.text = "Mouse free: click the panel.   Quote key (above Tab) to look around." if free else "Quote key (above Tab) to use the panel   |   WASD QE move, Shift fast"
