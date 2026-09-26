extends Node3D

const VehicleLibrary = preload("res://scripts/vehicle_library.gd")
const Quadrotor = preload("res://scripts/quadrotor.gd")

## Меню, полигон и камеры. Физика живёт в quadrotor.gd и flight_model.gd.
## Окно собирается кодом, чтобы не прятать логику в файле сцены.

var library := VehicleLibrary.new()
var selected := 0
var flying := false
var wind_speed := 7.0
var rain_on := false
var show_forces := true
var camera_mode := 0
var craft: Quadrotor
var camera: Camera3D
var rain: CPUParticles3D
var wind_arrow: MeshInstance3D
var force_arrows: Dictionary = {}
var log_lines: PackedStringArray = []
var warned := false

var menu_panel: PanelContainer
var flight_panel: PanelContainer
var list_box: VBoxContainer
var detail_label: Label
var hud_label: Label
var warning_label: Label
var wind_labels: Array[Label] = []
var wind_sliders: Array[HSlider] = []
var status_label: Label
var orbit_yaw := 0.6
var orbit_pitch := -0.45
var orbit_distance := 8.0


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
	craft.wind = _wind_vector()
	craft.rain = rain_on
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
	_update_forces()
	_update_hud()


func _process(_delta: float) -> void:
	if camera == null:
		return
	_place_camera()
	if rain != null:
		rain.emitting = rain_on and flying
		if craft != null:
			rain.global_position = craft.global_position + Vector3(0, 12, 0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		orbit_yaw -= event.relative.x * 0.005
		orbit_pitch = clampf(orbit_pitch - event.relative.y * 0.004, -1.2, -0.05)
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

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(240, 240)
	ground.mesh = plane
	var grass := StandardMaterial3D.new()
	grass.albedo_color = Color(0.32, 0.46, 0.28)
	ground.material_override = grass
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
	for mark in range(-4, 5):
		if mark == 0:
			continue
		var line := MeshInstance3D.new()
		var line_mesh := BoxMesh.new()
		line_mesh.size = Vector3(80.0, 0.02, 0.12)
		line.mesh = line_mesh
		line.position = Vector3(0.0, 0.02, mark * 10.0)
		var line_paint := StandardMaterial3D.new()
		line_paint.albedo_color = Color(0.75, 0.78, 0.7)
		line.material_override = line_paint
		add_child(line)

	var north := Label3D.new()
	north.text = "СЕВЕР"
	north.position = Vector3(0, 0.4, -28)
	north.font_size = 64
	north.modulate = Color(0.95, 0.95, 0.9)
	north.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(north)

	wind_arrow = MeshInstance3D.new()
	var arrow_mesh := BoxMesh.new()
	arrow_mesh.size = Vector3(0.35, 0.08, 6.0)
	wind_arrow.mesh = arrow_mesh
	var arrow_mat := StandardMaterial3D.new()
	arrow_mat.albedo_color = Color(0.35, 0.7, 0.95)
	wind_arrow.material_override = arrow_mat
	wind_arrow.position = Vector3(8, 0.4, 8)
	add_child(wind_arrow)

	for force_name in ["thrust", "drag", "weight"]:
		var arrow := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.04
		cylinder.bottom_radius = 0.04
		cylinder.height = 1.0
		arrow.mesh = cylinder
		var material := StandardMaterial3D.new()
		material.albedo_color = _force_color(force_name)
		arrow.material_override = material
		arrow.visible = false
		add_child(arrow)
		force_arrows[force_name] = arrow

	rain = CPUParticles3D.new()
	rain.amount = 420
	rain.lifetime = 1.4
	rain.preprocess = 1.2
	rain.emitting = false
	rain.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	rain.emission_box_extents = Vector3(16, 0.4, 16)
	rain.direction = Vector3(0.2, -1, 0.15)
	rain.spread = 6.0
	rain.gravity = Vector3(0, -8, 0)
	rain.initial_velocity_min = 9.0
	rain.initial_velocity_max = 13.0
	var drop := QuadMesh.new()
	drop.size = Vector2(0.03, 0.28)
	rain.mesh = drop
	add_child(rain)

	camera = Camera3D.new()
	camera.current = true
	add_child(camera)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	menu_panel = _panel(Vector2(24, 24), Vector2(460, 640))
	layer.add_child(menu_panel)
	var menu_box := VBoxContainer.new()
	menu_box.add_theme_constant_override("separation", 8)
	menu_panel.add_child(menu_box)
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
	menu_box.add_child(_hint("Ветер с северо-запада, м/с. 7 — пример из задания, не «шторм»."))
	menu_box.add_child(_wind_slider())
	var rain_box := CheckButton.new()
	rain_box.text = "Дождь: сопротивление +15%"
	rain_box.focus_mode = Control.FOCUS_NONE
	rain_box.toggled.connect(func(on: bool) -> void: rain_on = on)
	menu_box.add_child(rain_box)
	var force_box := CheckButton.new()
	force_box.text = "Показать силы: тяга, вес, сопротивление"
	force_box.button_pressed = true
	force_box.focus_mode = Control.FOCUS_NONE
	force_box.toggled.connect(func(on: bool) -> void: show_forces = on)
	menu_box.add_child(force_box)
	var start := Button.new()
	start.text = "Начать полёт"
	start.focus_mode = Control.FOCUS_NONE
	start.pressed.connect(_start_flight)
	menu_box.add_child(start)
	status_label = _hint("Shift поднимает, Ctrl снижает. Высоту потом держит сам. A/D крен, Q/E поворот, W/S наклон. C — камера.")
	menu_box.add_child(status_label)

	flight_panel = _panel(Vector2(8, 8), Vector2(1264, 52))
	flight_panel.visible = false
	var tight := flight_panel.get_theme_stylebox("panel") as StyleBoxFlat
	if tight != null:
		tight.content_margin_left = 8
		tight.content_margin_right = 8
		tight.content_margin_top = 4
		tight.content_margin_bottom = 4
	layer.add_child(flight_panel)
	var flight_box := HBoxContainer.new()
	flight_box.add_theme_constant_override("separation", 10)
	flight_panel.add_child(flight_box)
	hud_label = Label.new()
	hud_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flight_box.add_child(hud_label)
	flight_box.add_child(_wind_slider())
	var back := Button.new()
	back.text = "Меню"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_back_to_menu)
	flight_box.add_child(back)
	var save := Button.new()
	save.text = "Журнал"
	save.focus_mode = Control.FOCUS_NONE
	save.pressed.connect(_save_log)
	flight_box.add_child(save)
	warning_label = Label.new()
	warning_label.position = Vector2(16, 58)
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
	var scale := float(model.get("drag_scale", 1.0))
	lines.append("Сопротивление подогнано под паспортную скорость, множитель к площади: %.1f." % scale)
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
	orbit_distance = maxf(float(craft.model.get("width", 0.4)) * 22.0, 12.0)
	flying = true
	warned = false
	log_lines.clear()
	_log("Старт: " + str(library.profiles[selected].get("display_name", "")))
	if wind_speed > 0.1:
		_log("Ветер %.0f м/с с северо-запада" % wind_speed)
	if rain_on:
		_log("Дождь, сопротивление +15%")
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
	for arrow in force_arrows.values():
		(arrow as Node3D).visible = false


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
	if Input.is_physical_key_pressed(KEY_E):
		yaw_goal += 1.0
	if Input.is_physical_key_pressed(KEY_Q):
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
	# Короткое нажатие даёт маленький наклон. Полный наклон только если удерживать клавишу.
	var stick_step := 2.4 * delta
	craft.stick_pitch = move_toward(craft.stick_pitch, clampf(pitch_goal, -1.0, 1.0), stick_step)
	craft.stick_roll = move_toward(craft.stick_roll, clampf(roll_goal, -1.0, 1.0), stick_step)
	craft.stick_yaw = move_toward(craft.stick_yaw, clampf(yaw_goal, -1.0, 1.0), stick_step)
	craft.climb_command = climb


func _update_hud() -> void:
	if craft == null:
		return
	var ground_kmh := craft.velocity.length() * 3.6
	hud_label.text = "%s   %.1f м   %.0f км/ч   нос %s   тяга %d%%" % [
		str(craft.profile.get("display_name", "")),
		craft.position.y,
		ground_kmh,
		_heading_name(craft.forward()),
		int(round(craft.throttle * 100.0)),
	]
	warning_label.text = craft.warning


func _update_forces() -> void:
	var blow := _wind_vector()
	wind_arrow.visible = blow.length() > 0.2
	if wind_arrow.visible:
		wind_arrow.position = Vector3(0.0, 0.45, 0.0)
		wind_arrow.look_at(wind_arrow.position + Vector3(blow.x, 0.0, blow.z), Vector3.UP)
	if craft == null:
		return
	var visible := show_forces and craft.motors_on
	_place_force("thrust", craft.thrust_force, visible)
	_place_force("drag", craft.drag_force, visible)
	_place_force("weight", craft.weight_force, visible)


func _place_force(force_name: String, force: Vector3, visible: bool) -> void:
	var arrow := force_arrows[force_name] as MeshInstance3D
	var length := force.length()
	if not visible or length < 0.05:
		arrow.visible = false
		return
	arrow.visible = true
	var shown := force / maxf(float(craft.model.get("weight", 1.0)), 0.1) * 1.4
	var shown_len := maxf(shown.length(), 0.15)
	var direction := shown.normalized()
	var up := Vector3.UP
	if absf(direction.dot(up)) > 0.95:
		up = Vector3.RIGHT
	var side := direction.cross(up).normalized()
	var basis := Basis(side, direction, side.cross(direction).normalized())
	arrow.transform = Transform3D(basis.scaled(Vector3(1.0, shown_len, 1.0)), craft.position + Vector3(0, 0.3, 0) + direction * shown_len * 0.5)


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
	# Север в этой сцене — отрицательная Z. Ветер с северо-запада дует на юго-восток.
	return Vector3(1, 0, 1).normalized() * wind_speed


func _log(line: String) -> void:
	log_lines.append(line)
	if log_lines.size() > 40:
		log_lines.remove_at(0)


func _save_log() -> void:
	var path := "user://flight_log.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		status_label.text = "Не удалось записать журнал."
		return
	file.store_string("\n".join(log_lines))
	file.close()
	var full := ProjectSettings.globalize_path(path)
	warning_label.text = "Журнал записан: " + full
	_log("Журнал сохранён")


func _show_menu() -> void:
	menu_panel.visible = true
	flight_panel.visible = false


func _wind_slider() -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var caption := Label.new()
	caption.text = "Ветер"
	box.add_child(caption)
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


func _force_color(force_name: String) -> Color:
	match force_name:
		"thrust":
			return Color(0.3, 0.85, 0.45)
		"drag":
			return Color(0.35, 0.65, 1.0)
		_:
			return Color(0.95, 0.45, 0.35)
