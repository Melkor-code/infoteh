extends Node3D

const FlightModel = preload("res://scripts/flight_model.gd")
const ProcTree = preload("res://scripts/proc_tree.gd")
const Contacts = preload("res://scripts/map_contacts.gd")

# North is -Z. The layout follows the supplied overhead sketch.
const WATER_Y := 0.0
const SPAN := 800.0
const CELLS := 320
const LAND_Y := 6.0
const CITY := Rect2(-72, -60, 144, 120)
const COURSE := Rect2(-250, -40, 156, 60)
const SPAWNS := [Vector3(0, 0, 0), Vector3(-108, 0, -10)]
const LAKE_CENTERS := [Vector3(-130, 0, -118), Vector3(-153, 0, -88), Vector3(-112, 0, -96)]
const LAKE_RADII := [37.0, 31.0, 26.0]
const HILLS := [Vector3(87, 24, 145), Vector3(121, 37, 113), Vector3(159, 34, 84), Vector3(191, 25, 52)]

var crowns: Array[Dictionary] = []
var solids: Array[Dictionary] = []
var _height_cache: Dictionary = {}
var _paints: Dictionary = {}
var _tree_mats: Array[ShaderMaterial] = []
var _grass_mat: ShaderMaterial
var _windows: Array[Transform3D] = []
var _rng := RandomNumberGenerator.new()
var snow_cover := 0.0
var _snow_mats: Array[ShaderMaterial] = []
const SnowShader = preload("res://scripts/snow_surface.gdshader")

func advance_weather(snowing: bool, delta: float) -> void:
	if snowing:
		snow_cover = move_toward(maxf(snow_cover, 0.30), 1.0, delta / 45.0)
	else:
		snow_cover = move_toward(snow_cover, 0.0, delta / 25.0)

func _snow_material(color: Color, vertex_color: bool = false) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SnowShader
	mat.set_shader_parameter("base_color", color)
	mat.set_shader_parameter("use_vertex_color", vertex_color)
	_snow_mats.append(mat)
	return mat

func build() -> void:
	_rng.seed = 20261006
	_build_ground()
	_build_water()
	_build_city()
	_build_helipad()
	_build_course()
	_build_hill_sign()
	_build_nature()

func spawn_point(index: int) -> Vector3:
	return SPAWNS[clampi(index, 0, SPAWNS.size() - 1)]

func island_radius(x: float, z: float) -> float:
	# Slightly irregular shoreline while keeping the oval silhouette of the plan.
	var angle := atan2(z / 210.0, x / 310.0)
	return Vector2(x / 310.0, z / 210.0).length() / (1.0 + 0.016 * sin(angle * 5.0) + 0.01 * cos(angle * 9.0))

func lake_distance(x: float, z: float) -> float:
	var d := 1000.0
	for i in LAKE_CENTERS.size():
		d = minf(d, Vector2(x - LAKE_CENTERS[i].x, z - LAKE_CENTERS[i].z).length() - LAKE_RADII[i])
	return d

func _terrain_height(x: float, z: float) -> float:
	var radial := island_radius(x, z)
	var land := 1.0 - smoothstep(0.88, 1.05, radial)
	var h := lerpf(-12.0, LAND_Y, land)
	h += (sin(x * 0.031) * cos(z * 0.037) * 0.5) * land
	for hill in HILLS:
		var dist := Vector2((x - hill.x) / 31.0, (z - hill.z) / 28.0).length_squared()
		h += hill.y * exp(-dist * 1.25) * land
	var lake := lake_distance(x, z)
	if lake < 10.0:
		h = lerpf(-5.0, h, smoothstep(-5.0, 10.0, lake))
	var town_edge := _rect_distance(Vector2(x, z), CITY)
	var course_edge := _rect_distance(Vector2(x, z), COURSE)
	var flat := 1.0 - smoothstep(0.0, 10.0, minf(town_edge, course_edge))
	return lerpf(h, LAND_Y, flat)

func _rect_distance(point: Vector2, rect: Rect2) -> float:
	var q := (point - rect.get_center()).abs() - rect.size * 0.5
	return Vector2(maxf(q.x, 0), maxf(q.y, 0)).length()

func _grid_height(x: float, z: float) -> float:
	var key := Vector2(x, z)
	if not _height_cache.has(key):
		_height_cache[key] = _terrain_height(x, z)
	return float(_height_cache[key])

func sample_height(x: float, z: float) -> float:
	# Paint and pad layers are elevated a few centimetres above the base mesh.
	if Rect2(-21, -21, 42, 42).has_point(Vector2(x, z)):
		return LAND_Y + 0.11
	if Rect2(-113, -15, 10, 10).has_point(Vector2(x, z)):
		return LAND_Y + 0.115
	if CITY.has_point(Vector2(x, z)) and (absf(absf(x) - 36.0) < 5.0 or absf(absf(z) - 30.0) < 5.0):
		return LAND_Y + 0.11
	if CITY.has_point(Vector2(x, z)) or COURSE.has_point(Vector2(x, z)):
		return LAND_Y + 0.05
	var step := SPAN / float(CELLS)
	var x0 := floorf((x + SPAN / 2.0) / step) * step - SPAN / 2.0
	var z0 := floorf((z + SPAN / 2.0) / step) * step - SPAN / 2.0
	var u := (x - x0) / step
	var v := (z - z0) / step
	var h00 := _grid_height(x0, z0)
	var h11 := _grid_height(x0 + step, z0 + step)
	if u >= v:
		return h00 * (1.0 - u) + _grid_height(x0 + step, z0) * (u - v) + h11 * v
	return h00 * (1.0 - v) + h11 * u + _grid_height(x0, z0 + step) * (v - u)

func surface_kind(pos: Vector3) -> int:
	return 1 if sample_height(pos.x, pos.z) < WATER_Y else 0

func slope_accel(pos: Vector3) -> Vector3:
	if surface_kind(pos) == 1:
		return Vector3.ZERO
	var dx := (sample_height(pos.x + 0.8, pos.z) - sample_height(pos.x - 0.8, pos.z)) / 1.6
	var dz := (sample_height(pos.x, pos.z + 0.8) - sample_height(pos.x, pos.z - 0.8)) / 1.6
	var grade := Vector3(-dx, 0, -dz)
	return grade * FlightModel.G * 0.55 / (1.0 + grade.length_squared()) if grade.length() > 0.12 else Vector3.ZERO

func in_grove(pos: Vector3) -> bool:
	return not CITY.grow(8).has_point(Vector2(pos.x, pos.z)) and not COURSE.grow(8).has_point(Vector2(pos.x, pos.z)) and island_radius(pos.x, pos.z) < 0.87 and lake_distance(pos.x, pos.z) > 14.0

func resolve(pos: Vector3, vel: Vector3, radius: float, vertical_radius: float = -1.0) -> Dictionary:
	return Contacts.resolve(solids, pos, vel, radius, vertical_radius)

func support_height(pos: Vector3, clearance: float) -> float:
	var height := sample_height(pos.x, pos.z)
	for solid in solids:
		if str(solid.kind) != "box":
			continue
		var center: Vector3 = solid.center
		var half: Vector3 = solid.half
		var top := center.y + half.y
		if absf(pos.x - center.x) <= half.x and absf(pos.z - center.z) <= half.z and pos.y - clearance >= top - 0.8:
			height = maxf(height, top)
	return height

func _build_ground() -> void:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := SPAN / float(CELLS)
	for iz in CELLS:
		for ix in CELLS:
			var x := -SPAN / 2.0 + ix * step
			var z := -SPAN / 2.0 + iz * step
			for point in [Vector2(x, z), Vector2(x + step, z), Vector2(x + step, z + step), Vector2(x, z), Vector2(x + step, z + step), Vector2(x, z + step)]:
				var h := _grid_height(point.x, point.y)
				var green := Color(0.16, 0.34, 0.10).lerp(Color(0.29, 0.46, 0.15), 0.5 + 0.5 * sin(point.x * 0.027) * cos(point.y * 0.031))
				var color := Color(0.60, 0.49, 0.29).lerp(green, smoothstep(1.0, 4.5, h))
				color = color.lerp(Color(0.34, 0.34, 0.29), smoothstep(18.0, 39.0, h) * 0.85)
				tool.set_color(color)
				tool.set_uv(point * 0.05)
				tool.add_vertex(Vector3(point.x, h, point.y))
	tool.generate_normals()
	var material := _snow_material(Color.WHITE, true)
	var ground := MeshInstance3D.new()
	ground.name = "IslandTerrain"
	ground.mesh = tool.commit()
	ground.material_override = material
	add_child(ground)

func _build_water() -> void:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(12000, 12000)
	var node := MeshInstance3D.new()
	node.name = "OceanAndLake"
	node.mesh = mesh
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode cull_disabled;
varying vec3 world;
void vertex(){ world=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz; }
void fragment(){
 float a=sin(world.x*0.20+world.z*0.13+TIME*1.1);
 float b=sin(world.x*0.09-world.z*0.27+TIME*0.8);
 ALBEDO=mix(vec3(0.018,0.19,0.29),vec3(0.04,0.34,0.45),0.5+0.25*(a+b));
 ROUGHNESS=0.3; METALLIC=0.18;
 NORMAL=normalize(NORMAL+vec3(a*0.035,b*0.035,0.0));
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	node.material_override = material
	node.position.y = WATER_Y
	add_child(node)

func _paint(color: Color) -> ShaderMaterial:
	if _paints.has(color):
		return _paints[color]
	var mat := _snow_material(color)
	_paints[color] = mat
	return mat

func _box(center: Vector3, size: Vector3, color: Color, solid: bool = false) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = center
	node.material_override = _paint(color)
	add_child(node)
	if solid:
		solids.append({"kind": "box", "center": center, "half": size * 0.5, "yaw": 0.0, "note": "Столкновение с препятствием. Облетите его."})
	return node

func _pole(center: Vector3, radius: float, height: float, color: Color, solid: bool = true) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = center
	node.material_override = _paint(color)
	add_child(node)
	if solid:
		solids.append({"kind": "pole", "x": center.x, "z": center.z, "base": center.y - height * 0.5, "radius": radius, "height": height, "note": "Столкновение со столбом или стволом."})

func _build_city() -> void:
	_box(Vector3(0, LAND_Y, 0), Vector3(144, 0.1, 120), Color(0.39, 0.42, 0.42))
	var asphalt := Color(0.075, 0.092, 0.11)
	for x in [-36.0, 36.0]:
		_box(Vector3(x, 6.07, 0), Vector3(10, 0.025, 116), asphalt)
		for z in range(-54, 55, 9):
			_box(Vector3(x, 6.09, z), Vector3(0.18, 0.015, 3.6), Color(0.85, 0.82, 0.60))
	for z in [-30.0, 30.0]:
		_box(Vector3(0, 6.075, z), Vector3(140, 0.025, 10), asphalt)
		for x in range(-63, 64, 9):
			_box(Vector3(x, 6.1, z), Vector3(3.6, 0.015, 0.18), Color(0.85, 0.82, 0.60))
	var palette := [Color(0.52, 0.59, 0.62), Color(0.67, 0.57, 0.44), Color(0.44, 0.50, 0.55), Color(0.66, 0.65, 0.58)]
	var index := 0
	for z in [-46.0, 46.0]:
		for x in [-58.0, -17.0, 17.0, 58.0]:
			_building(Vector3(x, LAND_Y + 0.05, z), Vector3(15, _rng.randf_range(13, 29), 17), palette[index % 4])
			index += 1
	for x in [-59.0, 59.0]:
		for z in [-13.0, 13.0]:
			_building(Vector3(x, 6.05, z), Vector3(17, _rng.randf_range(15, 34), 16), palette[index % 4])
			index += 1
	# Windows are one instanced draw, not hundreds of individual scene nodes.
	var window_mesh := BoxMesh.new()
	window_mesh.size = Vector3.ONE
	_multimesh(window_mesh, _paint(Color(0.075, 0.20, 0.27)), _windows, Vector3.ZERO, 900)
	for x in [-28.0, 28.0]:
		for z in [-23.0, 23.0]:
			_pole(Vector3(x, 8.6, z), 0.1, 5, Color(0.15, 0.18, 0.18))
			_box(Vector3(x, 11.15, z), Vector3(0.7, 0.14, 0.7), Color(0.86, 0.84, 0.60))
	# Pedestrian link between the city and the east entrance of the course.
	_box(Vector3(-83, 6.04, -10), Vector3(22, 0.06, 4), Color(0.62, 0.56, 0.40))

func _building(base: Vector3, size: Vector3, color: Color) -> void:
	_box(base + Vector3(0, size.y * 0.5, 0), size, color, true)
	_box(base + Vector3(0, size.y + 0.25, 0), Vector3(size.x + 0.5, 0.5, size.z + 0.5), Color(0.22, 0.26, 0.28), true)
	_box(base + Vector3(2, size.y + 1, 1), Vector3(3, 1.5, 3), Color(0.45, 0.48, 0.49), true)
	for level in range(2, int(size.y) - 1, 3):
		for side in [-1.0, 1.0]:
			for x in range(-int(size.x / 2.0) + 2, int(size.x / 2.0) - 1, 3):
				_windows.append(Transform3D(Basis.IDENTITY.scaled(Vector3(1.5, 1.65, 0.07)), base + Vector3(x, level, side * (size.z / 2.0 + 0.045))))
			for z in range(-int(size.z / 2.0) + 2, int(size.z / 2.0) - 1, 3):
				_windows.append(Transform3D(Basis.IDENTITY.scaled(Vector3(0.07, 1.65, 1.5)), base + Vector3(side * (size.x / 2.0 + 0.045), level, z)))
	_box(base + Vector3(0, 1.4, size.z * 0.5 + 0.06), Vector3(2, 2.8, 0.12), Color(0.06, 0.13, 0.16))

func _build_helipad() -> void:
	_box(Vector3(0, 6.07, 0), Vector3(42, 0.025, 42), Color(0.09, 0.18, 0.18))
	var white := Color(0.79, 0.83, 0.75)
	# Flat painted landing circle and H, with an unobstructed centre.
	var ring := TorusMesh.new()
	ring.inner_radius = 15.1
	ring.outer_radius = 15.5
	ring.rings = 64
	ring.ring_segments = 6
	var marking := MeshInstance3D.new()
	marking.mesh = ring
	marking.scale.y = 0.04
	marking.position = Vector3(0, 6.095, 0)
	marking.material_override = _paint(white)
	add_child(marking)
	for x in [-4.0, 4.0]:
		_box(Vector3(x, 6.095, 0), Vector3(1.4, 0.015, 12), white)
	_box(Vector3(0, 6.095, 0), Vector3(8, 0.015, 1.4), white)
	for x in [-20.0, 20.0]:
		for z in [-20.0, 20.0]:
			_pole(Vector3(x, 6.3, z), 0.23, 0.5, Color(0.85, 0.49, 0.10))

func _build_course() -> void:
	_box(Vector3(-172, 6, -10), Vector3(156, 0.1, 60), Color(0.58, 0.49, 0.29))
	# Eastern red point from the sketch: start facing west, into the course.
	_box(Vector3(-108, 6.075, -10), Vector3(10, 0.03, 10), Color(0.14, 0.23, 0.22))
	_box(Vector3(-108, 6.1, -10), Vector3(4, 0.015, 0.7), Color(0.91, 0.67, 0.18))
	for i in 5:
		var x := -130.0 - i * 24.0
		var center := Vector3(x, 10.0 + (i % 3) * 2.0, -19.0)
		_ring(center, 2.8, 0.24, Color(0.84, 0.31 + i * 0.07, 0.12))
		_pole(Vector3(x, (center.y - 2.8 + 6.05) * 0.5, -19), 0.12, center.y - 2.8 - 6.05, Color(0.2, 0.23, 0.24))
	# Return lane: slalom, rectangular gates, then a low tunnel.
	for i in 5:
		_pole(Vector3(-231 + i * 12, 9.0, 4 + (i % 2) * 5), 0.45, 6, Color(0.77, 0.53, 0.13))
	for x in [-161.0, -143.0]:
		for z in [0.0, 10.0]:
			_box(Vector3(x, 9, z), Vector3(0.5, 6, 0.5), Color(0.13, 0.38, 0.47), true)
		_box(Vector3(x, 12.0, 5), Vector3(0.5, 0.5, 10.5), Color(0.13, 0.38, 0.47), true)
	# Open tunnel assembled from rings; each rim is a physical obstacle.
	for i in 9:
		_ring(Vector3(-124 + i * 0.5, 8.5, 5), 2.2, 0.28, Color(0.34, 0.39, 0.40))
	for x in range(-246, -115, 10):
		_box(Vector3(x, 6.07, -10), Vector3(4, 0.02, 0.23), Color(0.87, 0.78, 0.48))
	_label("ПОЛИГОН", Vector3(-175, 6.1, -35), 4, Vector3(-PI / 2, 0, 0))

func _ring(center: Vector3, hole: float, tube: float, color: Color) -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = hole
	mesh.outer_radius = hole + tube * 2
	mesh.rings = 48
	mesh.ring_segments = 10
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = center
	node.rotation.z = PI / 2
	node.material_override = _paint(color)
	add_child(node)
	solids.append({"kind": "ring", "center": center, "axis": Vector3.RIGHT, "major": hole + tube, "tube": tube, "note": "Столкновение с ободом кольца. Пройдите через центр."})

func _label(text: String, pos: Vector3, height: float, angles: Vector3) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = 128
	label.pixel_size = height / 128.0
	label.outline_size = 0
	label.modulate = Color(0.9, 0.9, 0.82)
	label.position = pos
	label.rotation = angles
	label.no_depth_test = false
	add_child(label)
	return label

func _build_hill_sign() -> void:
	# Real extruded Cyrillic letters, facing north towards the town.
	var font := ThemeDB.fallback_font
	for i in 4:
		var x := 141.0 - i * 11.0
		# Follow the same hillside contour so the word has a level baseline.
		var z := 40.0
		while z < 115.0 and sample_height(x, z) < 23.0:
			z += 0.25
		var ground := sample_height(x, z)
		var mesh := TextMesh.new()
		mesh.font = font
		mesh.text = ["А", "Б", "Д", "О"][i]
		mesh.font_size = 128
		mesh.pixel_size = 0.09
		mesh.depth = 0.7
		var node := MeshInstance3D.new()
		node.name = "HillLetter" + str(i)
		node.mesh = mesh
		node.rotation.y = PI
		var bounds := mesh.get_aabb()
		node.position = Vector3(x, 25.0 - bounds.position.y, z)
		node.material_override = _paint(Color(0.92, 0.91, 0.83))
		add_child(node)
		var box_center := node.position + Basis(Vector3.UP, PI) * bounds.get_center()
		solids.append({"kind": "box", "center": box_center, "half": bounds.size * 0.5, "yaw": 0.0, "note": "Столкновение с буквой надписи АБДО."})
		for offset in [-1.7, 1.7]:
			var foot := sample_height(x + offset, z + 0.6)
			var support_height := maxf(26.5 - foot, 0.5)
			_pole(Vector3(x + offset, foot + support_height * 0.5, z + 0.6), 0.12, support_height, Color(0.26, 0.28, 0.27))

func _nature_spot(x: float, z: float, margin: float = 0.0) -> bool:
	var point := Vector2(x, z)
	if CITY.grow(7 + margin).has_point(point) or COURSE.grow(6 + margin).has_point(point):
		return false
	if Rect2(-101, -16, 34, 12).grow(margin).has_point(point):
		return false
	if Rect2(86, 70, 64, 40).grow(margin).has_point(point):
		return false
	return island_radius(x, z) < 0.88 and lake_distance(x, z) > 13.0 + margin and sample_height(x, z) > 4.0 and sample_height(x, z) < 20.0

func _build_nature() -> void:
	var envelope_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/map/trees/envelopes.json"))
	var buckets: Dictionary = {}
	for z in range(-180, 185, 11):
		for x in range(-275, 280, 11):
			var px := x + _rng.randf_range(-3, 3)
			var pz := z + _rng.randf_range(-3, 3)
			if not _nature_spot(px, pz, 3) or _rng.randf() > 0.68:
				continue
			var kind := _rng.randi_range(0, 3)
			var variant := _rng.randi_range(0, 1)
			var size := _rng.randf_range(0.65, 1.18)
			var y := sample_height(px, pz)
			var spec: Dictionary = envelope_data[str(kind)]
			var crown_base := y + float(spec.base) * size
			var crown_top := y + float(spec.top) * size
			var reach := float(spec.reach) * size
			# Коллизии берутся из тех же отрезков, из которых строится видимая кора.
			# Поэтому вокруг веток больше нет невидимого куба/эллипсоида.
			var tree_yaw := _rng.randf() * TAU
			var tree_basis := Basis(Vector3.UP, tree_yaw).scaled(Vector3.ONE * size)
			for segment in ProcTree.collision_segments(kind, variant):
				var a: Vector3 = segment["a"]
				var b: Vector3 = segment["b"]
				solids.append({"kind": "branch", "a": Vector3(px, y, pz) + tree_basis * a, "b": Vector3(px, y, pz) + tree_basis * b, "radius": float(segment["radius"]) * size, "note": "Столкновение со стволом или веткой дерева."})
			crowns.append({"x": px, "z": pz, "reach": float(spec.reach) * size, "base": y + float(spec.base) * size, "top": y + float(spec.top) * size})
			var key := "%d:%d:%d:%d" % [kind, variant, floori(px / 70), floori(pz / 70)]
			if not buckets.has(key):
				buckets[key] = []
			buckets[key].append(Transform3D(tree_basis, Vector3(px, y, pz)))
	for kind in 4:
		_tree_mats.append(ProcTree.material(kind))
	for key in buckets:
		var parts := str(key).split(":")
		var origin := Vector3(float(parts[2]) * 70 + 35, 0, float(parts[3]) * 70 + 35)
		var mesh := load("res://assets/map/trees/tree_%s_%s.res" % [parts[0], parts[1]]) as Mesh
		_multimesh(mesh, _tree_mats[int(parts[0])], buckets[key], origin, 900)
	_grass_mat = load("res://assets/map/grass/Materials/EA_Grass_Green.tres").duplicate() as ShaderMaterial
	_grass_mat.set_shader_parameter("ambient_lift", 0.08)
	_grass_mat.set_shader_parameter("tint_intensity_small_blob", 0.15)
	_grass_mat.set_shader_parameter("tint_intensity_large_stripes", 0.1)
	var grass_buckets: Dictionary = {}
	for z in range(-192, 195, 3):
		for x in range(-290, 293, 3):
			var px := x + _rng.randf_range(-1.4, 1.4)
			var pz := z + _rng.randf_range(-1.4, 1.4)
			if not _nature_spot(px, pz) or _rng.randf() > 0.8:
				continue
			var key := Vector2i(floori(px / 40), floori(pz / 40))
			if not grass_buckets.has(key):
				grass_buckets[key] = []
			var size := _rng.randf_range(0.45, 0.85)
			grass_buckets[key].append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * size), Vector3(px, sample_height(px, pz), pz)))
	var grass_mesh := load("res://assets/map/grass/Meshes/EA_Grass_Clump.mesh") as Mesh
	for key in grass_buckets:
		_multimesh(grass_mesh, _grass_mat, grass_buckets[key], Vector3(key.x * 40 + 20, 0, key.y * 40 + 20), 140)

func _multimesh(mesh: Mesh, material: Material, rows: Array, origin: Vector3, distance: float) -> void:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = rows.size()
	for i in rows.size():
		var t: Transform3D = rows[i]
		t.origin -= origin
		multi.set_instance_transform(i, t)
	var node := MultiMeshInstance3D.new()
	node.multimesh = multi
	node.material_override = material
	node.position = origin
	node.visibility_range_end = distance
	node.visibility_range_end_margin = 20
	node.extra_cull_margin = 2
	add_child(node)

func set_foliage_wind(blow: Vector3, snow: float = 0) -> void:
	for material in _snow_mats:
		material.set_shader_parameter("snow_amount", snow)
	var speed := Vector2(blow.x, blow.z).length()
	var direction := Vector3(blow.x, 0, blow.z).normalized()
	for material in _tree_mats:
		material.set_shader_parameter("snow_amount", snow)
		material.set_shader_parameter("wind_dir", direction)
		material.set_shader_parameter("wind_strength", minf(speed * 0.04, 0.6))
		material.set_shader_parameter("wind_rate", 0.7 + speed * 0.07)
	if _grass_mat != null:
		_grass_mat.set_shader_parameter("wind_direction_x", direction.x)
		_grass_mat.set_shader_parameter("wind_direction_z", direction.z)
		_grass_mat.set_shader_parameter("wind_strength", minf(speed * 0.02, 0.25))
		_grass_mat.set_shader_parameter("gust_strength", minf(speed * 0.03, 0.4))
		_grass_mat.set_shader_parameter("snow_coverage", snow)
		_grass_mat.set_shader_parameter("winter_amount", snow)
