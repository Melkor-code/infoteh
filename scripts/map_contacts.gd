extends RefCounted

static func resolve(solids: Array, pos: Vector3, vel: Vector3, radius: float, vertical_radius: float = -1.0) -> Dictionary:
	var note := ""
	for _pass in 6:
		var best_depth := 0.0
		var best_normal := Vector3.UP
		var best_note := ""
		var restitution := 0.08
		var foliage := false
		for item in solids:
			var hit := _hit_box(item, pos, radius, vertical_radius) if str(item.kind) == "box" else _hit_solid(item, pos, radius)
			if hit.is_empty():
				continue
			if float(hit["depth"]) > best_depth:
				best_depth = float(hit["depth"])
				best_normal = hit["normal"]
				best_note = str(hit["note"])
				foliage = str(item.kind) == "canopy"
				restitution = 0.12 if foliage else (0.0 if best_normal.y > 0.65 else 0.08)
		if best_depth <= 0.001:
			break
		pos += best_normal * (best_depth + 0.0005)
		var into := vel.dot(best_normal)
		if into < 0.0:
			vel -= best_normal * into * (1.0 + restitution)
			if foliage:
				# A dissipative contact: tangential speed drops too, once on impact.
				vel *= 0.65
		note = best_note
	return {"pos": pos, "vel": vel, "note": note}


static func _hit_solid(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
	var kind := str(item["kind"])
	if kind == "pole":
		return _hit_pole(item, pos, radius)
	if kind == "ring":
		return _hit_ring(item, pos, radius)
	if kind == "box":
		return _hit_box(item, pos, radius)
	if kind == "pipe":
		return _hit_pipe(item, pos, radius)
	if kind == "canopy":
		return _hit_canopy(item, pos, radius)
	if kind == "branch":
		return _hit_branch(item, pos, radius)
	return {}


static func _hit_pole(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
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


static func _hit_ring(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
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
	var normal := gap / dist if dist > 0.001 else axis
	return {"normal": normal, "depth": limit - dist, "note": str(item["note"])}


static func _hit_box(item: Dictionary, pos: Vector3, radius: float, vertical_radius: float = -1.0) -> Dictionary:
	var center: Vector3 = item["center"]
	var half: Vector3 = item["half"]
	var yaw := float(item["yaw"])
	var local := pos - center
	var c := cos(yaw)
	var s := sin(yaw)
	var lx := local.x * c + local.z * s
	var lz := -local.x * s + local.z * c
	var ly := local.y
	var expanded := half + Vector3(radius, radius if vertical_radius < 0.0 else vertical_radius, radius)
	if absf(lx) > expanded.x or absf(ly) > expanded.y or absf(lz) > expanded.z:
		return {}
	var pen := Vector3(expanded.x - absf(lx), expanded.y - absf(ly), expanded.z - absf(lz))
	var normal := Vector3(c, 0.0, s) * (1.0 if lx >= 0.0 else -1.0)
	var depth := pen.x
	if pen.y < depth:
		normal = Vector3(0.0, 1.0 if ly >= 0.0 else -1.0, 0.0)
		depth = pen.y
	if pen.z < depth:
		normal = Vector3(-s, 0.0, c) * (1.0 if lz >= 0.0 else -1.0)
		depth = pen.z
	return {"normal": normal, "depth": depth, "note": str(item["note"])}


static func _hit_canopy(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
	var center: Vector3 = item.center
	var radii: Vector3 = item.radii + Vector3.ONE * radius
	var local := pos - center
	var q := local / radii
	var length := q.length()
	if length >= 1.0:
		return {}
	if length < 0.0001:
		return {"normal": Vector3.UP, "depth": radii.y, "note": item.note}
	var boundary := local / length
	var normal := (boundary / (radii * radii)).normalized()
	return {"normal": normal, "depth": maxf((boundary - local).dot(normal), 0.001), "note": item.note}


static func _hit_branch(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
	var a: Vector3 = item["a"]
	var b: Vector3 = item["b"]
	var ab := b - a
	var len_sq := ab.length_squared()
	var t := 0.0 if len_sq < 0.000001 else clampf((pos - a).dot(ab) / len_sq, 0.0, 1.0)
	var closest := a + ab * t
	var delta := pos - closest
	var distance := delta.length()
	var limit := float(item["radius"]) + radius
	if distance >= limit:
		return {}
	var normal := delta / distance if distance > 0.0001 else (ab.normalized() if len_sq > 0.000001 else Vector3.UP)
	return {"normal": normal, "depth": limit - distance, "note": str(item["note"])}


static func _hit_pipe(item: Dictionary, pos: Vector3, radius: float) -> Dictionary:
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


