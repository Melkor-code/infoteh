class_name Quadrotor
extends Node3D

const FlightModel = preload("res://scripts/flight_model.gd")

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
var rain := false
var motors_on := false
var warning := ""
var airborne := false
var thrust_force := Vector3.ZERO
var drag_force := Vector3.ZERO
var weight_force := Vector3.ZERO

var _props: Array[Node3D] = []


func setup(next_profile: Dictionary) -> void:
	profile = next_profile
	model = profile.get("_model", {})
	_clear_mesh()
	_build_mesh()
	var height := maxf(float(model.get("height", 0.1)), 0.05)
	position = Vector3(0.0, height * 0.5 + 0.04, 0.0)
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
	airborne = false
	warning = ""
	rotation = Vector3.ZERO


func step(delta: float) -> void:
	warning = ""
	var mass := maxf(float(model.get("mass", 0.1)), 0.05)
	var vmax := float(model.get("vmax", 0.0))
	var max_thrust := float(model.get("max_thrust", mass * FlightModel.G * 2.0))
	var drag_k := float(model.get("drag_k", 0.01))
	if rain:
		# Дождь в паспорте не расписан. Общее допущение: сопротивление на 15% больше.
		drag_k *= 1.15
	var max_tilt := deg_to_rad(32.0)
	# W/S уже совпадали с картинкой. A/D и Q/E в Godot на виде сзади получались зеркальными:
	# положительный крен уезжал вправо при нажатии A, положительное рыскание крутило влево при E.
	var target_pitch := -stick_pitch * max_tilt
	var target_roll := -stick_roll * max_tilt
	var target_yaw_rate := -stick_yaw * 1.1
	pitch = move_toward(pitch, target_pitch, deg_to_rad(100.0) * delta)
	roll = move_toward(roll, target_roll, deg_to_rad(100.0) * delta)
	yaw_rate = move_toward(yaw_rate, target_yaw_rate, 4.0 * delta)
	yaw += yaw_rate * delta
	rotation = Vector3(pitch, yaw, roll)

	var clearance := maxf(float(model.get("height", 0.1)) * 0.5, 0.04)
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

	if position.y <= clearance + 0.02 and climb_command <= 0.0 and target_altitude <= clearance + 0.25 and velocity.y <= 0.05:
		motors_on = false
		altitude_hold = false
		thrust = 0.0
		throttle = 0.0
		target_altitude = position.y

	var up := global_transform.basis.y
	thrust_force = up * thrust
	weight_force = Vector3(0.0, -mass * FlightModel.G, 0.0)
	var air := velocity - wind
	drag_force = -drag_k * air.length() * air
	var force := thrust_force + weight_force + drag_force
	velocity += force / mass * delta
	if velocity.length() > 40.0:
		velocity = velocity.limit_length(40.0)
	position += velocity * delta

	if position.y <= clearance:
		position.y = clearance
		if velocity.y < 0.0:
			velocity.y = 0.0
		velocity.x *= 0.92
		velocity.z *= 0.92
		airborne = false
	elif position.y > clearance + 0.35:
		airborne = true

	var spin := throttle * 25.0 * delta
	for prop in _props:
		prop.rotate_y(spin)
	_update_warning(vmax, air.length())


func forward() -> Vector3:
	# В Godot объект «смотрит» в свою локальную −Z.
	return -global_transform.basis.z


func _update_warning(vmax: float, airspeed: float) -> void:
	var wind_speed := wind.length()
	if wind_speed > 0.5 and vmax > 0.1 and wind_speed > vmax:
		warning = "Потеря устойчивости: ветер сильнее паспортной скорости. Снизьте высоту и садитесь по ветру."
		return
	var tilt_deg := rad_to_deg(Vector2(pitch, roll).length())
	if wind_speed > 4.0 and tilt_deg > 28.0 and airspeed > maxf(vmax * 0.75, 4.0):
		warning = "Потеря устойчивости: уменьшите крен и тангаж, не добавляйте газ рывком."
		return
	if wind_speed > 3.0 and airborne and stick_pitch * stick_pitch + stick_roll * stick_roll < 0.08:
		var downwind := velocity.dot(wind.normalized())
		if downwind > 3.0:
			warning = "Сносит ветром. Разверните нос против ветра и слегка наклонитесь вперёд."


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
