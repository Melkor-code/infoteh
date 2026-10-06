extends SceneTree

const App = preload("res://scripts/app.gd")

func _initialize() -> void:
	call_deferred("run")

func shot(name: String) -> void:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png("res://tests/output/" + name + ".png")

func run() -> void:
	DirAccess.make_dir_recursive_absolute("res://tests/output")
	root.size = Vector2i(1280, 720)
	var app := App.new()
	root.add_child(app)
	app.set_physics_process(false)
	await shot("menu")
	for index in 3:
		app._select(index)
		app._start_flight()
		app.wind_speed = 0
		for slider in app.wind_sliders:
			slider.value = 0
		# Drive the actual flight loop with input disabled for repeatability.
		app.craft.position.y = 8.0
		app.craft.target_altitude = 8.0
		app.craft.motors_on = true
		app.craft.altitude_hold = true
		for frame in 120:
			app._physics_process(1.0 / 60.0)
		app.camera_mode = 2
		app.orbit_distance = maxf(app.craft.collision_radius * 7.5, 0.65)
		app._place_camera()
		await shot(str(app.craft.profile.id))
		assert(app.craft.visual.loaded)
		app.camera_mode = 1
		app._place_camera()
		assert(not app.craft.visual.visible)
		app._back_to_menu()
	# Exercise every start zone and precipitation system through the application.
	for terrain in 2:
		app.terrain = terrain
		app._start_flight()
		for frame in 10:
			app._physics_process(1.0 / 60.0)
		assert(app.craft.position.is_finite() and not app.craft.ditched)
		app._back_to_menu()
	app.terrain = 0
	app._start_flight()
	app.precip = 2
	app.wind_speed = 7.0
	app.camera_mode = 2
	app.orbit_distance = 18.0
	app.craft.position = Vector3(-86, 14, 80)
	app.craft.target_altitude = 14.0
	app.craft.motors_on = true
	app.craft.altitude_hold = true
	for frame in 10:
		app._physics_process(1.0 / 60.0)
	await shot("forest_snow")
	assert(app.snow.emitting and not app.rain.emitting)
	app.precip = 1
	app._place_precip()
	assert(app.rain.emitting and not app.snow.emitting)
	app.precip = 3
	app._place_precip()
	assert(app.hail.emitting and not app.rain.emitting)
	app.precip = 0
	app._back_to_menu()
	app.field.set_foliage_wind(Vector3.ZERO, 0.0)
	app.set_process(false)
	app.menu_panel.hide()
	app.flight_panel.hide()
	app.warning_label.hide()
	app.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	app.camera.near = 1.0
	app.world_environment.environment.fog_enabled = false
	app.camera.size = 510.0
	app.camera.position = Vector3(0, 850, 0)
	app.camera.look_at(Vector3.ZERO, Vector3.FORWARD)
	await shot("island_top")
	app.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	app.camera.position = Vector3(295, 310, 410)
	app.camera.look_at(Vector3(0, 0, -15))
	await shot("island_overview")
	app.camera.position = Vector3(84, 53, -2)
	app.camera.look_at(Vector3(121, 33, 86))
	await shot("island_abdo")
	app.camera.position = Vector3(-67, 35, 49)
	app.camera.look_at(Vector3(0, 10, 0))
	await shot("island_city")
	app.camera.position = Vector3(-104, 26, 28)
	app.camera.look_at(Vector3(-180, 9, -10))
	await shot("island_course")
	app.free()
	print("RENDER CHECKS COMPLETE")
	quit()
