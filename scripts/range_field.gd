extends Node3D

const FlightModel = preload("res://scripts/flight_model.gd")
const ProcTree = preload("res://scripts/proc_tree.gd")

## Полигон собирается здесь, не в чужом симуляторе.
## Высота земли и картинка — одна функция: иначе аппарат садится сквозь холм.
## Деревья растут правилом развилки в proc_tree.gd, не стопкой конусов и не чужим плагином.
## Препятствия твёрдые: ствол, камень, обод кольца, балка, стенка трубы, столб.

const SPAN := 560.0
const CELLS := 140
const PAD_FLAT := 12.0
const PAD_BLEND := 20.0
const PIER_X0 := 50.0
const PIER_X1 := 68.0
const PIER_Z := 14.0
const PIER_HALF_Z := 1.7
const COURSE_X0 := -26.0
const COURSE_X1 := 40.0
const COURSE_Z0 := 46.0
const COURSE_Z1 := 300.0
const WATER_Y := -2.0

var crowns: Array[Dictionary] = []
var solids: Array[Dictionary] = []
var relief_noise := FastNoiseLite.new()
var valley_noise := FastNoiseLite.new()
var forest_noise := FastNoiseLite.new()
var _mesh_cache: Dictionary = {}
var _spec_cache: Dictionary = {}
var _tree_mats: Dictionary = {}
var _grass_mats: Dictionary = {}
var _grass_shader_res: Shader
var _card_shader_res: Shader
var _fpv_cache := PackedVector3Array()


func build() -> void:
	# Шум создаётся один раз. И картинка, и посадка читают одну и ту же функцию.
	relief_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	relief_noise.frequency = 0.015
	relief_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	relief_noise.fractal_octaves = 4
	relief_noise.seed = 41
	valley_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	valley_noise.frequency = 0.009
	valley_noise.seed = 88
	forest_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	forest_noise.frequency = 0.045
	forest_noise.seed = 19
	_build_ground()
	_build_water()
	_build_pier()
	_build_pad_marks()
	_scatter_nature()
	_build_course()
	_build_road()
	_build_yard()
	_build_grass()
	_build_zones()
	_add_sign("СЕВЕР", Vector3(0.0, 14.0, -230.0))
	_add_sign("ГРЯДА", Vector3(8.0, 12.0, -150.0))
	_add_sign("ПРУД", Vector3(96.0, 4.0, 22.0))
	_add_sign("РОЩА", Vector3(-90.0, 8.0, 16.0))
	_add_sign("ДОРОЖКА", Vector3(0.0, 5.5, 52.0))
	_add_sign("ЛЕС", Vector3(-102.0, 14.0, 24.0))
	_add_sign("ПРОМЗОНА", Vector3(168.0, 16.0, 6.0))
	_add_sign("КАНЬОН", Vector3(18.0, 18.0, -150.0))
	_add_sign("ТРАССА", Vector3(-96.0, 12.0, 148.0))


func sample_height(x: float, z: float) -> float:
	var h := _waves(x, z) + _relief(x, z) + _mounds(x, z)
	h = _carve_basin(x, z, h)
	var pad := Vector2(x, z).length()
	if pad < PAD_BLEND:
		h = lerpf(0.0, h, smoothstep(PAD_FLAT, PAD_BLEND, pad))
	if _on_pier(x, z):
		return 0.18
	if _on_course(x, z):
		var edge := _course_blend(x, z)
		h = lerpf(h, 0.16, edge)
	var corridor := _fpv_distance(x, z)
	if corridor < 16.0:
		h = lerpf(0.22, h, smoothstep(6.0, 16.0, corridor))
	return h


func surface_kind(pos: Vector3) -> int:
	if _on_pier(pos.x, pos.z):
		return 0
	if _water_covers(pos.x, pos.z):
		return 1
	return 0


func slope_accel(pos: Vector3) -> Vector3:
	if sample_height(pos.x, pos.z) < 0.35:
		return Vector3.ZERO
	var step := 1.6
	var dx := (sample_height(pos.x + step, pos.z) - sample_height(pos.x - step, pos.z)) / (2.0 * step)
	var dz := (sample_height(pos.x, pos.z + step) - sample_height(pos.x, pos.z - step)) / (2.0 * step)
	var grade := Vector3(-dx, 0.0, -dz)
	if grade.length() < 0.05:
		return Vector3.ZERO
	return grade * FlightModel.G * 0.55


func in_grove(pos: Vector3) -> bool:
	var nx := (pos.x + 90.0) / 46.0
	var nz := (pos.z - 16.0) / 36.0
	return nx * nx + nz * nz <= 1.0


func canopy_at(pos: Vector3) -> float:
	var best := 0.0
	for crown in crowns:
		var flat := Vector2(pos.x - float(crown["x"]), pos.z - float(crown["z"])).length()
		var reach := float(crown["reach"])
		if flat > reach:
			continue
		if pos.y < float(crown["base"]) or pos.y > float(crown["top"]):
			continue
		best = maxf(best, 1.0 - flat / reach)
	return best


func resolve(pos: Vector3, vel: Vector3, radius: float) -> Dictionary:
	var note := ""
	for _pass in 3:
		var best_depth := 0.0
		var best_normal := Vector3.UP
		var best_note := ""
		for item in solids:
			var hit := _hit_solid(item, pos, radius)
			if hit.is_empty():
				continue
			if float(hit["depth"]) > best_depth:
				best_depth = float(hit["depth"])
				best_normal = hit["normal"]
				best_note = str(hit["note"])
		if best_depth <= 0.001:
			break
		pos += best_normal * (best_depth + 0.03)
		var into := vel.dot(best_normal)
		if into < 0.0:
			vel -= best_normal * into * 1.4
		note = best_note
	return {"pos": pos, "vel": vel, "note": note}


func _build_ground() -> void:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := SPAN / float(CELLS)
	var origin := -SPAN * 0.5
	for iz in CELLS:
		for ix in CELLS:
			var x0 := origin + float(ix) * step
			var z0 := origin + float(iz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			_ground_quad(tool, x0, z0, x1, z1)
	tool.generate_normals()
	var mesh_node := MeshInstance3D.new()
	mesh_node.mesh = tool.commit()
	mesh_node.material_override = _ground_material()
	add_child(mesh_node)


func _ground_quad(tool: SurfaceTool, x0: float, z0: float, x1: float, z1: float) -> void:
	_ground_vertex(tool, x0, z0)
	_ground_vertex(tool, x1, z0)
	_ground_vertex(tool, x1, z1)
	_ground_vertex(tool, x0, z0)
	_ground_vertex(tool, x1, z1)
	_ground_vertex(tool, x0, z1)


func _ground_vertex(tool: SurfaceTool, x: float, z: float) -> void:
	var h := sample_height(x, z)
	tool.set_uv(Vector2(x, z) * 0.04)
	tool.set_color(_tint(h, x, z))
	tool.add_vertex(Vector3(x, h, z))


func _tint(h: float, x: float, z: float) -> Color:
	if h < WATER_Y + 0.08:
		var depth := clampf((WATER_Y - h) / 4.2, 0.0, 1.0)
		return Color(0.68, 0.58, 0.36).lerp(Color(0.36, 0.34, 0.3), depth)
	# Низина темнее, пригорок светлее. Камень и снег сверху это не отменяют.
	var lift := clampf((h + 0.6) / 5.5, 0.0, 1.0)
	var grass := Color(0.13, 0.29, 0.1).lerp(Color(0.48, 0.68, 0.3), lift)
	var sand := Color(0.76, 0.66, 0.42)
	var dirt := Color(0.46, 0.34, 0.2)
	var scree := Color(0.52, 0.47, 0.4)
	var rock := Color(0.48, 0.46, 0.42)
	var moss := Color(0.16, 0.3, 0.14)
	var pond := _pond_field(x, z)
	var beach := clampf(1.0 - absf(pond - 0.18) * 4.2, 0.0, 1.0)
	var tint := grass.lerp(sand, maxf(clampf(pond * 1.6, 0.0, 1.0), beach * 0.92))
	var cut := pow(1.0 - absf(valley_noise.get_noise_2d(x, z)), 4.0)
	if cut > 0.4 and h < 5.5:
		tint = tint.lerp(scree, clampf((cut - 0.4) * 2.3, 0.0, 0.82))
	tint = tint.lerp(dirt, _dirt_amount(x, z))
	if in_grove(Vector3(x, 0.0, z)):
		tint = tint.lerp(moss, 0.28)
	if h > 3.2:
		tint = tint.lerp(rock, clampf((h - 3.2) / 5.0, 0.0, 1.0))
	if h > 7.4:
		tint = tint.lerp(Color(0.9, 0.92, 0.94), clampf((h - 7.4) / 2.2, 0.0, 1.0))
	return tint


func _dirt_amount(x: float, z: float) -> float:
	var amount := 0.0
	if z > 42.0 and z < 308.0:
		amount = maxf(amount, 1.0 - smoothstep(3.4, 8.2, absf(x)))
	if x > 10.0 and x < 64.0 and z > -2.0 and z < 22.0:
		amount = maxf(amount, 1.0 - smoothstep(1.3, 3.8, absf(z - 6.0)))
	if x < -8.0 and x > -72.0 and z > -8.0 and z < 18.0:
		amount = maxf(amount, 1.0 - smoothstep(1.4, 3.6, absf(z - 4.0)))
	return clampf(amount, 0.0, 0.78)


func _relief(x: float, z: float) -> float:
	# FastNoiseLite: холмы и узкие овраги. Площадка, причал и дорожка потом выравниваются.
	var hill := relief_noise.get_noise_2d(x, z)
	var cut := pow(1.0 - absf(valley_noise.get_noise_2d(x, z)), 4.0)
	return hill * 1.7 - cut * 2.2


func _ground_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform sampler2D detail : repeat_enable, filter_linear_mipmap;
uniform sampler2D grass_tex : repeat_enable, filter_linear_mipmap, source_color;
varying vec3 world_normal;
varying float height_m;
void vertex() {
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	height_m = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}
void fragment() {
	float grain = texture(detail, UV).r;
	float slope = clamp(world_normal.y, 0.0, 1.0);
	vec3 rock = vec3(0.45, 0.43, 0.39);
	vec3 snow = vec3(0.88, 0.90, 0.93);
	vec3 albedo = mix(rock, COLOR.rgb, smoothstep(0.40, 0.78, slope));
	float snow_mix = smoothstep(7.2, 9.2, height_m) * smoothstep(0.5, 0.88, slope);
	albedo = mix(albedo, snow, snow_mix);
	albedo *= 0.88 + 0.2 * grain;
	// С высоты виден ковёр, не отдельные палочки. Рисунок травинок лежит на земле.
	float meadow = smoothstep(0.02, 0.1, COLOR.g - COLOR.r) * smoothstep(0.62, 0.86, slope);
	vec3 blades_near = texture(grass_tex, UV * 9.0).rgb;
	vec3 blades_far = texture(grass_tex, UV * 3.4 + vec2(0.31, 0.17)).rgb;
	vec3 blades = mix(blades_near, blades_far, 0.4) * vec3(1.55, 1.7, 1.25);
	albedo = mix(albedo, mix(albedo, blades, 0.78), meadow);
	ALBEDO = albedo;
	ROUGHNESS = mix(0.94, 0.58, snow_mix);
}
"""
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.08
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("detail", tex)
	mat.set_shader_parameter("grass_tex", load("res://textures/grass_top.png"))
	return mat


func _waves(x: float, z: float) -> float:
	return 0.85 * sin(x * 0.041) * cos(z * 0.036) + 0.42 * sin(x * 0.09 + 1.3) * sin(z * 0.078) + 0.2 * sin(x * 0.15 + z * 0.13)


func _mounds(x: float, z: float) -> float:
	var hills: Array[Vector4] = [
		Vector4(0.0, -78.0, 34.0, 7.5),
		Vector4(-38.0, -118.0, 26.0, 5.2),
		Vector4(34.0, -148.0, 30.0, 9.5),
		Vector4(-10.0, -186.0, 22.0, 4.0),
		Vector4(52.0, -96.0, 18.0, 3.2),
		Vector4(-22.0, -58.0, 14.0, 2.4),
	]
	var h := 0.0
	for hill in hills:
		var dist := Vector2(x - hill.x, z - hill.y).length()
		if dist >= hill.z:
			continue
		var t := 1.0 - dist / hill.z
		# t² с плоской макушкой, не острый конус.
		h += hill.w * t * t * (1.15 - 0.35 * t)
	return h


func _pond_field(x: float, z: float) -> float:
	var blobs: Array[Vector3] = [
		Vector3(82.0, 8.0, 18.0),
		Vector3(102.0, 24.0, 16.0),
		Vector3(70.0, 26.0, 13.0),
		Vector3(112.0, 8.0, 11.0),
		Vector3(92.0, 38.0, 10.0),
	]
	var field := 0.0
	for blob in blobs:
		var dist := Vector2(x - blob.x, z - blob.y).length()
		if dist >= blob.z:
			continue
		field = maxf(field, 1.0 - dist / blob.z)
	return field


func _carve_basin(x: float, z: float, h: float) -> float:
	var wet := maxf(_pond_field(x, z), _canyon_field(x, z))
	if wet <= 0.001:
		return h
	# Внутри чаши дно ниже зеркала воды. Иначе плоскость воды висит над землёй.
	var bed := WATER_Y - 0.45 - wet * 4.2
	return lerpf(h, bed, smoothstep(0.04, 0.22, wet))


func _canyon_field(x: float, z: float) -> float:
	if z > -98.0 or z < -206.0:
		return 0.0
	var along := clampf((-z - 102.0) / 96.0, 0.0, 1.0)
	var center_x := lerpf(6.0, 26.0, along)
	var dist := absf(x - center_x)
	var half := 12.0
	if dist >= half:
		return 0.0
	return 1.0 - dist / half


func _canyon_center_x(z: float) -> float:
	var along := clampf((-z - 102.0) / 96.0, 0.0, 1.0)
	return lerpf(6.0, 26.0, along)


func _water_covers(x: float, z: float) -> bool:
	if _on_pier(x, z):
		return false
	var wet := maxf(_pond_field(x, z), _canyon_field(x, z))
	return wet > 0.16 and sample_height(x, z) < WATER_Y + 0.05


func _fpv_points() -> PackedVector3Array:
	if not _fpv_cache.is_empty():
		return _fpv_cache
	_fpv_cache.append(Vector3(-46.0, 0.0, 100.0))
	_fpv_cache.append(Vector3(-78.0, 0.0, 132.0))
	_fpv_cache.append(Vector3(-118.0, 0.0, 154.0))
	_fpv_cache.append(Vector3(-156.0, 0.0, 196.0))
	_fpv_cache.append(Vector3(-128.0, 0.0, 232.0))
	_fpv_cache.append(Vector3(-82.0, 0.0, 258.0))
	return _fpv_cache


func _fpv_distance(x: float, z: float) -> float:
	var points := _fpv_points()
	var best := 9999.0
	for i in points.size() - 1:
		best = minf(best, _segment_distance(x, z, points[i], points[i + 1]))
	return best


func _segment_distance(x: float, z: float, a: Vector3, b: Vector3) -> float:
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var len2 := ab.length_squared()
	if len2 < 0.01:
		return Vector2(x - a.x, z - a.z).length()
	var t := clampf(Vector2(x - a.x, z - a.z).dot(ab) / len2, 0.0, 1.0)
	var point := Vector2(a.x, a.z) + ab * t
	return Vector2(x, z).distance_to(point)


func _on_pier(x: float, z: float) -> bool:
	return x >= PIER_X0 and x <= PIER_X1 and absf(z - PIER_Z) <= PIER_HALF_Z


func _on_course(x: float, z: float) -> bool:
	return x >= COURSE_X0 and x <= COURSE_X1 and z >= COURSE_Z0 and z <= COURSE_Z1


func _course_blend(x: float, z: float) -> float:
	var inset_x := minf(x - COURSE_X0, COURSE_X1 - x)
	var inset_z := minf(z - COURSE_Z0, COURSE_Z1 - z)
	return smoothstep(0.0, 8.0, minf(inset_x, inset_z))


func _build_water() -> void:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_water_patch(tool, 48.0, -18.0, 136.0, 64.0, 3.0)
	_water_patch(tool, -10.0, -208.0, 44.0, -96.0, 3.0)
	var mesh := tool.commit()
	if mesh.get_surface_count() == 0:
		return
	var water := MeshInstance3D.new()
	water.mesh = mesh
	water.material_override = _water_material()
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)
	_scatter_bed_rocks()


func _water_patch(tool: SurfaceTool, x_min: float, z_min: float, x_max: float, z_max: float, step: float) -> void:
	var ix_max := int((x_max - x_min) / step)
	var iz_max := int((z_max - z_min) / step)
	for iz in iz_max:
		for ix in ix_max:
			var x0 := x_min + float(ix) * step
			var z0 := z_min + float(iz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			if sample_height((x0 + x1) * 0.5, (z0 + z1) * 0.5) >= WATER_Y - 0.05:
				continue
			_water_vertex(tool, x0, z0)
			_water_vertex(tool, x1, z0)
			_water_vertex(tool, x1, z1)
			_water_vertex(tool, x0, z0)
			_water_vertex(tool, x1, z1)
			_water_vertex(tool, x0, z1)


func _water_vertex(tool: SurfaceTool, x: float, z: float) -> void:
	var bed := sample_height(x, z)
	var depth := clampf((WATER_Y - bed) / 4.4, 0.0, 1.0)
	tool.set_color(Color(depth, depth, 1.0))
	tool.add_vertex(Vector3(x, WATER_Y, z))


func _scatter_bed_rocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var spots: Array[Transform3D] = []
	var guard := 0
	while spots.size() < 48 and guard < 240:
		guard += 1
		var x := rng.randf_range(58.0, 120.0)
		var z := rng.randf_range(-8.0, 48.0)
		if not _water_covers(x, z):
			continue
		var y := sample_height(x, z)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.45, 1.1))
		spots.append(Transform3D(basis, Vector3(x, y + 0.08, z)))
	if spots.is_empty():
		return
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = _pebble_mesh()
	multi.instance_count = spots.size()
	for i in spots.size():
		multi.set_instance_transform(i, spots[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = multi
	node.material_override = _foliage_material()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = 90.0
	add_child(node)


func _build_pier() -> void:
	var pier := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(PIER_X1 - PIER_X0, 0.16, PIER_HALF_Z * 2.0)
	pier.mesh = box
	pier.position = Vector3((PIER_X0 + PIER_X1) * 0.5, 0.22, PIER_Z)
	pier.material_override = _paint(Color(0.42, 0.3, 0.18))
	add_child(pier)
	var bed := sample_height(72.0, PIER_Z)
	if bed < WATER_Y:
		for dz in [-1.1, 1.1]:
			var post := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			var height := 0.22 - bed
			cyl.top_radius = 0.12
			cyl.bottom_radius = 0.16
			cyl.height = height
			post.mesh = cyl
			post.position = Vector3(67.2, bed + height * 0.5, PIER_Z + dz)
			post.material_override = _paint(Color(0.35, 0.26, 0.16))
			add_child(post)


func _build_pad_marks() -> void:
	for i in range(-2, 3):
		var pad := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.2, 0.04, 8.0)
		pad.mesh = box
		pad.position = Vector3(i * 2.2, 0.04, 0.0)
		pad.material_override = _paint(Color(0.85, 0.85, 0.8) if i == 0 else Color(0.55, 0.55, 0.52))
		add_child(pad)


func _scatter_nature() -> void:
	# Кластеры, не ровная решётка: между куртинами остаются поляны.
	# Сетка одного дерева общая, поэтому дальний лес не плодит сотни узлов.
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	var clusters: Array[Vector3] = [
		Vector3(-78.0, 22.0, 13.0),
		Vector3(-112.0, 18.0, 14.0),
		Vector3(-98.0, -6.0, 12.0),
		Vector3(-68.0, 2.0, 11.0),
		Vector3(-108.0, 38.0, 12.0),
		Vector3(-86.0, 40.0, 10.0),
		Vector3(16.0, -162.0, 14.0),
		Vector3(-30.0, -38.0, 9.0),
	]
	var placed: Array[Vector2] = []
	for cluster in clusters:
		var spots: Array[Dictionary] = []
		var tries := 0
		var goal := 8 if (cluster.z < 12.0 or cluster.y < -80.0) else 12
		while spots.size() < goal and tries < 90:
			tries += 1
			var ang := rng.randf() * TAU
			var dist := cluster.z * sqrt(rng.randf())
			var x := cluster.x + cos(ang) * dist
			var z := cluster.y + sin(ang) * dist
			if not _tree_spot_ok(x, z, placed, 3.8):
				continue
			placed.append(Vector2(x, z))
			var kind := _cluster_kind(cluster, rng)
			var size := rng.randf_range(0.72, 1.22)
			_remember_tree(spots, x, z, kind, size, rng.randf() * TAU, rng.randi_range(0, 1))
		_flush_cluster(spots)
	_build_dense_forest()
	_scatter_floor(rng)


func _blocked_spot(x: float, z: float) -> bool:
	if Vector2(x, z).length() < 16.0:
		return true
	if _on_pier(x, z) or _pond_field(x, z) > 0.08 or _on_course(x, z):
		return true
	if Vector2(x, z - 14.0).length() < 8.0:
		return true
	if Vector2(x + 52.0, z - 8.0).length() < 8.0:
		return true
	if Vector2(x, z + 64.0).length() < 8.0:
		return true
	return false


func _too_close(spot: Vector2, placed: Array[Vector2], gap: float) -> bool:
	for other in placed:
		if spot.distance_to(other) < gap:
			return true
	return false


func _tree_spot_ok(x: float, z: float, placed: Array[Vector2], gap: float) -> bool:
	if _blocked_spot(x, z) or _pond_field(x, z) > 0.04:
		return false
	if sample_height(x, z) < -0.15:
		return false
	return not _too_close(Vector2(x, z), placed, gap)


func _cluster_kind(cluster: Vector3, rng: RandomNumberGenerator) -> int:
	# 0 ель, 1 сосна, 2 дуб, 3 берёза, 4 куст. На гряде только хвойные.
	if cluster.y < -80.0:
		return 0 if rng.randf() < 0.6 else 1
	var roll := rng.randf()
	if roll < 0.26:
		return 0
	if roll < 0.5:
		return 1
	if roll < 0.72:
		return 2
	if roll < 0.88:
		return 3
	return 4


func _tree_spec(kind: int) -> Dictionary:
	# Границы кроны берутся из той же развилки, что и сетка. Иначе сопротивление
	# сидит на старом конусе, а листва уже в другом месте.
	if _spec_cache.has(kind):
		return _spec_cache[kind]
	var spec := ProcTree.envelope(kind)
	_spec_cache[kind] = spec
	return spec


func _remember_tree(spots: Array[Dictionary], x: float, z: float, kind: int, size: float, yaw: float, variant: int) -> void:
	var spec := _tree_spec(kind)
	var y := sample_height(x, z)
	var note := "Столкновение со стволом. Облетите дерево: сквозь ствол не пройти."
	if kind == 4:
		note = "Столкновение с кустом. Это препятствие, не картинка."
	_add_solid(x, z, float(spec["trunk_r"]) * size, float(spec["trunk_h"]) * size, note)
	crowns.append({
		"x": x,
		"z": z,
		"reach": float(spec["reach"]) * size,
		"base": y + float(spec["base"]) * size,
		"top": y + float(spec["top"]) * size,
	})
	spots.append({
		"x": x,
		"y": y,
		"z": z,
		"kind": kind,
		"size": size,
		"yaw": yaw,
		"variant": variant,
	})


func _flush_cluster(spots: Array[Dictionary]) -> void:
	if spots.is_empty():
		return
	for kind in 5:
		for variant in 2:
			var subset: Array[Dictionary] = []
			for spot in spots:
				if int(spot["kind"]) == kind and int(spot["variant"]) == variant:
					subset.append(spot)
			if subset.is_empty():
				continue
			var multi := MultiMesh.new()
			multi.transform_format = MultiMesh.TRANSFORM_3D
			multi.mesh = _cached_tree_mesh(kind, variant)
			multi.instance_count = subset.size()
			for i in subset.size():
				var spot := subset[i]
				var basis := Basis(Vector3.UP, float(spot["yaw"])).scaled(Vector3.ONE * float(spot["size"]))
				multi.set_instance_transform(i, Transform3D(basis, Vector3(float(spot["x"]), float(spot["y"]), float(spot["z"]))))
			var node := MultiMeshInstance3D.new()
			node.multimesh = multi
			node.material_override = _tree_material(kind)
			# Дальше 200 м куртина гаснет и остаётся карточка, не полная сетка.
			node.visibility_range_end = 200.0
			node.visibility_range_end_margin = 36.0
			node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			add_child(node)
		_add_kind_cards(spots, kind)


func _add_kind_cards(spots: Array[Dictionary], kind: int) -> void:
	var subset: Array[Dictionary] = []
	for spot in spots:
		if int(spot["kind"]) == kind:
			subset.append(spot)
	if subset.is_empty():
		return
	var wide := 1.5 if kind == 4 else 3.2
	var tall := 1.35 if kind == 4 else 7.1
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = _card_mesh(wide, tall)
	multi.instance_count = subset.size()
	for i in subset.size():
		var spot := subset[i]
		var size := float(spot["size"])
		var basis := Basis.IDENTITY.scaled(Vector3(size, size, size))
		multi.set_instance_transform(i, Transform3D(basis, Vector3(float(spot["x"]), float(spot["y"]), float(spot["z"]))))
	var node := MultiMeshInstance3D.new()
	node.multimesh = multi
	node.material_override = _card_material(kind)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_begin = 165.0
	node.visibility_range_begin_margin = 28.0
	node.visibility_range_end = 255.0
	node.visibility_range_end_margin = 24.0
	node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(node)


func _cached_tree_mesh(kind: int, variant: int) -> ArrayMesh:
	var key := kind * 2 + variant
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var mesh := _tree_mesh(kind, variant)
	_mesh_cache[key] = mesh
	return mesh


func _tree_mesh(kind: int, variant: int) -> ArrayMesh:
	return ProcTree.build(kind, variant)


func _tree_material(kind: int) -> ShaderMaterial:
	if _tree_mats.has(kind):
		return _tree_mats[kind]
	var mat := ProcTree.material(kind)
	_tree_mats[kind] = mat
	return mat


func set_foliage_wind(blow: Vector3, snow: float = 0.0) -> void:
	# Тот же вектор, что в расчёте полёта. Картинка качается, силу это не добавляет:
	# силу ветер и так отдаёт в quadrotor.gd.
	var flat := Vector2(blow.x, blow.z)
	var speed := flat.length()
	var dir := Vector3(1.0, 0.0, 0.0)
	if speed > 0.05:
		dir = Vector3(flat.x / speed, 0.0, flat.y / speed)
	var sway := clampf(speed * 0.045, 0.0, 0.62)
	var rate := clampf(0.65 + speed * 0.09, 0.65, 2.4)
	for kind in _tree_mats:
		var mat: ShaderMaterial = _tree_mats[kind]
		mat.set_shader_parameter("wind_dir", dir)
		mat.set_shader_parameter("wind_strength", sway)
		mat.set_shader_parameter("wind_rate", rate)
	var grass_sway := clampf(speed * 0.02, 0.0, 0.18)
	var cover := clampf(snow, 0.0, 1.0)
	for kind in _grass_mats:
		var mat: ShaderMaterial = _grass_mats[kind]
		mat.set_shader_parameter("wind_dir", dir)
		mat.set_shader_parameter("wind_strength", grass_sway)
		mat.set_shader_parameter("wind_rate", rate)
		mat.set_shader_parameter("snow_amount", cover)


func _add_cylinder(tool: SurfaceTool, base: Vector3, axis: Vector3, r0: float, r1: float, height: float, color: Color, sides: int) -> void:
	if height < 0.02:
		return
	var y := axis.normalized()
	var x := y.cross(Vector3.FORWARD)
	if x.length() < 0.08:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y).normalized()
	var top := base + y * height
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p00 := base + (x * cos(a0) + z * sin(a0)) * r0
		var p10 := base + (x * cos(a1) + z * sin(a1)) * r0
		var p01 := top + (x * cos(a0) + z * sin(a0)) * r1
		var p11 := top + (x * cos(a1) + z * sin(a1)) * r1
		_tri_c(tool, p00, p10, p11, color)
		_tri_c(tool, p00, p11, p01, color)


func _tri_c(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	tool.set_color(color)
	tool.add_vertex(a)
	tool.set_color(color)
	tool.add_vertex(b)
	tool.set_color(color)
	tool.add_vertex(c)


func _card_mesh(width: float, height: float) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := width * 0.5
	tool.set_uv(Vector2(0.0, 0.0))
	tool.add_vertex(Vector3(-half, 0.0, 0.0))
	tool.set_uv(Vector2(1.0, 0.0))
	tool.add_vertex(Vector3(half, 0.0, 0.0))
	tool.set_uv(Vector2(1.0, 1.0))
	tool.add_vertex(Vector3(half, height, 0.0))
	tool.set_uv(Vector2(0.0, 0.0))
	tool.add_vertex(Vector3(-half, 0.0, 0.0))
	tool.set_uv(Vector2(1.0, 1.0))
	tool.add_vertex(Vector3(half, height, 0.0))
	tool.set_uv(Vector2(0.0, 1.0))
	tool.add_vertex(Vector3(-half, height, 0.0))
	return tool.commit()


func _card_material(kind: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _card_shader()
	var leaf := Color(0.12, 0.34, 0.12)
	var bark := Color(0.34, 0.22, 0.12)
	var shape := 0.0
	if kind == 1:
		leaf = Color(0.16, 0.4, 0.14)
	elif kind == 2:
		leaf = Color(0.18, 0.44, 0.15)
		shape = 1.0
	elif kind == 3:
		leaf = Color(0.5, 0.66, 0.28)
		bark = Color(0.86, 0.86, 0.8)
		shape = 1.0
	elif kind == 4:
		leaf = Color(0.2, 0.42, 0.15)
		shape = 1.0
	mat.set_shader_parameter("leaf", Vector3(leaf.r, leaf.g, leaf.b))
	mat.set_shader_parameter("bark", Vector3(bark.r, bark.g, bark.b))
	mat.set_shader_parameter("shape", shape)
	return mat


func _card_shader() -> Shader:
	if _card_shader_res != null:
		return _card_shader_res
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
uniform vec3 leaf = vec3(0.14, 0.36, 0.13);
uniform vec3 bark = vec3(0.34, 0.22, 0.12);
uniform float shape = 0.0;
void vertex() {
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	vec3 cam_z = normalize(INV_VIEW_MATRIX[2].xyz);
	vec3 up = vec3(0.0, 1.0, 0.0);
	if (abs(dot(cam_z, up)) > 0.95) {
		up = vec3(0.0, 0.0, 1.0);
	}
	vec3 right = normalize(cross(up, cam_z));
	vec3 forward = normalize(cross(right, up));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(right * scale.x, 0.0),
		vec4(vec3(0.0, scale.y, 0.0), 0.0),
		vec4(forward * scale.z, 0.0),
		MODEL_MATRIX[3]
	);
}
void fragment() {
	float trunk = step(abs(UV.x - 0.5), 0.055) * step(UV.y, 0.34);
	float spruce = step(abs(UV.x - 0.5), (UV.y - 0.2) * 0.7) * step(0.22, UV.y);
	vec2 q = (UV - vec2(0.5, 0.62)) * vec2(1.15, 1.05);
	float round_crown = step(dot(q, q), 0.2);
	float crown = mix(spruce, round_crown, step(0.5, shape));
	if (max(trunk, crown) < 0.5) {
		discard;
	}
	ALBEDO = mix(bark, leaf, crown);
}
"""
	_card_shader_res = shader
	return shader


func _foliage_material() -> StandardMaterial3D:
	var paint := StandardMaterial3D.new()
	paint.vertex_color_use_as_albedo = true
	paint.roughness = 0.9
	paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	return paint


func _scatter_floor(rng: RandomNumberGenerator) -> void:
	var rocks := 0
	var guard := 0
	while rocks < 18 and guard < 240:
		guard += 1
		var x := rng.randf_range(-28.0, 60.0)
		var z := rng.randf_range(-210.0, -46.0)
		if sample_height(x, z) < 1.1 or _blocked_spot(x, z):
			continue
		_add_rock(x, z, rng.randf_range(0.45, 1.8), rng.randf() * TAU)
		rocks += 1
	_scatter_pebbles(rng)
	_scatter_fallen(rng)


func _scatter_pebbles(rng: RandomNumberGenerator) -> void:
	var mesh := _pebble_mesh()
	var spots: Array[Transform3D] = []
	var guard := 0
	while spots.size() < 140 and guard < 700:
		guard += 1
		var x := rng.randf_range(-130.0, 80.0)
		var z := rng.randf_range(-190.0, 40.0)
		if _blocked_spot(x, z) or _pond_field(x, z) > 0.05:
			continue
		var cut := pow(1.0 - absf(valley_noise.get_noise_2d(x, z)), 4.0)
		if cut < 0.35 and sample_height(x, z) < 1.4 and not in_grove(Vector3(x, 0.0, z)):
			continue
		var y := sample_height(x, z)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.35, 0.95))
		spots.append(Transform3D(basis, Vector3(x, y, z)))
	if spots.is_empty():
		return
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = spots.size()
	for i in spots.size():
		multi.set_instance_transform(i, spots[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = multi
	node.material_override = _foliage_material()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = 80.0
	add_child(node)


func _pebble_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_cylinder(tool, Vector3.ZERO, Vector3.UP, 0.34, 0.1, 0.26, Color(0.5, 0.47, 0.42), 5)
	_add_cylinder(tool, Vector3(0.16, 0.0, 0.06), Vector3.UP, 0.2, 0.07, 0.16, Color(0.44, 0.42, 0.38), 5)
	tool.generate_normals()
	return tool.commit()


func _scatter_fallen(rng: RandomNumberGenerator) -> void:
	var logs := [
		Vector3(-64.0, 14.0, 0.4),
		Vector3(-104.0, 8.0, 1.1),
		Vector3(-90.0, 32.0, 2.2),
		Vector3(-118.0, 24.0, 0.7),
		Vector3(-72.0, -4.0, 1.8),
		Vector3(24.0, -150.0, 0.5),
		Vector3(-34.0, -32.0, 2.6),
	]
	for log in logs:
		if _blocked_spot(log.x, log.y) or _pond_field(log.x, log.y) > 0.05:
			continue
		_add_fallen(log.x, log.y, log.z, rng.randf_range(2.8, 4.2))


func _add_fallen(x: float, z: float, yaw: float, length: float) -> void:
	var y := sample_height(x, z)
	var root := Node3D.new()
	root.position = Vector3(x, y, z)
	root.rotation.y = yaw
	add_child(root)
	var log := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.18
	mesh.bottom_radius = 0.26
	mesh.height = length
	log.mesh = mesh
	log.rotation_degrees = Vector3(0.0, 0.0, 90.0)
	log.position = Vector3(0.0, 0.26, 0.0)
	log.material_override = _paint(Color(0.34, 0.24, 0.14))
	log.visibility_range_end = 160.0
	root.add_child(log)
	var stub := MeshInstance3D.new()
	var stub_mesh := CylinderMesh.new()
	stub_mesh.top_radius = 0.04
	stub_mesh.bottom_radius = 0.07
	stub_mesh.height = 0.7
	stub.mesh = stub_mesh
	stub.position = Vector3(length * 0.2, 0.45, 0.05)
	stub.rotation_degrees = Vector3(18.0, 0.0, 28.0)
	stub.material_override = _paint(Color(0.3, 0.22, 0.12))
	root.add_child(stub)
	# Несколько столбов вдоль той же оси, что и картинка. Так поворот не разъедется с ударом.
	var axis := root.global_transform.basis.x
	axis.y = 0.0
	if axis.length() < 0.01:
		axis = Vector3(1.0, 0.0, 0.0)
	axis = axis.normalized()
	var note := "Столкновение с поваленным стволом. Перелетите или облетите."
	for i in 5:
		var t := (float(i) / 4.0 - 0.5) * length
		var point := Vector3(x, 0.0, z) + axis * t
		_add_solid(point.x, point.z, 0.36, 0.7, note)


func _scatter_tall_grass(rng: RandomNumberGenerator) -> void:
	var mesh := _tall_grass_mesh()
	var spots: Array[Transform3D] = []
	var colors: Array[Color] = []
	var guard := 0
	while spots.size() < 1600 and guard < 5000:
		guard += 1
		var x := rng.randf_range(-140.0, 40.0)
		var z := rng.randf_range(-50.0, 55.0)
		if _blocked_spot(x, z) or _on_course(x, z) or _pond_field(x, z) > 0.08:
			continue
		if sample_height(x, z) > 3.5:
			continue
		var near_grove := in_grove(Vector3(x, 0.0, z)) or Vector2(x + 90.0, z - 16.0).length() < 58.0
		if not near_grove and rng.randf() > 0.25:
			continue
		var y := sample_height(x, z)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.75, 1.35))
		spots.append(Transform3D(basis, Vector3(x, y, z)))
		colors.append(Color(0.7 + rng.randf() * 0.35, 0.85 + rng.randf() * 0.15, 0.65))
	if spots.is_empty():
		return
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.mesh = mesh
	multi.instance_count = spots.size()
	for i in spots.size():
		multi.set_instance_transform(i, spots[i])
		multi.set_instance_color(i, colors[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = multi
	var paint := _paint(Color(0.2, 0.44, 0.16))
	paint.vertex_color_use_as_albedo = true
	node.material_override = paint
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = 58.0
	add_child(node)


func _tall_grass_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_grass_blade(tool, 0.0, 0.9)
	_grass_blade(tool, PI * 0.5, 0.75)
	tool.generate_normals()
	return tool.commit()


func _grass_blade(tool: SurfaceTool, yaw: float, height: float) -> void:
	var c := cos(yaw)
	var s := sin(yaw)
	var a := Vector3(-0.05 * c, 0.0, -0.05 * s)
	var b := Vector3(0.05 * c, 0.0, 0.05 * s)
	_tri(tool, a, b, Vector3(0.0, height, 0.0))


func _add_bush(x: float, z: float, size: float) -> void:
	var y := sample_height(x, z)
	var root := Node3D.new()
	root.position = Vector3(x, y, z)
	root.scale = Vector3.ONE * size
	add_child(root)
	for i in 3:
		var clump := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.08
		mesh.bottom_radius = 0.7
		mesh.height = 1.1
		clump.mesh = mesh
		clump.position = Vector3(cos(float(i) * 2.1) * 0.35, 0.55, sin(float(i) * 2.1) * 0.35)
		clump.material_override = _paint(Color(0.2, 0.4, 0.16))
		root.add_child(clump)
	_add_solid(x, z, 0.7 * size, 1.1 * size, "Столкновение с кустом. Это препятствие, не картинка.")


func _add_rock(x: float, z: float, size: float, yaw: float) -> void:
	var y := sample_height(x, z)
	var root := Node3D.new()
	root.position = Vector3(x, y, z)
	root.rotation.y = yaw
	root.scale = Vector3(size, size * 0.7, size * 0.85)
	add_child(root)
	var offsets := [Vector3(0, 0.35, 0), Vector3(0.35, 0.25, 0.1), Vector3(-0.25, 0.2, 0.3)]
	for offset in offsets:
		var chunk := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.8, 0.55, 0.65)
		chunk.mesh = box
		chunk.position = offset
		chunk.rotation = Vector3(0.2, offset.x, 0.15)
		chunk.material_override = _paint(Color(0.5, 0.48, 0.44))
		root.add_child(chunk)
	_add_solid(x, z, 0.75 * size, 0.9 * size, "Столкновение с камнем. Облетите или перелетите.")


func _add_solid(x: float, z: float, radius: float, height: float, note: String) -> void:
	solids.append({
		"kind": "pole",
		"x": x,
		"z": z,
		"base": sample_height(x, z),
		"radius": radius,
		"height": height,
		"note": note,
	})


func _build_course() -> void:
	_add_ring(Vector3(0.0, 3.4, 70.0), 2.7, 0.38)
	_add_ring(Vector3(12.0, 5.6, 108.0), 2.2, 0.34)
	_add_ring(Vector3(-11.0, 3.1, 146.0), 2.9, 0.4)
	_add_beam(Vector3(2.0, 3.5, 184.0))
	_add_pipe(Vector3(0.0, 2.7, 224.0))
	var poles := [Vector3(-6.0, 0.0, 258.0), Vector3(7.0, 0.0, 270.0), Vector3(-5.0, 0.0, 282.0)]
	for pole in poles:
		var y := sample_height(pole.x, pole.z)
		var post := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.22
		mesh.bottom_radius = 0.28
		mesh.height = 4.5
		post.mesh = mesh
		post.position = Vector3(pole.x, y + 2.25, pole.z)
		post.material_override = _paint(Color(0.75, 0.55, 0.2))
		add_child(post)
		_add_solid(pole.x, pole.z, 0.4, 4.5, "Столкновение со столбом дорожки. Это змейка, столб твёрдый.")


func _add_ring(center: Vector3, hole: float, tube: float) -> void:
	var ring := MeshInstance3D.new()
	var major := hole + tube
	ring.mesh = _ring_mesh(major, tube)
	ring.position = center
	var ring_paint := _metal(Color(0.72, 0.74, 0.76))
	ring_paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = ring_paint
	add_child(ring)
	_add_gate_frame(center, hole)
	solids.append({
		"kind": "ring",
		"center": center,
		"axis": Vector3(0.0, 0.0, 1.0),
		"major": major,
		"tube": tube,
		"note": "Столкновение с ободом кольца. Проходите в отверстие, не в обод.",
	})


func _add_beam(center: Vector3) -> void:
	var beam := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(14.0, 0.42, 0.42)
	beam.mesh = box
	beam.position = center
	beam.material_override = _paint(Color(0.55, 0.56, 0.58))
	add_child(beam)
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.35, center.y, 0.35)
		post.mesh = mesh
		post.position = Vector3(center.x + side * 6.4, center.y * 0.5, center.z)
		post.material_override = _paint(Color(0.5, 0.51, 0.53))
		add_child(post)
		_add_solid(center.x + side * 6.4, center.z, 0.3, center.y, "Столкновение с опорой балки.")
	solids.append({
		"kind": "box",
		"center": center,
		"half": Vector3(7.0, 0.21, 0.21),
		"yaw": 0.0,
		"note": "Столкновение с балкой. Под ней есть просвет, сквозь балку не пройти.",
	})


func _add_pipe(center: Vector3) -> void:
	var length := 14.0
	var inner_r := 2.05
	var outer_r := 2.55
	var tube := _tube_mesh(length, inner_r, outer_r)
	var pipe := MeshInstance3D.new()
	pipe.mesh = tube
	pipe.position = center
	var pipe_paint := _paint(Color(0.45, 0.5, 0.46))
	pipe_paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	pipe.material_override = pipe_paint
	add_child(pipe)
	solids.append({
		"kind": "pipe",
		"center": center,
		"axis": Vector3(0.0, 0.0, 1.0),
		"length": length,
		"inner": inner_r,
		"outer": outer_r,
		"note": "Столкновение со стенкой трубы. Держитесь просвета.",
	})


func _ring_mesh(major: float, tube: float) -> ArrayMesh:
	# Отверстие смотрит вдоль Z, как столкновение. Чужой тор движка не используем, чтобы картинка не разъехалась с расчётом.
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var around := 18
	var tube_steps := 8
	for i in around:
		var a0 := TAU * float(i) / float(around)
		var a1 := TAU * float(i + 1) / float(around)
		var c0 := Vector3(cos(a0), sin(a0), 0.0)
		var c1 := Vector3(cos(a1), sin(a1), 0.0)
		for j in tube_steps:
			var b0 := TAU * float(j) / float(tube_steps)
			var b1 := TAU * float(j + 1) / float(tube_steps)
			var p00 := c0 * major + _tube_offset(c0, b0, tube)
			var p10 := c1 * major + _tube_offset(c1, b0, tube)
			var p11 := c1 * major + _tube_offset(c1, b1, tube)
			var p01 := c0 * major + _tube_offset(c0, b1, tube)
			_tri(tool, p00, p10, p11)
			_tri(tool, p00, p11, p01)
	tool.generate_normals()
	return tool.commit()


func _tube_offset(radial: Vector3, angle: float, tube: float) -> Vector3:
	return radial * cos(angle) * tube + Vector3(0.0, 0.0, sin(angle) * tube)


func _add_gate_frame(center: Vector3, hole: float) -> void:
	var metal := _metal(Color(0.62, 0.64, 0.66))
	var span := hole + 1.3
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.28, center.y + span, 0.28)
		post.mesh = box
		post.position = Vector3(center.x + side * span, (center.y + span) * 0.5, center.z)
		post.material_override = metal
		add_child(post)
		_add_solid(center.x + side * span, center.z, 0.28, center.y + span, "Столкновение со стойкой ворот. Проходите в проём.")
	var header := MeshInstance3D.new()
	var bar := BoxMesh.new()
	bar.size = Vector3(span * 2.0 + 0.4, 0.28, 0.28)
	header.mesh = bar
	header.position = Vector3(center.x, center.y + span, center.z)
	header.material_override = metal
	add_child(header)


func _build_road() -> void:
	var asphalt := _paint(Color(0.28, 0.29, 0.3))
	asphalt.roughness = 0.82
	for i in 12:
		var z := 58.0 + float(i) * 18.0
		var plate := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(7.0, 0.05, 16.0)
		plate.mesh = box
		plate.position = Vector3(0.0, sample_height(0.0, z) + 0.05, z)
		plate.material_override = asphalt
		add_child(plate)


func _build_yard() -> void:
	_add_pylon(-24.0, 36.0)
	_add_pylon(36.0, -28.0)
	_add_pylon(128.0, 48.0)
	var blocks := [Vector3(18.0, 0.0, 88.0), Vector3(-18.0, 0.0, 124.0), Vector3(16.0, 0.0, 168.0)]
	for block in blocks:
		var y := sample_height(block.x, block.z)
		var chunk := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.8, 1.1, 1.4)
		chunk.mesh = box
		chunk.position = Vector3(block.x, y + 0.55, block.z)
		chunk.material_override = _paint(Color(0.62, 0.62, 0.6))
		add_child(chunk)
		_add_solid(block.x, block.z, 1.05, 1.2, "Столкновение с бетонным блоком. Это препятствие, не декорация.")


func _add_pylon(x: float, z: float) -> void:
	var y := sample_height(x, z)
	var metal := _metal(Color(0.58, 0.6, 0.62))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var leg := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.16, 9.0, 0.16)
			leg.mesh = box
			leg.position = Vector3(x + sx * 1.15, y + 4.5, z + sz * 1.15)
			leg.material_override = metal
			add_child(leg)
	var arm := MeshInstance3D.new()
	var bar := BoxMesh.new()
	bar.size = Vector3(4.2, 0.14, 0.14)
	arm.mesh = bar
	arm.position = Vector3(x, y + 8.2, z)
	arm.material_override = metal
	add_child(arm)
	_add_solid(x, z, 1.5, 9.0, "Столкновение с опорой ЛЭП. Облетите вышку.")


func _build_dense_forest() -> void:
	# Густая зона на западе. Шум оставляет поляны внутри кучи, не ровную решётку.
	var rng := RandomNumberGenerator.new()
	rng.seed = 29
	var clumps: Array[Vector3] = [
		Vector3(-98.0, 16.0, 20.0),
		Vector3(-132.0, 38.0, 16.0),
		Vector3(-74.0, 46.0, 15.0),
	]
	var placed: Array[Vector2] = []
	for clump in clumps:
		var spots: Array[Dictionary] = []
		var tries := 0
		while spots.size() < 34 and tries < 220:
			tries += 1
			var ang := rng.randf() * TAU
			var dist := clump.z * sqrt(rng.randf())
			var x := clump.x + cos(ang) * dist
			var z := clump.y + sin(ang) * dist
			if forest_noise.get_noise_2d(x, z) < -0.16:
				continue
			if not _tree_spot_ok(x, z, placed, 2.7):
				continue
			placed.append(Vector2(x, z))
			var kind := _cluster_kind(clump, rng)
			var size := rng.randf_range(0.85, 1.3)
			_remember_tree(spots, x, z, kind, size, rng.randf() * TAU, rng.randi_range(0, 1))
		_flush_cluster(spots)


func _build_zones() -> void:
	_build_canyon_gates()
	_build_industrial()
	_build_fpv_track()


func _build_canyon_gates() -> void:
	for z in [-128.0, -156.0, -184.0]:
		_add_canyon_gate(_canyon_center_x(z), z)


func _add_canyon_gate(x: float, z: float) -> void:
	var bed := sample_height(x, z)
	var hole := 2.25
	var center_y := WATER_Y + 4.7
	var center := Vector3(x, center_y, z)
	var ring := MeshInstance3D.new()
	ring.mesh = _ring_mesh(hole + 0.32, 0.32)
	ring.position = center
	var paint := _metal(Color(0.7, 0.72, 0.66))
	paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = paint
	_far(ring, 220.0)
	add_child(ring)
	solids.append({
		"kind": "ring",
		"center": center,
		"axis": Vector3(0.0, 0.0, 1.0),
		"major": hole + 0.32,
		"tube": 0.32,
		"note": "Столкновение с воротами каньона. Проходите в отверстие над водой.",
	})
	var top := center_y + hole + 0.35
	var metal := _metal(Color(0.58, 0.6, 0.56))
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var box := BoxMesh.new()
		var height := maxf(top - bed, 1.0)
		box.size = Vector3(0.28, height, 0.28)
		post.mesh = box
		post.position = Vector3(x + side * (hole + 0.7), bed + height * 0.5, z)
		post.material_override = metal
		_far(post, 220.0)
		add_child(post)
		_add_solid(x + side * (hole + 0.7), z, 0.28, height, "Столкновение со стойкой ворот каньона.")
	var header := MeshInstance3D.new()
	var bar := BoxMesh.new()
	bar.size = Vector3((hole + 0.7) * 2.0 + 0.4, 0.26, 0.26)
	header.mesh = bar
	header.position = Vector3(x, top, z)
	header.material_override = metal
	_far(header, 220.0)
	add_child(header)


func _build_industrial() -> void:
	var ground := sample_height(164.0, 4.0)
	_add_csg_box(Vector3(158.0, ground + 3.1, -2.0), Vector3(16.0, 6.2, 11.0), Color(0.45, 0.42, 0.38), Vector3(8.0, 3.1, 5.5), "Столкновение со зданием промзоны. Это стена, не декорация.")
	_add_csg_box(Vector3(182.0, ground + 2.4, 16.0), Vector3(10.0, 4.8, 8.0), Color(0.4, 0.38, 0.36), Vector3(5.0, 2.4, 4.0), "Столкновение со складом промзоны.")
	_add_csg_tank(Vector3(172.0, ground + 2.2, -16.0), 1.6, 4.4)
	_add_csg_tank(Vector3(186.0, ground + 1.7, -8.0), 1.2, 3.4)
	_add_csg_tank(Vector3(148.0, ground + 1.9, 18.0), 1.35, 3.8)
	_build_fence(Vector3(146.0, ground, -22.0), 22, 16)
	_add_yard_pipes(ground)


func _add_csg_box(pos: Vector3, size: Vector3, color: Color, half: Vector3, note: String) -> void:
	var box := CSGBox3D.new()
	box.size = size
	box.position = pos
	box.use_collision = false
	box.material = _paint(color)
	_far(box, 230.0)
	add_child(box)
	solids.append({
		"kind": "box",
		"center": pos,
		"half": half,
		"yaw": 0.0,
		"note": note,
	})


func _add_csg_tank(pos: Vector3, radius: float, height: float) -> void:
	var tank := CSGCylinder3D.new()
	tank.radius = radius
	tank.height = height
	tank.sides = 12
	tank.position = pos
	tank.use_collision = false
	tank.material = _metal(Color(0.55, 0.5, 0.42))
	_far(tank, 230.0)
	add_child(tank)
	_add_solid(pos.x, pos.z, radius, height, "Столкновение с цистерной. Облетите или перелетите.")


func _build_fence(origin: Vector3, cells_x: int, cells_z: int) -> void:
	var lib := MeshLibrary.new()
	var panel := BoxMesh.new()
	panel.size = Vector3(1.85, 1.35, 0.16)
	panel.material = _paint(Color(0.58, 0.57, 0.54))
	lib.create_item(0)
	lib.set_item_name(0, "fence")
	lib.set_item_mesh(0, panel)
	var post := BoxMesh.new()
	post.size = Vector3(0.28, 2.1, 0.28)
	post.material = _paint(Color(0.42, 0.42, 0.4))
	lib.create_item(1)
	lib.set_item_name(1, "post")
	lib.set_item_mesh(1, post)
	var grid := GridMap.new()
	grid.mesh_library = lib
	grid.cell_size = Vector3(2.0, 2.0, 2.0)
	grid.position = origin + Vector3(0.0, -0.55, 0.0)
	add_child(grid)
	for i in cells_x:
		grid.set_cell_item(Vector3i(i, 0, 0), 0 if i % 2 == 0 else 1)
		grid.set_cell_item(Vector3i(i, 0, cells_z), 0 if i % 2 == 0 else 1)
	for i in cells_z:
		grid.set_cell_item(Vector3i(0, 0, i), 1 if i % 2 == 0 else 0)
		grid.set_cell_item(Vector3i(cells_x, 0, i), 1 if i % 2 == 0 else 0)
	var y := origin.y + 0.7
	var span_x := float(cells_x) * 2.0
	var span_z := float(cells_z) * 2.0
	_fence_solid(origin + Vector3(span_x * 0.5, 0.7, 0.0), Vector3(span_x * 0.5, 0.7, 0.2))
	_fence_solid(origin + Vector3(span_x * 0.5, 0.7, span_z), Vector3(span_x * 0.5, 0.7, 0.2))
	_fence_solid(origin + Vector3(0.0, 0.7, span_z * 0.5), Vector3(0.2, 0.7, span_z * 0.5))
	_fence_solid(origin + Vector3(span_x, 0.7, span_z * 0.5), Vector3(0.2, 0.7, span_z * 0.5))


func _fence_solid(center: Vector3, half: Vector3) -> void:
	solids.append({
		"kind": "box",
		"center": center,
		"half": half,
		"yaw": 0.0,
		"note": "Столкновение с бетонным забором промзоны.",
	})


func _add_yard_pipes(ground: float) -> void:
	var joints: Array[Vector3] = [
		Vector3(160.0, ground + 0.45, 8.0),
		Vector3(170.0, ground + 0.45, 8.0),
		Vector3(170.0, ground + 0.45, 14.0),
	]
	for i in joints.size() - 1:
		var a: Vector3 = joints[i]
		var b: Vector3 = joints[i + 1]
		var mid := (a + b) * 0.5
		var span := b - a
		var pipe := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.22
		mesh.bottom_radius = 0.22
		mesh.height = maxf(span.length(), 0.4)
		pipe.mesh = mesh
		pipe.position = mid
		pipe.basis = _along(span.normalized())
		pipe.material_override = _metal(Color(0.42, 0.45, 0.4))
		_far(pipe, 200.0)
		add_child(pipe)
		solids.append({
			"kind": "box",
			"center": mid,
			"half": Vector3(maxf(absf(span.x), 0.3) * 0.5 + 0.2, 0.28, maxf(absf(span.z), 0.3) * 0.5 + 0.2),
			"yaw": 0.0,
			"note": "Столкновение с трубой промзоны.",
		})


func _build_fpv_track() -> void:
	var path := Path3D.new()
	var curve := Curve3D.new()
	curve.bake_interval = 6.0
	var points := _fpv_points()
	for point in points:
		curve.add_point(Vector3(point.x, sample_height(point.x, point.z) + 3.2, point.z))
	path.curve = curve
	add_child(path)
	var baked := curve.get_baked_points()
	var step := 5
	var index := step
	var gate := 0
	while index < baked.size() - 2:
		var here: Vector3 = baked[index]
		var nxt: Vector3 = baked[mini(index + 1, baked.size() - 1)]
		var forward := nxt - here
		if gate % 2 == 0:
			_add_facing_ring(here, forward, 2.15)
		else:
			var side := 1.0 if gate % 4 == 1 else -1.0
			var flat := Vector3(forward.x, 0.0, forward.z)
			if flat.length() < 0.01:
				flat = Vector3(1.0, 0.0, 0.0)
			flat = flat.normalized()
			var left := Vector3(-flat.z, 0.0, flat.x)
			var spot := here + left * 3.4 * side
			_add_flag(spot.x, spot.z)
		gate += 1
		index += step
	if baked.size() > 8:
		var mid := int(baked.size() / 2)
		var a: Vector3 = baked[mid]
		var b: Vector3 = baked[mini(mid + 1, baked.size() - 1)]
		var ground_y := sample_height(a.x, a.z)
		_add_facing_pipe(Vector3(a.x, ground_y + 2.35, a.z), b - a)


func _add_facing_ring(center: Vector3, forward: Vector3, hole: float) -> void:
	var root := Node3D.new()
	root.position = center
	add_child(root)
	var flat := Vector3(forward.x, 0.0, forward.z)
	if flat.length() < 0.01:
		flat = Vector3(0.0, 0.0, 1.0)
	flat = flat.normalized()
	root.look_at(center - flat, Vector3.UP)
	var ring := MeshInstance3D.new()
	ring.mesh = _ring_mesh(hole + 0.3, 0.3)
	var paint := _metal(Color(0.78, 0.32, 0.18))
	paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = paint
	_far(ring, 210.0)
	root.add_child(ring)
	solids.append({
		"kind": "ring",
		"center": center,
		"axis": flat,
		"major": hole + 0.3,
		"tube": 0.3,
		"note": "Столкновение с кольцом трассы. Проходите в отверстие.",
	})


func _add_flag(x: float, z: float) -> void:
	var y := sample_height(x, z)
	var post := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.06
	mesh.bottom_radius = 0.08
	mesh.height = 2.8
	post.mesh = mesh
	post.position = Vector3(x, y + 1.4, z)
	post.material_override = _paint(Color(0.85, 0.25, 0.15))
	_far(post, 180.0)
	add_child(post)
	var flag := MeshInstance3D.new()
	var cloth := BoxMesh.new()
	cloth.size = Vector3(0.7, 0.38, 0.04)
	flag.mesh = cloth
	flag.position = Vector3(x + 0.35, y + 2.5, z)
	flag.material_override = _paint(Color(0.9, 0.75, 0.15))
	_far(flag, 180.0)
	add_child(flag)
	_add_solid(x, z, 0.18, 2.8, "Столкновение с флажком слалома. Это препятствие трассы.")


func _add_facing_pipe(center: Vector3, forward: Vector3) -> void:
	var flat := Vector3(forward.x, 0.0, forward.z)
	if flat.length() < 0.01:
		flat = Vector3(0.0, 0.0, 1.0)
	flat = flat.normalized()
	var length := 12.0
	var root := Node3D.new()
	root.position = center
	add_child(root)
	root.look_at(center + flat, Vector3.UP)
	var pipe := MeshInstance3D.new()
	pipe.mesh = _tube_mesh(length, 1.9, 2.35)
	var paint := _paint(Color(0.42, 0.48, 0.44))
	paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	pipe.material_override = paint
	_far(pipe, 210.0)
	root.add_child(pipe)
	solids.append({
		"kind": "pipe",
		"center": center,
		"axis": flat,
		"length": length,
		"inner": 1.9,
		"outer": 2.35,
		"note": "Столкновение со стенкой тоннеля трассы. Держитесь просвета.",
	})


func _far(node: GeometryInstance3D, end: float) -> void:
	node.visibility_range_end = end
	node.visibility_range_end_margin = 28.0
	node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


func _grass_spot_ok(x: float, z: float) -> bool:
	if Vector2(x, z).length() < 13.0 or _on_course(x, z) or _pond_field(x, z) > 0.06:
		return false
	if _canyon_field(x, z) > 0.18 or _fpv_distance(x, z) < 4.2:
		return false
	var h := sample_height(x, z)
	return h >= WATER_Y + 0.25 and h <= 4.0


func _build_grass() -> void:
	# Не отдельные палочки, а ковёр: рисунок на земле плюс крупные пучки с той же текстурой.
	# Пакеты по клеткам, иначе дальность считается от центра поля.
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var buckets: Dictionary = {}
	var step := 1.15
	for iz in range(int(floor(-175.0 / step)), int(ceil(210.0 / step))):
		for ix in range(int(floor(-155.0 / step)), int(ceil(165.0 / step))):
			var x := float(ix) * step + rng.randf_range(-0.34, 0.34)
			var z := float(iz) * step + rng.randf_range(-0.34, 0.34)
			if not _grass_spot_ok(x, z):
				continue
			var dist := Vector2(x, z).length()
			if dist > 72.0 and rng.randf() > 0.5:
				continue
			if dist > 120.0 and rng.randf() > 0.22:
				continue
			if dist > 175.0:
				continue
			var kind := 1
			if dist < 42.0:
				kind = 0 if rng.randf() < 0.55 else 1
			elif rng.randf() < 0.16:
				kind = 3
			elif rng.randf() < 0.34:
				kind = 2
			var key := "%d:%d:%d" % [int(floor(x / 64.0)), int(floor(z / 64.0)), kind]
			if not buckets.has(key):
				buckets[key] = []
			var chunk: Array = buckets[key]
			var scale := rng.randf_range(0.85, 1.15)
			if kind == 0:
				scale *= 0.72
			elif kind == 2:
				scale *= 1.28
			elif kind == 3:
				scale *= 0.9
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * scale)
			chunk.append(Transform3D(basis, Vector3(x, sample_height(x, z) + 0.02, z)))
			buckets[key] = chunk
	for key in buckets:
		var rows: Array = buckets[key]
		if rows.is_empty():
			continue
		var parts := str(key).split(":")
		var kind := 0
		if parts.size() > 2:
			kind = int(parts[2])
		var origin := Vector3(float(parts[0]) * 64.0 + 32.0, 0.0, float(parts[1]) * 64.0 + 32.0)
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = _grass_card_mesh()
		multi.instance_count = rows.size()
		for i in rows.size():
			var world := rows[i] as Transform3D
			multi.set_instance_transform(i, Transform3D(world.basis, world.origin - origin))
		var node := MultiMeshInstance3D.new()
		node.position = origin
		node.multimesh = multi
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.visibility_range_end = 150.0
		node.visibility_range_end_margin = 36.0
		node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		node.extra_cull_margin = 6.0
		node.material_override = _grass_material(kind)
		add_child(node)


func _grass_card_mesh() -> ArrayMesh:
	if _mesh_cache.has(90):
		return _mesh_cache[90]
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Две наклонённые карточки. На каждой нарисован пучок, не одна палочка.
	# Наклон нужен, чтобы сверху, с дрона, была видна плоскость текстуры.
	_grass_card(tool, 0.0, 1.35, 0.78, 0.34)
	_grass_card(tool, PI * 0.5, 1.15, 0.7, -0.28)
	var mesh := tool.commit()
	_mesh_cache[90] = mesh
	return mesh


func _grass_card(tool: SurfaceTool, yaw: float, width: float, height: float, lean: float) -> void:
	var across := Vector3(cos(yaw), 0.0, sin(yaw))
	var forward := Vector3(-sin(yaw), 0.0, cos(yaw))
	var half := width * 0.5
	var root_l := -across * half
	var root_r := across * half
	var tip_shift := Vector3.UP * height + forward * lean
	var tip_l := -across * half * 0.78 + tip_shift
	var tip_r := across * half * 0.78 + tip_shift
	_grass_uv(tool, root_l, Vector2(0.0, 0.0), Color(0.0, 0.2, 0.4, 1.0))
	_grass_uv(tool, root_r, Vector2(1.0, 0.0), Color(0.0, 0.5, 0.6, 1.0))
	_grass_uv(tool, tip_r, Vector2(1.0, 1.0), Color(1.0, 0.5, 0.8, 1.0))
	_grass_uv(tool, root_l, Vector2(0.0, 0.0), Color(0.0, 0.2, 0.4, 1.0))
	_grass_uv(tool, tip_r, Vector2(1.0, 1.0), Color(1.0, 0.5, 0.8, 1.0))
	_grass_uv(tool, tip_l, Vector2(0.0, 1.0), Color(1.0, 0.2, 0.7, 1.0))


func _grass_uv(tool: SurfaceTool, point: Vector3, uv: Vector2, color: Color) -> void:
	tool.set_uv(uv)
	tool.set_color(color)
	tool.add_vertex(point)


func _grass_kind_mesh(kind: int) -> ArrayMesh:
	var key := 100 + kind
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Четыре пучка, как четыре материала в описании: короткая, обычная, высокая, сухая.
	# У каждой травинки свой сдвиг фазы, иначе пучок качается одной доской.
	if kind == 0:
		_tuft_blade(tool, 0.0, 0.42, 0.09, 0.15)
		_tuft_blade(tool, 1.15, 0.34, 0.07, 0.55)
		_tuft_blade(tool, 2.3, 0.28, 0.06, 0.82)
	elif kind == 1:
		_tuft_blade(tool, 0.2, 0.72, 0.07, 0.2)
		_tuft_blade(tool, 1.7, 0.58, 0.06, 0.48)
		_tuft_blade(tool, 2.8, 0.5, 0.05, 0.77)
	elif kind == 2:
		_tuft_blade(tool, 0.4, 1.05, 0.055, 0.12)
		_tuft_blade(tool, 1.5, 0.86, 0.048, 0.4)
		_tuft_blade(tool, 2.4, 0.7, 0.04, 0.7)
	else:
		_tuft_blade(tool, 0.15, 0.5, 0.1, 0.3)
		_tuft_blade(tool, 1.3, 0.42, 0.08, 0.6)
		_tuft_blade(tool, 2.5, 0.36, 0.07, 0.9)
	tool.generate_normals()
	var mesh := tool.commit()
	_mesh_cache[key] = mesh
	return mesh


func _grass_material(kind: int) -> ShaderMaterial:
	if _grass_mats.has(kind):
		return _grass_mats[kind]
	var greens: Array[Color] = [
		Color(0.32, 0.56, 0.18),
		Color(0.2, 0.46, 0.15),
		Color(0.13, 0.34, 0.11),
		Color(0.46, 0.48, 0.18),
	]
	var dry: Array[Color] = [
		Color(0.42, 0.58, 0.2),
		Color(0.38, 0.5, 0.16),
		Color(0.3, 0.4, 0.14),
		Color(0.62, 0.5, 0.22),
	]
	var hold := 1.0
	if kind == 0:
		hold = 0.7
	elif kind == 2:
		hold = 1.2
	elif kind == 3:
		hold = 0.5
	var mat := ShaderMaterial.new()
	mat.shader = _grass_shader()
	var base: Color = greens[kind]
	var straw: Color = dry[kind]
	mat.set_shader_parameter("base_color", Vector3(base.r, base.g, base.b))
	mat.set_shader_parameter("dry_color", Vector3(straw.r, straw.g, straw.b))
	mat.set_shader_parameter("hold", hold)
	mat.set_shader_parameter("clump_tex", load("res://textures/grass_clump.png"))
	_grass_mats[kind] = mat
	return mat


func _grass_shader() -> Shader:
	if _grass_shader_res != null:
		return _grass_shader_res
	var shader := Shader.new()
	# Три слоя ветра и снег от кончика — идея из описания пакета EmacE Art.
	# Их шейдер сюда не копировался: у пакета своя лицензия, а нам нужен Compatibility.
	shader.code = """shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, specular_disabled;
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.3);
uniform float wind_strength = 0.08;
uniform float wind_rate = 1.1;
uniform float snow_amount = 0.0;
uniform float hold = 1.0;
uniform vec3 base_color = vec3(0.22, 0.46, 0.16);
uniform vec3 dry_color = vec3(0.5, 0.46, 0.2);
uniform sampler2D clump_tex : filter_linear, repeat_disable, source_color;
varying vec3 world_pos;
varying float tip_amount;
void vertex() {
	tip_amount = UV.y;
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos = world;
	vec2 inst = MODEL_MATRIX[3].xz;
	float clump = fract(sin(dot(inst, vec2(12.9898, 78.233))) * 43758.5453);
	float phase = (COLOR.g + clump) * 6.28318;
	float own = sin(TIME * wind_rate * 1.6 + phase);
	float along = dot(world.xz, wind_dir.xz);
	float gust = sin(TIME * wind_rate * 0.52 + along * 0.16);
	float tremble = sin(TIME * wind_rate * 4.4 + phase * 1.7) * 0.22;
	float bend = (own * 0.4 + gust * 0.75 + tremble) * wind_strength * hold * tip_amount;
	vec3 side = vec3(-wind_dir.z, 0.0, wind_dir.x);
	vec3 blow = wind_dir + side * (COLOR.b - 0.5) * 0.7;
	vec3 local_blow = (inverse(MODEL_MATRIX) * vec4(blow * bend, 0.0)).xyz;
	VERTEX += local_blow;
	VERTEX.y += abs(bend) * 0.12 * tip_amount;
}
void fragment() {
	float patch = sin(world_pos.x * 0.06 + world_pos.z * 0.045) * 0.5 + 0.5;
	float band = sin(dot(world_pos.xz, wind_dir.xz) * 0.2 - TIME * wind_rate * 0.32) * 0.5 + 0.5;
	vec4 blade = texture(clump_tex, UV);
	if (blade.a < 0.32) {
		discard;
	}
	vec3 color = blade.rgb;
	color = mix(color, color * base_color * vec3(2.1, 2.3, 1.6), 0.28);
	color = mix(color, color * dry_color * vec3(2.2, 1.8, 1.1), (1.0 - hold) * 0.45);
	color = mix(color, color * vec3(1.08, 1.02, 0.72), band * 0.18);
	float snow_line = 1.0 - snow_amount * 0.9;
	float snow = smoothstep(snow_line - 0.18, snow_line + 0.04, tip_amount);
	snow *= snow_amount * (0.45 + 0.55 * patch);
	color = mix(color, vec3(0.93, 0.95, 0.97), snow);
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	ALBEDO = color;
	ROUGHNESS = 0.92;
}
"""
	_grass_shader_res = shader
	return shader


func _grass_tri(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	tool.set_color(ca)
	tool.add_vertex(a)
	tool.set_color(cb)
	tool.add_vertex(b)
	tool.set_color(cc)
	tool.add_vertex(c)


func _tuft_blade(tool: SurfaceTool, yaw: float, height: float, half_w: float, phase: float) -> void:
	# Лента из двух звеньев, не один треугольник. Красный канал — насколько точку гнёт ветер:
	# у земли 0, на кончике 1. Зелёный — свой ритм травинки внутри пучка.
	var across := Vector3(cos(yaw), 0.0, sin(yaw))
	var forward := Vector3(-sin(yaw), 0.0, cos(yaw))
	var curve := forward * height * 0.32
	var root_l := -across * half_w
	var root_r := across * half_w
	var mid := Vector3(0.0, height * 0.46, 0.0) + curve * 0.4
	var mid_l := mid - across * half_w * 0.58
	var mid_r := mid + across * half_w * 0.58
	var tip := Vector3(0.0, height, 0.0) + curve
	var tip_l := tip - across * half_w * 0.1
	var tip_r := tip + across * half_w * 0.1
	var c0 := Color(0.0, phase, 0.42, 1.0)
	var c1 := Color(0.4, phase, 0.6, 1.0)
	var c2 := Color(1.0, phase, 0.82, 1.0)
	_grass_tri(tool, root_l, root_r, mid_r, c0, c0, c1)
	_grass_tri(tool, root_l, mid_r, mid_l, c0, c1, c1)
	_grass_tri(tool, mid_l, mid_r, tip_r, c1, c1, c2)
	_grass_tri(tool, mid_l, tip_r, tip_l, c1, c2, c2)


func _grass_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_grass_quad(tool, 0.0)
	_grass_quad(tool, PI * 0.5)
	tool.generate_normals()
	return tool.commit()


func _grass_quad(tool: SurfaceTool, yaw: float) -> void:
	var c := cos(yaw)
	var s := sin(yaw)
	var a := Vector3(-0.08 * c, 0.0, -0.08 * s)
	var b := Vector3(0.08 * c, 0.0, 0.08 * s)
	var top := Vector3(0.0, 0.55, 0.0)
	_tri(tool, a, b, top)


func _water_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_schlick_ggx;
varying float basin_depth;
void vertex() {
	basin_depth = COLOR.r;
	VERTEX.y += sin(VERTEX.x * 0.35 + TIME * 0.9) * 0.04;
	VERTEX.y += cos(VERTEX.z * 0.28 + TIME * 0.6) * 0.03;
}
void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.2);
	vec3 shallow = vec3(0.28, 0.58, 0.56);
	vec3 deep = vec3(0.02, 0.07, 0.14);
	vec3 color = mix(shallow, deep, smoothstep(0.08, 0.72, basin_depth));
	color = mix(color, vec3(0.7, 0.84, 0.9), fresnel * 0.4);
	ALBEDO = color;
	// Берег прозрачный, глубина тёмная. Экранный Depth Fade в Compatibility нет.
	ALPHA = mix(0.16, 0.88, smoothstep(0.0, 0.42, basin_depth));
	ALPHA = mix(ALPHA, min(ALPHA, 0.62), fresnel);
	ROUGHNESS = mix(0.22, 0.05, fresnel);
	METALLIC = 0.04;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


func _metal(color: Color) -> StandardMaterial3D:
	var paint := _paint(color)
	paint.metallic = 0.62
	paint.roughness = 0.38
	return paint


func _tube_mesh(length: float, inner_r: float, outer_r: float) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides := 14
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		_tube_quad(tool, d0, d1, outer_r, -length * 0.5, length * 0.5, true)
		_tube_quad(tool, d0, d1, inner_r, -length * 0.5, length * 0.5, false)
	tool.generate_normals()
	return tool.commit()


func _tube_quad(tool: SurfaceTool, d0: Vector2, d1: Vector2, radius: float, z0: float, z1: float, outward: bool) -> void:
	var p00 := Vector3(d0.x * radius, d0.y * radius, z0)
	var p10 := Vector3(d1.x * radius, d1.y * radius, z0)
	var p11 := Vector3(d1.x * radius, d1.y * radius, z1)
	var p01 := Vector3(d0.x * radius, d0.y * radius, z1)
	if outward:
		_tri(tool, p00, p10, p11)
		_tri(tool, p00, p11, p01)
	else:
		_tri(tool, p00, p11, p10)
		_tri(tool, p00, p01, p11)


func _tri(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	tool.add_vertex(a)
	tool.add_vertex(b)
	tool.add_vertex(c)


func _hit_solid(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
	var kind := str(item["kind"])
	if kind == "pole":
		return _hit_pole(item, pos, radius)
	if kind == "ring":
		return _hit_ring(item, pos, radius)
	if kind == "box":
		return _hit_box(item, pos, radius)
	if kind == "pipe":
		return _hit_pipe(item, pos, radius)
	return {}


func _hit_pole(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
	var dx := pos.x - float(item["x"])
	var dz := pos.z - float(item["z"])
	var dist := Vector2(dx, dz).length()
	var height := float(item["height"])
	var base := float(item.get("base", 0.0))
	var pole_r := float(item["radius"])
	if pos.y > base + height + radius or pos.y < base - radius:
		return {}
	if dist >= pole_r + radius:
		return {}
	var normal := Vector3(dx, 0.0, dz)
	if normal.length() < 0.001:
		normal = Vector3(1.0, 0.0, 0.0)
	else:
		normal = normal.normalized()
	return {"normal": normal, "depth": pole_r + radius - dist, "note": str(item["note"])}


func _hit_ring(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
	var center: Vector3 = item["center"]
	var axis: Vector3 = item["axis"]
	var rel := pos - center
	var along := rel.dot(axis)
	var radial_vec := rel - axis * along
	var radial := radial_vec.length()
	if radial < 0.05:
		return {}
	var tube_center := center + radial_vec / radial * float(item["major"])
	var gap := pos - tube_center
	var dist := gap.length()
	var limit := float(item["tube"]) + radius
	if dist >= limit:
		return {}
	var normal := gap / maxf(dist, 0.001)
	return {"normal": normal, "depth": limit - dist, "note": str(item["note"])}


func _hit_box(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
	var center: Vector3 = item["center"]
	var half: Vector3 = item["half"]
	var yaw := float(item["yaw"])
	var local := pos - center
	var c := cos(yaw)
	var s := sin(yaw)
	var lx := local.x * c + local.z * s
	var lz := -local.x * s + local.z * c
	var ly := local.y
	var expanded := half + Vector3(radius, radius, radius)
	if absf(lx) > expanded.x or absf(ly) > expanded.y or absf(lz) > expanded.z:
		return {}
	var pen := Vector3(expanded.x - absf(lx), expanded.y - absf(ly), expanded.z - absf(lz))
	var normal := Vector3(c, 0.0, s) * signf(lx)
	var depth := pen.x
	if pen.y < depth:
		normal = Vector3(0.0, signf(ly), 0.0)
		depth = pen.y
	if pen.z < depth:
		normal = Vector3(-s, 0.0, c) * signf(lz)
		depth = pen.z
	return {"normal": normal, "depth": depth, "note": str(item["note"])}


func _hit_pipe(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
	var center: Vector3 = item["center"]
	var axis: Vector3 = item["axis"]
	var rel := pos - center
	var along := rel.dot(axis)
	var half_len := float(item["length"]) * 0.5
	if absf(along) > half_len + radius:
		return {}
	var radial_vec := rel - axis * along
	var radial := radial_vec.length()
	if radial < 0.001:
		radial_vec = Vector3(1.0, 0.0, 0.0)
		radial = 0.001
	var outward := radial_vec / radial
	var inner_r := float(item["inner"])
	var outer_r := float(item["outer"])
	if radial - radius > outer_r:
		return {}
	if absf(along) <= half_len and radial + radius < inner_r:
		return {}
	var note := str(item["note"])
	if absf(along) > half_len:
		if radial < inner_r - radius:
			return {}
		return {"normal": axis * signf(along), "depth": half_len + radius - absf(along), "note": note}
	if radial < (inner_r + outer_r) * 0.5:
		return {"normal": -outward, "depth": radial + radius - inner_r, "note": note}
	return {"normal": outward, "depth": outer_r + radius - radial, "note": note}


func _trunk(root: Node3D, radius: float, height: float, color: Color) -> void:
	var trunk := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.75
	mesh.bottom_radius = radius
	mesh.height = height
	trunk.mesh = mesh
	trunk.position = Vector3(0.0, height * 0.5, 0.0)
	trunk.material_override = _paint(color)
	root.add_child(trunk)


func _along(dir: Vector3) -> Basis:
	var y_axis := dir.normalized()
	var side := y_axis.cross(Vector3.UP)
	if side.length() < 0.05:
		side = Vector3.RIGHT
	side = side.normalized()
	return Basis(side, y_axis, side.cross(y_axis).normalized())


func _paint(color: Color) -> StandardMaterial3D:
	var paint := StandardMaterial3D.new()
	paint.albedo_color = color
	paint.roughness = 0.86
	return paint


func _add_sign(text: String, pos: Vector3) -> void:
	var sign_label := Label3D.new()
	sign_label.text = text
	sign_label.position = pos
	sign_label.font_size = 48
	sign_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sign_label.modulate = Color(0.95, 0.95, 0.9)
	add_child(sign_label)
