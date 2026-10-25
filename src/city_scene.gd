extends RefCounted
## A city at night, made procedurally: a grid of blocks with shops and flats, a plaza with a fountain and string lights, a
## market, a park, street lamps, trees, parked cars, street furniture and neon signs. One car drives round the blocks with its
## headlights on (a moving object with moving spot lights).
##
## Every block is one mesh with one surface per material and vertex colours, so the whole city is a few hundred draw calls.
## The GI volume is far smaller than the city: it follows the camera (main.gd moves it in FOLLOW_STEP steps).

const GRID := 5 # blocks per side
const BLOCK := 34.0 # a block, sidewalks included
const STREET := 10.0 # the road between two blocks
const PITCH := BLOCK + STREET
const SIDEWALK := 3.0
const CURB := 0.15
const FLOOR_H := 3.1
const SHOP_H := 3.8

# The GI volume around the camera (world metres) and how far the camera moves before it follows.
const VOLUME_SIZE := Vector3(64.0, 24.0, 64.0)
const VOLUME_MIN := Vector3(-32.0, -1.0, -32.0)
const FOLLOW_STEP := 8.0

const FACADES: Array[Color] = [Color(0.85, 0.55, 0.42), Color(0.92, 0.8, 0.55), Color(0.62, 0.78, 0.68), Color(0.9, 0.66, 0.7),
	Color(0.62, 0.72, 0.86), Color(0.93, 0.9, 0.82), Color(0.78, 0.5, 0.36), Color(0.7, 0.66, 0.84), Color(0.95, 0.72, 0.45)]
const AWNINGS: Array[Color] = [Color(0.85, 0.15, 0.15), Color(0.1, 0.45, 0.25), Color(0.15, 0.3, 0.7), Color(0.95, 0.7, 0.1),
	Color(0.6, 0.15, 0.5), Color(0.1, 0.55, 0.6)]
const CAR_PAINT: Array[Color] = [Color(0.75, 0.08, 0.08), Color(0.1, 0.25, 0.6), Color(0.9, 0.9, 0.88), Color(0.12, 0.12, 0.13),
	Color(0.95, 0.75, 0.1), Color(0.2, 0.5, 0.3), Color(0.55, 0.57, 0.6), Color(0.9, 0.45, 0.1)]
const FRUIT: Array[Color] = [Color(1.0, 0.5, 0.05), Color(0.85, 0.08, 0.08), Color(0.4, 0.75, 0.15), Color(1.0, 0.85, 0.1),
	Color(0.5, 0.1, 0.45), Color(0.95, 0.35, 0.4)]
const NEONS := ["neon_pink", "neon_cyan", "neon_green", "neon_amber"]

## Emissive materials: [colour, energy]. A surface per material, so the GI reads each one's emission.
const GLOW := {
	"win_warm": [Color(1.0, 0.72, 0.42), 1.4], "win_cool": [Color(0.62, 0.8, 1.0), 1.1], "shop": [Color(1.0, 0.86, 0.62), 0.7], "shop_cool": [Color(0.8, 0.92, 1.0), 0.6],
	"traffic_red": [Color(1.0, 0.08, 0.05), 5.0], "traffic_green": [Color(0.1, 1.0, 0.4), 5.0],
	"neon_pink": [Color(1.0, 0.18, 0.62), 5.0], "neon_cyan": [Color(0.15, 0.9, 1.0), 5.0], "neon_green": [Color(0.3, 1.0, 0.35), 4.5],
	"neon_amber": [Color(1.0, 0.55, 0.08), 5.0], "lamp": [Color(1.0, 0.78, 0.5), 7.0], "bulb": [Color(1.0, 0.82, 0.55), 6.0],
	"tail": [Color(1.0, 0.05, 0.05), 3.0]}

var main: Node3D
var rng := RandomNumberGenerator.new()
var poses := {}
var selectables: Array[Node3D] = []
var sun: DirectionalLight3D
var sun_energy := 0.0
var lamp_scale := 1.0
var car: Node3D
var car_lights: Array[SpotLight3D] = []
var _route: Array[Vector3] = [] # the moving car's loop
var _route_len := 0.0
var _lamps: Array[OmniLight3D] = []
var traffic_spots := [] # [position, towards the street, facing] of every traffic light


# --- a mesh builder: one set of arrays per material ---------------------------------------------------------------

class Part:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var i := PackedInt32Array()

	## A triangle facing along nrm (Godot front faces are clockwise).
	func tri(a: Vector3, b: Vector3, d: Vector3, na: Vector3, nb: Vector3, nd: Vector3, col: Color) -> void:
		var base := v.size()
		v.append(a)
		v.append(b)
		v.append(d)
		n.append(na)
		n.append(nb)
		n.append(nd)
		c.append(col)
		c.append(col)
		c.append(col)
		if (b - a).cross(d - a).dot(na + nb + nd) < 0.0:
			i.append_array([base, base + 1, base + 2])
		else:
			i.append_array([base, base + 2, base + 1])

	func quad(a: Vector3, b: Vector3, d: Vector3, e: Vector3, na: Vector3, nb: Vector3, nd: Vector3, ne: Vector3, col: Color) -> void:
		var base := v.size()
		v.append_array([a, b, d, e])
		n.append_array([na, nb, nd, ne])
		c.append_array([col, col, col, col])
		if (b - a).cross(d - a).dot(na + nb + nd + ne) < 0.0:
			i.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
		else:
			i.append_array([base, base + 2, base + 1, base, base + 3, base + 2])

	## A box: centre, full size, colour, orientation.
	func box(ctr: Vector3, size: Vector3, col: Color, b := Basis.IDENTITY) -> void:
		var h := size * 0.5
		var ax := [b.x, b.y, b.z]
		var hs := [h.x, h.y, h.z]
		for k in 3:
			for sgn in [-1.0, 1.0]:
				var nrm: Vector3 = ax[k] * sgn
				var fc: Vector3 = ctr + nrm * hs[k]
				var u: Vector3 = ax[(k + 1) % 3] * hs[(k + 1) % 3]
				var w: Vector3 = ax[(k + 2) % 3] * hs[(k + 2) % 3]
				quad(fc - u - w, fc + u - w, fc + u + w, fc - u + w, nrm, nrm, nrm, nrm, col)

	## A closed cylinder standing on base along the basis' y axis.
	func cylinder(base_ctr: Vector3, r: float, h: float, col: Color, seg := 10, b := Basis.IDENTITY) -> void:
		var top := base_ctr + b.y * h
		for s in seg:
			var a0 := TAU * s / seg
			var a1 := TAU * (s + 1) / seg
			var d0: Vector3 = b.x * cos(a0) + b.z * sin(a0)
			var d1: Vector3 = b.x * cos(a1) + b.z * sin(a1)
			quad(base_ctr + d0 * r, base_ctr + d1 * r, top + d1 * r, top + d0 * r, d0, d1, d1, d0, col)
			tri(top, top + d0 * r, top + d1 * r, b.y, b.y, b.y, col)
			tri(base_ctr, base_ctr + d1 * r, base_ctr + d0 * r, -b.y, -b.y, -b.y, col)

	## A flat slab cut into tiles of at most `tile` metres (no huge triangles: the voxelizer gives each triangle one thread).
	func slab(ctr: Vector3, size: Vector3, col: Color, tile := 4.0) -> void:
		var nx := maxi(int(ceil(size.x / tile)), 1)
		var nz := maxi(int(ceil(size.z / tile)), 1)
		var sx := size.x / nx
		var sz := size.z / nz
		for a in nx:
			for b in nz:
				box(ctr + Vector3(-size.x * 0.5 + (a + 0.5) * sx, 0, -size.z * 0.5 + (b + 0.5) * sz), Vector3(sx, size.y, sz), col)

	func sphere(ctr: Vector3, r: float, col: Color, seg := 8, rings := 5) -> void:
		for j in rings:
			var t0 := PI * j / rings
			var t1 := PI * (j + 1) / rings
			for s in seg:
				var p0 := TAU * s / seg
				var p1 := TAU * (s + 1) / seg
				var a := Vector3(sin(t0) * cos(p0), cos(t0), sin(t0) * sin(p0))
				var bb := Vector3(sin(t0) * cos(p1), cos(t0), sin(t0) * sin(p1))
				var d := Vector3(sin(t1) * cos(p1), cos(t1), sin(t1) * sin(p1))
				var e := Vector3(sin(t1) * cos(p0), cos(t1), sin(t1) * sin(p0))
				quad(ctr + a * r, ctr + bb * r, ctr + d * r, ctr + e * r, a, bb, d, e, col)


## Parts of one block, by material.
var _parts := {}


func _part(mat: String) -> Part:
	if not _parts.has(mat):
		_parts[mat] = Part.new()
	return _parts[mat]


func _flush(parent: Node, name: String) -> void:
	var mesh := ArrayMesh.new()
	var mats := []
	for key in _parts:
		var p: Part = _parts[key]
		if p.v.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = p.v
		arrays[Mesh.ARRAY_NORMAL] = p.n
		arrays[Mesh.ARRAY_COLOR] = p.c
		arrays[Mesh.ARRAY_INDEX] = p.i
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mats.append(_material(key))
	for k in mats.size():
		mesh.surface_set_material(k, mats[k])
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = name
	mi.set_meta("rc_closed", true) # every primitive is closed: the GI fills their insides
	parent.add_child(mi)
	_parts.clear()


var _mat_cache := {}


func _material(key: String) -> Material:
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	if GLOW.has(key):
		var g: Array = GLOW[key]
		m.albedo_color = g[0]
		m.emission_enabled = true
		m.emission = g[0]
		m.emission_energy_multiplier = g[1]
	elif key == "glass":
		m.albedo_color = Color(0.55, 0.8, 0.75, 0.3)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.roughness = 0.05
	else:
		m.vertex_color_use_as_albedo = true
		match key:
			"paint":
				m.roughness = 0.25
				m.metallic = 0.5
			"chrome":
				m.roughness = 0.15
				m.metallic = 1.0
			"water":
				m.roughness = 0.05
			"road":
				m.roughness = 0.32 # wet asphalt
			_:
				m.roughness = 0.88
	_mat_cache[key] = m
	return m


# --- the city -------------------------------------------------------------------------------------------------

func _block_centre(i: int, j: int) -> Vector3:
	var o := (GRID - 1) * 0.5
	return Vector3((i - o) * PITCH, 0.0, (j - o) * PITCH)


func build(m: Node3D) -> void:
	main = m
	rng.seed = 2026
	var S: Node3D = m.static_root
	var D: Node3D = m.dyn_root
	var t0 := Time.get_ticks_msec()
	var half := GRID * PITCH * 0.5 + 20.0
	# The road: one slab under the whole city, with lane markings and crossings.
	var road := _part("road")
	road.slab(Vector3(0, -0.15, 0), Vector3(half * 2, 0.3, half * 2), Color(0.12, 0.12, 0.13))
	road = _part("base")
	for k in GRID + 1:
		var c := (k - GRID * 0.5) * PITCH # the middle of a street
		var x := -half
		while x < half:
			road.box(Vector3(x + 1.5, 0.005, c), Vector3(3.0, 0.01, 0.15), Color(0.85, 0.82, 0.6))
			road.box(Vector3(c, 0.005, x + 1.5), Vector3(0.15, 0.01, 3.0), Color(0.85, 0.82, 0.6))
			x += 7.0
	for a in GRID + 1:
		for b in GRID + 1:
			var ix := (a - GRID * 0.5) * PITCH
			var iz := (b - GRID * 0.5) * PITCH
			for s in 8: # zebra crossings on the four sides of every crossing
				var off := -3.5 + s * 1.0
				road.box(Vector3(ix + off, 0.011, iz - STREET * 0.5 - 1.2), Vector3(0.5, 0.02, 2.0), Color(0.9, 0.9, 0.88))
				road.box(Vector3(ix + off, 0.011, iz + STREET * 0.5 + 1.2), Vector3(0.5, 0.02, 2.0), Color(0.9, 0.9, 0.88))
	_flush(S, "Road")
	for i in GRID:
		for j in GRID:
			var c := _block_centre(i, j)
			var kind := "shops"
			if i == 2 and j == 2:
				kind = "plaza"
			elif i == 1 and j == 2:
				kind = "market"
			elif i == 3 and j == 1:
				kind = "park"
			_block(S, c, kind)
			_flush(S, "Block_%d_%d" % [i, j])
	_build_car(D)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, 30.0, 0.0)
	sun.light_color = Color(1.0, 0.94, 0.84)
	sun.light_energy = 0.0
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	S.add_child(sun)
	m._make_env(Color(0.02, 0.025, 0.06), Color(0.25, 0.3, 0.5), 0.03, 1.0)
	m._make_camera(75.0)
	m.cam.far = 400.0
	var road_z := PITCH * 0.5 # the street just south of the middle row
	poses = {
		"avenue": [Vector3(-20.0, 1.7, road_z + 1.0), Vector3(40.0, 2.5, road_z)],
		"plaza": [Vector3(-10.0, 1.7, -9.0), Vector3(4.0, 1.5, 4.0)],
		"market": [Vector3(-PITCH + 12.0, 1.7, -12.0), Vector3(-PITCH - 4.0, 1.0, 6.0)],
		"park": [Vector3(PITCH - 4.0, 1.7, -PITCH + 14.0), Vector3(PITCH + 10.0, 2.0, -PITCH)],
		"crossing": [Vector3(road_z - 6.0, 1.6, road_z - 10.0), Vector3(road_z + 2.0, 2.0, road_z + 6.0)],
		"rooftops": [Vector3(-30.0, 16.0, 30.0), Vector3(10.0, 4.0, -10.0)],
	}
	print("city: built in %d ms" % (Time.get_ticks_msec() - t0))


## One block: a raised sidewalk, then shops and flats round the edge (or a plaza, a market or a park), props on the sidewalk.
func _block(S: Node3D, c: Vector3, kind: String) -> void:
	var base := _part("base")
	var h := BLOCK * 0.5
	base.slab(c + Vector3(0, CURB * 0.5, 0), Vector3(BLOCK, CURB, BLOCK), Color(0.55, 0.53, 0.5))
	# Kerb stones: a lighter rim.
	for s in [-1.0, 1.0]:
		base.box(c + Vector3(0, CURB * 0.5 + 0.005, s * (h - 0.1)), Vector3(BLOCK, CURB + 0.01, 0.2), Color(0.72, 0.7, 0.66))
		base.box(c + Vector3(s * (h - 0.1), CURB * 0.5 + 0.005, 0), Vector3(0.2, CURB + 0.01, BLOCK - 0.4), Color(0.72, 0.7, 0.66))
	_sidewalk_props(S, c)
	match kind:
		"plaza":
			_plaza(c)
		"market":
			_market(S, c)
		"park":
			_park(c)
		_:
			_buildings(c)


## Lamps, trees, benches, bins, hydrants and parked cars along the four edges of a block.
func _sidewalk_props(S: Node3D, c: Vector3) -> void:
	var h := BLOCK * 0.5
	for side in 4:
		var dir: Vector3 = [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)][side]
		var out: Vector3 = [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)][side] # towards the street
		var start: Vector3 = c + out * (h - 0.6) - dir * (h - 2.0)
		var yaw := atan2(out.x, out.z)
		var t := 2.0
		var k := 0
		while t < BLOCK - 3.0:
			var p: Vector3 = start + dir * t + Vector3(0, CURB, 0)
			if k == 0 and side % 2 == 0:
				_traffic_light(p + dir * -1.0, out, dir)
			elif k == 3 and side == 1 and rng.randf() < 0.6:
				_bus_stop(p - out * 0.9, yaw)
			elif k % 3 == 0:
				_street_lamp(S, p, out)
			elif k % 3 == 1:
				_tree(p - out * 0.2, rng.randf_range(0.8, 1.2))
			else:
				var r := rng.randi() % 4
				if r == 0:
					_bench(p - out * 0.6, yaw)
				elif r == 1:
					_part("base").cylinder(p - out * 0.3, 0.25, 0.9, Color(0.2, 0.35, 0.25), 10)
				elif r == 2:
					_hydrant(p)
				else:
					_part("base").box(p + Vector3(0, 0.6, 0) - out * 0.4, Vector3(0.45, 1.2, 0.4), [Color(0.95, 0.75, 0.1), Color(0.15, 0.3, 0.75)][rng.randi() % 2], Basis(Vector3.UP, yaw))
			k += 1
			t += 5.0
		# Parked cars in the lane next to the kerb, with gaps.
		var u := 4.0
		while u < BLOCK - 5.0:
			if rng.randf() < 0.55:
				_parked_car(start + dir * u + out * 1.8, atan2(dir.x, dir.z))
			u += rng.randf_range(5.5, 7.5)


func _street_lamp(S: Node3D, p: Vector3, out: Vector3) -> void:
	var b := _part("base")
	b.cylinder(p, 0.07, 5.2, Color(0.2, 0.22, 0.24), 8)
	var arm_end := p + Vector3(0, 5.15, 0) + out * 1.1
	b.box((p + Vector3(0, 5.15, 0) + arm_end) * 0.5, Vector3(0.08, 0.08, 1.2), Color(0.2, 0.22, 0.24), Basis(Vector3.UP, atan2(out.x, out.z)))
	_part("lamp").box(arm_end - Vector3(0, 0.12, 0), Vector3(0.35, 0.1, 0.5), Color.WHITE, Basis(Vector3.UP, atan2(out.x, out.z)))
	var l := OmniLight3D.new()
	l.position = arm_end - Vector3(0, 0.4, 0)
	l.light_color = Color(1.0, 0.72, 0.42)
	l.light_energy = 3.0
	l.omni_range = 13.0
	l.omni_attenuation = 1.6
	S.add_child(l)
	_lamps.append(l)


func _traffic_light(p: Vector3, out: Vector3, dir: Vector3) -> void:
	traffic_spots.append([p, out, dir])
	var b := _part("base")
	b.cylinder(p, 0.06, 3.2, Color(0.18, 0.2, 0.18), 8)
	var hb := Basis(Vector3.UP, atan2(dir.x, dir.z))
	var head := p + Vector3(0, 3.0, 0) + out * 0.15
	b.box(head, Vector3(0.32, 0.9, 0.28), Color(0.12, 0.13, 0.12), hb)
	var red := rng.randf() < 0.5
	for k in 3:
		var lp := head + Vector3(0, 0.28 - k * 0.28, 0) + dir * 0.15
		var mat := "base"
		if (k == 0 and red) or (k == 2 and not red):
			mat = "traffic_red" if k == 0 else "traffic_green"
		_part(mat).box(lp, Vector3(0.18, 0.18, 0.04), Color(0.2, 0.2, 0.2), hb)


func _bus_stop(p: Vector3, yaw: float) -> void:
	var b := _part("base")
	var bs := Basis(Vector3.UP, yaw)
	b.box(p + Vector3(0, 2.3, 0), Vector3(3.2, 0.08, 1.4), Color(0.2, 0.25, 0.3), bs) # roof
	for sx in [-1.5, 1.5]:
		b.box(p + bs.x * sx + Vector3(0, 1.15, 0) - bs.z * 0.6, Vector3(0.06, 2.3, 0.06), Color(0.2, 0.25, 0.3), bs)
	_part("glass").box(p + Vector3(0, 1.2, 0) - bs.z * 0.62, Vector3(3.0, 1.9, 0.03), Color.WHITE, bs) # back pane
	_part("shop_cool").box(p + bs.x * 1.55 + Vector3(0, 1.2, 0), Vector3(0.06, 1.6, 1.0), Color.WHITE, bs) # lit advert
	b.box(p + Vector3(0, 0.45, 0) - bs.z * 0.4, Vector3(2.4, 0.06, 0.4), Color(0.6, 0.62, 0.65), bs) # seat


func _tree(p: Vector3, s: float) -> void:
	var b := _part("base")
	b.box(p + Vector3(0, 0.02, 0), Vector3(1.2, 0.04, 1.2), Color(0.3, 0.22, 0.15)) # tree pit
	b.cylinder(p, 0.12 * s, 2.4 * s, Color(0.35, 0.25, 0.18), 8)
	var greens := [Color(0.22, 0.45, 0.18), Color(0.3, 0.55, 0.2), Color(0.18, 0.38, 0.22)]
	for k in 3:
		var o := Vector3(rng.randf_range(-0.5, 0.5), rng.randf_range(0.0, 0.7), rng.randf_range(-0.5, 0.5)) * s
		b.sphere(p + Vector3(0, 2.8 * s, 0) + o, rng.randf_range(0.9, 1.3) * s, greens[k], 8, 6)


func _bench(p: Vector3, yaw: float) -> void:
	var b := _part("base")
	var bs := Basis(Vector3.UP, yaw)
	b.box(p + Vector3(0, 0.45, 0), Vector3(1.6, 0.06, 0.45), Color(0.55, 0.36, 0.2), bs)
	b.box(p + Vector3(0, 0.75, 0) + bs.z * 0.2, Vector3(1.6, 0.35, 0.05), Color(0.55, 0.36, 0.2), bs)
	for sx in [-0.7, 0.7]:
		b.box(p + bs.x * sx + Vector3(0, 0.22, 0), Vector3(0.06, 0.44, 0.4), Color(0.15, 0.15, 0.16), bs)


func _hydrant(p: Vector3) -> void:
	var b := _part("base")
	b.cylinder(p, 0.13, 0.6, Color(0.8, 0.1, 0.08), 10)
	b.sphere(p + Vector3(0, 0.62, 0), 0.13, Color(0.8, 0.1, 0.08), 8, 4)
	b.box(p + Vector3(0, 0.4, 0), Vector3(0.42, 0.1, 0.1), Color(0.8, 0.1, 0.08))


func _parked_car(p: Vector3, yaw: float) -> void:
	var bs := Basis(Vector3.UP, yaw)
	var col: Color = CAR_PAINT[rng.randi() % CAR_PAINT.size()]
	var paint := _part("paint")
	paint.box(p + Vector3(0, 0.62, 0), Vector3(1.75, 0.65, 4.1), col, bs)
	paint.box(p + Vector3(0, 1.17, 0) - bs.z * 0.2, Vector3(1.6, 0.5, 2.2), col.darkened(0.1), bs)
	var b := _part("base")
	b.box(p + Vector3(0, 1.17, 0) - bs.z * 0.2, Vector3(1.62, 0.36, 2.0), Color(0.08, 0.1, 0.12), bs) # windows
	for sx in [-0.8, 0.8]:
		for sz in [-1.3, 1.3]:
			b.cylinder(p + bs.x * (sx - 0.1) + bs.z * sz + Vector3(0, 0.33, 0), 0.33, 0.2, Color(0.06, 0.06, 0.06), 10,
				Basis(bs.z, PI * 0.5) * bs)
	_part("tail").box(p + Vector3(0, 0.7, 0) - bs.z * 2.06, Vector3(1.4, 0.12, 0.03), Color.WHITE, bs)


## Shops at street level and flats above, round the edge of the block.
func _buildings(c: Vector3) -> void:
	var h := BLOCK * 0.5 - SIDEWALK
	for side in 4:
		var dir: Vector3 = [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)][side]
		var out: Vector3 = [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)][side]
		var depth := 10.0
		# North and south rows run the whole width; east and west fit between them.
		var length := h * 2.0 if side % 2 == 0 else h * 2.0 - depth * 2.0
		var start: Vector3 = c + out * h - dir * (length * 0.5)
		var t := 0.0
		while t < length - 0.5:
			var w := minf(rng.randf_range(6.0, 11.0), length - t)
			if length - t - w < 4.0:
				w = length - t
			var floors := rng.randi_range(2, 6) if rng.randf() < 0.8 else rng.randi_range(7, 9)
			_building(start + dir * (t + w * 0.5) - out * depth * 0.5 + Vector3(0, CURB, 0), dir, out, w, depth, floors)
			t += w
	# The courtyard: grass and a few trees.
	var inner := h * 2.0 - 20.0
	if inner > 2.0:
		_part("base").slab(c + Vector3(0, CURB + 0.03, 0), Vector3(inner, 0.06, inner), Color(0.25, 0.42, 0.2))
		for k in 3:
			_tree(c + Vector3(rng.randf_range(-inner, inner) * 0.35, CURB, rng.randf_range(-inner, inner) * 0.35), 1.1)


func _building(ground: Vector3, dir: Vector3, out: Vector3, w: float, depth: float, floors: int) -> void:
	var yaw := atan2(out.x, out.z)
	var bs := Basis(Vector3.UP, yaw) # z = out (street side), x along the street
	var col: Color = FACADES[rng.randi() % FACADES.size()]
	var height := SHOP_H + (floors - 1) * FLOOR_H
	var b := _part("base")
	b.box(ground + Vector3(0, height * 0.5, 0), Vector3(w, height, depth), col, bs)
	var front := ground + out * (depth * 0.5)
	# Ground floor: a shop window, a door, an awning and a neon sign.
	var shop_w := w - 1.6
	var lit := rng.randf() < 0.8
	var glow := "shop" if rng.randf() < 0.65 else "shop_cool"
	var win_w := shop_w * 0.7
	_part(glow if lit else "base").box(front + Vector3(0, 1.55, 0) + out * 0.02, Vector3(win_w, 2.1, 0.04), Color(0.08, 0.1, 0.12), bs)
	# Shelves seen against the lit window, with goods on them.
	for sh in 2:
		var sy := 0.75 + sh * 0.7
		b.box(front + Vector3(0, sy, 0) + out * 0.09, Vector3(win_w * 0.9, 0.04, 0.1), Color(0.3, 0.22, 0.15), bs)
		var ng := int(win_w * 2.0)
		for g in ng:
			if rng.randf() < 0.75:
				b.box(front + Vector3(0, sy + 0.12, 0) + out * 0.09 + bs.x * (-win_w * 0.43 + g * win_w * 0.86 / maxf(ng - 1, 1)),
					Vector3(0.14, 0.2 + rng.randf() * 0.12, 0.08), FRUIT[rng.randi() % FRUIT.size()].lerp(Color(0.9, 0.9, 0.85), 0.3), bs)
	b.box(front + Vector3(0, 1.1, 0) + out * 0.03 + bs.x * (shop_w * 0.42), Vector3(0.9, 2.2, 0.06), Color(0.25, 0.18, 0.12), bs)
	b.box(front + Vector3(0, SHOP_H - 0.1, 0) + out * 0.08, Vector3(w, 0.2, 0.16), col.darkened(0.25), bs) # cornice
	var aw: Color = AWNINGS[rng.randi() % AWNINGS.size()]
	var n_str := int(shop_w / 0.5)
	var tilt := Basis(bs.x, deg_to_rad(-20.0)) * bs
	for s in n_str: # a striped awning
		var sc := aw if s % 2 == 0 else Color(0.95, 0.93, 0.88)
		b.box(front + Vector3(0, 3.0, 0) + out * 0.65 + bs.x * (-shop_w * 0.5 + (s + 0.5) * shop_w / n_str), Vector3(shop_w / n_str, 0.04, 1.3), sc, tilt)
	var neon: String = NEONS[rng.randi() % NEONS.size()]
	b.box(front + Vector3(0, SHOP_H + 0.45, 0) + out * 0.05, Vector3(minf(w * 0.6, 4.0), 0.7, 0.08), Color(0.1, 0.1, 0.12), bs)
	var sw := minf(w * 0.6, 4.0) - 0.4
	for row in 2:
		_part(neon).box(front + Vector3(0, SHOP_H + 0.3 + row * 0.3, 0) + out * 0.1, Vector3(sw * (1.0 - 0.3 * row), 0.07, 0.04), Color.WHITE, bs)
	# A vertical neon sign standing out from the facade on some buildings.
	if rng.randf() < 0.3:
		var blade: String = NEONS[rng.randi() % NEONS.size()]
		var bp := front + Vector3(0, SHOP_H + 1.6, 0) + bs.x * (w * 0.5 - 0.6) + out * 0.55
		b.box(bp, Vector3(0.12, 2.4, 0.9), Color(0.1, 0.1, 0.12), bs)
		for s in 2:
			_part(blade).box(bp + bs.x * (0.07 if s == 0 else -0.07), Vector3(0.03, 2.0, 0.6), Color.WHITE, bs)
	# Upper floors: windows (some lit), sills, flower boxes, air conditioners, balconies.
	var n_win := maxi(int((w - 1.0) / 1.7), 1)
	for f in range(1, floors):
		var y := SHOP_H + (f - 1) * FLOOR_H + 0.9
		var balcony := rng.randf() < 0.25
		for k in n_win:
			var x := -w * 0.5 + (k + 0.5) * w / n_win
			var wp := front + Vector3(0, y + 0.7, 0) + bs.x * x + out * 0.04
			var r := rng.randf()
			var wm := "win_warm" if r < 0.3 else ("win_cool" if r < 0.42 else "base")
			_part(wm).box(wp, Vector3(0.95, 1.35, 0.08), Color(0.06, 0.08, 0.12), bs)
			b.box(wp - Vector3(0, 0.75, 0) + out * 0.06, Vector3(1.15, 0.08, 0.2), col.lightened(0.3), bs) # sill
			if rng.randf() < 0.25:
				b.box(wp - Vector3(0, 0.62, 0) + out * 0.2, Vector3(0.9, 0.2, 0.22), Color(0.4, 0.25, 0.15), bs)
				for fl in 4:
					b.sphere(wp - Vector3(0, 0.45, 0) + out * 0.2 + bs.x * (-0.33 + fl * 0.22), 0.1,
						[Color(0.95, 0.2, 0.35), Color(1.0, 0.85, 0.2), Color(0.9, 0.4, 0.8)][rng.randi() % 3], 6, 4)
			elif rng.randf() < 0.15:
				b.box(wp - Vector3(0, 0.95, 0) + out * 0.3, Vector3(0.7, 0.45, 0.45), Color(0.82, 0.82, 0.8), bs)
		if balcony:
			b.box(front + Vector3(0, y - 0.1, 0) + out * 0.6, Vector3(w * 0.7, 0.12, 1.1), Color(0.75, 0.73, 0.7), bs)
			b.box(front + Vector3(0, y + 0.45, 0) + out * 1.12, Vector3(w * 0.7, 0.05, 0.05), Color(0.15, 0.15, 0.16), bs)
			var nb := int(w * 0.7 / 0.25)
			for s in nb:
				b.box(front + Vector3(0, y + 0.2, 0) + out * 1.12 + bs.x * (-w * 0.35 + (s + 0.5) * w * 0.7 / nb), Vector3(0.03, 0.5, 0.03), Color(0.15, 0.15, 0.16), bs)
	# Roof: a parapet, sometimes a water tank or an antenna.
	b.box(ground + Vector3(0, height + 0.3, 0) + out * (depth * 0.5 - 0.1), Vector3(w, 0.6, 0.2), col.darkened(0.15), bs)
	if rng.randf() < 0.4:
		b.cylinder(ground + Vector3(0, height, 0) + bs.x * rng.randf_range(-w * 0.3, w * 0.3), 0.8, 1.6, Color(0.5, 0.52, 0.55), 12)
	elif rng.randf() < 0.4:
		b.box(ground + Vector3(0, height + 1.5, 0), Vector3(0.06, 3.0, 0.06), Color(0.3, 0.3, 0.32))


func _plaza(c: Vector3) -> void:
	var b := _part("base")
	var inner := BLOCK - 2.0 * SIDEWALK
	b.slab(c + Vector3(0, CURB + 0.04, 0), Vector3(inner, 0.08, inner), Color(0.78, 0.72, 0.62)) # paving
	# Fountain: a basin, water, a column and a bowl.
	b.cylinder(c + Vector3(0, CURB, 0), 3.2, 0.6, Color(0.7, 0.68, 0.64), 24)
	_part("water").cylinder(c + Vector3(0, CURB + 0.6, 0), 2.9, 0.02, Color(0.1, 0.3, 0.45), 24)
	b.cylinder(c + Vector3(0, CURB + 0.62, 0), 0.35, 1.6, Color(0.7, 0.68, 0.64), 12)
	b.cylinder(c + Vector3(0, CURB + 2.2, 0), 1.1, 0.25, Color(0.7, 0.68, 0.64), 16)
	# Benches round it, trees in the corners.
	for k in 8:
		var a := TAU * k / 8.0
		_bench(c + Vector3(cos(a) * 6.0, CURB + 0.08, sin(a) * 6.0), -a + PI * 0.5)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_tree(c + Vector3(sx * 9.5, CURB + 0.08, sz * 9.5), 1.3)
	# String lights between four poles: rows of glowing bulbs (two lamps light the plaza for the GI and Godot).
	var corners := [Vector3(-10, 0, -10), Vector3(10, 0, -10), Vector3(10, 0, 10), Vector3(-10, 0, 10)]
	for p in corners:
		b.cylinder(c + p + Vector3(0, CURB, 0), 0.08, 5.0, Color(0.25, 0.25, 0.27), 8)
	for k in 4:
		var a: Vector3 = c + corners[k] + Vector3(0, 5.0, 0)
		var e: Vector3 = c + corners[(k + 2) % 4] + Vector3(0, 5.0, 0) if k < 2 else c + corners[(k + 1) % 4] + Vector3(0, 5.0, 0)
		var n := 22
		for s in n + 1:
			var f := float(s) / n
			var p := a.lerp(e, f) - Vector3(0, sin(f * PI) * 1.2, 0)
			_part("bulb").sphere(p, 0.07, Color.WHITE, 6, 4)
	for p in [Vector3(-4, 4.2, 0), Vector3(4, 4.2, 0)]:
		var l := OmniLight3D.new()
		l.position = c + p
		l.light_color = Color(1.0, 0.8, 0.55)
		l.light_energy = 3.0
		l.omni_range = 14.0
		main.static_root.add_child(l)
		_lamps.append(l)


func _market(S: Node3D, c: Vector3) -> void:
	var b := _part("base")
	var inner := BLOCK - 2.0 * SIDEWALK
	b.slab(c + Vector3(0, CURB + 0.04, 0), Vector3(inner, 0.08, inner), Color(0.5, 0.48, 0.45))
	# Rows of stalls: posts, a striped canopy, a table of crates full of fruit, a hanging bulb.
	for row in 3:
		for k in 5:
			var p := c + Vector3(-10.0 + k * 5.0, CURB + 0.08, -8.0 + row * 8.0)
			var cc: Color = AWNINGS[rng.randi() % AWNINGS.size()]
			for sx in [-1.6, 1.6]:
				for sz in [-1.1, 1.1]:
					b.box(p + Vector3(sx, 1.2, sz), Vector3(0.06, 2.4, 0.06), Color(0.4, 0.3, 0.2))
			for s in 8:
				b.box(p + Vector3(-1.75 + (s + 0.5) * 0.4375, 2.45, 0), Vector3(0.4375, 0.05, 2.5), cc if s % 2 == 0 else Color(0.95, 0.94, 0.9),
					Basis(Vector3.RIGHT, deg_to_rad(8.0)))
			b.box(p + Vector3(0, 0.8, 0), Vector3(3.0, 0.06, 1.8), Color(0.55, 0.4, 0.25))
			for cx in 4:
				for cz in 2:
					var cp := p + Vector3(-1.1 + cx * 0.73, 0.83, -0.4 + cz * 0.8)
					b.box(cp + Vector3(0, 0.1, 0), Vector3(0.6, 0.2, 0.6), Color(0.6, 0.45, 0.28))
					var fc: Color = FRUIT[rng.randi() % FRUIT.size()]
					for fx in 3:
						for fz in 3:
							b.sphere(cp + Vector3(-0.18 + fx * 0.18, 0.27, -0.18 + fz * 0.18), 0.085, fc, 6, 4)
			_part("bulb").sphere(p + Vector3(0, 2.15, 0), 0.08, Color.WHITE, 6, 4)
	for p in [Vector3(-6, 3.0, -4), Vector3(6, 3.0, 4)]:
		var l := OmniLight3D.new()
		l.position = c + p
		l.light_color = Color(1.0, 0.82, 0.55)
		l.light_energy = 2.5
		l.omni_range = 12.0
		S.add_child(l)
		_lamps.append(l)


func _park(c: Vector3) -> void:
	var b := _part("base")
	var inner := BLOCK - 2.0 * SIDEWALK
	b.slab(c + Vector3(0, CURB + 0.04, 0), Vector3(inner, 0.08, inner), Color(0.24, 0.42, 0.18))
	b.box(c + Vector3(0, CURB + 0.085, 0), Vector3(inner, 0.01, 2.0), Color(0.7, 0.62, 0.45)) # paths
	b.box(c + Vector3(0, CURB + 0.085, 0), Vector3(2.0, 0.01, inner), Color(0.7, 0.62, 0.45))
	for k in 14:
		var p := c + Vector3(rng.randf_range(-12, 12), CURB + 0.08, rng.randf_range(-12, 12))
		if absf(p.x - c.x) < 2.0 or absf(p.z - c.z) < 2.0:
			continue
		_tree(p, rng.randf_range(0.9, 1.6))
	for k in 6:
		var p2 := c + Vector3(rng.randf_range(-10, 10), CURB + 0.08, 1.8 if k % 2 == 0 else -1.8)
		_bench(p2, 0.0 if k % 2 == 0 else PI)
	# Flower beds.
	for k in 4:
		var fb := c + Vector3(-8.0 + (k % 2) * 16.0, CURB + 0.08, -8.0 + (k / 2) * 16.0)
		b.box(fb + Vector3(0, 0.15, 0), Vector3(3.0, 0.3, 3.0), Color(0.45, 0.32, 0.2))
		for f in 30:
			b.sphere(fb + Vector3(rng.randf_range(-1.3, 1.3), 0.38, rng.randf_range(-1.3, 1.3)), 0.09,
				[Color(0.95, 0.2, 0.3), Color(1.0, 0.8, 0.15), Color(0.85, 0.4, 0.9), Color(1.0, 1.0, 0.95)][rng.randi() % 4], 6, 4)


# --- the moving car ----------------------------------------------------------------------------------------------

## A moving part: its own BoxMesh node (the GI voxelizes moving boxes every frame).
func _node_box(parent: Node, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.4
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _build_car(D: Node3D) -> void:
	car = Node3D.new()
	car.name = "Car"
	D.add_child(car)
	var paint := Color(0.85, 0.1, 0.08)
	for part in [[Vector3(0, 0.62, 0), Vector3(1.75, 0.65, 4.1), paint], [Vector3(0, 1.17, -0.2), Vector3(1.6, 0.5, 2.2), paint.darkened(0.1)],
			[Vector3(0, 0.33, 1.3), Vector3(1.8, 0.66, 0.66), Color(0.06, 0.06, 0.06)], [Vector3(0, 0.33, -1.3), Vector3(1.8, 0.66, 0.66), Color(0.06, 0.06, 0.06)]]:
		_node_box(car, part[0], part[1], part[2])
	var head := _node_box(car, Vector3(0, 0.7, 2.06), Vector3(1.4, 0.12, 0.04), Color(1.0, 0.95, 0.85))
	var hm := head.material_override as StandardMaterial3D
	hm.emission_enabled = true
	hm.emission = Color(1.0, 0.95, 0.85)
	hm.emission_energy_multiplier = 4.0
	for sx in [-0.6, 0.6]:
		var s := SpotLight3D.new()
		s.position = Vector3(sx, 0.75, 2.1)
		s.rotation.y = PI # a spot shines along -Z; the car's front is +Z
		s.rotation.x = deg_to_rad(-8.0)
		s.light_color = Color(1.0, 0.95, 0.85)
		s.light_energy = 8.0
		s.spot_range = 25.0
		s.spot_angle = 28.0
		car.add_child(s)
		car_lights.append(s)
	# The loop: round the plaza block, in the middle of the streets around it.
	var e := PITCH * 0.5
	_route = [Vector3(-e, 0, -e), Vector3(e, 0, -e), Vector3(e, 0, e), Vector3(-e, 0, e), Vector3(-e, 0, -e)]
	_route_len = 0.0
	for k in 4:
		_route_len += _route[k].distance_to(_route[k + 1])


## The car's place on its loop (u in 0..1) and the live settings.
func animate(u: float, t: float) -> void:
	var d := fposmod(t * 8.0, _route_len) # 8 m/s
	for k in 4:
		var seg := _route[k].distance_to(_route[k + 1])
		if d <= seg:
			var p := _route[k].lerp(_route[k + 1], d / seg)
			var dir := (_route[k + 1] - _route[k]).normalized()
			car.position = p + dir.cross(Vector3.UP) * -2.0 # drive on the right
			car.rotation.y = atan2(dir.x, dir.z)
			break
		d -= seg
	for l in _lamps:
		l.light_energy = 3.0 * lamp_scale
	sun.light_energy = sun_energy
