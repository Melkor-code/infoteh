extends Node3D

const VehicleLibrary = preload("res://scripts/vehicle_library.gd")
const Quadrotor = preload("res://scripts/quadrotor.gd")
const FlightModel = preload("res://scripts/flight_model.gd")

const TERRAIN_POLYGON := 0
const TERRAIN_SLOPE := 1
const TERRAIN_WATER := 2
const TERRAIN_FOREST := 3
const HILL_CENTER := Vector3(0.0, 0.0, -42.0)
const HILL_RADIUS := 26.0
const HILL_PEAK := 5.0
const POND_CENTER := Vector2(34.0, 12.0)
const POND_RADIUS := 11.0
const FOREST_CENTER := Vector2(-28.0, 4.0)
const FOREST_RADIUS := 16.0

## Меню, полигон и камеры. Физика живёт в quadrotor.gd и flight_model.gd.
## Окно собирается кодом, чтобы не прятать логику в файле сцены.

var library := VehicleLibrary.new()
var selected := 0
var flying := false
var wind_speed := 7.0
var wind_from := 7
var terrain := TERRAIN_POLYGON
var precip := 0
var air_temp := 15.0
var turbulence_on := false
var camera_mode := 0
var craft: Quadrotor
var camera: Camera3D
var rain: CPUParticles3D
var snow: CPUParticles3D
var hail: CPUParticles3D
var ground: MeshInstance3D
var ground_mat: StandardMaterial3D
var slope_visual: Node3D
var forest_root: Node3D
var wind_arrow: Node3D
var log_lines: PackedStringArray = []
var warned := false

var menu_panel: PanelContainer
var flight_panel: PanelContainer
var list_box: VBoxContainer
var detail_label: Label
var hud_slots: Dictionary = {}
var warning_label: Label
var terrain_hint: Label
var temp_label: Label
var wind_labels: Array[Label] = []
var wind_sliders: Array[HSlider] = []
var wind_pickers: Array[OptionButton] = []
var status_label: Label
var orbit_yaw := 0.6
var orbit_pitch := -0.45
var orbit_distance := 8.0
var mouse_stick := false
var mouse_pitch := 0.0
var mouse_roll := 0.0
var gust := Vector3.ZERO
var gust_target := Vector3.ZERO
var gust_timer := 0.0
var status_flash := ""
var status_flash_time := 0.0
var flight_seconds := 0.0
var max_altitude := 0.0
var max_speed := 0.0
var min_battery := 100.0
var min_signal := 100.0
var max_motor_temp := 0.0
var report_warnings: PackedStringArray = []


func _ready() -> void:
	_build_world()
	library.load_all()
	_build_ui()
	_select(0)
	_show_menu()


func _physics_process(delta: float) -> void:
	if not flying or craft == null:
		return
	_read_flight_input(delta)
	_update_gust(delta)
	craft.wind = _wind_vector() + gust
	craft.air_density = FlightModel.air_density(air_temp)
	craft.air_temp = air_temp
	craft.precip = precip
	craft.surface_y = _ground_height(craft.position)
	craft.surface_kind = _surface_kind(craft.position)
	craft.slope_accel = _slope_accel(craft.position)
	var was_airborne := craft.airborne
	var had_motors := craft.motors_on
	craft.step(delta)
	if not was_airborne and craft.airborne:
		_log("Взлёт")
	if had_motors and not craft.motors_on:
		_log("Посадка")
	if craft.warning != "" and not warned:
		_log(craft.warning)
		warned = true
	if craft.warning == "":
		warned = false
	if craft.warning != "" and not report_warnings.has(craft.warning):
		report_warnings.append(craft.warning)
	flight_seconds += delta
	max_altitude = maxf(max_altitude, craft.position.y)
	max_speed = maxf(max_speed, craft.velocity.length())
	min_battery = minf(min_battery, craft.battery * 100.0)
	min_signal = minf(min_signal, craft.radio)
	max_motor_temp = maxf(max_motor_temp, craft.motor_temp)
	_update_wind_arrow()
	_update_hud()


func _process(_delta: float) -> void:
	if camera == null:
		return
	_place_camera()
	if status_flash_time > 0.0:
		status_flash_time -= _delta
		if status_flash_time <= 0.0:
			status_flash = ""
	_place_precip()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		orbit_yaw -= event.relative.x * 0.005
		orbit_pitch = clampf(orbit_pitch - event.relative.y * 0.004, -1.2, -0.05)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		mouse_stick = event.pressed and flying
		if not mouse_stick:
			mouse_pitch = 0.0
			mouse_roll = 0.0
	if event is InputEventMouseMotion and mouse_stick and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		# Вверх — как W, вправо — как D. Отпускание возвращает наклон к центру.
		mouse_roll = clampf(mouse_roll + event.relative.x * 0.0035, -1.0, 1.0)
		mouse_pitch = clampf(mouse_pitch - event.relative.y * 0.0035, -1.0, 1.0)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			orbit_distance = maxf(orbit_distance - 0.6, 1.5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			orbit_distance = minf(orbit_distance + 0.6, 40.0)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_C:
			camera_mode = (camera_mode + 1) % 3
		elif event.keycode == KEY_ESCAPE and flying:
			_back_to_menu()


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.52, 0.82)
	sky_mat.sky_horizon_color = Color(0.78, 0.82, 0.86)
	sky_mat.ground_bottom_color = Color(0.22, 0.3, 0.18)
	sky_mat.ground_horizon_color = Color(0.55, 0.58, 0.48)
	sky.sky_material = sky_mat
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.85
	env.environment = environment
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.light_energy = 1.2
	add_child(sun)

	ground = MeshInstance3D.new()
	ground.mesh = _build_height_mesh()
	ground_mat = StandardMaterial3D.new()
	ground_mat.vertex_color_use_as_albedo = true
	ground_mat.roughness = 0.92
	ground.material_override = ground_mat
	add_child(ground)

	for i in range(-2, 3):
		var pad := MeshInstance3D.new()
		var pad_mesh := BoxMesh.new()
		pad_mesh.size = Vector3(1.2, 0.04, 8.0)
		pad.mesh = pad_mesh
		pad.position = Vector3(i * 2.2, 0.03, 0)
		var paint := StandardMaterial3D.new()
		paint.albedo_color = Color(0.85, 0.85, 0.8) if i == 0 else Color(0.55, 0.55, 0.52)
		pad.material_override = paint
		add_child(pad)
	_build_hill()
	_build_pond()
	_build_forest()
	var north := Label3D.new()
	north.text = "СЕВЕР"
	north.position = Vector3(0, 6.2, -72)
	north.font_size = 64
	north.modulate = Color(0.95, 0.95, 0.9)
	north.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(north)

	_build_wind_arrow()

	rain = _make_precip(420, 1.4, 9.0, 13.0, Vector2(0.03, 0.28), Color(0.75, 0.82, 0.9), Vector3(0, -8, 0))
	snow = _make_precip(260, 2.4, 1.5, 3.0, Vector2(0.06, 0.06), Color(0.95, 0.96, 0.98), Vector3(0, -1.2, 0))
	hail = _make_precip(70, 0.7, 16.0, 22.0, Vector2(0.07, 0.07), Color(0.85, 0.9, 0.95), Vector3(0, -18, 0))

	camera = Camera3D.new()
	camera.current = true
	add_child(camera)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	menu_panel = _panel(Vector2(24, 24), Vector2(460, 660))
	layer.add_child(menu_panel)
	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("separation", 6)
	menu_panel.add_child(outer)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var menu_box := VBoxContainer.new()
	menu_box.add_theme_constant_override("separation", 8)
	menu_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(menu_box)
	menu_box.add_child(_title("Полётный симулятор БПЛА"))
	menu_box.add_child(_hint("Выберите аппарат. Это не официальные модели производителей: числа из открытых паспортов."))
	list_box = VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 6)
	menu_box.add_child(list_box)
	for index in library.profiles.size():
		var profile: Dictionary = library.profiles[index]
		var button := Button.new()
		button.text = str(profile.get("display_name", "Без имени"))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_select.bind(index))
		list_box.add_child(button)
	detail_label = _hint("")
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu_box.add_child(detail_label)
	if library.errors.size() > 0:
		menu_box.add_child(_hint("Ошибки чтения: " + "\n".join(library.errors)))
	menu_box.add_child(_hint("Ветер: скорость и откуда дует. 7 м/с с северо-запада — пример из задания."))
	menu_box.add_child(_wind_slider())
	menu_box.add_child(_hint("Местность"))
	menu_box.add_child(_terrain_picker())
	terrain_hint = _hint("")
	menu_box.add_child(terrain_hint)
	menu_box.add_child(_hint("Осадки"))
	menu_box.add_child(_precip_picker())
	menu_box.add_child(_temp_slider())
	var turb_box := CheckButton.new()
	turb_box.text = "Турбулентность: порывы к ветру"
	turb_box.focus_mode = Control.FOCUS_NONE
	turb_box.toggled.connect(func(on: bool) -> void: turbulence_on = on)
	menu_box.add_child(turb_box)
	var start := Button.new()
	start.text = "Начать полёт"
	start.focus_mode = Control.FOCUS_NONE
	start.pressed.connect(_start_flight)
	outer.add_child(start)
	status_label = _hint("Shift поднимает, Ctrl снижает. Левая кнопка мыши наклоняет аппарат. Правая крутит камеру.")
	outer.add_child(status_label)
	_apply_terrain()

	flight_panel = _panel(Vector2(8, 8), Vector2(1264, 96))
	flight_panel.visible = false
	var tight := flight_panel.get_theme_stylebox("panel") as StyleBoxFlat
	if tight != null:
		tight.content_margin_left = 8
		tight.content_margin_right = 8
		tight.content_margin_top = 4
		tight.content_margin_bottom = 4
	layer.add_child(flight_panel)
	var flight_box := VBoxContainer.new()
	flight_box.add_theme_constant_override("separation", 2)
	flight_panel.add_child(flight_box)
	var flight_row := HBoxContainer.new()
	flight_row.add_theme_constant_override("separation", 8)
	flight_box.add_child(flight_row)
	flight_row.add_child(_slot("name", 210.0))
	flight_row.add_child(_pair("высота", "alt", 52.0))
	flight_row.add_child(_pair("скорость", "spd", 68.0))
	flight_row.add_child(_pair("нос", "nose", 32.0))
	flight_row.add_child(_pair("тяга", "thr", 40.0))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flight_row.add_child(spacer)
	flight_row.add_child(_wind_slider())
	var back := Button.new()
	back.text = "Меню"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_back_to_menu)
	flight_row.add_child(back)
	var save := Button.new()
	save.text = "Отчёт"
	save.focus_mode = Control.FOCUS_NONE
	save.pressed.connect(_save_log)
	flight_row.add_child(save)
	var telemetry_row := HBoxContainer.new()
	telemetry_row.add_theme_constant_override("separation", 8)
	flight_box.add_child(telemetry_row)
	telemetry_row.add_child(_pair("крен", "roll", 40.0))
	telemetry_row.add_child(_pair("тангаж", "pitch", 40.0))
	telemetry_row.add_child(_pair("курс", "yaw", 40.0))
	telemetry_row.add_child(_pair("батарея", "bat", 40.0))
	telemetry_row.add_child(_pair("моторы", "mot", 40.0))
	telemetry_row.add_child(_pair("сигнал", "sig", 40.0))
	telemetry_row.add_child(_pair("порывы", "gust", 36.0))
	warning_label = Label.new()
	warning_label.position = Vector2(16, 108)
	warning_label.size = Vector2(1100, 24)
	warning_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	warning_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.4))
	layer.add_child(warning_label)


func _select(index: int) -> void:
	if library.profiles.is_empty():
		detail_label.text = "В data/vehicles нет ни одного аппарата с массой."
		return
	selected = clampi(index, 0, library.profiles.size() - 1)
	var profile: Dictionary = library.profiles[selected]
	var lines := library.summary_lines(profile)
	var model: Dictionary = profile.get("_model", {})
	var drag_scale := float(model.get("drag_scale", 1.0))
	lines.append("Сопротивление подогнано под паспортную скорость, множитель к площади: %.1f." % drag_scale)
	lines.append("Форму корпуса не считаем. Тяга моторов в паспорте не указана: взяли запас в 2 веса.")
	detail_label.text = "\n".join(lines)
	for i in list_box.get_child_count():
		var button := list_box.get_child(i) as Button
		if button == null:
			continue
		button.modulate = Color(1, 1, 1) if i == selected else Color(0.75, 0.75, 0.75)


func _start_flight() -> void:
	if library.profiles.is_empty():
		return
	if craft != null:
		craft.queue_free()
	craft = Quadrotor.new()
	add_child(craft)
	craft.setup(library.profiles[selected])
	var spot := _start_spot()
	var clearance := maxf(float(craft.model.get("height", 0.1)) * 0.5, 0.04)
	craft.position = Vector3(spot.x, _ground_height(spot) + clearance + 0.04, spot.z)
	craft.target_altitude = craft.position.y
	craft.motor_temp = air_temp
	craft.air_temp = air_temp
	orbit_distance = maxf(float(craft.model.get("width", 0.4)) * 22.0, 12.0)
	flying = true
	warned = false
	log_lines.clear()
	report_warnings.clear()
	flight_seconds = 0.0
	max_altitude = craft.position.y
	max_speed = 0.0
	min_battery = 100.0
	min_signal = 100.0
	max_motor_temp = air_temp
	status_flash = ""
	gust = Vector3.ZERO
	gust_target = Vector3.ZERO
	_log("Старт: " + str(library.profiles[selected].get("display_name", "")))
	_log("Местность: " + _terrain_name())
	_log("Ветер %.0f м/с, откуда %s, воздух %.0f °C" % [wind_speed, _wind_from_name(), air_temp])
	_log("Осадки: " + _precip_name())
	menu_panel.visible = false
	flight_panel.visible = true
	_update_hud()


func _back_to_menu() -> void:
	flying = false
	if craft != null:
		craft.queue_free()
		craft = null
	menu_panel.visible = true
	flight_panel.visible = false
	warning_label.text = ""
	mouse_stick = false
	mouse_pitch = 0.0
	mouse_roll = 0.0
	for key in hud_slots:
		(hud_slots[key] as Label).text = ""
	status_flash = ""


func _read_flight_input(delta: float) -> void:
	var pitch_goal := 0.0
	var roll_goal := 0.0
	var yaw_goal := 0.0
	var climb := 0.0
	if Input.is_physical_key_pressed(KEY_W):
		pitch_goal += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		pitch_goal -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		roll_goal += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		roll_goal -= 1.0
	# Q/E оставлены. Стрелки — тот же поворот, чтобы второй рукой крутить нос, не отпуская W/A/S/D.
	if Input.is_physical_key_pressed(KEY_E) or Input.is_physical_key_pressed(KEY_RIGHT):
		yaw_goal += 1.0
	if Input.is_physical_key_pressed(KEY_Q) or Input.is_physical_key_pressed(KEY_LEFT):
		yaw_goal -= 1.0
	if Input.is_physical_key_pressed(KEY_SHIFT):
		climb = 1.6
	if Input.is_physical_key_pressed(KEY_CTRL):
		climb = -1.4
	if Input.get_connected_joypads().size() > 0:
		var joy: int = Input.get_connected_joypads()[0]
		var right_x := Input.get_joy_axis(joy, JOY_AXIS_RIGHT_X)
		var right_y := Input.get_joy_axis(joy, JOY_AXIS_RIGHT_Y)
		var left_x := Input.get_joy_axis(joy, JOY_AXIS_LEFT_X)
		if absf(right_x) > 0.15:
			roll_goal = right_x
		if absf(right_y) > 0.15:
			pitch_goal = -right_y
		if absf(left_x) > 0.15:
			yaw_goal = left_x
		var trigger_up := Input.get_joy_axis(joy, JOY_AXIS_TRIGGER_RIGHT)
		var trigger_down := Input.get_joy_axis(joy, JOY_AXIS_TRIGGER_LEFT)
		if trigger_up > 0.1:
			climb = 1.6 * trigger_up
		elif trigger_down > 0.1:
			climb = -1.4 * trigger_down
	if mouse_stick:
		pitch_goal = mouse_pitch
		roll_goal = mouse_roll
	# Короткое нажатие даёт маленький наклон. Полный наклон только если удерживать клавишу.
	var stick_step := 2.4 * delta
	craft.stick_pitch = move_toward(craft.stick_pitch, clampf(pitch_goal, -1.0, 1.0), stick_step)
	craft.stick_roll = move_toward(craft.stick_roll, clampf(roll_goal, -1.0, 1.0), stick_step)
	craft.stick_yaw = move_toward(craft.stick_yaw, clampf(yaw_goal, -1.0, 1.0), stick_step)
	craft.climb_command = climb


func _update_hud() -> void:
	if craft == null:
		return
	_set_slot("name", str(craft.profile.get("display_name", "")))
	_set_slot("alt", "%.1f м" % craft.position.y)
	_set_slot("spd", "%.0f км/ч" % (craft.velocity.length() * 3.6))
	_set_slot("nose", _heading_name(craft.forward()))
	_set_slot("thr", "%d%%" % int(round(craft.throttle * 100.0)))
	_set_slot("roll", "%.0f°" % craft.sensor_roll)
	_set_slot("pitch", "%.0f°" % craft.sensor_pitch)
	_set_slot("yaw", "%.0f°" % craft.sensor_yaw_deg)
	_set_slot("bat", "%.0f%%" % craft.sensor_battery)
	_set_slot("mot", "%.0f°" % craft.sensor_motor_temp)
	_set_slot("sig", "%.0f%%" % craft.sensor_signal)
	_set_slot("gust", "%.1f" % gust.length())
	if status_flash_time > 0.0:
		warning_label.text = status_flash
	else:
		warning_label.text = craft.warning


func _build_wind_arrow() -> void:
	# Короткая стрелка сбоку от площадки. Раньше была длинная плашка через старт.
	wind_arrow = Node3D.new()
	var paint := _flat_color(Color(0.35, 0.7, 0.95))
	var shaft := MeshInstance3D.new()
	var shaft_mesh := BoxMesh.new()
	shaft_mesh.size = Vector3(0.06, 0.04, 0.9)
	shaft.mesh = shaft_mesh
	shaft.position = Vector3(0.0, 0.02, 0.05)
	shaft.material_override = paint
	wind_arrow.add_child(shaft)
	var head := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.1
	cone.height = 0.28
	head.mesh = cone
	# look_at направляет минус Z по ветру, поэтому остриё смотрит туда же.
	head.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	head.position = Vector3(0.0, 0.02, -0.48)
	head.material_override = paint
	wind_arrow.add_child(head)
	add_child(wind_arrow)
	_update_wind_arrow()


func _update_wind_arrow() -> void:
	if wind_arrow == null:
		return
	var blow := _wind_vector()
	wind_arrow.visible = blow.length() > 0.2
	if not wind_arrow.visible:
		return
	var spot := Vector3(6.5, 0.0, 4.0)
	spot.y = _sample_height(spot.x, spot.z) + 0.12
	wind_arrow.position = spot
	wind_arrow.look_at(spot + Vector3(blow.x, 0.0, blow.z), Vector3.UP)


func _place_camera() -> void:
	var target := Vector3(0, 1, 0)
	if craft != null:
		target = craft.global_position
	if camera_mode == 1 and craft != null:
		camera.global_position = target + craft.global_transform.basis.y * 0.12
		camera.global_rotation = craft.global_rotation
		return
	if camera_mode == 2:
		var offset := Vector3(
			sin(orbit_yaw) * cos(orbit_pitch),
			sin(-orbit_pitch),
			cos(orbit_yaw) * cos(orbit_pitch)
		) * orbit_distance
		camera.global_position = target + offset
		camera.look_at(target, Vector3.UP)
		return
	if craft != null:
		var back := craft.global_transform.basis.z
		camera.global_position = target + back * orbit_distance * 0.55 + Vector3(0, orbit_distance * 0.28, 0)
		camera.look_at(target + Vector3(0, 0.2, 0), Vector3.UP)
	else:
		camera.global_position = Vector3(0, 4, 8)
		camera.look_at(Vector3.ZERO, Vector3.UP)


func _wind_vector() -> Vector3:
	if wind_speed <= 0.05:
		return Vector3.ZERO
	# 0 — север, дальше по часовой. Ветер летит из этой стороны, не в неё.
	# Север в сцене — отрицательная Z. Северо-запад поэтому даёт поток на юго-восток.
	var deg := float(wind_from) * 45.0
	var rad := deg_to_rad(deg)
	return Vector3(-sin(rad), 0.0, cos(rad)) * wind_speed


func _wind_from_name() -> String:
	var names := ["С", "СВ", "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ"]
	return names[clampi(wind_from, 0, names.size() - 1)]


func _log(line: String) -> void:
	log_lines.append(line)
	if log_lines.size() > 40:
		log_lines.remove_at(0)


func _save_log() -> void:
	var path := "user://flight_report.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		status_flash = "Не удалось записать отчёт."
		status_flash_time = 4.0
		return
	var lines: PackedStringArray = []
	lines.append("Отчёт полёта")
	lines.append("Аппарат: " + str(library.profiles[selected].get("display_name", "")))
	lines.append("Местность: " + _terrain_name())
	lines.append("Ветер: %.0f м/с, откуда %s" % [wind_speed, _wind_from_name()])
	lines.append("Осадки: " + _precip_name())
	lines.append("Температура воздуха: %.0f °C" % air_temp)
	lines.append("Плотность воздуха: %.3f кг/м³" % FlightModel.air_density(air_temp))
	lines.append("Турбулентность: " + ("да" if turbulence_on else "нет"))
	lines.append("Время в полёте: %.0f с" % flight_seconds)
	lines.append("Максимальная высота: %.1f м" % max_altitude)
	lines.append("Максимальная скорость: %.1f м/с" % max_speed)
	lines.append("Минимальный заряд: %.0f%%" % min_battery)
	lines.append("Минимальный сигнал: %.0f%%" % min_signal)
	lines.append("Максимальная температура моторов: %.0f °C" % max_motor_temp)
	lines.append("Предупреждения:")
	if report_warnings.is_empty():
		lines.append("- нет")
	else:
		for item in report_warnings:
			lines.append("- " + item)
	lines.append("")
	lines.append("Журнал:")
	lines.append_array(log_lines)
	file.store_string("\n".join(lines))
	file.close()
	var full := ProjectSettings.globalize_path(path)
	status_flash = "Отчёт записан: " + full
	status_flash_time = 6.0
	_log("Отчёт сохранён")


func _show_menu() -> void:
	menu_panel.visible = true
	flight_panel.visible = false


func _terrain_picker() -> OptionButton:
	var picker := OptionButton.new()
	picker.focus_mode = Control.FOCUS_NONE
	picker.add_item("Старт на площадке", TERRAIN_POLYGON)
	picker.add_item("Старт на горке", TERRAIN_SLOPE)
	picker.add_item("Старт у воды", TERRAIN_WATER)
	picker.add_item("Старт у леса", TERRAIN_FOREST)
	picker.selected = terrain
	picker.item_selected.connect(func(index: int) -> void:
		terrain = index
		_apply_terrain()
	)
	return picker


func _precip_picker() -> OptionButton:
	var picker := OptionButton.new()
	picker.focus_mode = Control.FOCUS_NONE
	picker.add_item("Нет", 0)
	picker.add_item("Дождь: сопротивление +15%", 1)
	picker.add_item("Снег: сопротивление +10% и тяга −8%", 2)
	picker.add_item("Град: редкие удары", 3)
	picker.selected = precip
	picker.item_selected.connect(func(index: int) -> void:
		precip = index
	)
	return picker


func _temp_slider() -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var caption := Label.new()
	caption.text = "Воздух"
	box.add_child(caption)
	var slider := HSlider.new()
	slider.min_value = -10.0
	slider.max_value = 40.0
	slider.step = 1.0
	slider.value = air_temp
	slider.custom_minimum_size = Vector2(130, 16)
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(func(value: float) -> void:
		air_temp = value
		if temp_label != null:
			temp_label.text = "%.0f °C" % air_temp
	)
	box.add_child(slider)
	temp_label = Label.new()
	temp_label.custom_minimum_size = Vector2(58, 0)
	temp_label.text = "%.0f °C" % air_temp
	box.add_child(temp_label)
	return box


func _apply_terrain() -> void:
	if terrain_hint == null:
		return
	terrain_hint.text = "На одной карте сразу площадка, горка на севере, пруд справа и лес слева. Выбор только переносит точку старта."


func _build_hill() -> void:
	slope_visual = Node3D.new()
	add_child(slope_visual)
	_add_sign("ГОРКА", HILL_CENTER + Vector3(0.0, HILL_PEAK + 1.4, 0.0), slope_visual)


func _build_pond() -> void:
	var pond := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = POND_RADIUS
	mesh.bottom_radius = POND_RADIUS
	mesh.height = 0.35
	pond.mesh = mesh
	pond.position = Vector3(POND_CENTER.x, -0.05, POND_CENTER.y)
	var water := _flat_color(Color(0.16, 0.42, 0.72))
	water.roughness = 0.18
	pond.material_override = water
	add_child(pond)
	var pier := MeshInstance3D.new()
	var pier_mesh := BoxMesh.new()
	pier_mesh.size = Vector3(12.0, 0.18, 3.2)
	pier.mesh = pier_mesh
	pier.position = Vector3(24.0, 0.12, POND_CENTER.y)
	pier.material_override = _flat_color(Color(0.45, 0.34, 0.22))
	add_child(pier)
	_add_sign("ВОДА", Vector3(POND_CENTER.x, 3.5, POND_CENTER.y), self)


func _build_forest() -> void:
	forest_root = Node3D.new()
	add_child(forest_root)
	var spots: Array[Vector3] = [
		Vector3(-28, 0, 4), Vector3(-24, 0, -2), Vector3(-33, 0, 8),
		Vector3(-22, 0, 10), Vector3(-36, 0, 0), Vector3(-30, 0, 14),
		Vector3(-18, 0, 2), Vector3(-34, 0, -6),
	]
	for spot in spots:
		var placed := Vector3(spot.x, _sample_height(spot.x, spot.z), spot.z)
		var trunk := MeshInstance3D.new()
		var trunk_mesh := CylinderMesh.new()
		trunk_mesh.top_radius = 0.22
		trunk_mesh.bottom_radius = 0.32
		trunk_mesh.height = 3.4
		trunk.mesh = trunk_mesh
		trunk.position = placed + Vector3(0, 1.7, 0)
		trunk.material_override = _flat_color(Color(0.35, 0.24, 0.14))
		forest_root.add_child(trunk)
		var crown := MeshInstance3D.new()
		var crown_mesh := SphereMesh.new()
		crown_mesh.radius = 2.1
		crown_mesh.height = 3.6
		crown.mesh = crown_mesh
		crown.position = placed + Vector3(0, 4.2, 0)
		crown.material_override = _flat_color(Color(0.15, 0.38, 0.16))
		forest_root.add_child(crown)
	_add_sign("ЛЕС", Vector3(FOREST_CENTER.x, 7.0, FOREST_CENTER.y), forest_root)


func _add_sign(text: String, pos: Vector3, parent: Node) -> void:
	var sign_label := Label3D.new()
	sign_label.text = text
	sign_label.position = pos
	sign_label.font_size = 48
	sign_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	parent.add_child(sign_label)


func _make_precip(amount: int, life: float, speed_min: float, speed_max: float, drop_size: Vector2, color: Color, gravity: Vector3) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = life
	particles.preprocess = 0.4
	particles.emitting = false
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = Vector3(16, 0.4, 16)
	particles.direction = Vector3(0.15, -1, 0.1)
	particles.spread = 8.0
	particles.gravity = gravity
	particles.initial_velocity_min = speed_min
	particles.initial_velocity_max = speed_max
	var drop := QuadMesh.new()
	drop.size = drop_size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop.material = material
	particles.mesh = drop
	add_child(particles)
	return particles


func _place_precip() -> void:
	var origin := Vector3(0, 14, 0)
	if craft != null:
		origin = craft.global_position + Vector3(0, 12, 0)
	for particles in [rain, snow, hail]:
		if particles == null:
			continue
		particles.global_position = origin
	if rain != null:
		rain.emitting = flying and precip == 1
	if snow != null:
		snow.emitting = flying and precip == 2
	if hail != null:
		hail.emitting = flying and precip == 3


func _update_gust(delta: float) -> void:
	gust_timer -= delta
	if gust_timer <= 0.0:
		gust_timer = randf_range(0.45, 1.15)
		var amp := 0.0
		if turbulence_on:
			amp += 0.3 * wind_speed + 0.25
		if craft != null and craft.airborne and craft.position.y < 8.0 and _in_forest(craft.position):
			amp += 1.5
		amp = minf(amp, 2.5)
		var dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
		if dir.length() < 0.05:
			dir = Vector3(1, 0, 0)
		gust_target = dir.normalized() * amp
	gust = gust.move_toward(gust_target, 3.5 * delta)


func _ground_height(pos: Vector3) -> float:
	return _sample_height(pos.x, pos.z)


func _sample_height(x: float, z: float) -> float:
	var h := _wave_height(x, z) + _hill_only(x, z) + _pond_dent(x, z)
	var pad_d := Vector2(x, z).length()
	if pad_d < 9.0:
		h = lerpf(0.0, h, smoothstep(4.0, 9.0, pad_d))
	if x >= 18.0 and x <= 30.0 and absf(z - POND_CENTER.y) <= 1.6:
		h = 0.05
	return h


func _wave_height(x: float, z: float) -> float:
	return 0.45 * sin(x * 0.085) * cos(z * 0.07) + 0.22 * sin(x * 0.19 + z * 0.13)


func _hill_only(x: float, z: float) -> float:
	var dist := Vector2(x - HILL_CENTER.x, z - HILL_CENTER.z).length()
	if dist >= HILL_RADIUS:
		return 0.0
	var t := 1.0 - dist / HILL_RADIUS
	return HILL_PEAK * t * t


func _pond_dent(x: float, z: float) -> float:
	var dist := Vector2(x, z).distance_to(POND_CENTER)
	var edge := POND_RADIUS + 6.0
	if dist >= edge:
		return 0.0
	var u := 1.0 - dist / edge
	return -1.2 * u * u


func _surface_kind(pos: Vector3) -> int:
	if _on_pier(pos):
		return 0
	if Vector2(pos.x, pos.z).distance_to(POND_CENTER) <= POND_RADIUS:
		return 1
	return 0


func _slope_accel(pos: Vector3) -> Vector3:
	if _hill_only(pos.x, pos.z) < 0.35:
		return Vector3.ZERO
	var away := Vector3(pos.x - HILL_CENTER.x, 0.0, pos.z - HILL_CENTER.z)
	if away.length() < 1.2:
		return Vector3.ZERO
	var dist := away.length()
	var t := 1.0 - dist / HILL_RADIUS
	var grade := 2.0 * HILL_PEAK / HILL_RADIUS * t
	return away.normalized() * FlightModel.G * grade * 0.7


func _on_pier(pos: Vector3) -> bool:
	return pos.x >= 18.0 and pos.x <= 30.0 and absf(pos.z - POND_CENTER.y) <= 1.6


func _in_forest(pos: Vector3) -> bool:
	return Vector2(pos.x, pos.z).distance_to(FOREST_CENTER) <= FOREST_RADIUS


func _start_spot() -> Vector3:
	match terrain:
		TERRAIN_SLOPE:
			return Vector3(0.0, 0.0, -24.0)
		TERRAIN_WATER:
			return Vector3(22.0, 0.0, POND_CENTER.y)
		TERRAIN_FOREST:
			return Vector3(-16.0, 0.0, 4.0)
		_:
			return Vector3.ZERO


func _terrain_name() -> String:
	match terrain:
		TERRAIN_SLOPE:
			return "склон на север"
		TERRAIN_WATER:
			return "вода с причалом"
		TERRAIN_FOREST:
			return "лес"
		_:
			return "ровный полигон"


func _precip_name() -> String:
	match precip:
		1:
			return "дождь"
		2:
			return "снег"
		3:
			return "град"
		_:
			return "нет"


func _flat_color(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	return material


func _pair(caption: String, key: String, width: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var title := Label.new()
	title.text = caption
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.78, 0.82, 0.86))
	row.add_child(title)
	row.add_child(_slot(key, width))
	return row


func _slot(key: String, width: float) -> Control:
	var frame := Control.new()
	frame.custom_minimum_size = Vector2(width, 18)
	frame.clip_contents = true
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.add_theme_font_size_override("font_size", 14)
	label.position = Vector2.ZERO
	label.size = Vector2(width, 18)
	frame.add_child(label)
	hud_slots[key] = label
	return frame


func _set_slot(key: String, text: String) -> void:
	var label := hud_slots.get(key) as Label
	if label != null:
		label.text = text


func _build_height_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cells := 72
	var span := 180.0
	var step := span / float(cells)
	var origin := -span * 0.5
	for iz in cells:
		for ix in cells:
			var x0 := origin + float(ix) * step
			var z0 := origin + float(iz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			_add_ground_vertex(tool, x0, z0)
			_add_ground_vertex(tool, x1, z0)
			_add_ground_vertex(tool, x1, z1)
			_add_ground_vertex(tool, x0, z0)
			_add_ground_vertex(tool, x1, z1)
			_add_ground_vertex(tool, x0, z1)
	tool.generate_normals()
	return tool.commit()


func _add_ground_vertex(tool: SurfaceTool, x: float, z: float) -> void:
	var h := _sample_height(x, z)
	tool.set_color(_ground_tint(h, x, z))
	tool.add_vertex(Vector3(x, h, z))


func _ground_tint(h: float, x: float, z: float) -> Color:
	var grass := Color(0.30, 0.46, 0.24)
	var sand := Color(0.64, 0.58, 0.38)
	var rock := Color(0.46, 0.47, 0.42)
	var shore := clampf((Vector2(x, z).distance_to(POND_CENTER) - POND_RADIUS) / 6.0, 0.0, 1.0)
	var tint := sand.lerp(grass, shore)
	if h > 2.2:
		tint = tint.lerp(rock, clampf((h - 2.2) / 2.4, 0.0, 1.0))
	return tint * (0.94 + 0.06 * sin(x * 0.55 + z * 0.8))


func _wind_slider() -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var caption := Label.new()
	caption.text = "Ветер"
	box.add_child(caption)
	box.add_child(_wind_direction_picker())
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 15.0
	slider.step = 1.0
	slider.value = wind_speed
	slider.custom_minimum_size = Vector2(130, 16)
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(func(value: float) -> void:
		wind_speed = value
		_refresh_wind_labels()
	)
	wind_sliders.append(slider)
	box.add_child(slider)
	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(58, 0)
	wind_labels.append(value_label)
	box.add_child(value_label)
	_refresh_wind_labels()
	return box


func _wind_direction_picker() -> OptionButton:
	var picker := OptionButton.new()
	picker.focus_mode = Control.FOCUS_NONE
	var names := ["С", "СВ", "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ"]
	for index in names.size():
		picker.add_item(names[index], index)
	picker.selected = wind_from
	picker.item_selected.connect(func(index: int) -> void:
		wind_from = index
		_refresh_wind_dirs()
	)
	wind_pickers.append(picker)
	return picker


func _refresh_wind_dirs() -> void:
	for picker in wind_pickers:
		if picker.selected == wind_from:
			continue
		picker.set_block_signals(true)
		picker.selected = wind_from
		picker.set_block_signals(false)


func _refresh_wind_labels() -> void:
	var text := "%.0f м/с" % wind_speed
	for label in wind_labels:
		label.text = text
	for slider in wind_sliders:
		if absf(slider.value - wind_speed) > 0.01:
			slider.set_value_no_signal(wind_speed)


func _heading_name(forward: Vector3) -> String:
	var east := forward.x
	var north := -forward.z
	var sector := int(round(rad_to_deg(atan2(east, north)) / 45.0))
	var names := ["С", "СВ", "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ"]
	return names[posmod(sector, 8)]


func _panel(pos: Vector2, size: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.position = pos
	panel.custom_minimum_size = size
	panel.size = size
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.13, 0.9)
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 22)
	return label


func _hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(420, 0)
	return label



