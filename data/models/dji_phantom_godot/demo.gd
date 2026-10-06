extends Node3D

func _ready() -> void:
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(-0.55, 0.35, -0.65)
	camera.look_at(Vector3(0, -0.035, 0), Vector3.UP)
	camera.near = 0.005
	camera.current = true
	var key := DirectionalLight3D.new()
	add_child(key)
	key.rotation_degrees = Vector3(-45, -25, 0)
	key.light_energy = 1.5
	var fill := OmniLight3D.new()
	add_child(fill)
	fill.position = Vector3(0.1, 0.2, -0.2)
	fill.omni_range = 2.0
	fill.light_energy = 0.4
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.15, 0.18, 0.22)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.9, 0.93, 1.0)
	environment.ambient_light_energy = 0.8
	environment_node.environment = environment
	add_child(environment_node)
