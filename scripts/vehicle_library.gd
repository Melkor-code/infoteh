extends RefCounted

const FlightModel = preload("res://scripts/flight_model.gd")

var profiles: Array[Dictionary] = []
var errors: PackedStringArray = []


func load_all() -> void:
	profiles.clear()
	errors.clear()
	var folder := "res://data/vehicles"
	var dir := DirAccess.open(folder)
	if dir == null:
		errors.append("Не открылась папка data/vehicles")
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	var names: PackedStringArray = []
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json") and not file_name.begins_with("_"):
			names.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	names.sort()
	for json_name in names:
		var path := folder.path_join(json_name)
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			errors.append("Пустой файл: %s" % json_name)
			continue
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			errors.append("Не читается: %s" % json_name)
			continue
		var profile: Dictionary = parsed
		if FlightModel.read_number(profile.get("mass_kg")) <= 0.0:
			continue
		profile["_file"] = json_name
		profile["_model"] = FlightModel.describe(profile)
		profiles.append(profile)
	var order := ["geoscan_pioneer_mini", "geoscan_pioneer_fpv", "dji_phantom_4_pro"]
	profiles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ai := order.find(str(a.get("id", "")))
		var bi := order.find(str(b.get("id", "")))
		return (ai if ai >= 0 else 99) < (bi if bi >= 0 else 99)
	)


func summary_lines(profile: Dictionary) -> PackedStringArray:
	var model: Dictionary = profile.get("_model", {})
	var mass_g := int(round(float(model.get("mass", 0.0)) * 1000.0))
	var vmax := float(model.get("vmax", 0.0))
	var holds: bool = model.get("can_hold_demo_wind", false)
	var lines: PackedStringArray = []
	lines.append(("до " if bool(profile.get("mass_is_upper_bound", false)) else "") + "%s г" % mass_g)
	if vmax > 0.1:
		lines.append("Паспортная скорость до %.0f км/ч" % (vmax * 3.6))
	else:
		lines.append("Паспортной скорости нет")
	lines.append("Расчёт в стандартных условиях, ветер 7 м/с: %s" % ("удержит" if holds else "не удержит"))
	return lines
