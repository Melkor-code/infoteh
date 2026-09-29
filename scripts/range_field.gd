extends Node3D

const FlightModel = preload("res://scripts/flight_model.gd")

## Полигон собирается здесь, не в чужом симуляторе.
## Высота земли и картинка — одна функция: иначе аппарат садится сквозь холм.
## Готовые CC0-модели с сайтов авторов отсюда не скачались, поэтому деревья и
## камни собраны сетками в коде. Это не палки с одним шаром и не конус-горка.
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

var crowns: Array[Dictionary] = []
var solids: Array[Dictionary] = []
var relief_noise := FastNoiseLite.new()
var valley_noise := FastNoiseLite.new()


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
	_build_ground()
	_build_water()
	_build_pier()
	_build_pad_marks()
	_scatter_nature()
	_build_course()
	_build_road()
	_build_yard()
	_build_grass()
	_add_sign("СЕВЕР", Vector3(0.0, 14.0, -230.0))
	_add_sign("ГРЯДА", Vector3(8.0, 12.0, -150.0))
	_add_sign("ПРУД", Vector3(96.0, 4.0, 22.0))
	_add_sign("РОЩА", Vector3(-90.0, 8.0, 16.0))
	_add_sign("ДОРОЖКА", Vector3(0.0, 5.5, 52.0))


func sample_height(x: float, z: float) -> float:
	var h := _waves(x, z) + _relief(x, z) + _mounds(x, z) + _pond_dent(x, z)
	var pad := Vector2(x, z).length()
	if pad < PAD_BLEND:
		h = lerpf(0.0, h, smoothstep(PAD_FLAT, PAD_BLEND, pad))
	if _on_pier(x, z):
		return 0.18
	if _on_course(x, z):
		var edge := _course_blend(x, z)
		h = lerpf(h, 0.16, edge)
	return h


func surface_kind(pos: Vector3) -> int:
	if _on_pier(pos.x, pos.z):
		return 0
	if _pond_field(pos.x, pos.z) > 0.22:
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
	var grass := Color(0.28, 0.46, 0.22)
	var sand := Color(0.62, 0.55, 0.36)
	var rock := Color(0.48, 0.47, 0.43)
	var moss := Color(0.22, 0.38, 0.2)
	var shore := clampf(_pond_field(x, z) * 1.4, 0.0, 1.0)
	var tint := grass.lerp(sand, shore)
	if in_grove(Vector3(x, 0.0, z)):
		tint = tint.lerp(moss, 0.45)
	if h > 3.2:
		tint = tint.lerp(rock, clampf((h - 3.2) / 5.0, 0.0, 1.0))
	if h > 7.4:
		tint = tint.lerp(Color(0.9, 0.92, 0.94), clampf((h - 7.4) / 2.2, 0.0, 1.0))
	return tint


func _relief(x: float, z: float) -> float:
	# FastNoiseLite: холмы и узкие овраги. Площадка, причал и дорожка потом выравниваются.
	var hill := relief_noise.get_noise_2d(x, z)
	var cut := pow(1.0 - absf(valley_noise.get_noise_2d(x, z)), 4.0)
	return hill * 1.7 - cut * 2.2


func _ground_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform sampler2D detail : repeat_enable;
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
	albedo *= 0.76 + 0.38 * grain;
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


func _pond_dent(x: float, z: float) -> float:
	var field := _pond_field(x, z)
	if field <= 0.0:
		return 0.0
	return -1.35 * field * field


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
	var step := 3.0
	for iz in 28:
		for ix in 28:
			var x0 := 52.0 + float(ix) * step
			var z0 := -12.0 + float(iz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			if _pond_field(x0, z0) < 0.18 and _pond_field(x1, z1) < 0.18:
				continue
			if _pond_field((x0 + x1) * 0.5, (z0 + z1) * 0.5) < 0.16:
				continue
			_water_vertex(tool, x0, z0)
			_water_vertex(tool, x1, z0)
			_water_vertex(tool, x1, z1)
			_water_vertex(tool, x0, z0)
			_water_vertex(tool, x1, z1)
			_water_vertex(tool, x0, z1)
	var water := MeshInstance3D.new()
	water.mesh = tool.commit()
	water.material_override = _water_material()
	add_child(water)


func _water_vertex(tool: SurfaceTool, x: float, z: float) -> void:
	var field := _pond_field(x, z)
	var shade := 0.75 + 0.25 * field
	tool.set_color(Color(shade, shade, 1.0))
	tool.add_vertex(Vector3(x, 0.05, z))


func _build_pier() -> void:
	var pier := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(PIER_X1 - PIER_X0, 0.16, PIER_HALF_Z * 2.0)
	pier.mesh = box
	pier.position = Vector3((PIER_X0 + PIER_X1) * 0.5, 0.22, PIER_Z)
	pier.material_override = _paint(Color(0.42, 0.3, 0.18))
	add_child(pier)


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
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	var placed: Array[Vector2] = []
	var guard := 0
	while crowns.size() < 42 and guard < 400:
		guard += 1
		var x := rng.randf_range(-132.0, -48.0)
		var z := rng.randf_range(-18.0, 50.0)
		if not in_grove(Vector3(x, 0.0, z)):
			continue
		if _too_close(Vector2(x, z), placed, 6.5):
			continue
		if _blocked_spot(x, z):
			continue
		placed.append(Vector2(x, z))
		var kind := rng.randi_range(0, 2)
		var size := rng.randf_range(0.8, 1.25)
		_add_tree(x, z, kind, size)
	guard = 0
	var rocks := 0
	while rocks < 16 and guard < 200:
		guard += 1
		var x := rng.randf_range(-20.0, 55.0)
		var z := rng.randf_range(-200.0, -50.0)
		if sample_height(x, z) < 1.2:
			continue
		if _blocked_spot(x, z):
			continue
		_add_rock(x, z, rng.randf_range(0.7, 1.5), rng.randf_range(0.0, TAU))
		rocks += 1
	guard = 0
	var bushes := 0
	while bushes < 14 and guard < 200:
		guard += 1
		var x := rng.randf_range(-40.0, 70.0)
		var z := rng.randf_range(-40.0, 40.0)
		if _blocked_spot(x, z) or _pond_field(x, z) > 0.05 or in_grove(Vector3(x, 0.0, z)):
			continue
		if Vector2(x, z).length() < 22.0:
			continue
		_add_bush(x, z, rng.randf_range(0.8, 1.3))
		bushes += 1


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


func _add_tree(x: float, z: float, kind: int, size: float) -> void:
	var y := sample_height(x, z)
	var root := Node3D.new()
	root.position = Vector3(x, y, z)
	root.scale = Vector3.ONE * size
	add_child(root)
	var trunk_h := 2.4
	var trunk_r := 0.28
	var crown_r := 2.4
	var crown_base := 1.8
	var crown_top := 6.5
	if kind == 0:
		_pine(root)
		trunk_h = 2.2
		trunk_r = 0.26
		crown_r = 2.3
		crown_base = 1.6
		crown_top = 7.4
	elif kind == 1:
		_oak(root)
		trunk_h = 2.6
		trunk_r = 0.38
		crown_r = 3.1
		crown_base = 2.0
		crown_top = 6.2
	else:
		_birch(root)
		trunk_h = 4.8
		trunk_r = 0.16
		crown_r = 1.5
		crown_base = 3.6
		crown_top = 6.8
	_add_solid(x, z, trunk_r * size, trunk_h * size, "Столкновение со стволом. Облетите дерево: сквозь ствол не пройти.")
	# Дальние деревья не рисуются. Диапазон видимости есть у сетки, не у пустого узла.
	for child in root.get_children():
		var shown := child as GeometryInstance3D
		if shown != null:
			shown.visibility_range_end = 180.0
			shown.visibility_range_end_margin = 20.0
	crowns.append({
		"x": x,
		"z": z,
		"reach": crown_r * size,
		"base": y + crown_base * size,
		"top": y + crown_top * size,
	})


func _pine(root: Node3D) -> void:
	_trunk(root, 0.22, 2.2, Color(0.32, 0.22, 0.12))
	var greens := [Color(0.1, 0.32, 0.14), Color(0.14, 0.4, 0.16), Color(0.08, 0.28, 0.12)]
	for i in 4:
		var cone := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.05
		mesh.bottom_radius = 2.15 - float(i) * 0.42
		mesh.height = 2.0
		cone.mesh = mesh
		cone.position = Vector3(0.15 * float(i % 2), 2.1 + float(i) * 1.25, -0.1 * float(i % 2))
		cone.material_override = _paint(greens[i % greens.size()])
		root.add_child(cone)


func _oak(root: Node3D) -> void:
	_trunk(root, 0.36, 2.5, Color(0.34, 0.22, 0.12))
	var arms := [Vector3(1.2, 2.6, 0.4), Vector3(-1.1, 2.8, 0.6), Vector3(0.3, 3.0, -1.2), Vector3(-0.4, 2.5, 1.1)]
	for arm in arms:
		var branch := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.06
		mesh.bottom_radius = 0.1
		mesh.height = arm.length()
		branch.mesh = mesh
		branch.position = arm * 0.5
		branch.basis = _along(arm.normalized())
		branch.material_override = _paint(Color(0.36, 0.24, 0.14))
		root.add_child(branch)
		var clump := MeshInstance3D.new()
		var leaf := CylinderMesh.new()
		leaf.top_radius = 0.15
		leaf.bottom_radius = 1.15
		leaf.height = 1.5
		clump.mesh = leaf
		clump.position = arm + Vector3(0.0, 0.5, 0.0)
		clump.material_override = _paint(Color(0.16, 0.42, 0.18))
		root.add_child(clump)


func _birch(root: Node3D) -> void:
	_trunk(root, 0.14, 5.0, Color(0.82, 0.82, 0.78))
	var crown := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.08
	mesh.bottom_radius = 1.35
	mesh.height = 2.2
	crown.mesh = mesh
	crown.position = Vector3(0.0, 5.4, 0.0)
	crown.material_override = _paint(Color(0.45, 0.62, 0.28))
	root.add_child(crown)
	var side := MeshInstance3D.new()
	var side_mesh := CylinderMesh.new()
	side_mesh.top_radius = 0.05
	side_mesh.bottom_radius = 0.7
	side_mesh.height = 1.3
	side.mesh = side_mesh
	side.position = Vector3(0.55, 4.6, 0.2)
	side.material_override = _paint(Color(0.38, 0.55, 0.24))
	root.add_child(side)


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


func _build_grass() -> void:
	var mesh := _grass_mesh()
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	var spots: Array[Vector3] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var guard := 0
	while spots.size() < 4500 and guard < 12000:
		guard += 1
		var x := rng.randf_range(-70.0, 70.0)
		var z := rng.randf_range(-40.0, 55.0)
		if _pond_field(x, z) > 0.05 or _on_course(x, z) or Vector2(x, z).length() < 14.0:
			continue
		if sample_height(x, z) > 4.5:
			continue
		spots.append(Vector3(x, sample_height(x, z), z))
	multi.instance_count = spots.size()
	for i in spots.size():
		var spot := spots[i]
		var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * rng.randf_range(0.7, 1.3))
		multi.set_instance_transform(i, Transform3D(basis, spot))
	var grass := MultiMeshInstance3D.new()
	grass.multimesh = multi
	grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grass.visibility_range_end = 75.0
	grass.material_override = _paint(Color(0.22, 0.46, 0.18))
	add_child(grass)


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
void vertex() {
	VERTEX.y += sin(VERTEX.x * 0.42 + TIME * 1.1) * 0.06;
	VERTEX.y += cos(VERTEX.z * 0.31 + TIME * 0.7) * 0.04;
}
void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.4);
	vec3 deep = vec3(0.04, 0.2, 0.36);
	vec3 shallow = vec3(0.12, 0.42, 0.55);
	vec3 color = mix(deep, shallow, COLOR.r);
	color = mix(color, vec3(0.62, 0.78, 0.86), fresnel * 0.5);
	ALBEDO = color;
	ALPHA = mix(0.78, 0.55, fresnel);
	ROUGHNESS = mix(0.2, 0.05, fresnel);
	METALLIC = 0.05;
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
