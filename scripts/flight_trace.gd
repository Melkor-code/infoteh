extends MeshInstance3D

var points := PackedVector3Array()
var timer := 0.0
const MAX_POINTS := 2400

func _ready() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.65, 0.15)
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func clear() -> void:
	points.clear()
	mesh = null
	timer = 0.0

func sample(pos: Vector3, delta: float) -> void:
	timer += delta
	if timer < 0.15:
		return
	timer = 0.0
	if not points.is_empty() and points[-1].distance_to(pos) < 0.08:
		return
	points.append(pos)
	if points.size() > MAX_POINTS:
		points.remove_at(0)
	if points.size() < 2:
		return
	var path := ImmediateMesh.new()
	path.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for point in points:
		path.surface_add_vertex(point)
	path.surface_end()
	mesh = path
