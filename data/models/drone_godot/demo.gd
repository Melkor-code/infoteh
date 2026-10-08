extends Node3D

func _ready() -> void:
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(0.36, 0.40, 0.46)
	camera.look_at(Vector3.ZERO, Vector3.UP)
	camera.near = 0.01
	camera.current = true
	var key := DirectionalLight3D.new()
	add_child(key)
	key.rotation_degrees = Vector3(-50, -35, 0)
	key.light_energy = 1.2
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.15, 0.19)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.8, 0.86, 1.0)
	environment.ambient_light_energy = 0.7
	environment_node.environment = environment
	add_child(environment_node)
