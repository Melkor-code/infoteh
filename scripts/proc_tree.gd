extends RefCounted

## Дерево растёт развилкой, не стопкой конусов.
## Ствол несколько шагов идёт вверх и на каждом шаге отпускает боковую ветку.
## Ветка делится надвое: одна прижата к направлению родителя, вторая — её отражение.
## Дальше отрезки короче и тоньше. На конце три карточки листвы, не зелёный цилиндр.
## В цвете вершины записано, насколько точку качает ветер: комель стоит, макушка ходит.
## Правило развилки записано здесь по мотивам gdTree3D (обёртка над proctree), чтобы результат был воспроизводимым.
## Чужая библиотека и .dll в проект не входят: игра использует собственную сетку и локальные правила.


static var _shader_res: Shader = null


static func build(kind: int, variant: int) -> ArrayMesh:
	var grown := _grow(kind, variant)
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cursor := {"n": 0}
	var root: Dictionary = grown["root"]
	var head: Vector3 = root["head"]
	var top := float(grown["top"])
	var shade := 0.55 + 0.45 * _rnd(float(grown["seed"]) + 1.7)
	_tube(tool, cursor, Vector3.ZERO, head, float(grown["flare"]), float(root["radius"]), 0.0, _wind(head.y, top), shade)
	_emit(tool, cursor, root, float(grown["twig"]), top, float(grown["seed"]))
	tool.generate_normals()
	return tool.commit()


static func envelope(kind: int) -> Dictionary:
	var reach := 0.0
	var top := 0.0
	var leaf := 99.0
	var spine := 0.0
	var radius := 0.0
	for variant in 2:
		var grown := _grow(kind, variant)
		reach = maxf(reach, float(grown["reach"]))
		top = maxf(top, float(grown["top"]))
		leaf = minf(leaf, float(grown["leaf"]))
		spine = maxf(spine, float(grown["spine"]))
		radius = maxf(radius, float(grown["radius"]))
	# Куст — препятствие целиком. Тонкий стебель аппарат не остановит, а в задании куст твёрдый.
	if kind == 4:
		radius = maxf(radius, reach * 0.38)
		spine = maxf(spine, top * 0.72)
	if top < 0.4:
		top = 0.4
	return {
		"trunk_r": radius,
		"trunk_h": clampf(spine, 0.35, top),
		"reach": reach,
		"base": clampf(leaf, 0.05, top - 0.12),
		"top": top,
	}


static func material(kind: int) -> ShaderMaterial:
	var props := _props(kind, 0)
	var mat := ShaderMaterial.new()
	mat.shader = _shader()
	mat.set_shader_parameter("bark_texture", load("res://assets/map/trees/bark.jpg"))
	mat.set_shader_parameter("leaf_texture", load("res://assets/map/trees/twig.png"))
	var bark: Color = props["bark"]
	var leaf: Color = props["leaf"]
	mat.set_shader_parameter("bark_color", Vector3(bark.r, bark.g, bark.b))
	mat.set_shader_parameter("leaf_color", Vector3(leaf.r, leaf.g, leaf.b))
	mat.set_shader_parameter("mark_bands", 1.0 if kind == 3 else 0.0)
	mat.set_shader_parameter("wind_dir", Vector3(1.0, 0.0, 0.35))
	mat.set_shader_parameter("wind_strength", 0.12)
	mat.set_shader_parameter("wind_rate", 1.15)
	return mat


static func _grow(kind: int, variant: int) -> Dictionary:
	var props := _props(kind, variant)
	var root := _new_branch(Vector3(0.0, float(props["trunk_len"]), 0.0), Vector3.ZERO, int(props["levels"]))
	root["length"] = float(props["length"])
	root["trunk"] = true
	_split(root, int(props["levels"]), int(props["steps"]), props, 1, 1)
	_radii(root, float(props["radius"]), props)
	var acc := {"top": 0.0, "reach": 0.0, "leaf": 99.0, "spine": 0.0}
	_measure(root, acc, float(props["twig"]))
	var raw_top := maxf(float(acc["top"]), 0.4)
	var fit := float(props["target"]) / raw_top
	_scale(root, fit)
	return {
		"root": root,
		"seed": int(props["seed"]),
		"top": float(props["target"]),
		"reach": float(acc["reach"]) * fit,
		"leaf": float(acc["leaf"]) * fit,
		"spine": float(acc["spine"]) * fit,
		"radius": float(props["radius"]) * fit,
		"flare": float(props["radius"]) / float(props["rfall"]) * fit,
		"twig": float(props["twig"]) * fit,
	}


static func _props(kind: int, variant: int) -> Dictionary:
	var seed := 101
	var row := {}
	match kind:
		0:
			# Ель: ветки прижаты к стволу и опущены, крона узкая.
			seed = 101
			row = {"levels": 3, "cmax": 0.64, "cmin": 0.42, "fall": 0.78, "power": 1.0, "factor": 1.9, "rfall": 0.68, "climb": 0.52, "kink": 0.05, "radius": 0.16, "steps": 6, "taper": 0.92, "twist": 2.4, "trunk_len": 1.7, "drop": -0.38, "grow": 0.42, "sweep": 0.0, "length": 1.25, "twig": 0.48, "target": 7.2, "bark": Color(0.28, 0.17, 0.1), "leaf": Color(0.09, 0.28, 0.11)}
		1:
			# Сосна: голый низ, ветки почти горизонтальные.
			seed = 88
			row = {"levels": 3, "cmax": 0.46, "cmin": 0.3, "fall": 0.8, "power": 1.0, "factor": 2.3, "rfall": 0.7, "climb": 0.7, "kink": 0.06, "radius": 0.18, "steps": 5, "taper": 0.94, "twist": 2.6, "trunk_len": 2.5, "drop": -0.06, "grow": 0.22, "sweep": 0.02, "length": 1.05, "twig": 0.55, "target": 7.6, "bark": Color(0.4, 0.26, 0.14), "leaf": Color(0.16, 0.38, 0.14)}
		2:
			# Дуб: короткий ствол, широкая крона, ветки тяжелеют.
			seed = 17
			row = {"levels": 3, "cmax": 0.38, "cmin": 0.22, "fall": 0.8, "power": 0.98, "factor": 2.5, "rfall": 0.74, "climb": 0.38, "kink": 0.1, "radius": 0.22, "steps": 3, "taper": 0.9, "twist": 1.8, "trunk_len": 1.55, "drop": -0.2, "grow": 0.16, "sweep": 0.04, "length": 1.15, "twig": 0.68, "target": 6.0, "bark": Color(0.34, 0.21, 0.11), "leaf": Color(0.18, 0.42, 0.14)}
		3:
			# Берёза: тонкий светлый ствол, крона выше середины.
			seed = 41
			row = {"levels": 3, "cmax": 0.5, "cmin": 0.32, "fall": 0.74, "power": 1.0, "factor": 2.15, "rfall": 0.66, "climb": 0.58, "kink": 0.07, "radius": 0.11, "steps": 5, "taper": 0.94, "twist": 1.6, "trunk_len": 2.7, "drop": -0.14, "grow": 0.28, "sweep": 0.03, "length": 0.9, "twig": 0.46, "target": 6.6, "bark": Color(0.84, 0.84, 0.78), "leaf": Color(0.48, 0.64, 0.26)}
		_:
			seed = 9
			row = {"levels": 2, "cmax": 0.32, "cmin": 0.18, "fall": 0.75, "power": 1.0, "factor": 2.6, "rfall": 0.7, "climb": 0.18, "kink": 0.1, "radius": 0.07, "steps": 1, "taper": 0.88, "twist": 1.4, "trunk_len": 0.42, "drop": -0.16, "grow": 0.08, "sweep": 0.04, "length": 0.55, "twig": 0.46, "target": 1.45, "bark": Color(0.3, 0.2, 0.11), "leaf": Color(0.2, 0.42, 0.15)}
	row["seed"] = seed + variant * 19
	return row


static func _new_branch(head: Vector3, from: Vector3, level: int) -> Dictionary:
	return {
		"head": head,
		"from": from,
		"level": level,
		"length": 1.0,
		"trunk": false,
		"c0": null,
		"c1": null,
		"radius": 0.05,
		"side": Vector3.RIGHT,
	}


static func _split(branch: Dictionary, level: int, steps: int, props: Dictionary, l1: int, l2: int) -> void:
	var rlevel := int(props["levels"]) - level
	var so: Vector3 = branch["head"]
	var po: Vector3 = branch["from"]
	var direction := _safe_norm(so - po, Vector3.UP)
	var helper := Vector3(direction.z, direction.x, direction.y)
	var normal := direction.cross(helper)
	if normal.length() < 0.001:
		normal = direction.cross(Vector3.RIGHT)
	normal = normal.normalized()
	var tangent := direction.cross(normal).normalized()
	var r := _rnd(float(rlevel * 10) + float(l1) * 5.0 + float(l2) + float(props["seed"]))
	var adj := normal * r + tangent * (1.0 - r)
	if r > 0.5:
		adj = -adj
	var clump := (float(props["cmax"]) - float(props["cmin"])) * r + float(props["cmin"])
	var newdir := _safe_norm(adj * (1.0 - clump) + direction * clump, direction)
	var newdir2 := _mirror(newdir, direction, float(props["factor"]))
	if r > 0.5:
		var swap := newdir
		newdir = newdir2
		newdir2 = swap
	if steps > 0:
		var angle := float(steps) / float(maxi(int(props["steps"]), 1)) * TAU * float(props["twist"])
		newdir2 = Vector3(sin(angle), r, cos(angle)).normalized()
	var grow := float(level * level) / float(int(props["levels"]) * int(props["levels"])) * float(props["grow"])
	var bias := Vector3(float(rlevel) * float(props["sweep"]), float(rlevel) * float(props["drop"]) + grow, 0.0)
	newdir = _safe_norm(newdir + bias, direction)
	newdir2 = _safe_norm(newdir2 + bias, direction)
	var length := float(branch["length"])
	var child_len := pow(maxf(length, 0.05), float(props["power"])) * float(props["fall"])
	var c0 := _new_branch(_above(so + newdir * length), so, level - 1)
	var c1 := _new_branch(_above(so + newdir2 * length), so, level - 1)
	c0["length"] = child_len
	c1["length"] = child_len
	c0["side"] = tangent
	c1["side"] = tangent
	branch["c0"] = c0
	branch["c1"] = c1
	if level <= 0:
		return
	if steps > 0:
		var kink := Vector3((r - 0.5) * 2.0 * float(props["kink"]), float(props["climb"]), (r - 0.5) * 2.0 * float(props["kink"]))
		c0["head"] = _above(so + kink)
		c0["trunk"] = true
		c0["length"] = length * float(props["taper"])
		_split(c0, level, steps - 1, props, l1 + 1, l2)
	else:
		_split(c0, level - 1, 0, props, l1 + 1, l2)
	_split(c1, level - 1, 0, props, l1, l2 + 1)


static func _radii(branch: Dictionary, radius: float, props: Dictionary) -> void:
	branch["radius"] = radius
	if branch["c0"] == null:
		return
	var child: Dictionary = branch["c0"]
	var r0 := radius * (float(props["taper"]) if bool(child["trunk"]) else float(props["rfall"]))
	var r1 := radius * float(props["rfall"])
	_radii(branch["c0"], r0, props)
	_radii(branch["c1"], r1, props)


static func _measure(branch: Dictionary, acc: Dictionary, twig: float) -> void:
	var head: Vector3 = branch["head"]
	acc["top"] = maxf(float(acc["top"]), head.y)
	if bool(branch["trunk"]):
		acc["spine"] = maxf(float(acc["spine"]), head.y)
	if branch["c0"] == null:
		acc["reach"] = maxf(float(acc["reach"]), Vector2(head.x, head.z).length() + twig * 1.05)
		acc["leaf"] = minf(float(acc["leaf"]), head.y - twig * 1.15)
		acc["top"] = maxf(float(acc["top"]), head.y + twig * 0.7)
		return
	_measure(branch["c0"], acc, twig)
	_measure(branch["c1"], acc, twig)


static func _scale(branch: Dictionary, fit: float) -> void:
	branch["head"] = (branch["head"] as Vector3) * fit
	branch["from"] = (branch["from"] as Vector3) * fit
	branch["length"] = float(branch["length"]) * fit
	branch["radius"] = float(branch["radius"]) * fit
	if branch["c0"] == null:
		return
	_scale(branch["c0"], fit)
	_scale(branch["c1"], fit)


static func _emit(tool: SurfaceTool, cursor: Dictionary, branch: Dictionary, twig: float, top: float, seed: float) -> void:
	if branch["c0"] == null:
		_leaves(tool, cursor, branch, twig, top, seed)
		return
	_link(tool, cursor, branch, branch["c0"], top, seed)
	_link(tool, cursor, branch, branch["c1"], top, seed)
	_emit(tool, cursor, branch["c0"], twig, top, seed)
	_emit(tool, cursor, branch["c1"], twig, top, seed)


static func _link(tool: SurfaceTool, cursor: Dictionary, parent: Dictionary, child: Dictionary, top: float, seed: float) -> void:
	var a: Vector3 = parent["head"]
	var b: Vector3 = child["head"]
	var delta := b - a
	var dist := delta.length()
	if dist < 0.04:
		return
	var dir := delta / dist
	var sink := minf(float(parent["radius"]) * 0.7, dist * 0.35)
	var start := a - dir * sink
	var r0 := maxf(float(child["radius"]), float(parent["radius"]) * 0.42)
	var shade := 0.42 + 0.58 * _rnd(b.x * 8.0 + b.z * 5.0 + seed)
	_tube(tool, cursor, start, b, r0, float(child["radius"]), _wind(start.y, top), _wind(b.y, top), shade)


static func _leaves(tool: SurfaceTool, cursor: Dictionary, branch: Dictionary, twig: float, top: float, seed: float) -> void:
	var head: Vector3 = branch["head"]
	var origin: Vector3 = branch["from"]
	var binormal := _safe_norm(head - origin, Vector3.UP)
	var side: Vector3 = branch["side"]
	var tangent := _safe_norm(binormal.cross(side), Vector3.ZERO)
	if tangent == Vector3.ZERO:
		tangent = _safe_norm(binormal.cross(Vector3.UP), Vector3.RIGHT)
	var bitangent := binormal.cross(tangent).normalized()
	var back := minf(float(branch["length"]) * 0.9, twig * 1.35)
	var forward := twig * 0.55
	var center := head - binormal * back * 0.25
	var wind := maxf(_wind(head.y, top), 0.8)
	var shade := 0.62 + 0.38 * _rnd(head.x * 6.0 + head.z * 9.0 + seed)
	var half_len := (back + forward) * 0.5
	_card(tool, cursor, center, tangent, binormal, twig * 0.5, half_len, wind, shade)
	_card(tool, cursor, center, bitangent, binormal, twig * 0.42, half_len * 0.92, wind, shade * 0.92)
	# Третья карточка наклонена: сверху, с дрона, вертикальный крест был бы двумя линиями.
	var tilt := _safe_norm(Vector3.UP * 0.72 + binormal * 0.38, Vector3.UP)
	_card(tool, cursor, center + Vector3.UP * twig * 0.08, tangent, tilt, twig * 0.46, half_len * 0.72, wind, shade)


static func _tube(tool: SurfaceTool, cursor: Dictionary, a: Vector3, b: Vector3, r0: float, r1: float, wind0: float, wind1: float, shade: float) -> void:
	var axis := b - a
	var height := axis.length()
	if height < 0.03 or r0 < 0.004:
		return
	axis /= height
	var x := axis.cross(Vector3.FORWARD)
	if x.length() < 0.08:
		x = axis.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(axis).normalized()
	var sides := 6 if r0 > 0.1 else 4
	var ring0: Array[int] = []
	var ring1: Array[int] = []
	for i in sides:
		var ang := TAU * float(i) / float(sides)
		var off := x * cos(ang) + z * sin(ang)
		var u := float(i) / float(sides)
		ring0.append(_vert(tool, cursor, a + off * r0, Color(wind0, 0.0, shade, 1.0), Vector2(u, 0.0)))
		ring1.append(_vert(tool, cursor, b + off * r1, Color(wind1, 0.0, shade, 1.0), Vector2(u, height * 0.42)))
	for i in sides:
		var n := (i + 1) % sides
		_quad(tool, ring0[i], ring0[n], ring1[n], ring1[i])


static func _card(tool: SurfaceTool, cursor: Dictionary, center: Vector3, axis_u: Vector3, axis_v: Vector3, half_u: float, half_v: float, wind: float, shade: float) -> void:
	var color := Color(wind, 1.0, shade, 1.0)
	var p00 := center - axis_u * half_u - axis_v * half_v
	var p10 := center + axis_u * half_u - axis_v * half_v
	var p11 := center + axis_u * half_u + axis_v * half_v
	var p01 := center - axis_u * half_u + axis_v * half_v
	var i00 := _vert(tool, cursor, p00, color, Vector2(0.0, 1.0))
	var i10 := _vert(tool, cursor, p10, color, Vector2(1.0, 1.0))
	var i11 := _vert(tool, cursor, p11, color, Vector2(1.0, 0.0))
	var i01 := _vert(tool, cursor, p01, color, Vector2(0.0, 0.0))
	_quad(tool, i00, i10, i11, i01)


static func _vert(tool: SurfaceTool, cursor: Dictionary, point: Vector3, color: Color, uv: Vector2) -> int:
	tool.set_color(color)
	tool.set_uv(uv)
	tool.add_vertex(point)
	var index := int(cursor["n"])
	cursor["n"] = index + 1
	return index


static func _quad(tool: SurfaceTool, a: int, b: int, c: int, d: int) -> void:
	tool.add_index(a)
	tool.add_index(b)
	tool.add_index(c)
	tool.add_index(a)
	tool.add_index(c)
	tool.add_index(d)


static func _wind(y: float, height: float) -> float:
	# Низ ствола не двигается. Иначе дерево уезжает от своей тени и от столкновения.
	if y < 0.15:
		return 0.0
	var t := clampf((y / maxf(height, 0.5) - 0.22) / 0.4, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func _above(point: Vector3) -> Vector3:
	if point.y < 0.08:
		point.y = 0.08
	return point


static func _safe_norm(v: Vector3, fallback: Vector3) -> Vector3:
	if v.length() < 0.001:
		return fallback
	return v.normalized()


static func _mirror(vec: Vector3, axis: Vector3, factor: float) -> Vector3:
	var across := axis.cross(vec.cross(axis))
	return _safe_norm(vec - across * (factor * across.dot(vec)), vec)


static func _rnd(fixed: float) -> float:
	return absf(cos(fixed + fixed * fixed))


static func _shader() -> Shader:
	if _shader_res != null:
		return _shader_res
	var shader := Shader.new()
	# Без DEPTH_TEXTURE: в Compatibility его нет. Прозрачность листвы задаётся альфа-текстурой.
	shader.code = """shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, specular_disabled;
uniform sampler2D bark_texture : source_color, repeat_enable;
uniform sampler2D leaf_texture : source_color;
uniform vec3 bark_color = vec3(0.34, 0.22, 0.12);
uniform vec3 leaf_color = vec3(0.16, 0.4, 0.14);
uniform float mark_bands = 0.0;
uniform float snow_amount = 0.0;
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.3);
uniform float wind_strength = 0.12;
uniform float wind_rate = 1.1;
void vertex() {
	float influence = COLOR.r;
	float height_lock = smoothstep(0.8, 2.2, VERTEX.y);
	// Ствол, ветки и узлы остаются неподвижны; качаются только карточки листвы.
	float foliage_motion = step(0.5, COLOR.g);
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float along = world.x * 0.17 + world.z * 0.11;
	float sway = sin(TIME * wind_rate + along) * min(wind_strength, 0.12) * influence * height_lock * foliage_motion;
	world += wind_dir * sway;
	world.y += abs(sway) * 0.1;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
}


void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	if (COLOR.g > 0.5) {
		vec2 p = UV * 2.0 - 1.0;
		vec2 qa = (p - vec2(0.3, 0.1)) * 1.45;
		vec2 qb = (p + vec2(0.26, 0.02)) * vec2(1.3, 1.2);
		vec2 qt = (p - vec2(0.0, 0.36)) * vec2(1.7, 1.35);
		float main_blob = dot(p * vec2(1.05, 0.76), p);
		float side_a = dot(qa, qa);
		float side_b = dot(qb, qb);
		float tip = dot(qt, qt);
		vec4 leaf_tex = texture(leaf_texture, UV);
		float cover = leaf_tex.a;
		if (cover < 0.5) {
			discard;
		}
		float shade = (0.7 + 0.3 * COLOR.b) * (0.8 + 0.2 * clamp(NORMAL.y, 0.0, 1.0));
		ALBEDO = mix(leaf_color, leaf_tex.rgb, 0.65) * shade;
	} else {
		float grain = 0.8 + 0.2 * sin(UV.y * 26.0 + UV.x * 7.0);
		float band = step(0.8, fract(UV.y * 2.6)) * mark_bands;
		vec3 color = mix(bark_color, texture(bark_texture, UV).rgb, 0.65) * grain * (0.76 + 0.38 * COLOR.b);
		ALBEDO = mix(color, color * vec3(0.32, 0.34, 0.3), band);
	}
	vec3 dormant = mix(ALBEDO, vec3(0.29,0.27,0.25), 0.7);
	ALBEDO = mix(ALBEDO, dormant, clamp(snow_amount*2.0,0.0,1.0));
	ALBEDO = mix(ALBEDO, vec3(0.84,0.87,0.90), snow_amount*(COLOR.g > 0.5 ? 0.95 : 0.45));
	ROUGHNESS = 0.92;
}
"""
	_shader_res = shader
	return shader


## Геометрия физических веток, полученная тем же генератором, что и видимая сетка.
## Каждый элемент — капсула вдоль одного реального отрезка ствола/ветки.
static func collision_segments(kind: int, variant: int) -> Array[Dictionary]:
	var grown := _grow(kind, variant)
	var result: Array[Dictionary] = []
	var root: Dictionary = grown["root"]
	_collect_segments(root, result, -1.0)
	return result


static func _collect_segments(branch: Dictionary, result: Array[Dictionary], parent_radius: float) -> void:
	var a: Vector3 = branch["from"]
	var b: Vector3 = branch["head"]
	var delta := b - a
	var length := delta.length()
	if length > 0.025:
		var direction := delta / length
		var sink := minf(float(branch["radius"]) * 0.7, length * 0.35)
		var start := a - direction * sink if a != Vector3.ZERO else a
		var end_radius := float(branch["radius"])
		var start_radius := end_radius * 1.35 if parent_radius < 0.0 else maxf(end_radius, parent_radius * 0.42)
		result.append({"a": start, "b": b, "radius": maxf(start_radius, 0.018)})
	if branch["c0"] == null:
		return
	_collect_segments(branch["c0"], result, float(branch["radius"]))
	_collect_segments(branch["c1"], result, float(branch["radius"]))
