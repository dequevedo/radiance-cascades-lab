extends RefCounted
## A small grocery store built from simple box props (no external assets).
## Room 14 x 9.5 m, ceiling 3.4 m: front wall with two windows and a door, six ceiling fluorescents,
## a street lamp outside, gondolas stocked with products, a counter with a register, fridges and freezers,
## and a dolly of cartons (dynamic: moves, carries a work lamp) driven along the central aisle.
##
## Everything static goes under main.static_root (voxelized once), everything that moves under main.dyn_root
## (voxelized every frame as boxes).

## One set of rules for the whole building: every wall is WALL thick and runs from the underside of the floor slab
## (FLOOR_Y) to the top of the ceiling slab (ROOF_Y); every floor slab tops out at 0 and every ceiling slab starts at CEIL; every
## coordinate is a multiple of CELL. The plan is painted on a CELL grid and turned into boxes that never overlap (see room()).
const ROOM_X := 7.0
const ROOM_Z := 4.75
const CEIL := 3.4
const WALL := 0.3
const FLOOR_Y := -0.3
const ROOF_Y := CEIL + 0.3
const BAND_H := 1.2 # the tiled band on the lower part of the store's walls
const CELL := 0.05

# The curved corridor leaves through an opening in the left wall (centred on z = COR_Z, 3 m wide), runs 6 m west, turns
# left (towards +z) on a 5 m radius, and runs 8 m. No lamp inside: whatever light is in there got in from the store.
const COR_Z := 0.3
const COR_W := 3.0
const COR_A := 6.0
const COR_R := 5.0
const COR_B := 8.0

# A door in the corridor's right wall (between these distances from the opening) leads to two rooms south of it: a materials
# room (glass, metal, glossy and rough spheres, one lamp) and, through it, a dark room lit only by a television. The rooms
# line up with the store's back wall; the dark room stops one wall short of the corridor, so the bend never grazes its wall.
const DOOR_S0 := 2.7
const DOOR_S1 := 3.9
const DIVIDER_X := -13.0 # west face of the wall between the two rooms
const DARK_X0 := -18.5 # west end of the dark room (inside)
const MAT_Z1 := COR_Z - COR_W * 0.5 - WALL # north end of the materials room: the corridor's wall
const DARK_Z1 := MAT_Z1 - WALL

# The GI volume that holds the store and the corridor (world metres). The plan grid covers the same area.
const VOLUME_MIN := Vector3(-20.5, -0.5, -5.25)
const VOLUME_SIZE := Vector3(28.0, 4.5, 19.25)
const GRID_NX := 560
const GRID_NZ := 385

var main: Node3D
var rng := RandomNumberGenerator.new()
var ceiling_lights: Array[OmniLight3D] = []
var street_lamp: OmniLight3D
var corridor_lamp: OmniLight3D
var sun: DirectionalLight3D
# Live settings (the panel changes these; animate() applies them every frame).
var ceiling_scale := 1.0
var street_energy := 60.0
var corridor_lamp_energy := 0.0
var sun_energy := 0.0
var dolly: Node3D
var dolly_lamp: OmniLight3D
var dolly_bulb: MeshInstance3D
var poses := {}
var selectables: Array[Node3D] = [] # the props the object picker can select and move
var tv_screen: MeshInstance3D # the dark room's television: a moving (re-voxelized) box whose emission changes colour
var tv_animate := true
var materials_lamp: OmniLight3D
var materials_lamp_energy := 3.0
# The plan: one profile id per grid cell; a profile is the list of solid [y0, y1, colour] intervals of that column.
var _cells := PackedInt32Array()
var _profiles: Array = [[]]
var _profile_ids := {"[]": 0}
var _rooms: Array = []


## The props, as boxes: [centre (pivot at the bottom centre, +z = front), size, colour, emission]. Sizes are real-world metres,
## so the light bounces off things of the right size; the look is deliberately plain. Emission > 0: the part glows and lights the
## scene through the bounce; < 0: it only glows (the fluorescent tubes, whose light is an OmniLight3D already).
const KIT := {
	"fluorescent_fixture": [[Vector3(0, 0.03, 0), Vector3(1.24, 0.06, 0.22), Color(0.85, 0.85, 0.82), 0.0],
		[Vector3(0, -0.01, 0), Vector3(1.18, 0.03, 0.12), Color(0.85, 1.0, 0.9), -3.0]],
	"shelf_metal": [[Vector3(0, 0.9, -0.2), Vector3(1.0, 1.8, 0.04), Color(0.72, 0.72, 0.7), 0.0],
		[Vector3(0, 0.22, 0), Vector3(0.96, 0.03, 0.42), Color(0.75, 0.75, 0.73), 0.0],
		[Vector3(0, 0.636, 0), Vector3(0.96, 0.03, 0.42), Color(0.75, 0.75, 0.73), 0.0],
		[Vector3(0, 1.052, 0), Vector3(0.96, 0.03, 0.42), Color(0.75, 0.75, 0.73), 0.0],
		[Vector3(0, 1.468, 0), Vector3(0.96, 0.03, 0.42), Color(0.75, 0.75, 0.73), 0.0],
		[Vector3(0, 0.05, 0), Vector3(0.98, 0.1, 0.42), Color(0.4, 0.4, 0.4), 0.0]],
	"biscuit_pack": [[Vector3(0, 0.04, 0), Vector3(0.28, 0.08, 0.2), Color(0.85, 0.65, 0.3), 0.0]],
	"rice_pack": [[Vector3(0, 0.125, 0), Vector3(0.18, 0.25, 0.08), Color(0.92, 0.9, 0.85), 0.0]],
	"guarana_2l": [[Vector3(0, 0.165, 0), Vector3(0.1, 0.33, 0.1), Color(0.15, 0.55, 0.2), 0.0]],
	"grocery_tins": [[Vector3(0, 0.06, 0), Vector3(0.28, 0.12, 0.09), Color(0.6, 0.62, 0.65), 0.0]],
	"cooking_oil": [[Vector3(0, 0.14, 0), Vector3(0.08, 0.28, 0.08), Color(0.95, 0.8, 0.25), 0.0]],
	"washing_powder": [[Vector3(0, 0.14, 0), Vector3(0.2, 0.28, 0.08), Color(0.2, 0.4, 0.85), 0.0]],
	"formica_counter": [[Vector3(0, 0.44, 0), Vector3(1.5, 0.88, 0.6), Color(0.62, 0.45, 0.28), 0.0],
		[Vector3(0, 0.9, 0), Vector3(1.54, 0.04, 0.64), Color(0.85, 0.82, 0.75), 0.0]],
	"cash_register": [[Vector3(0, 0.1, 0), Vector3(0.4, 0.2, 0.4), Color(0.35, 0.36, 0.38), 0.0],
		[Vector3(0, 0.25, -0.1), Vector3(0.3, 0.1, 0.12), Color(0.25, 0.25, 0.27), 0.0]],
	"scale_analog": [[Vector3(0, 0.12, 0), Vector3(0.3, 0.24, 0.28), Color(0.85, 0.2, 0.18), 0.0]],
	"tv_crt": [[Vector3(0, 0.35, 0), Vector3(0.6, 0.7, 0.45), Color(0.3, 0.22, 0.15), 0.0],
		[Vector3(0, 0.93, 0), Vector3(0.56, 0.46, 0.46), Color(0.2, 0.2, 0.2), 0.0],
		[Vector3(0, 0.95, 0.235), Vector3(0.44, 0.33, 0.02), Color(0.55, 0.75, 1.0), 2.5]],
	"wall_clock": [[Vector3(0, 0.0, 0), Vector3(0.34, 0.34, 0.05), Color(0.9, 0.88, 0.8), 0.0]],
	"storage_cabinet": [[Vector3(0, 0.95, 0), Vector3(0.9, 1.9, 0.45), Color(0.55, 0.6, 0.55), 0.0]],
	"upright_fridge": [[Vector3(0, 0.95, 0), Vector3(0.7, 1.9, 0.7), Color(0.9, 0.9, 0.88), 0.0]],
	"chest_freezer": [[Vector3(0, 0.42, 0), Vector3(1.3, 0.85, 0.65), Color(0.88, 0.88, 0.86), 0.0]],
	"water_cooler": [[Vector3(0, 0.45, 0), Vector3(0.33, 0.9, 0.33), Color(0.85, 0.85, 0.85), 0.0],
		[Vector3(0, 1.05, 0), Vector3(0.26, 0.32, 0.26), Color(0.4, 0.6, 0.85), 0.0]],
	"wire_display_rack": [[Vector3(0, 0.75, 0), Vector3(0.5, 1.5, 0.5), Color(0.55, 0.55, 0.58), 0.0]],
	"shopping_cart": [[Vector3(0, 0.75, 0), Vector3(0.55, 0.45, 0.9), Color(0.6, 0.6, 0.62), 0.0],
		[Vector3(0, 0.25, 0), Vector3(0.5, 0.08, 0.8), Color(0.3, 0.3, 0.32), 0.0]],
	"shopping_basket": [[Vector3(0, 0.11, 0), Vector3(0.45, 0.22, 0.32), Color(0.8, 0.15, 0.15), 0.0]],
	"plastic_chair": [[Vector3(0, 0.22, 0), Vector3(0.45, 0.44, 0.45), Color(0.92, 0.92, 0.9), 0.0],
		[Vector3(0, 0.66, -0.2), Vector3(0.45, 0.44, 0.05), Color(0.92, 0.92, 0.9), 0.0]],
	"step_ladder": [[Vector3(0, 0.75, 0), Vector3(0.5, 1.5, 0.15), Color(0.7, 0.72, 0.75), 0.0]],
	"bottle_crate": [[Vector3(0, 0.13, 0), Vector3(0.45, 0.26, 0.32), Color(0.75, 0.15, 0.12), 0.0]],
	"market_crate": [[Vector3(0, 0.14, 0), Vector3(0.5, 0.28, 0.35), Color(0.7, 0.55, 0.35), 0.0]],
	"carton": [[Vector3(0, 0.17, 0), Vector3(0.4, 0.34, 0.33), Color(0.62, 0.5, 0.32), 0.0]],
	"foam_cooler": [[Vector3(0, 0.24, 0), Vector3(0.67, 0.48, 0.44), Color(0.85, 0.85, 0.82), 0.0]],
}


## Places a prop from KIT (named by the last part of `path`, e.g. "furniture/shelf_metal") at pos, turned by yaw.
func prop(parent: Node, path: String, pos: Vector3, yaw := 0.0) -> Node3D:
	var n := Node3D.new()
	n.name = path.get_file().to_pascal_case()
	for part in KIT[path.get_file()]:
		var b := box(n, part[0], part[1], part[2])
		if part[3] != 0.0:
			var mat := b.material_override as StandardMaterial3D
			mat.emission_enabled = true
			mat.emission = part[2]
			mat.emission_energy_multiplier = absf(part[3])
			if part[3] < 0.0:
				b.set_meta("rc_skip", true) # a glowing tube whose light is a lamp already: not part of the voxels
	n.position = pos
	n.rotation.y = yaw
	parent.add_child(n)
	if parent == main.static_root:
		selectables.append(n)
	return n


func box(parent: Node, pos: Vector3, size: Vector3, color: Color, yaw := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	mi.material_override = mat
	mi.position = pos
	mi.rotation.y = yaw
	parent.add_child(mi)
	return mi


## An invisible box the GI uses for something that moves (the visible mesh is not a box).
func proxy(parent: Node, pos: Vector3, size: Vector3, color: Color) -> void:
	var mi := box(parent, pos, size, color)
	mi.visible = false
	mi.set_meta("rc_proxy", true)


func checker_floor(parent: Node, half_x: float, half_z: float, tile: float, c1: Color, c2: Color) -> void:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var nx := int(round(half_x * 2.0 / tile))
	var nz := int(round(half_z * 2.0 / tile))
	for i in nx:
		for j in nz:
			var x0 := -half_x + i * tile
			var z0 := -half_z + j * tile
			var base := verts.size()
			verts.append_array([Vector3(x0, 0, z0), Vector3(x0 + tile, 0, z0), Vector3(x0 + tile, 0, z0 + tile), Vector3(x0, 0, z0 + tile)])
			var c := c1 if (i + j) % 2 == 0 else c2
			cols.append_array([c, c, c, c])
			norms.append_array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
			# Godot front faces are clockwise.
			idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.6
	mi.material_override = mat
	mi.set_meta("rc_albedo", c1.lerp(c2, 0.5)) # the voxels use the average of the checker
	parent.add_child(mi)


# --- the plan: walls, floors and ceilings --------------------------------------------------------------
#
# Rooms are declared with room(), openings with opening() and fill(); build_plan() then paints them on the grid in a fixed
# order and emits one box per solid interval of every maximal rectangle of equal cells:
#
#   1. every wall of every room, WALL thick (a corner belongs to both walls, so nothing is left open);
#   2. every room repaints the inner half of its own walls, so a wall between two rooms has each room's colour on its side;
#   3. the band strip (CELL deep) on the walls of rooms that have one: flush with the wall, nothing stuck on it;
#   4. the inside of every room: floor slab and ceiling slab;
#   5. the openings, cut through whatever is there (jambs, sill and lintel come out of the wall itself).
#
# Boxes never overlap and neighbouring faces meet edge to edge, so nothing z-fights and nothing is left open.

## A room: its inside (x0..x1, z0..z1), a colour per walled side ("n" = +z, "s" = -z, "e" = +x, "w" = -x; a side with no entry has
## no wall of its own: open, or closed by another room's wall), floor and ceiling colours, and an optional band colour.
func room(x0: float, z0: float, x1: float, z1: float, walls: Dictionary, floor_c: Color, ceil_c: Color, band: Variant = null,
		floor_top := 0.0) -> void:
	_rooms.append({"r": [x0, z0, x1, z1], "walls": walls, "floor": floor_c, "ceil": ceil_c, "band": band, "floor_top": floor_top})


var _openings: Array = []


## A hole through the walls in x0..x1, z0..z1 from y0 to y1. below / above recolour what is left under and over it (a sill, a
## lintel); null keeps the wall's colour.
func opening(x0: float, z0: float, x1: float, z1: float, y0: float, y1: float, below: Variant = null, above: Variant = null) -> void:
	_openings.append(["cut", [x0, z0, x1, z1], y0, y1, below, above])


## Replaces what is in x0..x1, z0..z1 with a plain floor and ceiling (a passage through a wall, full height).
func passage(x0: float, z0: float, x1: float, z1: float, floor_c: Color, ceil_c: Color) -> void:
	_openings.append(["fill", [x0, z0, x1, z1], [[FLOOR_Y, 0.0, floor_c], [CEIL, ROOF_Y, ceil_c]]])


func _pid(intervals: Array) -> int:
	var sorted := intervals.duplicate()
	sorted.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for iv in sorted:
		if iv[1] - iv[0] < 0.001:
			continue
		if not out.is_empty() and absf(out[-1][1] - iv[0]) < 0.001 and out[-1][2] == iv[2]:
			out[-1] = [out[-1][0], iv[1], iv[2]]
		else:
			out.append(iv)
	var key := str(out)
	if not _profile_ids.has(key):
		_profile_ids[key] = _profiles.size()
		_profiles.append(out)
	return _profile_ids[key]


func _cell_range(r: Array) -> Array:
	var i0 := roundi((r[0] - VOLUME_MIN.x) / CELL)
	var i1 := roundi((r[2] - VOLUME_MIN.x) / CELL)
	var j0 := roundi((r[1] - VOLUME_MIN.z) / CELL)
	var j1 := roundi((r[3] - VOLUME_MIN.z) / CELL)
	assert(i0 >= 0 and j0 >= 0 and i1 <= GRID_NX and j1 <= GRID_NZ, "plan rectangle outside the grid: %s" % [r])
	return [i0, j0, i1, j1]


func _fill(r: Array, pid: int) -> void:
	var c := _cell_range(r)
	for j in range(c[1], c[3]):
		for i in range(c[0], c[2]):
			_cells[j * GRID_NX + i] = pid


func _cut(r: Array, y0: float, y1: float, below: Variant, above: Variant) -> void:
	var c := _cell_range(r)
	var memo := {}
	for j in range(c[1], c[3]):
		for i in range(c[0], c[2]):
			var k := j * GRID_NX + i
			var p := _cells[k]
			if not memo.has(p):
				var out: Array = []
				for iv in _profiles[p]:
					if iv[1] <= y0 or iv[0] >= y1:
						out.append(iv)
						continue
					if iv[0] < y0:
						out.append([iv[0], y0, below if below != null else iv[2]])
					if iv[1] > y1:
						out.append([y1, iv[1], above if above != null else iv[2]])
				memo[p] = _pid(out)
			_cells[k] = memo[p]


## The strip of a room's side `side` that is t deep into the wall, reaching into the corners where the next side has a wall too.
func _side_rect(rm: Dictionary, side: String, t: float) -> Array:
	var r: Array = rm["r"]
	var w: Dictionary = rm["walls"]
	var xw := t if w.has("w") else 0.0
	var xe := t if w.has("e") else 0.0
	var zs := t if w.has("s") else 0.0
	var zn := t if w.has("n") else 0.0
	match side:
		"s":
			return [r[0] - xw, r[1] - t, r[2] + xe, r[1]]
		"n":
			return [r[0] - xw, r[3], r[2] + xe, r[3] + t]
		"w":
			return [r[0] - t, r[1] - zs, r[0], r[3] + zn]
		_:
			return [r[2], r[1] - zs, r[2] + t, r[3] + zn]


func build_plan(parent: Node) -> void:
	_cells.resize(GRID_NX * GRID_NZ)
	_cells.fill(0)
	for rm in _rooms:
		for side in rm["walls"]:
			_fill(_side_rect(rm, side, WALL), _pid([[FLOOR_Y, ROOF_Y, rm["walls"][side]]]))
	for rm in _rooms:
		for side in rm["walls"]:
			_fill(_side_rect(rm, side, WALL * 0.5), _pid([[FLOOR_Y, ROOF_Y, rm["walls"][side]]]))
	for rm in _rooms:
		if rm["band"] != null:
			for side in rm["walls"]:
				_fill(_side_rect(rm, side, CELL), _pid([[FLOOR_Y, BAND_H, rm["band"]], [BAND_H, ROOF_Y, rm["walls"][side]]]))
	for rm in _rooms:
		_fill(rm["r"], _pid([[FLOOR_Y, rm["floor_top"], rm["floor"]], [CEIL, ROOF_Y, rm["ceil"]]]))
	for op in _openings:
		if op[0] == "cut":
			_cut(op[1], op[2], op[3], op[4], op[5])
		else:
			_fill(op[1], _pid(op[2]))
	# Maximal rectangles of equal cells (greedy: grow along x, then along z), one box per solid interval.
	var used := PackedByteArray()
	used.resize(_cells.size())
	var n := 0
	for j in GRID_NZ:
		for i in GRID_NX:
			var k := j * GRID_NX + i
			var p := _cells[k]
			if p == 0 or used[k] == 1:
				continue
			var i1 := i + 1
			while i1 < GRID_NX and _cells[j * GRID_NX + i1] == p and used[j * GRID_NX + i1] == 0:
				i1 += 1
			var j1 := j + 1
			while j1 < GRID_NZ:
				var row_ok := true
				for ii in range(i, i1):
					if _cells[j1 * GRID_NX + ii] != p or used[j1 * GRID_NX + ii] == 1:
						row_ok = false
						break
				if not row_ok:
					break
				j1 += 1
			for jj in range(j, j1):
				for ii in range(i, i1):
					used[jj * GRID_NX + ii] = 1
			var x0 := VOLUME_MIN.x + i * CELL
			var x1 := VOLUME_MIN.x + i1 * CELL
			var z0 := VOLUME_MIN.z + j * CELL
			var z1 := VOLUME_MIN.z + j1 * CELL
			for iv in _profiles[p]:
				var b := box(parent, Vector3((x0 + x1) * 0.5, (iv[0] + iv[1]) * 0.5, (z0 + z1) * 0.5),
					Vector3(x1 - x0, iv[1] - iv[0], z1 - z0), iv[2])
				b.name = "Plan%d" % n
				b.set_meta("arch", true)
				n += 1


func ceiling_light(parent: Node, pos: Vector3, shadows := true) -> OmniLight3D:
	prop(parent, "electronics/fluorescent_fixture", Vector3(pos.x, CEIL - 0.06, pos.z))
	var l := OmniLight3D.new()
	l.position = Vector3(pos.x, CEIL - 0.25, pos.z)
	l.light_color = Color(0.82, 1.0, 0.88)
	l.light_energy = 4.0
	l.omni_range = 9.0
	l.omni_attenuation = 2.0
	l.shadow_enabled = shadows
	l.shadow_blur = 1.5
	parent.add_child(l)
	return l


## One gondola shelf with products on its four levels. facing = 0 looks to +z, PI to -z.
func gondola(parent: Node, pos: Vector3, yaw: float, stock: bool) -> void:
	prop(parent, "furniture/shelf_metal", pos, yaw)
	if not stock:
		return
	var products := [
		["products/biscuit_pack", 0.30], ["products/rice_pack", 0.20], ["products/guarana_2l", 0.12],
		["products/grocery_tins", 0.30], ["products/cooking_oil", 0.10], ["products/washing_powder", 0.21]]
	var levels := [0.235, 0.651, 1.067, 1.483]
	var basis := Basis(Vector3.UP, yaw)
	for y in levels:
		var pr: Array = products[rng.randi() % products.size()]
		var n := int(floor(0.86 / float(pr[1])))
		for k in n:
			var lx := -0.43 + (k + 0.5) * (0.86 / n)
			var local := Vector3(lx, y, 0.06 + rng.randf_range(-0.03, 0.03))
			prop(parent, pr[0], pos + basis * local, yaw + rng.randf_range(-0.12, 0.12))


func build(m: Node3D) -> void:
	main = m
	rng.seed = 1999
	var S: Node3D = m.static_root
	var D: Node3D = m.dyn_root
	var paint := Color(0.66, 0.74, 0.62)
	var cream := Color(0.82, 0.78, 0.66)

	# The building. The store's floor slab stops 2 cm short of the top: the checker floor is the surface there.
	var walls := Node3D.new()
	walls.name = "Building"
	S.add_child(walls)
	var slab := Color(0.5, 0.47, 0.4)
	plan_corridor_and_rooms() # first: the store's walls are painted last, so its colour wins at the jambs of its passage
	room(-ROOM_X, -ROOM_Z, ROOM_X, ROOM_Z, {"n": paint, "s": paint, "e": paint, "w": paint}, slab, cream,
		Color(0.32, 0.45, 0.4), -0.02)
	checker_floor(walls, ROOM_X, ROOM_Z, 0.5, Color(0.66, 0.62, 0.5), Color(0.38, 0.34, 0.28))
	opening(-5.4, ROOM_Z, -3.4, ROOM_Z + WALL, 0.9, 2.4) # windows
	opening(-2.2, ROOM_Z, -0.2, ROOM_Z + WALL, 0.9, 2.4)
	opening(3.4, ROOM_Z, 4.6, ROOM_Z + WALL, 0.0, 2.2, slab) # the street door
	build_plan(walls)
	build_bend(walls)

	# Lights: six ceiling fluorescents and a sodium street lamp outside the windows.
	var xs := [-4.5, 0.0, 4.5]
	var zs := [-1.8, 2.2]
	for x in xs:
		for z in zs:
			var l := ceiling_light(S, Vector3(x, 0, z))
			ceiling_lights.append(l)
	var street := OmniLight3D.new()
	street.position = Vector3(-2.8, 4.2, 7.5)
	street.light_color = Color(1.0, 0.62, 0.28)
	street.light_energy = 60.0
	street.omni_range = 16.0
	street.omni_attenuation = 2.0
	street.shadow_enabled = true
	S.add_child(street)
	street_lamp = street

	# Daylight (off by default): a sun that comes in through the windows.
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, 8.0, 0.0)
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.light_energy = 0.0
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	S.add_child(sun)

	# The corridor, and an optional lamp inside it (off by default) to see light travel the other way.
	build_corridor(S)
	build_rooms(S, D)
	corridor_lamp = OmniLight3D.new()
	corridor_lamp.position = Vector3(cor_path(COR_A + COR_R * PI * 0.25)[0]) + Vector3(0, 2.7, 0)
	corridor_lamp.light_color = Color(1.0, 0.8, 0.5)
	corridor_lamp.light_energy = 0.0
	corridor_lamp.omni_range = 10.0
	corridor_lamp.omni_attenuation = 2.0
	corridor_lamp.shadow_enabled = true
	S.add_child(corridor_lamp)

	# Back wall: shelving along it, counter with register, scale and clock at the right.
	for i in 5:
		gondola(S, Vector3(-6.2 + i * 1.0, 0, -ROOM_Z + 0.26), 0.0, true)
	prop(S, "furniture/formica_counter", Vector3(3.3, 0, -3.7), 0.0)
	prop(S, "furniture/formica_counter", Vector3(4.85, 0, -3.7), 0.0)
	prop(S, "props/cash_register", Vector3(3.0, 0.92, -3.7), 0.2)
	prop(S, "props/scale_analog", Vector3(4.85, 0.92, -3.65), -0.3)
	prop(S, "electronics/tv_crt", Vector3(2.0, 0.0, -4.35))
	prop(S, "props/wall_clock", Vector3(3.9, 2.5, -ROOM_Z + 0.03), 0.0)
	prop(S, "furniture/storage_cabinet", Vector3(0.2, 0, -4.45), 0.0)

	# Island gondolas, back to back, in two rows.
	for i in 4:
		gondola(S, Vector3(-4.5 + i * 1.0, 0, -1.25), 0.0, true)
		gondola(S, Vector3(-4.5 + i * 1.0, 0, -1.75), PI, true)
	for i in 3:
		gondola(S, Vector3(-4.0 + i * 1.0, 0, 2.0), 0.0, true)
		gondola(S, Vector3(-4.0 + i * 1.0, 0, 1.5), PI, true)

	# Right wall: fridges and freezers facing the room.
	prop(S, "furniture/upright_fridge", Vector3(ROOM_X - 0.45, 0, -2.4), -PI * 0.5)
	prop(S, "furniture/upright_fridge", Vector3(ROOM_X - 0.45, 0, -1.65), -PI * 0.5)
	prop(S, "furniture/chest_freezer", Vector3(ROOM_X - 0.5, 0, -0.2), -PI * 0.5)
	prop(S, "furniture/chest_freezer", Vector3(ROOM_X - 0.5, 0, 1.2), -PI * 0.5)
	prop(S, "furniture/water_cooler", Vector3(ROOM_X - 0.3, 0, 2.6), -PI * 0.5)

	# Near the entrance: display racks, a parked cart, baskets, chairs, a stepladder, crates and cartons.
	prop(S, "furniture/wire_display_rack", Vector3(2.4, 0, 3.8), 0.4)
	prop(S, "furniture/wire_display_rack", Vector3(1.4, 0, 3.9), -0.2)
	prop(S, "props/shopping_cart", Vector3(5.6, 0, 3.0), 0.5)
	prop(S, "props/shopping_basket", Vector3(5.9, 0, 3.9), 0.2)
	prop(S, "props/shopping_basket", Vector3(5.9, 0.44, 3.9), 0.5)
	prop(S, "furniture/plastic_chair", Vector3(-6.2, 0, 3.6), 0.6)
	prop(S, "furniture/plastic_chair", Vector3(-5.5, 0, 3.9), -0.3)
	prop(S, "props/step_ladder", Vector3(-6.3, 0, -3.4), 1.2)
	for k in 3:
		prop(S, "props/bottle_crate", Vector3(1.0, k * 0.26, -3.2), 0.1 * k)
	prop(S, "props/market_crate", Vector3(1.0, 0.0, -2.6), 0.3)
	prop(S, "props/market_crate", Vector3(1.05, 0.28, -2.6), -0.2)
	prop(S, "props/carton", Vector3(-1.0, 0.0, -4.3), 0.2)
	prop(S, "props/carton", Vector3(-1.0, 0.34, -4.3), -0.3)
	prop(S, "props/foam_cooler", Vector3(5.3, 0.0, -2.2), 0.4)

	# The dolly (dynamic): a board with two cartons and a foam cooler, a work lamp on top. It is a Node3D that
	# main.gd slides along the central aisle; its BoxMesh parts are what the GI voxelizes every frame.
	dolly = Node3D.new()
	dolly.name = "Dolly"
	D.add_child(dolly)
	var wood := Color(0.55, 0.4, 0.25)
	var board := box(dolly, Vector3(0, 0.12, 0), Vector3(0.9, 0.08, 0.6), wood)
	board.name = "DollyBoard"
	box(dolly, Vector3(-0.25, 0.16 + 0.17, 0.0), Vector3(0.4, 0.34, 0.33), Color(0.62, 0.5, 0.32))
	box(dolly, Vector3(-0.25, 0.5 + 0.17, 0.0), Vector3(0.4, 0.34, 0.33), Color(0.62, 0.5, 0.32))
	box(dolly, Vector3(0.3, 0.16 + 0.24, 0.0), Vector3(0.67, 0.48, 0.44), Color(0.85, 0.85, 0.82))
	dolly_lamp = OmniLight3D.new()
	dolly_lamp.position = Vector3(0, 1.7, 0)
	dolly_lamp.light_color = Color(1.0, 0.85, 0.6)
	dolly_lamp.light_energy = 7.0
	dolly_lamp.omni_range = 9.0
	dolly_lamp.omni_attenuation = 2.0
	dolly_lamp.shadow_enabled = true
	dolly_lamp.shadow_blur = 1.6
	dolly.add_child(dolly_lamp)
	dolly_bulb = box(dolly, Vector3(0, 1.7, 0), Vector3(0.18, 0.18, 0.18), Color(1.0, 0.85, 0.6))
	var bm := dolly_bulb.material_override as StandardMaterial3D
	bm.emission_enabled = true
	bm.emission = Color(1.0, 0.85, 0.6)
	bm.emission_energy_multiplier = 6.0
	dolly_bulb.set_meta("rc_skip", true)
	dolly_bulb.name = "DollyBulb"

	m._make_env(Color(0.0, 0.0, 0.0), Color(0.5, 0.55, 0.8), 0.02, 1.0)
	m._make_camera(78.0)
	poses = {
		"entrance": [Vector3(4.0, 1.6, 4.2), Vector3(-2.5, 1.3, -1.8)],
		"aisle": [Vector3(-6.4, 1.55, 0.3), Vector3(5.0, 1.2, 0.3)],
		"counter": [Vector3(0.8, 1.6, 0.9), Vector3(3.6, 1.0, -3.7)],
		"island": [Vector3(-1.2, 1.5, 0.4), Vector3(-3.2, 1.1, -1.5)],
		"dolly": [Vector3(-1.2, 1.3, 2.6), Vector3(0.6, 0.6, 0.3)],
		"corridor_mouth": [Vector3(-4.2, 1.6, 0.3), Vector3(-12.0, 1.3, 0.3)],
		"corridor_bend": [Vector3(cor_path(9.0)[0]) + Vector3(0, 1.6, 0), Vector3(cor_path(15.5)[0]) + Vector3(0, 1.3, 0)],
		"materials": [Vector3(-7.9, 1.55, -1.9), Vector3(-11.2, 0.6, -4.1)],
		"glass": [Vector3(-11.6, 1.5, -1.9), Vector3(-7.95, 1.0, -3.5)],
		"tv_room": [Vector3(-13.5, 1.45, -1.9), Vector3(-17.6, 0.75, -3.3)],
		"corridor_neon": [Vector3(cor_path(COR_A + COR_R * PI * 0.5 + 1.5)[0]) + Vector3(0, 1.6, 0), Vector3(cor_path(COR_A + COR_R * PI * 0.5 + COR_B - 2.0)[0]) + Vector3(0, 1.4, 0)],
		"corridor_end": [Vector3(cor_path(COR_A + COR_R * PI * 0.5 + 5.5)[0]) + Vector3(0, 1.6, 0), Vector3(cor_path(COR_A + 1.0)[0]) + Vector3(0, 1.2, 0)],
	}


## Dolly position along the aisle for u in 0..1 and the live light settings.
func animate(u: float, _t: float) -> void:
	dolly.position = Vector3(lerpf(-5.2, 4.6, u), 0.0, 0.3)
	for l in ceiling_lights:
		l.light_energy = 4.0 * ceiling_scale
	street_lamp.light_energy = street_energy
	materials_lamp.light_energy = materials_lamp_energy
	# The television: its picture changes colour slowly (a cross-fade every few seconds, never a flash).
	var screen_mat := tv_screen.material_override as StandardMaterial3D
	var c := TV_COLORS[0]
	if tv_animate:
		var ph := _t / 3.5
		var k := int(floor(ph))
		c = TV_COLORS[k % TV_COLORS.size()].lerp(TV_COLORS[(k + 1) % TV_COLORS.size()], smoothstep(0.6, 1.0, ph - floor(ph)))
	screen_mat.albedo_color = c
	screen_mat.emission = c
	corridor_lamp.light_energy = corridor_lamp_energy
	sun.light_energy = sun_energy


# --- the two rooms south of the corridor ----------------------------------------------------------------

const TV_COLORS: Array[Color] = [Color(0.55, 0.7, 1.0), Color(1.0, 0.95, 0.85), Color(0.35, 0.9, 0.55), Color(1.0, 0.45, 0.3), Color(0.65, 0.5, 1.0)]


func sphere(parent: Node, pos: Vector3, radius: float, color: Color, metallic: float, roughness: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 48
	sm.rings = 24
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metallic
	mat.roughness = roughness
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


const COR_FLOOR := Color(0.45, 0.42, 0.38)
const COR_CEIL := Color(0.72, 0.72, 0.7)
const COR_RIGHT := Color(0.78, 0.3, 0.24) # the outside of the turn
const COR_LEFT := Color(0.2, 0.52, 0.56) # the inside of the turn


## The two straight runs of the corridor, the two rooms south of it, and their doors (the bend is build_bend()).
func plan_corridor_and_rooms() -> void:
	var grey := Color(0.72, 0.72, 0.7)
	var blue := Color(0.25, 0.35, 0.7)
	var room_floor := Color(0.42, 0.42, 0.42)
	var room_ceil := Color(0.6, 0.6, 0.58)
	var hw := COR_W * 0.5
	var x_bend := -ROOM_X - COR_A
	room(DIVIDER_X + WALL, -ROOM_Z, -ROOM_X - WALL, MAT_Z1, {"s": grey, "w": blue, "n": grey, "e": grey}, room_floor, room_ceil)
	room(DARK_X0, -ROOM_Z, DIVIDER_X, DARK_Z1, {"s": grey, "w": grey, "n": grey, "e": blue}, room_floor, room_ceil)
	# First run: from the store's wall to the bend. Second run: from the bend to the closed far end.
	room(x_bend, COR_Z - hw, -ROOM_X - WALL, COR_Z + hw, {"s": COR_RIGHT, "n": COR_LEFT}, COR_FLOOR, COR_CEIL)
	var xc := x_bend - COR_R
	room(xc - hw, COR_Z + COR_R, xc + hw, COR_Z + COR_R + COR_B, {"w": COR_RIGHT, "e": COR_LEFT, "n": Color(0.6, 0.6, 0.58)},
		COR_FLOOR, COR_CEIL)
	passage(-ROOM_X - WALL, COR_Z - hw, -ROOM_X, COR_Z + hw, COR_FLOOR, COR_CEIL) # through the store's left wall
	opening(-ROOM_X - DOOR_S1, MAT_Z1, -ROOM_X - DOOR_S0, MAT_Z1 + WALL, 0.0, 2.2, room_floor) # corridor -> materials room
	# Between the rooms, near the south wall (so little of the materials room's light gets into the dark room).
	opening(DIVIDER_X, -ROOM_Z + 0.15, DIVIDER_X + WALL, -ROOM_Z + 1.05, 0.0, 2.1, room_floor)


## The bend: the corridor's cross-section (the same walls, floor and ceiling as the straight runs) swept round a quarter
## circle, with smooth curved faces. Its two ends meet the straight runs face to face.
func build_bend(parent: Node) -> void:
	var hw := COR_W * 0.5
	var columns := [
		[-hw - WALL, -hw, [[FLOOR_Y, ROOF_Y, COR_LEFT]]],
		[-hw, hw, [[FLOOR_Y, 0.0, COR_FLOOR], [CEIL, ROOF_Y, COR_CEIL]]],
		[hw, hw + WALL, [[FLOOR_Y, ROOF_Y, COR_RIGHT]]]]
	var centre := Vector3(-ROOM_X - COR_A, 0.0, COR_Z + COR_R)
	var segs := 64
	var surf := {} # colour -> [verts, normals, indices]
	for col in columns:
		var ra: float = COR_R + col[0]
		var rb: float = COR_R + col[1]
		for iv in col[2]:
			var y0: float = iv[0]
			var y1: float = iv[1]
			if not surf.has(iv[2]):
				surf[iv[2]] = [PackedVector3Array(), PackedVector3Array(), PackedInt32Array()]
			var s: Array = surf[iv[2]]
			for k in segs:
				var t0 := PI * 0.5 * k / segs
				var t1 := PI * 0.5 * (k + 1) / segs
				var d0 := Vector3(-sin(t0), 0.0, -cos(t0)) # outwards from the centre of the bend
				var d1 := Vector3(-sin(t1), 0.0, -cos(t1))
				var y0v := Vector3(0, y0, 0)
				var y1v := Vector3(0, y1, 0)
				_quad(s, [centre + d0 * rb + y0v, centre + d1 * rb + y0v, centre + d1 * rb + y1v, centre + d0 * rb + y1v], [d0, d1, d1, d0])
				_quad(s, [centre + d0 * ra + y0v, centre + d1 * ra + y0v, centre + d1 * ra + y1v, centre + d0 * ra + y1v], [-d0, -d1, -d1, -d0])
				_quad(s, [centre + d0 * ra + y1v, centre + d1 * ra + y1v, centre + d1 * rb + y1v, centre + d0 * rb + y1v], [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
				_quad(s, [centre + d0 * ra + y0v, centre + d1 * ra + y0v, centre + d1 * rb + y0v, centre + d0 * rb + y0v], [Vector3.DOWN, Vector3.DOWN, Vector3.DOWN, Vector3.DOWN])
			# End caps: hidden against the straight runs, but they close each piece, so the GI can fill its inside.
			for t in [0.0, PI * 0.5]:
				var d := Vector3(-sin(t), 0.0, -cos(t))
				var cap_n := Vector3(cos(t), 0.0, -sin(t)) * (1.0 if t == 0.0 else -1.0)
				_quad(s, [centre + d * ra + Vector3(0, y0, 0), centre + d * rb + Vector3(0, y0, 0), centre + d * rb + Vector3(0, y1, 0),
					centre + d * ra + Vector3(0, y1, 0)], [cap_n, cap_n, cap_n, cap_n])
	for color in surf:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = surf[color][0]
		arrays[Mesh.ARRAY_NORMAL] = surf[color][1]
		arrays[Mesh.ARRAY_INDEX] = surf[color][2]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.name = "Bend"
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.95
		mi.material_override = mat
		parent.add_child(mi)


## Appends a quad (4 corners in order round it) facing along its vertex normals. Godot treats clockwise triangles as front faces.
func _quad(s: Array, v: Array, nrm: Array) -> void:
	var base: int = s[0].size()
	for k in 4:
		s[0].append(v[k])
		s[1].append(nrm[k])
	var face_n: Vector3 = nrm[0] + nrm[1] + nrm[2] + nrm[3]
	var tri_n: Vector3 = (v[1] - v[0]).cross(v[2] - v[0])
	if tri_n.dot(face_n) < 0.0:
		s[2].append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	else:
		s[2].append_array([base, base + 2, base + 1, base, base + 3, base + 2])


func build_rooms(S: Node3D, D: Node3D) -> void:
	# --- Materials room: one lamp; spheres of chrome, gold, glossy plastic and rough plaster; a glass pane; a copper box.
	prop(S, "electronics/fluorescent_fixture", Vector3(-10.0, CEIL - 0.06, -3.1))
	materials_lamp = OmniLight3D.new()
	materials_lamp.position = Vector3(-10.0, CEIL - 0.3, -3.1)
	materials_lamp.light_color = Color(1.0, 0.95, 0.88)
	materials_lamp.light_energy = materials_lamp_energy
	materials_lamp.omni_range = 8.0
	materials_lamp.omni_attenuation = 2.0
	materials_lamp.shadow_enabled = true
	S.add_child(materials_lamp)
	var pedestal := Color(0.82, 0.82, 0.8)
	var specs := [
		[-11.9, Color(0.92, 0.92, 0.94), 1.0, 0.08, "Chrome"],
		[-10.7, Color(1.0, 0.78, 0.36), 1.0, 0.35, "Gold"],
		[-9.5, Color(0.8, 0.08, 0.06), 0.0, 0.08, "GlossyPlastic"],
		[-8.3, Color(0.85, 0.85, 0.83), 0.0, 1.0, "RoughPlaster"]]
	for sp in specs:
		box(S, Vector3(sp[0], 0.25, -4.1), Vector3(0.55, 0.5, 0.55), pedestal)
		sphere(S, Vector3(sp[0], 0.5 + 0.3, -4.1), 0.3, sp[1], sp[2], sp[3]).name = sp[4] + "Sphere"
	var copper := box(S, Vector3(-12.1, 0.3, -2.2), Vector3(0.6, 0.6, 0.6), Color(0.95, 0.6, 0.45), 0.4)
	(copper.material_override as StandardMaterial3D).metallic = 1.0
	(copper.material_override as StandardMaterial3D).roughness = 0.45
	copper.name = "CopperBox"
	# A tinted glass pane: Godot's light goes through it (it casts no shadow) and so does the bounce (see-through materials are
	# not voxelized).
	var glass := box(S, Vector3(-7.95, 1.1, -3.25), Vector3(0.04, 2.2, 2.0), Color(0.6, 0.8, 1.0, 0.25))
	var gm := glass.material_override as StandardMaterial3D
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.roughness = 0.05
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glass.name = "GlassPane"

	# --- Dark room: no lamp. A television on a stand, a sofa facing it, a rug and a low table.
	box(S, Vector3(-17.9, 0.25, -3.1), Vector3(0.5, 0.5, 0.9), Color(0.35, 0.25, 0.18)) # stand
	box(S, Vector3(-17.85, 0.76, -3.1), Vector3(0.45, 0.52, 0.66), Color(0.12, 0.12, 0.12)) # television body
	box(S, Vector3(-14.4, 0.225, -3.1), Vector3(0.9, 0.45, 1.9), Color(0.72, 0.64, 0.52)) # sofa seat
	box(S, Vector3(-13.95, 0.7, -3.1), Vector3(0.25, 0.55, 2.0), Color(0.72, 0.64, 0.52)) # sofa back
	box(S, Vector3(-16.0, 0.01, -3.1), Vector3(2.4, 0.02, 1.6), Color(0.45, 0.15, 0.12)) # rug
	box(S, Vector3(-15.6, 0.2, -3.1), Vector3(0.5, 0.4, 0.9), Color(0.5, 0.36, 0.22)) # low table
	# The picture: a moving box (re-voxelized every frame like the dolly) so its changing colour lights the room at once.
	tv_screen = box(D, Vector3(-17.615, 0.78, -3.1), Vector3(0.02, 0.38, 0.54), TV_COLORS[0])
	var tm := tv_screen.material_override as StandardMaterial3D
	tm.emission_enabled = true
	tm.emission = TV_COLORS[0]
	tm.emission_energy_multiplier = 3.0
	tv_screen.name = "TvScreen"


# --- the corridor ------------------------------------------------------------------------------------

## Point and heading of the corridor centreline at distance s from the opening.
func cor_path(s: float) -> Array:
	var arc := COR_R * PI * 0.5
	s = clampf(s, 0.0, COR_A + arc + COR_B)
	if s <= COR_A:
		return [Vector3(-ROOM_X - s, 0, COR_Z), Vector3(-1, 0, 0)]
	s -= COR_A
	if s <= arc:
		var th := s / COR_R
		var cx := -ROOM_X - COR_A
		return [Vector3(cx - COR_R * sin(th), 0, COR_Z + COR_R - COR_R * cos(th)), Vector3(-cos(th), 0, sin(th))]
	s -= arc
	return [Vector3(-ROOM_X - COR_A - COR_R, 0, COR_Z + COR_R + s), Vector3(0, 0, 1)]


## The corridor's fittings (its walls, floor and ceiling are part of the plan and the bend).
func build_corridor(parent: Node) -> void:
	var hw := COR_W * 0.5
	var up := Vector3.UP
	# A neon sign near the far end, the only light of that part of the corridor: it lights its surroundings through the bounce alone.
	var ns := COR_A + COR_R * PI * 0.5 + COR_B - 2.0
	var np := cor_path(ns)
	var nr: Vector3 = (np[1] as Vector3).cross(Vector3.UP)
	var neon := box(parent, (np[0] as Vector3) - nr * (hw - 0.025) + up * 2.2, Vector3(0.05, 0.12, 1.2), Color(1.0, 0.25, 0.6),
		atan2(-(np[1] as Vector3).x, -(np[1] as Vector3).z))
	var nm := neon.material_override as StandardMaterial3D
	nm.emission_enabled = true
	nm.emission = Color(1.0, 0.25, 0.6)
	nm.emission_energy_multiplier = 4.0
	neon.name = "NeonSign"
