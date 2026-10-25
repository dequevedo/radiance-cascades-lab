extends RefCounted
## A small grocery store built from simple box props (no external assets).
## Room 14 x 9.5 m, ceiling 3.4 m: front wall with two windows and a door, six ceiling fluorescents,
## a street lamp outside, gondolas stocked with products, a counter with a register, fridges and freezers,
## and a dolly of cartons (dynamic: moves, carries a work lamp) driven along the central aisle.
##
## Everything static goes under main.static_root (voxelized once), everything that moves under main.dyn_root
## (voxelized every frame as boxes).

const ROOM_X := 7.0
const ROOM_Z := 4.75
const CEIL := 3.4
const WALL := 0.3

# The curved corridor leaves through an opening in the left wall (centred on z = COR_Z, 3 m wide), runs 6 m west, turns
# left (towards +z) on a 5 m radius, and runs 8 m. No lamp inside: whatever light is in there got in from the store.
const COR_Z := 0.3
const COR_W := 3.0
const COR_H := 3.4
const COR_T := 0.25
const COR_A := 6.0
const COR_R := 5.0
const COR_B := 8.0

# A door in the corridor's right wall (between these distances from the opening) leads to two rooms south of it: a materials
# room (glass, metal, glossy and rough spheres, one lamp) and, through it, a dark room lit only by a television.
const DOOR_S0 := 2.7
const DOOR_S1 := 3.9
const ROOMS_X0 := -18.5 # west end of the two rooms (outer face)
const ROOMS_Z0 := -5.0 # south wall, outer face
const ROOMS_Z1 := -1.45 # the corridor's right wall, outer face
const DIVIDER_X := -12.875 # the wall between the two rooms

# The GI volume that holds the store and the corridor (world metres).
const VOLUME_MIN := Vector3(-20.5, -0.5, -5.25)
const VOLUME_SIZE := Vector3(28.0, 4.5, 19.25)

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


## The props, as boxes: [centre (pivot at the bottom centre, +z = front), size, colour, emission]. Sizes are real-world metres,
## so the light bounces off things of the right size; the look is deliberately plain. Emission > 0: the part glows and lights the
## scene through the bounce; < 0: it only glows (the fluorescent tubes, whose light is an OmniLight3D already).
const KIT := {
	"fluorescent_fixture": [[Vector3(0, 0.03, 0), Vector3(1.24, 0.06, 0.22), Color(0.85, 0.85, 0.82), 0.0],
		[Vector3(0, -0.01, 0), Vector3(1.18, 0.03, 0.12), Color(0.85, 1.0, 0.9), -3.0]],
	"shelf_metal": [[Vector3(0, 0.9, -0.2), Vector3(1.0, 1.8, 0.04), Color(0.72, 0.72, 0.7), 0.0],
		[Vector3(0, 0.22, 0), Vector3(1.0, 0.03, 0.42), Color(0.75, 0.75, 0.73), 0.0],
		[Vector3(0, 0.636, 0), Vector3(1.0, 0.03, 0.42), Color(0.75, 0.75, 0.73), 0.0],
		[Vector3(0, 1.052, 0), Vector3(1.0, 0.03, 0.42), Color(0.75, 0.75, 0.73), 0.0],
		[Vector3(0, 1.468, 0), Vector3(1.0, 0.03, 0.42), Color(0.75, 0.75, 0.73), 0.0],
		[Vector3(0, 0.05, 0), Vector3(1.0, 0.1, 0.42), Color(0.4, 0.4, 0.4), 0.0]],
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


## The front wall: full height except over the window and door openings.
func front_wall(parent: Node, z: float, color: Color) -> void:
	var holes := [[-5.4, -3.4, 0.9, 2.4], [-2.2, -0.2, 0.9, 2.4], [3.4, 4.6, 0.0, 2.2]]
	var xs := [-ROOM_X - WALL, -5.4, -3.4, -2.2, -0.2, 3.4, 4.6, ROOM_X + WALL]
	for i in xs.size() - 1:
		var x0: float = xs[i]
		var x1: float = xs[i + 1]
		var hole = null
		for h in holes:
			if absf(h[0] - x0) < 0.001 and absf(h[1] - x1) < 0.001:
				hole = h
		var cx := (x0 + x1) * 0.5
		var w := x1 - x0
		if hole == null:
			box(parent, Vector3(cx, CEIL * 0.5, z), Vector3(w, CEIL, WALL), color)
		else:
			if hole[2] > 0.0:
				box(parent, Vector3(cx, hole[2] * 0.5, z), Vector3(w, hole[2], WALL), color)
			box(parent, Vector3(cx, (hole[3] + CEIL) * 0.5, z), Vector3(w, CEIL - hole[3], WALL), color)


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

	# Shell. The floor slab is solid for the voxels; the checker sits on top of it.
	box(S, Vector3(0, -0.255, 0), Vector3(ROOM_X * 2 + 0.6, 0.49, ROOM_Z * 2 + 0.6), Color(0.5, 0.47, 0.4))
	checker_floor(S, ROOM_X, ROOM_Z, 0.5, Color(0.66, 0.62, 0.5), Color(0.38, 0.34, 0.28))
	box(S, Vector3(0, CEIL + 0.15, 0), Vector3(ROOM_X * 2 + 0.6, 0.3, ROOM_Z * 2 + 0.6), cream)
	var z_lo := COR_Z - COR_W * 0.5 # opening edges
	var z_hi := COR_Z + COR_W * 0.5
	var zs0 := -ROOM_Z - WALL
	var zs1 := ROOM_Z + WALL
	box(S, Vector3(-ROOM_X - WALL * 0.5, CEIL * 0.5, (zs0 + z_lo) * 0.5), Vector3(WALL, CEIL, z_lo - zs0), paint)
	box(S, Vector3(-ROOM_X - WALL * 0.5, CEIL * 0.5, (z_hi + zs1) * 0.5), Vector3(WALL, CEIL, zs1 - z_hi), paint)
	box(S, Vector3(ROOM_X + WALL * 0.5, CEIL * 0.5, 0), Vector3(WALL, CEIL, ROOM_Z * 2 + 0.6), paint)
	box(S, Vector3(0, CEIL * 0.5, -ROOM_Z - WALL * 0.5), Vector3(ROOM_X * 2 + 0.6, CEIL, WALL), paint)
	front_wall(S, ROOM_Z + WALL * 0.5, paint)
	# A darker band on the lower part of the walls (tiles).
	box(S, Vector3(-ROOM_X + 0.02, 0.6, (-ROOM_Z + z_lo) * 0.5), Vector3(0.04, 1.2, z_lo + ROOM_Z), Color(0.32, 0.45, 0.4))
	box(S, Vector3(-ROOM_X + 0.02, 0.6, (z_hi + ROOM_Z) * 0.5), Vector3(0.04, 1.2, ROOM_Z - z_hi), Color(0.32, 0.45, 0.4))
	box(S, Vector3(ROOM_X - 0.02, 0.6, 0), Vector3(0.04, 1.2, ROOM_Z * 2), Color(0.32, 0.45, 0.4))
	box(S, Vector3(0, 0.6, -ROOM_Z + 0.02), Vector3(ROOM_X * 2, 1.2, 0.04), Color(0.32, 0.45, 0.4))

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
	box(dolly, Vector3(-0.2, 0.16 + 0.17, 0.0), Vector3(0.4, 0.34, 0.33), Color(0.62, 0.5, 0.32))
	box(dolly, Vector3(-0.2, 0.5 + 0.17, 0.0), Vector3(0.4, 0.34, 0.33), Color(0.62, 0.5, 0.32))
	box(dolly, Vector3(0.25, 0.16 + 0.24, 0.0), Vector3(0.67, 0.48, 0.44), Color(0.85, 0.85, 0.82))
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


func build_rooms(S: Node3D, D: Node3D) -> void:
	var x0 := ROOMS_X0
	var x1 := -ROOM_X - WALL # the store's left wall closes them on the east
	var cx := (x0 + x1) * 0.5
	var cz := (ROOMS_Z0 + ROOMS_Z1) * 0.5
	var wx := x1 - x0
	var wz := ROOMS_Z1 - ROOMS_Z0
	var grey := Color(0.72, 0.72, 0.7)
	box(S, Vector3(cx, -0.125, cz), Vector3(wx, 0.25, wz), Color(0.42, 0.42, 0.42)) # floor
	box(S, Vector3(cx, CEIL + 0.125, cz), Vector3(wx, 0.25, wz), Color(0.6, 0.6, 0.58)) # ceiling
	box(S, Vector3(cx, CEIL * 0.5, ROOMS_Z0 + 0.125), Vector3(wx, CEIL, 0.25), grey) # south wall
	box(S, Vector3(x0 + 0.125, CEIL * 0.5, cz), Vector3(0.25, CEIL, wz), grey) # west wall
	# North wall of the dark room (the corridor bends away from it there).
	var nx1 := -ROOM_X - COR_A
	box(S, Vector3((x0 + nx1) * 0.5, CEIL * 0.5, ROOMS_Z1 + 0.125), Vector3(nx1 - x0, CEIL, 0.25), grey)
	# The wall between the rooms, with a door near the south wall (so little of the materials room's light gets in).
	var dz0 := ROOMS_Z0 + 0.25 + 0.15
	var dz1 := dz0 + 0.9
	var blue := Color(0.25, 0.35, 0.7)
	box(S, Vector3(DIVIDER_X, CEIL * 0.5, (dz1 + ROOMS_Z1) * 0.5), Vector3(0.25, CEIL, ROOMS_Z1 - dz1), blue)
	box(S, Vector3(DIVIDER_X, CEIL * 0.5, (ROOMS_Z0 + 0.25 + dz0) * 0.5), Vector3(0.25, CEIL, dz0 - ROOMS_Z0 - 0.25), blue)
	box(S, Vector3(DIVIDER_X, (2.1 + CEIL) * 0.5, (dz0 + dz1) * 0.5), Vector3(0.25, CEIL - 2.1, dz1 - dz0), blue)

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
	box(S, Vector3(-14.4, 0.225, -3.1), Vector3(0.9, 0.45, 2.0), Color(0.72, 0.64, 0.52)) # sofa seat
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


## One mesh per surface, built slice by slice so the bend is smooth (an inner face to see and an outer one 0.25 m behind it, so the
## walls are solid for the voxels). Godot treats clockwise triangles as front faces.
func cor_strip(parent: Node, color: Color, parts: Array) -> void:
	var total := COR_A + COR_R * PI * 0.5 + COR_B
	var n := int(ceil(total / 0.2))
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for part in parts:
		for i in n:
			var s_mid := total * (i + 0.5) / n
			if part.has("hole") and s_mid > part["hole"][0] and s_mid < part["hole"][1]:
				continue # a door through this wall
			var q := []
			for sd in [total * i / n, total * (i + 1) / n]:
				var pth := cor_path(sd)
				var c: Vector3 = pth[0]
				var r: Vector3 = (pth[1] as Vector3).cross(Vector3.UP)
				q.append([part["e0"].call(c, r), part["e1"].call(c, r), part["n"].call(r)])
			var base := verts.size()
			verts.append_array([q[0][0], q[0][1], q[1][1], q[1][0]])
			norms.append_array([q[0][2], q[0][2], q[1][2], q[1][2]])
			var face_n: Vector3 = ((q[0][2] as Vector3) + (q[1][2] as Vector3)).normalized()
			var tri_n := (verts[base + 1] - verts[base]).cross(verts[base + 2] - verts[base])
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
	parent.add_child(mi)


func build_corridor(parent: Node) -> void:
	var hw := COR_W * 0.5
	var t := COR_T
	var up := Vector3.UP
	var h := COR_H
	cor_strip(parent, Color(0.45, 0.42, 0.38), [
		{"e0": func(c, r): return c - r * hw, "e1": func(c, r): return c + r * hw, "n": func(_r): return up},
		{"e0": func(c, r): return c - r * (hw + t) - up * t, "e1": func(c, r): return c + r * (hw + t) - up * t, "n": func(_r): return -up}])
	cor_strip(parent, Color(0.72, 0.72, 0.7), [
		{"e0": func(c, r): return c - r * hw + up * h, "e1": func(c, r): return c + r * hw + up * h, "n": func(_r): return -up},
		{"e0": func(c, r): return c - r * (hw + t) + up * (h + t), "e1": func(c, r): return c + r * (hw + t) + up * (h + t), "n": func(_r): return up}])
	cor_strip(parent, Color(0.78, 0.3, 0.24), [ # right wall: the outside of the left turn (with the door to the rooms)
		{"e0": func(c, r): return c + r * hw, "e1": func(c, r): return c + r * hw + up * h, "n": func(r): return -r, "hole": [DOOR_S0, DOOR_S1]},
		{"e0": func(c, r): return c + r * (hw + t) - up * t, "e1": func(c, r): return c + r * (hw + t) + up * (h + t), "n": func(r): return r, "hole": [DOOR_S0, DOOR_S1]}])
	# Above the door.
	var door_c: Vector3 = cor_path((DOOR_S0 + DOOR_S1) * 0.5)[0]
	box(parent, Vector3(door_c.x, (2.2 + h + t) * 0.5, door_c.z - hw - t * 0.5), Vector3(DOOR_S1 - DOOR_S0, h + t - 2.2, t), Color(0.78, 0.3, 0.24))
	cor_strip(parent, Color(0.2, 0.52, 0.56), [ # left wall: the inside of the turn
		{"e0": func(c, r): return c - r * hw, "e1": func(c, r): return c - r * hw + up * h, "n": func(r): return r},
		{"e0": func(c, r): return c - r * (hw + t) - up * t, "e1": func(c, r): return c - r * (hw + t) + up * (h + t), "n": func(r): return -r}])
	# A neon sign near the far end, the only light of that part of the corridor: it lights its surroundings through the bounce alone.
	var ns := COR_A + COR_R * PI * 0.5 + COR_B - 2.0
	var np := cor_path(ns)
	var nr: Vector3 = (np[1] as Vector3).cross(Vector3.UP)
	var neon := box(parent, (np[0] as Vector3) - nr * (hw - 0.04) + up * 2.2, Vector3(0.05, 0.12, 1.2), Color(1.0, 0.25, 0.6),
		atan2(-(np[1] as Vector3).x, -(np[1] as Vector3).z))
	var nm := neon.material_override as StandardMaterial3D
	nm.emission_enabled = true
	nm.emission = Color(1.0, 0.25, 0.6)
	nm.emission_energy_multiplier = 4.0
	neon.name = "NeonSign"
	# Closed at the far end, so nothing leaks out of it.
	var e := cor_path(COR_A + COR_R * PI * 0.5 + COR_B)
	var eh: Vector3 = e[1]
	box(parent, (e[0] as Vector3) + eh * 0.15 + Vector3(0, COR_H * 0.5, 0), Vector3(COR_W + 2 * COR_T, COR_H + 2 * COR_T, 0.3), Color(0.6, 0.6, 0.58), atan2(-eh.x, -eh.z))
