extends Node3D

const VehicleLibrary = preload("res://scripts/vehicle_library.gd")
const Quadrotor = preload("res://scripts/quadrotor.gd")
const FlightModel = preload("res://scripts/flight_model.gd")
const RangeField = preload("res://scripts/island_field.gd")
const FlightOverlay = preload("res://scripts/flight_overlay.gd")
const DayNight = preload("res://scripts/day_night.gd")
const FlightTrace = preload("res://scripts/flight_trace.gd")
const CanopyDrag = preload("res://scripts/canopy_drag.gd")
const InterfaceHud = preload("res://scripts/interface_hud.gd")
const UiTheme = preload("res://scripts/ui_theme.gd")

const TERRAIN_POLYGON := 0
const TERRAIN_COURSE := 1

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
var world_environment: WorldEnvironment
var overlay
var day_night: DayNight
var trace: FlightTrace
var show_trace := false
var show_flow := false
var lights_on := true
var autopilot_button: Button
var trace_button: Button
var flow_button: Button
var lights_button: Button
var conditions_panel: PanelContainer
var clock_labels: Array[Label] = []
var hour_sliders: Array[HSlider] = []
var cycle_buttons: Array[CheckButton] = []
var precip_pickers: Array[OptionButton] = []
var show_sensors := false
var show_aero := false
var show_wind := false
var show_thrust := false
var show_drag := false
var sensor_button: Button
var aero_button: Button
var wind_button: Button
var thrust_button: Button
var drag_button: Button
var rain: GPUParticles3D
var snow: GPUParticles3D
var hail: GPUParticles3D
var field
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
var max_tilt_deg := 0.0
var sample_timer := 0.0
var sample_lines: PackedStringArray = []
var report_warnings: PackedStringArray = []
var report_dialog: FileDialog
var event_autopilot := false
var event_low_battery := false
var event_empty_battery := false
var event_precip := 0
var event_turbulence := false
var home_position := Vector3.ZERO
var route_points: Array[Vector3] = []
var interface_hud: Control
var pause_panel: PanelContainer
var paused := false
var clean_screen := false
var hud_scale := 1.0


func _ready() -> void:
	_build_world()
	library.load_all()
	_build_ui()
	_select(0)
	_show_menu()


func _physics_process(delta: float) -> void:
	if not flying or craft == null or paused:
		return
	_read_flight_input(delta)
	_update_gust(delta)
	CanopyDrag.apply(craft, field.crowns, delta)
	craft.wind = _wind_vector() + gust + craft.canopy_gust
	craft.air_density = FlightModel.air_density(air_temp)
	craft.air_temp = air_temp
	craft.precip = precip
	_sync_surface()
	craft.water_surface = RangeField.WATER_Y
	var was_airborne := craft.airborne
	var had_motors := craft.motors_on
	var hit := {"note": ""}
	# At most half a body radius travelled per substep prevents thin-wall tunnelling.
	# Не допускаем спираль перегрузки: большой delta после просадки FPS не
	# должен запускать десятки дополнительных физических подшагов.
	var substeps := clampi(int(ceil(maxf(delta * 120.0, craft.velocity.length() * delta / maxf(craft.collision_radius * 0.5, 0.02)))), 1, 8)
	for substep in substeps:
		_sync_surface()
		craft.step(delta / float(substeps))
		var contact: Dictionary = field.resolve(craft.position, craft.velocity, craft.collision_radius, craft.ground_clearance)
		craft.position = contact["pos"]
		craft.velocity = contact["vel"]
		# Re-sample after moving horizontally: steep terrain must not lag by a tick.
		_sync_surface()
		if craft.surface_kind == 0 and craft.position.y < craft.surface_y + craft.ground_clearance:
			craft.position.y = craft.surface_y + craft.ground_clearance
			craft.velocity.y = maxf(craft.velocity.y, 0.0)
			craft.airborne = false
		if str(contact["note"]) != "":
			hit = contact
	if str(hit["note"]) != "" and not craft.ditched and craft.battery > 0.02:
		craft.warning = str(hit["note"])
	elif craft.canopy > 0.35 and craft.airborne and craft.warning == "":
		craft.warning = "Крона мешает полёту: сопротивление выше. Поднимитесь над листвой или облетите рощу."
	if not was_airborne and craft.airborne:
		_log("Взлёт")
	if had_motors and not craft.motors_on:
		_log("Посадка")
	if craft.autopilot_on != event_autopilot:
		_log("Срабатывание автопилота" if craft.autopilot_on else "Отключение автопилота")
		event_autopilot = craft.autopilot_on
	if craft.battery <= 0.15 and not event_low_battery:
		_log("Низкий заряд батареи: %.0f%%" % (craft.battery * 100.0))
		event_low_battery = true
	if craft.battery <= 0.02 and not event_empty_battery:
		_log("Батарея села. Моторы выключены")
		event_empty_battery = true
	if precip != event_precip:
		if precip != 0:
			_log("Начало осадков: " + _precip_name())
		event_precip = precip
	if turbulence_on != event_turbulence:
		_log("Турбулентность: " + ("включена" if turbulence_on else "отключена"))
		event_turbulence = turbulence_on
	if craft.warning != "" and not warned:
		_log(craft.warning)
		warned = true
		if craft.warning.begins_with("Столкновение") or craft.warning.begins_with("Крона"):
			status_flash = craft.warning
			status_flash_time = 3.5
	if craft.warning == "":
		warned = false
	if craft.warning != "" and not report_warnings.has(craft.warning):
		report_warnings.append(craft.warning)
	flight_seconds += delta
	max_altitude = maxf(max_altitude, craft.height_above_surface())
	max_speed = maxf(max_speed, craft.velocity.length())
	min_battery = minf(min_battery, craft.battery * 100.0)
	min_signal = minf(min_signal, craft.radio)
	max_motor_temp = maxf(max_motor_temp, craft.motor_temp)
	max_tilt_deg = maxf(max_tilt_deg, rad_to_deg(Vector2(craft.pitch, craft.roll).length()))
	sample_timer -= delta
	if sample_timer <= 0.0:
		sample_timer = 1.0
		_take_sample()
	trace.sample(craft.position, delta)
	_update_wind_arrow()
	_update_hud()


func _sync_surface() -> void:
	craft.surface_y = field.support_height(craft.position, craft.ground_clearance)
	craft.surface_kind = field.surface_kind(craft.position)
	craft.slope_accel = field.slope_accel(craft.position)


func _process(_delta: float) -> void:
	if paused:
		flight_panel.hide()
		return
	if field != null:
		field.advance_weather(precip == 2, _delta)
		field.set_foliage_wind(_wind_vector() + gust, field.snow_cover)
	day_night.update(_delta)
	for label in clock_labels:
		label.text = day_night.clock_text()
	for slider in hour_sliders:
		slider.set_value_no_signal(day_night.hour)
	for button in cycle_buttons:
		button.set_pressed_no_signal(day_night.cycling)
	if craft != null:
		craft.navigation_lights.visible = lights_on and day_night.daylight < 0.5
		# FPV получает отдельный OSD без старой верхней строки телеметрии.
		flight_panel.visible = flying and camera_mode != 1 and not paused and not clean_screen
	trace.visible = show_trace and flying
	if camera == null:
		return
	_place_camera()
	if overlay != null and is_instance_valid(overlay):
		# Из кабины конус не рисуем: он начинается в объективе и зальёт весь кадр.
		overlay.set("sensors_on", show_sensors and camera_mode != 1)
		overlay.set("aero_on", show_aero)
		overlay.set("wind_on", show_wind)
		overlay.set("thrust_on", show_thrust)
		overlay.set("drag_on", show_drag)
		overlay.set("flow_on", show_flow and camera_mode != 1)
	if status_flash_time > 0.0:
		status_flash_time -= _delta
		if status_flash_time <= 0.0:
			status_flash = ""
	_place_precip()


func _unhandled_input(event: InputEvent) -> void:
	if report_dialog != null and report_dialog.visible:
		return
	if paused and not (event is InputEventKey and event.keycode == KEY_ESCAPE):
		return
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
		if event.keycode == KEY_P:
			_toggle_autopilot()
		elif event.keycode == KEY_T:
			_toggle_trace()
		elif event.keycode == KEY_F:
			_toggle_flow()
		elif event.keycode == KEY_L:
			_toggle_lights()
		elif event.keycode == KEY_C:
			camera_mode = (camera_mode + 1) % 4
		elif event.keycode == KEY_V:
			_toggle_sensors()
		elif event.keycode == KEY_B:
			_toggle_forces()
		elif event.keycode == KEY_ESCAPE and flying:
			_toggle_pause()
		elif event.keycode == KEY_F10 and flying:
			clean_screen = not clean_screen
			interface_hud.clean_screen = clean_screen
		elif event.keycode == KEY_F11 and flying:
			hud_scale = 1.15 if hud_scale < 1.1 else 1.0
			interface_hud.hud_scale = hud_scale


func _build_world() -> void:
	var env := WorldEnvironment.new()
	world_environment = env
	var environment := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.16, 0.36, 0.74)
	sky_mat.sky_horizon_color = Color(0.66, 0.8, 0.94)
	sky_mat.ground_bottom_color = Color(0.16, 0.24, 0.14)
	sky_mat.ground_horizon_color = Color(0.48, 0.58, 0.52)
	sky_mat.sky_curve = 0.2
	sky_mat.sun_angle_max = 0.5
	sky_mat.sky_energy_multiplier = 0.65
	sky_mat.ground_energy_multiplier = 0.65
	sky.sky_material = sky_mat
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	# Холодный заполняющий свет, чтобы тень была синей, а не чёрной. Это не SSAO.
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.62, 0.8)
	environment.ambient_light_energy = 0.3
	environment.ambient_light_sky_contribution = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# Обычный туман даёт глубину в Compatibility. Объёмный туман и SSAO этот рендер не рисует.
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_density = 0.0006
	environment.fog_light_color = Color(0.55, 0.7, 0.88)
	environment.fog_aerial_perspective = 0.4
	environment.fog_sun_scatter = 0.18
	environment.glow_enabled = false
	environment.glow_intensity = 0.25
	environment.glow_strength = 0.45
	environment.glow_bloom = 0.04
	env.environment = environment
	add_child(env)

	day_night = DayNight.new()
	add_child(day_night)
	day_night.setup(environment)
	trace = FlightTrace.new()
	add_child(trace)

	field = RangeField.new()
	add_child(field)
	field.build()

	_build_wind_arrow()

	rain = _make_precip(420, 1.4, 9.0, 13.0, Vector2(0.03, 0.28), Color(0.75, 0.82, 0.9), Vector3(0, -8, 0))
	snow = _make_precip(1000, 8.0, 1.5, 2.5, Vector2(0.10, 0.10), Color(0.95, 0.96, 0.98), Vector3(0, -0.2, 0))
	hail = _make_precip(70, 0.7, 16.0, 22.0, Vector2(0.07, 0.07), Color(0.85, 0.9, 0.95), Vector3(0, -18, 0))

	camera = Camera3D.new()
	camera.current = true
	camera.near = 0.015
	camera.far = 7000.0
	add_child(camera)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	menu_panel = _panel(Vector2(24, 24), Vector2(460, 660))
	menu_panel.theme = UiTheme.get_theme()
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
	menu_box.add_child(_time_controls())
	var turb_box := CheckButton.new()
	turb_box.text = "Турбулентность: порывы к ветру"
	turb_box.focus_mode = Control.FOCUS_NONE
	turb_box.toggled.connect(func(on: bool) -> void: turbulence_on = on)
	menu_box.add_child(turb_box)
	var menu_actions := HBoxContainer.new()
	menu_actions.add_theme_constant_override("separation", 8)
	outer.add_child(menu_actions)
	var start := Button.new()
	start.text = "Начать полёт"
	start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start.focus_mode = Control.FOCUS_NONE
	start.pressed.connect(_start_flight)
	menu_actions.add_child(start)
	var exit_button := Button.new()
	exit_button.text = "Выйти"
	exit_button.focus_mode = Control.FOCUS_NONE
	exit_button.pressed.connect(func() -> void: get_tree().quit())
	menu_actions.add_child(exit_button)
	status_label = _hint("Shift / Ctrl — высота. P — автопилот после взлёта. L — бортовые огни ночью. T — траектория, F — потоки. C — камеры, B — силы, V — конус камеры.")
	outer.add_child(status_label)
	_apply_terrain()

	flight_panel = _panel(Vector2(8, 8), Vector2(1264, 92))
	flight_panel.theme = UiTheme.get_theme()
	flight_panel.visible = false
	flight_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	flight_panel.offset_left = 8
	flight_panel.offset_top = 8
	flight_panel.offset_right = -8
	flight_panel.offset_bottom = 100
	layer.add_child(flight_panel)
	var flight_box := VBoxContainer.new()
	flight_box.add_theme_constant_override("separation", 4)
	flight_panel.add_child(flight_box)
	var feature_row := HBoxContainer.new()
	feature_row.add_theme_constant_override("separation", 6)
	flight_box.add_child(feature_row)
	wind_button = _toggle_button("Ветер", "Показать направление ветра")
	wind_button.pressed.connect(_toggle_wind)
	feature_row.add_child(wind_button)
	thrust_button = _toggle_button("Тяга", "Показать тягу моторов")
	thrust_button.pressed.connect(_toggle_thrust)
	feature_row.add_child(thrust_button)
	drag_button = _toggle_button("Сопр.", "Показать сопротивление")
	drag_button.pressed.connect(_toggle_drag)
	feature_row.add_child(drag_button)
	sensor_button = _toggle_button("Камера", "Показать конус камеры")
	sensor_button.pressed.connect(_toggle_sensors)
	feature_row.add_child(sensor_button)
	aero_button = _toggle_button("Аэродинамика", "Показать скорость")
	aero_button.pressed.connect(_toggle_aero)
	feature_row.add_child(aero_button)
	flow_button = _toggle_button("Потоки [F]", "Показать воздушные потоки")
	flow_button.pressed.connect(_toggle_flow)
	feature_row.add_child(flow_button)
	lights_button = _toggle_button("Огни [L]", "Бортовые огни")
	lights_button.button_pressed = lights_on
	lights_button.pressed.connect(_toggle_lights)
	feature_row.add_child(lights_button)
	var menu_button := Button.new()
	menu_button.text = "Меню"
	menu_button.focus_mode = Control.FOCUS_NONE
	menu_button.pressed.connect(_back_to_menu)
	feature_row.add_child(menu_button)
	var report := Button.new()
	report.text = "Отчёт"
	report.focus_mode = Control.FOCUS_NONE
	report.pressed.connect(_save_log)
	feature_row.add_child(report)
	var control_row := HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 6)
	flight_box.add_child(control_row)
	autopilot_button = _toggle_button("Автопилот: ВЫКЛ [P]", "Удержание высоты и курса")
	autopilot_button.pressed.connect(_toggle_autopilot)
	control_row.add_child(autopilot_button)
	trace_button = _toggle_button("Траектория [T]", "Показать маршрут")
	trace_button.pressed.connect(_toggle_trace)
	control_row.add_child(trace_button)
	var camera_cycle := Button.new()
	camera_cycle.text = "Камера [C]"
	camera_cycle.focus_mode = Control.FOCUS_NONE
	camera_cycle.pressed.connect(_cycle_camera)
	control_row.add_child(camera_cycle)
	var pause_button := Button.new()
	pause_button.text = "Пауза [ESC]"
	pause_button.focus_mode = Control.FOCUS_NONE
	pause_button.pressed.connect(_toggle_pause)
	control_row.add_child(pause_button)
	conditions_panel = _panel(Vector2(0, 0), Vector2(460, 440))
	conditions_panel.theme = UiTheme.get_theme()
	conditions_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	conditions_panel.offset_left = -230
	conditions_panel.offset_top = -220
	conditions_panel.offset_right = 230
	conditions_panel.offset_bottom = 220
	layer.add_child(conditions_panel)
	var settings_scroll := ScrollContainer.new()
	settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	conditions_panel.add_child(settings_scroll)
	var conditions_box := VBoxContainer.new()
	conditions_box.add_theme_constant_override("separation", 8)
	conditions_box.custom_minimum_size.x = 420
	settings_scroll.add_child(conditions_box)
	conditions_box.add_child(_title("Настройки полёта"))
	conditions_box.add_child(_hint("Ветер и погода применяются сразу после изменения."))
	conditions_box.add_child(_wind_slider())
	conditions_box.add_child(_time_controls())
	conditions_box.add_child(_precip_picker())
	var close_conditions := Button.new()
	close_conditions.text = "Назад к паузе"
	close_conditions.pressed.connect(func() -> void:
		conditions_panel.hide()
		pause_panel.visible = paused
	)
	conditions_box.add_child(close_conditions)
	conditions_panel.hide()
	warning_label = Label.new()
	warning_label.visible = false
	warning_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(warning_label)
	interface_hud = InterfaceHud.new()
	interface_hud.setup(self)
	layer.add_child(interface_hud)
	_build_pause_panel(layer)

func _select(index: int) -> void:
	if library.profiles.is_empty():
		detail_label.text = "В data/vehicles нет ни одного аппарата с массой."
		return
	selected = clampi(index, 0, library.profiles.size() - 1)
	var profile: Dictionary = library.profiles[selected]
	var lines := library.summary_lines(profile)
	var fov_node: Variant = profile.get("camera_fov_deg", {})
	if FlightModel.read_number(fov_node, -1.0) > 0.0:
		lines.append("Угол камеры: " + _tagged_number(fov_node, "%.0f", "°") + ". На тягу не влияет, только на конус.")
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
	trace.clear()
	conditions_panel.hide()
	var spot := _start_spot()
	var clearance := craft.ground_clearance
	craft.position = Vector3(spot.x, field.sample_height(spot.x, spot.z) + clearance + 0.04, spot.z)
	home_position = craft.position
	overlay = FlightOverlay.new()
	craft.add_child(overlay)
	overlay.call("setup")
	craft.target_altitude = craft.position.y
	if terrain == TERRAIN_COURSE:
		craft.yaw = PI / 2
		craft.rotation.y = craft.yaw
	craft.motor_temp = air_temp
	craft.air_temp = air_temp
	orbit_distance = maxf(craft.collision_radius * 16.0, 2.0)
	flying = true
	paused = false
	clean_screen = false
	interface_hud.clean_screen = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	warned = false
	log_lines.clear()
	report_warnings.clear()
	event_autopilot = false
	event_low_battery = false
	event_empty_battery = false
	event_precip = precip
	event_turbulence = turbulence_on
	flight_seconds = 0.0
	max_altitude = 0.0
	max_speed = 0.0
	min_battery = 100.0
	min_signal = 100.0
	max_motor_temp = air_temp
	max_tilt_deg = 0.0
	sample_timer = 0.0
	sample_lines = PackedStringArray()
	status_flash = ""
	gust = Vector3.ZERO
	gust_target = Vector3.ZERO
	gust_timer = 0.0
	mouse_stick = false
	mouse_pitch = 0.0
	mouse_roll = 0.0
	_log("Старт: " + str(library.profiles[selected].get("display_name", "")))
	_log("Местность: " + _terrain_name())
	_log("Ветер %.0f м/с, откуда %s, воздух %.0f °C" % [wind_speed, _wind_from_name(), air_temp])
	_log("Осадки: " + _precip_name())
	menu_panel.visible = false
	flight_panel.visible = true
	pause_panel.hide()
	_update_hud()


func _back_to_menu() -> void:
	conditions_panel.hide()
	pause_panel.hide()
	trace.visible = false
	flying = false
	paused = false
	overlay = null
	if craft != null:
		craft.queue_free()
		craft = null
	menu_panel.visible = true
	flight_panel.visible = false
	warning_label.text = ""
	mouse_stick = false
	mouse_pitch = 0.0
	mouse_roll = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
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
	_set_slot("alt", "%.1f м" % craft.height_above_surface())
	_set_slot("spd", "%.0f км/ч" % (craft.velocity.length() * 3.6))
	_set_slot("nose", _heading_name(craft.forward()))
	_set_slot("thr", "%d%%" % int(round(craft.throttle * 100.0)))
	_set_slot("roll", "%.0f°" % craft.sensor_roll)
	_set_slot("pitch", "%.0f°" % craft.sensor_pitch)
	_set_slot("yaw", "%d°" % (int(round(craft.sensor_yaw_deg)) % 360))
	autopilot_button.text = "Автопилот: %s [P]" % ("ВКЛ" if craft.autopilot_on else "ВЫКЛ")
	autopilot_button.button_pressed = craft.autopilot_on
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
	spot.y = field.sample_height(spot.x, spot.z) + 0.12
	wind_arrow.position = spot
	wind_arrow.look_at(spot + Vector3(blow.x, 0.0, blow.z), Vector3.UP)


func _place_camera() -> void:
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.near = 0.015 if flying and camera_mode != 3 else 1.0
	world_environment.environment.fog_enabled = camera_mode != 3 and flying
	if camera_mode == 3 and craft != null:
		craft.visual.visible = true
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 510.0
		camera.global_position = Vector3(0, 850, 0)
		camera.look_at(Vector3.ZERO, Vector3.FORWARD)
		return
	var target := Vector3(0, 1, 0)
	if craft != null:
		target = craft.global_position
	if craft != null and craft.visual != null:
		craft.visual.visible = camera_mode != 1
	camera.fov = 75.0
	if camera_mode == 1 and craft != null:
		camera.fov = FlightModel.read_number(craft.profile.get("camera_fov_deg"), 75.0)
		camera.global_position = target + craft.forward() * craft.collision_radius * 0.7
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
		camera.global_position = Vector3(250, 300, 340)
		camera.look_at(Vector3(0, 0, -15), Vector3.UP)


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
	var clean := line.strip_edges()
	if clean == "" or (not log_lines.is_empty() and log_lines[-1].ends_with(clean)):
		return
	log_lines.append("[%06.1f с] %s" % [flight_seconds, clean])
	if log_lines.size() > 40:
		log_lines.remove_at(0)


func _take_sample() -> void:
	if craft == null or sample_lines.size() >= 1200:
		return
	# Крен, тангаж, курс, батарея, моторы и сигнал — с шумом датчика, как на экране.
	# Высота и скорость — из модели, без этого шума.
	sample_lines.append("%.1f;%.2f;%.2f;%.1f;%.1f;%.1f;%.1f;%.1f;%.1f;%.2f;%.1f;%.2f" % [
		flight_seconds,
		craft.position.y,
		craft.velocity.length(),
		craft.sensor_roll,
		craft.sensor_pitch,
		craft.sensor_yaw_deg,
		craft.sensor_battery,
		craft.sensor_motor_temp,
		craft.sensor_signal,
		craft.throttle,
		wind_speed,
		gust.length(),
	])


func _origin_label(node: Variant) -> String:
	if typeof(node) != TYPE_DICTIONARY:
		return "нет в карточке"
	match str(node.get("origin", "")):
		"passport":
			return "паспорт"
		"assumption":
			return "допущение"
		"missing":
			return "нет в паспорте"
		_:
			return "нет в карточке"


func _tagged_number(node: Variant, pattern: String, unit: String) -> String:
	if FlightModel.read_number(node, -1.0) < 0.0:
		return "нет в карточке (" + _origin_label(node) + ")"
	return (pattern % FlightModel.read_number(node)) + " " + unit + " (" + _origin_label(node) + ")"


func _report_conclusion(profile: Dictionary, described: Dictionary) -> String:
	var vmax := float(described.get("vmax", 0.0))
	var lost := false
	for item in report_warnings:
		if item.find("Потеря устойчивости") >= 0:
			lost = true
	if lost:
		return "Модель показала потерю устойчивости. Рекомендация, которая была на экране, записана ниже. Это не лётное испытание настоящего аппарата."
	if wind_speed > 0.5 and vmax > 0.1 and wind_speed > vmax:
		return "Ветер сильнее паспортной скорости этого аппарата. Модель не обещает ход против такого ветра. Это не лётное испытание настоящего аппарата."
	if flight_seconds < 3.0:
		return "Полёт короче 3 секунд, для вывода мало данных. Это не лётное испытание настоящего аппарата."
	return "Предупреждения о потере устойчивости не было. Это учебный расчёт, не лётное испытание настоящего аппарата."


func _save_log() -> void:
	if flying:
		paused = true
		pause_panel.hide()
		flight_panel.hide()
		interface_hud.hide()
		mouse_stick = false
		mouse_pitch = 0.0
		mouse_roll = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if report_dialog == null:
		report_dialog = FileDialog.new()
		report_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		report_dialog.access = FileDialog.ACCESS_FILESYSTEM
		report_dialog.use_native_dialog = true
		report_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		report_dialog.title = "Выберите папку для отчёта"
		report_dialog.ok_button_text = "Выбрать папку"
		report_dialog.dir_selected.connect(_write_report)
		report_dialog.canceled.connect(_report_closed)
		add_child(report_dialog)
	report_dialog.popup_centered_ratio(0.72)
	return


func _write_report(folder: String) -> void:
	if craft != null and sample_lines.is_empty():
		_take_sample()
	var html_path := folder.path_join("графики_полёта.html")
	var events_path := folder.path_join("журнал_событий.txt")
	var failed := PackedStringArray()
	var events_file := FileAccess.open(events_path, FileAccess.WRITE)
	if events_file == null:
		failed.append("журнал событий")
	else:
		for event_line in log_lines:
			if event_line.strip_edges() != "":
				events_file.store_line(event_line)
		if events_file.get_error() != OK:
			failed.append("журнал событий")
		events_file.close()
	var html_file := FileAccess.open(html_path, FileAccess.WRITE)
	if html_file == null:
		failed.append("графики")
	else:
		html_file.store_string(_report_html())
		if html_file.get_error() != OK:
			failed.append("графики")
		html_file.close()
	status_flash = "Графики и журнал сохранены: " + folder if failed.is_empty() else "Не удалось сохранить: " + ", ".join(failed)
	status_flash_time = 8.0
	_report_closed()


func _report_closed() -> void:
	# Выбор папки и отмена не возобновляют полёт без команды пользователя.
	if flying and paused:
		pause_panel.show()


func _chart_svg(title: String, column: int, unit: String, color: String) -> String:
	var values: Array[float] = []
	var times: Array[float] = []
	for row in sample_lines:
		var fields := row.split(";")
		if column < fields.size():
			values.append(float(fields[column]))
			times.append(float(fields[0]))
	if values.is_empty():
		return "<section><h2>" + title + "</h2><p>Нет данных</p></section>"
	var low := values[0]
	var high := values[0]
	for value in values:
		low = minf(low, value)
		high = maxf(high, value)
	# Постоянный параметр тоже имеет читаемую шкалу.
	var padding := maxf((high - low) * 0.08, 1.0)
	low -= padding
	high += padding
	var span := high - low
	var start := times[0]
	var finish := maxf(times[-1], start + 1.0)
	var points := PackedStringArray()
	for i in values.size():
		var x := 85.0 + 650.0 * (times[i] - start) / (finish - start)
		var y := 235.0 - 190.0 * (values[i] - low) / span
		points.append("%.1f,%.1f" % [x, y])
	var svg := "<section><h2>%s</h2><svg viewBox='0 0 780 300' role='img' aria-label='%s'>" % [title, title]
	svg += "<text x='85' y='22'>%s (%s)</text>" % [title, unit]
	for i in range(6):
		var y := 235.0 - 190.0 * float(i) / 5.0
		var value := low + span * float(i) / 5.0
		svg += "<line x1='85' y1='%.1f' x2='735' y2='%.1f' stroke='#dce3ea'/><text x='75' y='%.1f' text-anchor='end'>%.2f</text>" % [y, y, y + 4.0, value]
		var x := 85.0 + 650.0 * float(i) / 5.0
		var seconds := start + (finish - start) * float(i) / 5.0
		svg += "<line x1='%.1f' y1='45' x2='%.1f' y2='235' stroke='#dce3ea'/><text x='%.1f' y='256' text-anchor='middle'>%.1f</text>" % [x, x, x, seconds]
	svg += "<text x='410' y='283' text-anchor='middle'>Время полёта (с)</text>"
	svg += "<polyline fill='none' stroke='%s' stroke-width='2.5' points='%s'/>" % [color, " ".join(points)]
	if values.size() == 1:
		svg += "<circle cx='85' cy='140' r='4' fill='%s'/>" % color
	return svg + "</svg></section>"


func _report_html() -> String:
	var html := "<!doctype html><html lang='ru'><head><meta charset='utf-8'><title>Графики полёта</title>"
	html += "<style>body{font-family:Arial,sans-serif;background:#f3f5f7;color:#18222d;max-width:860px;margin:24px auto;padding:0 20px}h1{font-size:28px}section{background:white;border:1px solid #cbd5df;border-radius:10px;padding:12px 18px;margin:16px 0}h2{font-size:19px;margin:4px 0 8px}svg{width:100%;height:auto;background:#f8fafb}text{font-size:12px;fill:#526170}</style></head><body>"
	html += "<h1>Графики полёта БПЛА</h1><p>Данные симуляции. Время по горизонтали, значения и единицы указаны на каждом графике.</p>"
	html += _chart_svg("Высота", 1, "м", "#2672c8")
	html += _chart_svg("Скорость", 2, "м/с", "#d77a19")
	html += _chart_svg("Углы ориентации: крен", 3, "°", "#8e44ad")
	html += _chart_svg("Углы ориентации: тангаж", 4, "°", "#16a085")
	html += _chart_svg("Курс", 5, "°", "#c0392b")
	html += _chart_svg("Заряд батареи", 6, "%", "#2e8b57")
	html += _chart_svg("Температура моторов", 7, "°C", "#b03a2e")
	html += _chart_svg("Сигнал связи", 8, "%", "#1f618d")
	html += "</body></html>"
	return html


func _show_menu() -> void:
	menu_panel.visible = true
	flight_panel.visible = false
	if pause_panel != null:
		pause_panel.hide()


func _toggle_pause() -> void:
	if not flying:
		return
	if conditions_panel != null and conditions_panel.visible:
		conditions_panel.hide()
		pause_panel.visible = paused
		return
	paused = not paused
	pause_panel.visible = paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _cycle_camera() -> void:
	if not flying:
		return
	camera_mode = (camera_mode + 1) % 4


func _build_pause_panel(layer: CanvasLayer) -> void:
	pause_panel = _panel(Vector2(0, 0), Vector2(380, 250))
	pause_panel.theme = UiTheme.get_theme()
	pause_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	pause_panel.offset_left = -190
	pause_panel.offset_top = -140
	pause_panel.offset_right = 190
	pause_panel.offset_bottom = 140
	pause_panel.hide()
	layer.add_child(pause_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pause_panel.add_child(box)
	box.add_child(_title("Пауза"))
	box.add_child(_hint("Управление дроном приостановлено. ESC возвращает к полёту."))
	var resume := Button.new()
	resume.text = "Продолжить"
	resume.pressed.connect(_toggle_pause)
	box.add_child(resume)
	var settings := Button.new()
	settings.text = "Настройки полёта"
	settings.pressed.connect(func() -> void:
		conditions_panel.visible = true
		pause_panel.hide()
	)
	box.add_child(settings)
	var restart := Button.new()
	restart.text = "Перезапустить"
	restart.pressed.connect(_start_flight)
	box.add_child(restart)
	var finish := Button.new()
	finish.text = "Завершить полёт"
	finish.pressed.connect(_back_to_menu)
	box.add_child(finish)


func _ui_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 15
	theme.set_color("font_color", "Label", Color(0.88, 0.92, 0.96))
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", Color(0.85, 0.95, 1.0))
	theme.set_color("font_color", "Button", Color(0.76, 0.82, 0.88))
	theme.set_font_size("font_size", "Button", 14)
	var button := StyleBoxFlat.new()
	button.bg_color = Color(0.08, 0.12, 0.16, 0.94)
	button.border_color = Color(0.25, 0.55, 0.68, 0.65)
	button.set_border_width_all(1)
	button.set_corner_radius_all(5)
	button.content_margin_left = 12
	button.content_margin_right = 12
	button.content_margin_top = 7
	button.content_margin_bottom = 7
	theme.set_stylebox("normal", "Button", button)
	var hover := button.duplicate()
	hover.bg_color = Color(0.12, 0.22, 0.28, 0.98)
	theme.set_stylebox("hover", "Button", hover)
	return theme


func _terrain_picker() -> OptionButton:
	var picker := OptionButton.new()
	picker.focus_mode = Control.FOCUS_NONE
	picker.add_item("1 · Вертолётная площадка в городе", TERRAIN_POLYGON)
	picker.add_item("3 · Вход на полигон", TERRAIN_COURSE)
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
	precip_pickers.append(picker)
	picker.item_selected.connect(func(index: int) -> void:
		precip = index
		for other in precip_pickers:
			other.select(index)
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
	terrain_hint.text = "Остров: город и площадка в центре, полигон на западе, озеро на северо-западе, холмы АБДО на юго-востоке. Две точки старта отмечены на плане. C — камеры, включая вид острова сверху."


func _make_precip(amount: int, life: float, speed_min: float, speed_max: float, drop_size: Vector2, color: Color, gravity: Vector3) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = life
	particles.preprocess = minf(life, 3.0)
	particles.emitting = false
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(18, 0.4, 18)
	process.direction = Vector3(0.15, -1, 0.1)
	process.spread = 8.0
	process.gravity = gravity
	process.initial_velocity_min = speed_min
	process.initial_velocity_max = speed_max
	particles.process_material = process
	var drop := QuadMesh.new()
	drop.size = drop_size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop.material = material
	particles.draw_pass_1 = drop
	particles.visibility_aabb = AABB(Vector3(-24, -20, -24), Vector3(48, 40, 48))
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
		var material := particles.process_material as ParticleProcessMaterial
		var fall_speed := 2.2 if particles == snow else (19.0 if particles == hail else 11.0)
		var flow := _wind_vector() + gust + Vector3(0, -fall_speed, 0)
		material.direction = flow.normalized()
		material.initial_velocity_min = flow.length() * 0.9
		material.initial_velocity_max = flow.length() * 1.1
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
		if craft != null and craft.airborne and (craft.position.y - craft.surface_y) < 8.0 and field.in_grove(craft.position):
			amp += 1.5
		amp = minf(amp, 2.5)
		var dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
		if dir.length() < 0.05:
			dir = Vector3(1, 0, 0)
		gust_target = dir.normalized() * amp
	gust = gust.move_toward(gust_target, 3.5 * delta)


func _start_spot() -> Vector3:
	return field.spawn_point(terrain)


func _terrain_name() -> String:
	return "полигон острова" if terrain == TERRAIN_COURSE else "вертолётная площадка в городе"


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


func _toggle_button(text: String, tip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(72, 22)
	button.add_theme_font_size_override("font_size", 13)
	return button


func _toggle_sensors() -> void:
	show_sensors = not show_sensors
	_paint_toggles()


func _toggle_aero() -> void:
	show_aero = not show_aero
	_paint_toggles()


func _toggle_wind() -> void:
	show_wind = not show_wind
	_paint_toggles()


func _toggle_thrust() -> void:
	show_thrust = not show_thrust
	_paint_toggles()


func _toggle_drag() -> void:
	show_drag = not show_drag
	_paint_toggles()

func _toggle_autopilot() -> void:
	if craft == null:
		return
	craft.set_autopilot(not craft.autopilot_on)
	_update_hud()
	_paint_toggles()

func _toggle_trace() -> void:
	show_trace = not show_trace
	if trace != null:
		trace.visible = show_trace and flying
	_paint_toggles()

func _toggle_flow() -> void:
	show_flow = not show_flow
	_paint_toggles()

func _toggle_lights() -> void:
	lights_on = not lights_on
	if craft != null:
		craft.navigation_lights.visible = lights_on and day_night.daylight < 0.5
	_paint_toggles()

func _time_controls() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var title := Label.new()
	title.text = "Время суток"
	box.add_child(title)
	var row := HBoxContainer.new()
	var caption := Label.new()
	caption.text = "Часы"
	row.add_child(caption)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 24.0
	slider.step = 0.25
	slider.value = day_night.hour if day_night != null else 12.0
	slider.custom_minimum_size = Vector2(150, 16)
	slider.value_changed.connect(func(value: float) -> void: day_night.hour = value)
	hour_sliders.append(slider)
	row.add_child(slider)
	var clock := Label.new()
	clock.custom_minimum_size = Vector2(55, 0)
	clock.text = day_night.clock_text() if day_night != null else "12:00"
	clock_labels.append(clock)
	row.add_child(clock)
	box.add_child(row)
	var cycle := CheckButton.new()
	cycle.text = "Цикл день / ночь"
	cycle.button_pressed = day_night.cycling if day_night != null else false
	cycle.toggled.connect(func(on: bool) -> void: day_night.cycling = on)
	cycle_buttons.append(cycle)
	box.add_child(cycle)
	var quick := HBoxContainer.new()
	for pair in [["День", 12.0], ["Закат", 19.0], ["Ночь", 0.0]]:
		var button := Button.new()
		button.text = pair[0]
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(func() -> void: day_night.hour = pair[1])
		quick.add_child(button)
	box.add_child(quick)
	return box


func _toggle_forces() -> void:
	var enable := not (show_aero and show_wind and show_thrust and show_drag)
	show_aero = enable
	show_wind = enable
	show_thrust = enable
	show_drag = enable
	_paint_toggles()


func _paint_toggles() -> void:
	if sensor_button != null:
		sensor_button.modulate = Color(0.65, 1.0, 0.72) if show_sensors else Color(0.72, 0.74, 0.76)
	if aero_button != null:
		aero_button.modulate = Color(0.95, 0.84, 0.45) if show_aero else Color(0.72, 0.74, 0.76)
	if wind_button != null:
		wind_button.modulate = Color(0.55, 0.78, 1.0) if show_wind else Color(0.72, 0.74, 0.76)
	if thrust_button != null:
		thrust_button.modulate = Color(0.55, 0.9, 0.55) if show_thrust else Color(0.72, 0.74, 0.76)
	if drag_button != null:
		drag_button.modulate = Color(1.0, 0.55, 0.5) if show_drag else Color(0.72, 0.74, 0.76)
	if autopilot_button != null:
		autopilot_button.modulate = Color(0.3, 1.0, 0.4) if craft != null and craft.autopilot_on else Color(0.72, 0.74, 0.76)
	if trace_button != null:
		trace_button.modulate = Color(1.0, 0.65, 0.2) if show_trace else Color(0.72, 0.74, 0.76)
	if flow_button != null:
		flow_button.modulate = Color(0.35, 0.75, 1.0) if show_flow else Color(0.72, 0.74, 0.76)
	if lights_button != null:
		lights_button.modulate = Color(1.0, 0.85, 0.35) if lights_on else Color(0.72, 0.74, 0.76)


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



