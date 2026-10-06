extends SceneTree

const Library = preload("res://scripts/vehicle_library.gd")
const Craft = preload("res://scripts/quadrotor.gd")
const Flight = preload("res://scripts/flight_model.gd")
const Field = preload("res://scripts/island_field.gd")
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures += 1

func make_craft(profile: Dictionary):
	var craft := Craft.new()
	root.add_child(craft)
	craft.setup(profile)
	craft.position.y = 20.0
	craft.target_altitude = 20.0
	craft.motors_on = true
	craft.altitude_hold = true
	craft.airborne = true
	return craft

func simulate(craft, seconds: float, dt: float = 1.0 / 120.0) -> void:
	for i in int(seconds / dt):
		craft.step(dt)

func run() -> void:
	var library := Library.new()
	library.load_all()
	check(library.profiles.size() == 3, "three vehicle profiles")
	var masses := [0.1, 0.5, 1.388]
	for index in library.profiles.size():
		var profile := library.profiles[index]
		var id := str(profile["id"])
		var craft = make_craft(profile)
		check(is_equal_approx(craft.model.mass, masses[index]), id + " mass")
		check(craft.visual.loaded and craft.visual.rotors.size() == 4, id + " imported mesh and four rotor pivots")
		check(craft.visual.bounds.size.is_finite() and craft.ground_clearance > 0.0, id + " visual bounds")
		var rotor_before: float = craft.visual.rotors[0].rotation.y
		simulate(craft, 5.0)
		check(absf(craft.position.y - 20.0) < 0.2, id + " stable hover")
		check(not is_equal_approx(rotor_before, craft.visual.rotors[0].rotation.y), id + " spinning rotor")
		craft.stick_pitch = 1.0
		simulate(craft, 45.0)
		var speed: float = Vector2(craft.velocity.x, craft.velocity.z).length()
		print("SPEED ", id, " ", speed, " expected ", craft.model.vmax)
		check(absf(speed - float(craft.model.vmax)) < float(craft.model.vmax) * 0.07, id + " calibrated airspeed")
		craft.free()
		craft = make_craft(profile)
		craft.wind = Vector3(0, 0, 7)
		craft.stick_pitch = 1.0
		simulate(craft, 45.0)
		check(craft.velocity.z > 1.0 if index == 0 else craft.velocity.z < -5.0, id + " headwind 7 m/s")
		craft.free()
		craft = make_craft(profile)
		craft.stick_pitch = 1.0
		craft.stick_roll = 1.0
		simulate(craft, 35.0)
		check(craft.velocity.length() < float(craft.model.vmax) * 1.03, id + " diagonal input cannot exceed speed envelope")
		craft.free()

	var mini := library.profiles[0]
	var landing = make_craft(mini)
	landing.position.y = 2.0
	landing.target_altitude = 2.0
	landing.climb_command = -1.4
	simulate(landing, 5.0)
	check(not landing.motors_on and absf(landing.position.y - landing.ground_clearance) < 0.001, "landing disarms on dry ground")
	var stopped_rotor: float = landing.visual.rotors[0].rotation.y
	simulate(landing, 1.0)
	check(is_equal_approx(stopped_rotor, landing.visual.rotors[0].rotation.y), "rotors stop after disarming")
	landing.climb_command = 1.6
	simulate(landing, 2.0)
	check(landing.airborne and landing.position.y > 1.0, "takeoff after landing")
	landing.free()
	var cold = make_craft(mini)
	var warm = make_craft(mini)
	cold.air_temp = -10.0
	cold.air_density = Flight.air_density(-10.0)
	simulate(cold, 30.0)
	simulate(warm, 30.0)
	check(cold.battery < warm.battery, "cold increases battery drain")
	cold.free()
	warm.free()
	var baseline = make_craft(mini)
	baseline.stick_pitch = 1.0
	simulate(baseline, 30.0)
	var rainy = make_craft(mini)
	rainy.precip = 1
	rainy.stick_pitch = 1.0
	simulate(rainy, 30.0)
	check(rainy.velocity.length() < baseline.velocity.length(), "rain increases drag")
	rainy.free()
	baseline.free()
	var slow = make_craft(mini)
	var fast = make_craft(mini)
	slow.stick_pitch = 0.7
	fast.stick_pitch = 0.7
	simulate(slow, 20, 1.0 / 60.0)
	simulate(fast, 20, 1.0 / 240.0)
	check(slow.velocity.distance_to(fast.velocity) < 0.1, "physics timestep convergence")
	slow.free()
	fast.free()
	var wet = make_craft(mini)
	wet.surface_kind = 1
	wet.water_surface = -2.0
	wet.position.y = -2.0 + wet.ground_clearance
	wet.climb_command = -1.0
	wet.step(1.0 / 120.0)
	check(wet.ditched and not wet.motors_on, "water contact stops motors")
	wet.climb_command = 1.6
	wet.step(1.0 / 120.0)
	check(not wet.motors_on, "ditched craft cannot restart")
	wet.free()
	var extreme = make_craft(mini)
	extreme.wind = Vector3(80, 0, 80)
	extreme.canopy = 1.0
	extreme.precip = 2
	simulate(extreme, 10.0)
	check(extreme.position.is_finite() and extreme.velocity.is_finite(), "strong gusts remain finite")
	extreme.free()
	var field := Field.new()
	root.add_child(field)
	field.build()
	check(field.crowns.size() > 0 and field.solids.size() > 0, "unified map has canopy and solid contacts")
	for i in 2:
		var spawn := field.spawn_point(i)
		check(field.surface_kind(spawn) == 0, "island spawn %d is dry" % i)
	check(field.surface_kind(Vector3(360, 0, 0)) == 1, "ocean surrounds island")
	check(field.surface_kind(Vector3(-130, 0, -118)) == 1, "northwest lake is water")
	check(field.sample_height(140, 100) > 25, "southeast hills have relief")
	check(field.find_child("HillLetter0", false, false) != null, "ABDO sign has 3D letters")
	var interpolated := field.sample_height(-81.3, 17.7)
	var u := 1.2 / 2.5
	var v := 0.2 / 2.5
	var expected := field._terrain_height(-82.5, 17.5) * (1-u) + field._terrain_height(-80, 17.5) * (u-v) + field._terrain_height(-80, 20) * v
	check(absf(interpolated - expected) < 0.0001, "island collision follows mesh triangles")
	field.solids = [{"kind": "box", "center": Vector3(0, 10, 0), "half": Vector3(0.1, 1, 1), "yaw": 0.0, "note": "test wall"}]
	var centered: Dictionary = field.resolve(Vector3(0, 10, 0), Vector3(5, 0, 0), 0.1)
	check(absf(centered.pos.x) > 0.2, "collision resolves exact box centre")
	for kind in 5:
		for variant in 2:
			check(ResourceLoader.exists("res://assets/map/trees/tree_%d_%d.res" % [kind, variant]), "baked tree %d/%d" % [kind, variant])
	var contact: Dictionary = field.resolve(Vector3(0, 2, 0), Vector3(4, 0, 0), 0.1)
	check(contact.pos.is_finite(), "collision resolution is finite")
	field.free()
	print("RESULT: ", failures, " failures")
	quit(0 if failures == 0 else 1)
