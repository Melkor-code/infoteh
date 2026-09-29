extends Node3D

const FlightModel = preload("res://scripts/flight_model.gd")

## Конус камеры и стрелки скорости и ветра. На расчёт полёта не влияют.
## По умолчанию скрыты: раньше сплошной конус закрывал аппарат.

var sensors_on := false
var aero_on := false
var wind_on := false
var thrust_on := false
var drag_on := false

var _cone: Node3D
var _speed: Node3D
var _wind: Node3D
var _thrust: Node3D
var _drag: Node3D


func setup() -> void:
	var body := get_parent() as Node3D
	if body == null:
		return
	var profile: Dictionary = body.get("profile")
	var model: Dictionary = body.get("model")
	var fov := FlightModel.read_number(profile.get("camera_fov_deg"), 70.0)
	fov = clampf(fov, 24.0, 140.0)
	var width := maxf(float(model.get("width", 0.3)), 0.12)
	var height := maxf(float(model.get("height", 0.08)), 0.04)
	_cone = _build_cone(fov)
	# Объектив впереди корпуса. В Godot нос смотрит в локальный минус Z.
	_cone.position = Vector3(0.0, -height * 0.15, -width * 0.3)
	add_child(_cone)
	_speed = _make_arrow(Color(0.95, 0.78, 0.38, 0.62))
	_speed.position = Vector3(0.0, 0.14, 0.0)
	add_child(_speed)
	_wind = _make_arrow(Color(0.4, 0.74, 0.98, 0.62))
	_wind.position = Vector3(0.0, 0.08, 0.0)
	add_child(_wind)
	_thrust = _make_arrow(Color(0.35, 0.9, 0.42, 0.6))
	_thrust.position = Vector3(0.0, 0.05, 0.0)
	add_child(_thrust)
	_drag = _make_arrow(Color(0.92, 0.32, 0.28, 0.6))
	_drag.position = Vector3(0.0, 0.02, 0.0)
	add_child(_drag)


func _process(_delta: float) -> void:
	if _cone != null:
		_cone.visible = sensors_on
	var body := get_parent() as Node3D
	if body == null:
		return
	var model: Dictionary = body.get("model")
	var mass := maxf(float(model.get("mass", 0.2)), 0.05)
	var weight := mass * 9.81
	if _speed != null:
		if aero_on:
			_aim(_speed, body.get("velocity"), 0.22, 2.6)
		else:
			_speed.visible = false
	if _wind != null:
		if wind_on:
			_aim(_wind, body.get("wind"), 0.22, 2.4)
		else:
			_wind.visible = false
	if _thrust != null:
		if thrust_on:
			_aim(_thrust, body.get("thrust_force"), 1.2 / weight, 2.2)
		else:
			_thrust.visible = false
	if _drag != null:
		if drag_on:
			_aim(_drag, body.get("drag_force"), 2.4 / weight, 2.2)
		else:
			_drag.visible = false


func _build_cone(fov_deg: float) -> Node3D:
	var root := Node3D.new()
	var half := deg_to_rad(fov_deg * 0.5)
	# Радиус картинки держим примерно одинаковым, иначе широкий FPV закроет полполя.
	var length := clampf(4.6 / maxf(tan(half), 0.25), 2.2, 7.5)
	var radius := tan(half) * length
	var fill := MeshInstance3D.new()
	fill.mesh = _cone_fill(length, radius)
	fill.material_override = _glass(Color(0.4, 0.9, 0.5, 0.07))
	fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(fill)
	var wire := _glass(Color(0.45, 0.92, 0.55, 0.7))
	var sides := 12
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cos(a0) * radius, sin(a0) * radius, -length)
		var p1 := Vector3(cos(a1) * radius, sin(a1) * radius, -length)
		root.add_child(_rib(Vector3.ZERO, p0, wire))
		root.add_child(_rib(p0, p1, wire))
	return root


func _cone_fill(length: float, radius: float) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides := 16
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cos(a0) * radius, sin(a0) * radius, -length)
		var p1 := Vector3(cos(a1) * radius, sin(a1) * radius, -length)
		tool.add_vertex(Vector3.ZERO)
		tool.add_vertex(p0)
		tool.add_vertex(p1)
	tool.generate_normals()
	return tool.commit()


func _rib(a: Vector3, b: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	var span := b - a
	mesh.top_radius = 0.012
	mesh.bottom_radius = 0.012
	mesh.height = maxf(span.length(), 0.05)
	node.mesh = mesh
	node.position = (a + b) * 0.5
	node.basis = _align_y(span.normalized())
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


func _make_arrow(color: Color) -> Node3D:
	var root := Node3D.new()
	var material := _glass(color)
	var shaft := MeshInstance3D.new()
	shaft.name = "shaft"
	var box := BoxMesh.new()
	box.size = Vector3(0.018, 0.018, 1.0)
	shaft.mesh = box
	shaft.material_override = material
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(shaft)
	var head := MeshInstance3D.new()
	head.name = "head"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.042
	cone.height = 0.16
	head.mesh = cone
	# Плюс 90° по X направляет остриё цилиндра в локальный минус Z, туда же смотрит look_at.
	head.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	head.material_override = material
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)
	root.visible = false
	return root


func _aim(arrow: Node3D, dir: Vector3, meters_per_speed: float, limit: float = 2.6) -> void:
	var speed := dir.length()
	var length := speed * meters_per_speed
	if length < 0.28:
		arrow.visible = false
		return
	arrow.visible = true
	length = minf(length, limit)
	var up := Vector3.UP
	if absf(dir.normalized().dot(Vector3.UP)) > 0.96:
		up = Vector3.RIGHT
	arrow.look_at(arrow.global_position + dir, up)
	var shaft := arrow.get_node("shaft") as MeshInstance3D
	shaft.position = Vector3(0.0, 0.0, -length * 0.5)
	shaft.scale = Vector3(1.0, 1.0, length)
	var head := arrow.get_node("head") as MeshInstance3D
	head.position = Vector3(0.0, 0.0, -length - 0.08)


func _glass(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return material


func _align_y(dir: Vector3) -> Basis:
	var y_axis := dir.normalized()
	var side := y_axis.cross(Vector3.FORWARD)
	if side.length() < 0.05:
		side = y_axis.cross(Vector3.RIGHT)
	side = side.normalized()
	return Basis(side, y_axis, side.cross(y_axis).normalized())
