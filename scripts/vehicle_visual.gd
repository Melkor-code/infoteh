extends Node3D

## Визуальная модель подгоняется по размерам профиля, но не меняет массу и состояние полёта. Границы измеряются в метрах.
var rotors: Array[Node3D] = []
var bounds := AABB()
var loaded := false

func setup(profile: Dictionary) -> void:
	var path := str(profile.get("visual_scene", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	var model := scene.instantiate() as Node3D
	if model == null:
		return
	add_child(model)
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	var first := true
	for item in meshes:
		var mesh := item as MeshInstance3D
		var box := (global_transform.affine_inverse() * mesh.global_transform) * mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	if first:
		model.queue_free()
		return
	var span := float(profile.get("visual_span_m", maxf(bounds.size.x, bounds.size.z)))
	var fit := span / maxf(maxf(bounds.size.x, bounds.size.z), 0.001)
	model.scale *= fit
	model.position = -bounds.get_center() * fit
	bounds = AABB(-bounds.size * fit * 0.5, bounds.size * fit)
	for index in 4:
		var rotor := model.find_child("Propeller_%d" % index, true, false) as Node3D
		if rotor != null:
			rotors.append(rotor)
	loaded = true

func spin(delta: float, throttle: float) -> void:
	for index in rotors.size():
		var direction := 1.0 if index == 0 or index == 3 else -1.0
		rotors[index].rotate_y(direction * sqrt(maxf(throttle, 0.0)) * 160.0 * delta)
