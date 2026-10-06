extends Node3D

const FlightModel = preload("res://scripts/flight_model.gd")
const VehicleVisual = preload("res://scripts/vehicle_visual.gd")
const CanopyDrag = preload("res://scripts/canopy_drag.gd")

## Упрощённый квадрокоптер на этом шаге.
## Четыре мотора свёрнуты в одну тягу и наклон корпуса. Этого хватает, чтобы
## сравнить аппараты в ветре. Отдельные обороты моторов будут следующим шагом.
## Числа приходят из файла аппарата через FlightModel, здесь их нет.

var profile: Dictionary = {}
var model: Dictionary = {}
var velocity := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
var roll := 0.0
var pitch_rate := 0.0
var roll_rate := 0.0
var yaw_rate := 0.0
var throttle := 0.0
var stick_pitch := 0.0
var stick_roll := 0.0
var stick_yaw := 0.0
var climb_command := 0.0
var target_altitude := 0.2
var altitude_hold := false
var wind := Vector3.ZERO
var air_density := 1.225
var air_temp := 15.0
var precip := 0
var canopy := 0.0
var canopy_gust := Vector3.ZERO
var water_surface := 0.0
var surface_y := 0.0
var surface_kind := 0
var slope_accel := Vector3.ZERO
var battery := 1.0
var motor_temp := 15.0
# Нельзя назвать signal: в Godot это служебное слово, скрипт из-за него не читается.
var radio := 100.0
var sensor_roll := 0.0
var sensor_pitch := 0.0
var sensor_yaw_deg := 0.0
var sensor_battery := 100.0
var sensor_motor_temp := 15.0
var sensor_signal := 100.0
var motors_on := false
var ditched := false
var warning := ""
var airborne := false
var _hail_wait := 0.7
var thrust_force := Vector3.ZERO
var drag_force := Vector3.ZERO
var weight_force := Vector3.ZERO

var _props: Array[Node3D] = []
var visual: VehicleVisual
var ground_clearance := 0.04
var collision_radius := 0.09
var _rng := RandomNumberGenerator.new()
var autopilot_on := false
var autopilot_position := Vector3.ZERO
var autopilot_heading := 0.0
var navigation_lights: Node3D

func set_autopilot(on: bool) -> bool:
	if on and (not motors_on or ditched or battery <= 0.02):
		return false
	autopilot_on = on
	if on:
		autopilot_position = position
		autopilot_heading = yaw
		target_altitude = position.y
		altitude_hold = true
	return true


func setup(next_profile: Dictionary) -> void:
	profile = next_profile
	model = profile.get("_model", {})
	_clear_mesh()
	visual = VehicleVisual.new()
	add_child(visual)
	visual.setup(profile)
	ground_clearance = maxf(float(model.get("height", 0.1)) * 0.5, 0.02)
	collision_radius = maxf(float(model.get("width", 0.18)) * 0.5, 0.04)
	if visual.loaded:
		ground_clearance = maxf(visual.bounds.size.y * 0.5, 0.02)
		collision_radius = maxf(visual.bounds.size.x, visual.bounds.size.z) * 0.5
	else:
		_build_mesh()
	_rng.seed = 20261005
	stick_pitch = 0.0
	stick_roll = 0.0
	stick_yaw = 0.0
	motor_temp = air_temp
	position = Vector3(0.0, ground_clearance + 0.04, 0.0)
	velocity = Vector3.ZERO
	yaw = 0.0
	pitch = 0.0
	roll = 0.0
	pitch_rate = 0.0
	roll_rate = 0.0
	yaw_rate = 0.0
	throttle = 0.0
	climb_command = 0.0
	target_altitude = position.y
	altitude_hold = false
	motors_on = false
	ditched = false
	airborne = false
	battery = 1.0
	radio = 100.0
	_hail_wait = 0.7
	warning = ""
	rotation = Vector3.ZERO
	autopilot_on = false
	_build_lights()


func step(delta: float) -> void:
	warning = ""
	var mass := maxf(float(model.get("mass", 0.1)), 0.05)
	var vmax := float(model.get("vmax", 0.0))
	var density_scale := air_density / FlightModel.RHO
	var max_thrust := float(model.get("max_thrust", mass * FlightModel.G * 2.0)) * density_scale
	var drag_k := float(model.get("drag_k", 0.01)) * density_scale
	# 0 ясно, 1 дождь, 2 снег, 3 град. Числа — допущения из FlightModel, не из паспорта.
	if precip == 1:
		drag_k *= FlightModel.RAIN_DRAG
	elif precip == 2:
		drag_k *= FlightModel.SNOW_DRAG
		max_thrust *= FlightModel.SNOW_THRUST
	elif precip == 3:
		drag_k *= FlightModel.HAIL_DRAG
	# Крона — допущение, не паспорт. Листва не стена: она сильно растит сопротивление.
	drag_k *= CanopyDrag.drag_scale(canopy)
	var max_tilt := deg_to_rad(FlightModel.CRUISE_TILT_DEG)
	var stick := Vector2(stick_pitch, stick_roll).limit_length(1.0)
	# W/S уже совпадали с картинкой. A/D и Q/E в Godot на виде сзади получались зеркальными:
	# положительный крен уезжал вправо при нажатии A, положительное рыскание крутило влево при E.
	var target_pitch := -stick.x * max_tilt
	var target_roll := -stick.y * max_tilt
	var target_yaw_rate := -stick_yaw * 1.1
	if autopilot_on and motors_on:
		var heading_basis := Basis(Vector3.UP, yaw)
		autopilot_position += heading_basis * Vector3(stick.y, 0, -stick.x) * 3.0 * delta
		autopilot_heading -= stick_yaw * 1.1 * delta
		var error := autopilot_position - position
		error.y = 0.0
		var relative_air := velocity - wind
		var predicted_drag := -drag_k * relative_air.length() * relative_air
		var requested := error * 0.9 - Vector3(velocity.x, 0, velocity.z) * 1.8 - Vector3(predicted_drag.x, 0, predicted_drag.z) / mass
		requested = requested.limit_length(FlightModel.G * tan(max_tilt))
		var local := heading_basis.inverse() * requested
		var angles := Vector2(atan2(local.z, FlightModel.G), -atan2(local.x, FlightModel.G)).limit_length(max_tilt)
		target_pitch = angles.x
		target_roll = angles.y
		target_yaw_rate = clampf(wrapf(autopilot_heading - yaw, -PI, PI) * 2.5, -1.1, 1.1)
	pitch = move_toward(pitch, target_pitch, deg_to_rad(100.0) * delta)
	roll = move_toward(roll, target_roll, deg_to_rad(100.0) * delta)
	yaw_rate = move_toward(yaw_rate, target_yaw_rate, 4.0 * delta)
	yaw += yaw_rate * delta
	rotation = Vector3(pitch, yaw, roll)

	var clearance := ground_clearance
	var floor_y := surface_y + clearance
	if ditched or battery <= 0.02:
		climb_command = 0.0
		motors_on = false
		altitude_hold = false
	if climb_command > 0.05:
		motors_on = true
		altitude_hold = true
		target_altitude += climb_command * delta
	elif climb_command < -0.05 and motors_on:
		target_altitude += climb_command * delta
	elif not airborne:
		target_altitude = position.y

	var thrust := 0.0
	if motors_on and altitude_hold:
		# Удержание высоты само добавляет тягу, когда аппарат наклонён против ветра.
		# Иначе наклон «съедает» вертикальную тягу, и пилот вынужден дёргать газ.
		var desired_vy := clampf((target_altitude - position.y) * 1.3, -1.8, 2.0)
		if absf(climb_command) > 0.05:
			desired_vy = climb_command
		var vertical_share := maxf(global_transform.basis.y.y, 0.4)
		var accel := clampf((desired_vy - velocity.y) * 2.8, -6.0, 6.0)
		thrust = clampf(mass * (FlightModel.G + accel) / vertical_share, 0.0, max_thrust)
		throttle = thrust / max_thrust
	else:
		throttle = 0.0

	if surface_kind == 0 and position.y <= floor_y + 0.02 and climb_command <= 0.0 and target_altitude <= floor_y + 0.25 and velocity.y <= 0.05:
		motors_on = false
		altitude_hold = false
		thrust = 0.0
		throttle = 0.0
		target_altitude = position.y
	_drain_battery(delta, mass)
	if not motors_on:
		thrust = 0.0

	var up := global_transform.basis.y
	thrust_force = up * thrust
	weight_force = Vector3(0.0, -mass * FlightModel.G, 0.0)
	var air := velocity - wind
	# Stable quadratic drag: exact dissipation over this substep, no reversal in gusts.
	var free_velocity := velocity + (thrust_force + weight_force) / mass * delta
	var relative := free_velocity - wind
	var damped := relative / (1.0 + drag_k * relative.length() * delta / mass)
	drag_force = (damped - relative) * mass / maxf(delta, 0.000001)
	velocity = wind + damped
	if precip == 3 and airborne and not ditched:
		_hail_wait -= delta
		if _hail_wait <= 0.0:
			# Короткий удар, не постоянная сила. Поэтому град не равен дождю.
			_hail_wait = _rng.randf_range(0.55, 1.2)
			velocity += Vector3(_rng.randf_range(-0.012, 0.012), -0.018, _rng.randf_range(-0.012, 0.012)) / mass
	if velocity.length() > 40.0:
		velocity = velocity.limit_length(40.0)
	position += velocity * delta

	if surface_kind == 1 and position.y <= water_surface + clearance + 0.02:
		ditched = true
		motors_on = false
		altitude_hold = false
		throttle = 0.0
		velocity = Vector3.ZERO
		position.y = water_surface + clearance
		airborne = false
		warning = "Касание воды: моторы выключены. Выберите сушу и начните полёт заново."
	elif position.y <= floor_y:
		position.y = floor_y
		if velocity.y < 0.0:
			velocity.y = 0.0
		var grip := exp(-0.9 * delta) if slope_accel.length() > 0.01 else exp(-5.0 * delta)
		velocity.x *= grip
		velocity.z *= grip
		if not motors_on:
			velocity += slope_accel * delta
			# Static friction holds a parked craft when aerodynamic load is small.
			var lateral := Vector2(drag_force.x, drag_force.z).length()
			if slope_accel.length() < 0.01 and lateral < mass * FlightModel.G * 0.8:
				velocity.x = 0.0
				velocity.z = 0.0
		airborne = false
	elif position.y > floor_y + 0.35:
		airborne = true

	visual.spin(delta, throttle)
	var spin := throttle * 25.0 * delta
	for prop in _props:
		prop.rotate_y(spin)
	_update_sensors(delta, air.length())
	_update_warning(vmax, air.length())
	if not motors_on:
		autopilot_on = false
		pitch = move_toward(pitch, 0.0, delta * 1.5)
		roll = move_toward(roll, 0.0, delta * 1.5)
		rotation = Vector3(pitch, yaw, roll)

func _build_lights() -> void:
	navigation_lights = Node3D.new()
	add_child(navigation_lights)
	for side in [-1.0, 1.0]:
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(side * collision_radius * 0.65, 0.05, 0)
		lamp.light_color = Color(1, 0.08, 0.03) if side < 0 else Color(0.05, 1, 0.18)
		lamp.light_energy = 0.35
		lamp.omni_range = 1.5
		navigation_lights.add_child(lamp)
	var headlight := SpotLight3D.new()
	headlight.position = Vector3(0, 0, -collision_radius)
	headlight.rotation.x = deg_to_rad(-18.0)
	headlight.light_energy = 4.0
	headlight.spot_range = 28.0
	headlight.spot_angle = 38.0
	headlight.shadow_enabled = true
	navigation_lights.add_child(headlight)
	navigation_lights.visible = false


func forward() -> Vector3:
	# В Godot объект «смотрит» в свою локальную −Z.
	return -global_transform.basis.z


func height_above_surface() -> float:
	var ground := water_surface if surface_kind == 1 else surface_y
	return maxf(position.y - ground - ground_clearance, 0.0)


func _drain_battery(delta: float, _mass: float) -> void:
	if not motors_on:
		return
	# Паспорт даёт время полёта, но не ток. Допущение: на висении батарея садится за это время.
	var flight_time := maxf(FlightModel.read_number(profile.get("flight_time_s"), 600.0), 30.0)
	var hover := maxf(float(model.get("hover_throttle", 0.5)), 0.2)
	var cold_factor := 1.0 + clampf((15.0 - air_temp) * 0.012, 0.0, 0.4)
	var draw := pow(maxf(throttle, 0.08) / hover, 1.5) * cold_factor
	battery = maxf(battery - draw * delta / flight_time, 0.0)
	if battery <= 0.02:
		motors_on = false
		altitude_hold = false
		throttle = 0.0
		warning = "Батарея села. Моторы выключены."


func _update_sensors(delta: float, airspeed: float) -> void:
	# На экран идут не идеальные числа, а датчики с небольшим шумом.
	var cool := 0.35 + airspeed * 0.04
	var target_temp := air_temp + 45.0 * throttle
	motor_temp += (target_temp - motor_temp) * clampf(cool * delta, 0.0, 0.25)
	var dist := Vector2(position.x, position.z).length()
	# Поле стало просторнее, поэтому сигнал падает медленнее. На краю дорожки он ещё заметен.
	radio = clampf(100.0 - dist * 0.16, 8.0, 100.0)
	sensor_roll = rad_to_deg(roll) + randf_range(-0.4, 0.4)
	sensor_pitch = rad_to_deg(pitch) + randf_range(-0.4, 0.4)
	sensor_yaw_deg = fposmod(_compass_deg() + randf_range(-0.6, 0.6), 360.0)
	sensor_battery = clampf(battery * 100.0 + randf_range(-0.3, 0.3), 0.0, 100.0)
	sensor_motor_temp = motor_temp + randf_range(-0.4, 0.4)
	sensor_signal = clampf(radio + randf_range(-1.2, 1.2), 0.0, 100.0)


func _compass_deg() -> float:
	var east := forward().x
	var north := -forward().z
	return fposmod(rad_to_deg(atan2(east, north)), 360.0)


func _update_warning(vmax: float, airspeed: float) -> void:
	if ditched:
		warning = "Касание воды: моторы выключены. Выберите сушу и начните полёт заново."
		return
	if battery <= 0.02:
		warning = "Батарея села. Моторы выключены."
		return
	if warning != "":
		return
	var wind_speed := wind.length()
	if wind_speed > 0.5 and vmax > 0.1 and wind_speed > vmax:
		warning = "Ветер сильнее максимальной воздушной скорости: удержать точку невозможно. Выберите безопасную площадку для посадки."
		return
	var passport_wind := float(model.get("wind_limit", -1.0))
	if passport_wind > 0.0 and wind_speed > passport_wind:
		warning = "Ветер выше паспортного предела %.0f м/с. Вернитесь на посадку." % passport_wind
		return
	var tilt_deg := rad_to_deg(Vector2(pitch, roll).length())
	if wind_speed > 4.0 and tilt_deg > 28.0 and airspeed > maxf(vmax * 0.75, 4.0):
		warning = "Потеря устойчивости: уменьшите крен и тангаж, не добавляйте газ рывком."
		return
	if wind_speed > 3.0 and airborne and stick_pitch * stick_pitch + stick_roll * stick_roll < 0.08:
		var downwind := velocity.dot(wind.normalized())
		if downwind > 3.0:
			warning = "Сносит ветром. Разверните нос против ветра и слегка наклонитесь вперёд."
			return
	var limits: Variant = profile.get("operating_temperature_c", {})
	if typeof(limits) == TYPE_DICTIONARY:
		var tmin := float(limits.get("min", -40.0))
		var tmax := float(limits.get("max", 60.0))
		if air_temp < tmin or air_temp > tmax:
			warning = "Температура воздуха вне паспорта этого аппарата."
			return
	if battery < 0.15:
		warning = "Батарея ниже 15%. Садитесь."
		return
	if radio < 25.0:
		warning = "Слабый сигнал. Вернитесь ближе к точке старта."
		return
	if not motors_on and not airborne and slope_accel.length() > 0.01 and Vector2(velocity.x, velocity.z).length() > 0.25:
		warning = "На склоне аппарат сползает вниз. Для взлёта удерживайте Shift."


func _clear_mesh() -> void:
	_props.clear()
	while get_child_count() > 0:
		var child := get_child(0)
		remove_child(child)
		child.free()


func _build_mesh() -> void:
	var width := maxf(float(model.get("width", 0.3)), 0.12)
	var height := maxf(float(model.get("height", 0.08)), 0.04)
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width * 0.42, height * 0.65, width * 0.42)
	body.mesh = box
	body.material_override = _paint(_body_color())
	add_child(body)
	var reach := width * 0.46
	for axis in [Vector3(1, 0, 0), Vector3(0, 0, 1)]:
		var arm := MeshInstance3D.new()
		var arm_mesh := BoxMesh.new()
		arm_mesh.size = Vector3(0.025, 0.015, reach * 2.0) if axis.z > 0.5 else Vector3(reach * 2.0, 0.015, 0.025)
		arm.mesh = arm_mesh
		arm.position.y = height * 0.05
		arm.material_override = _paint(Color(0.22, 0.24, 0.27))
		add_child(arm)
	for corner in [Vector3(1, 0, 1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(-1, 0, -1)]:
		var motor := MeshInstance3D.new()
		var motor_mesh := CylinderMesh.new()
		motor_mesh.top_radius = 0.028
		motor_mesh.bottom_radius = 0.028
		motor_mesh.height = 0.03
		motor.mesh = motor_mesh
		motor.position = Vector3(corner.x, height * 0.15, corner.z) * reach * 0.72
		motor.material_override = _paint(Color(0.12, 0.12, 0.13))
		add_child(motor)
		var prop := MeshInstance3D.new()
		var prop_mesh := CylinderMesh.new()
		var radius := maxf(width * 0.16, 0.035)
		prop_mesh.top_radius = radius
		prop_mesh.bottom_radius = radius
		prop_mesh.height = 0.006
		prop.mesh = prop_mesh
		prop.position = motor.position + Vector3(0, 0.03, 0)
		prop.material_override = _paint(Color(0.8, 0.82, 0.85, 0.8))
		add_child(prop)
		_props.append(prop)


func _body_color() -> Color:
	var id := str(profile.get("id", ""))
	if id.find("mini") >= 0:
		return Color(0.95, 0.78, 0.2)
	if id.find("fpv") >= 0:
		return Color(0.9, 0.45, 0.15)
	return Color(0.82, 0.84, 0.86)


func _paint(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.62
	return material
