extends SceneTree

const Contacts = preload("res://scripts/map_contacts.gd")
var failures := 0

# Headless Godot has no physical keyboard. Inject only the input boundary;
# the application's terrain sampling, substeps and collisions remain unchanged.
class DrivenApp:
	extends "res://scripts/app.gd"
	var climb_input := 0.0
	func _read_flight_input(_delta: float) -> void:
		craft.climb_command = climb_input

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, text: String) -> void:
	print(("PASS " if ok else "FAIL ") + text)
	if not ok:
		failures += 1

func run() -> void:
	var app := DrivenApp.new()
	root.add_child(app)
	app.set_physics_process(false)
	app.set_process(false)
	app.wind_speed = 0
	for vehicle in 3:
		app._select(vehicle)
		for spawn in 2:
			app.terrain = spawn
			app._start_flight()
			for frame in 30:
				app._physics_process(1.0 / 60.0)
			check(not app.craft.ditched and not app.craft.motors_on, "dry parked spawn %d vehicle %d" % [spawn, vehicle])
			if spawn == 1:
				check(app.craft.forward().x < -0.99, "course spawn faces obstacles")
			app.climb_input = 1.6
			for frame in 180:
				app._physics_process(1.0 / 60.0)
			app.climb_input = 0.0
			check(app.craft.airborne and app.craft.height_above_surface() > 3.0, "takeoff from spawn %d vehicle %d" % [spawn, vehicle])
			app.climb_input = -1.4
			for frame in 360:
				app._physics_process(1.0 / 60.0)
			app.climb_input = 0.0
			check(not app.craft.motors_on and app.craft.height_above_surface() < 0.1, "landing at spawn %d vehicle %d" % [spawn, vehicle])
			app._back_to_menu()
	var rings := 0
	var buildings := 0
	for solid in app.field.solids:
		if solid.kind == "ring":
			rings += 1
			check(Contacts._hit_solid(solid, solid.center, 0.24).is_empty(), "ring opening is passable")
			var rim: Vector3 = solid.center + Vector3(0, solid.major, 0)
			var hit := Contacts._hit_solid(solid, rim, 0.24)
			check(not hit.is_empty() and hit.normal.length() > 0.9, "ring rim is solid with a valid contact normal")
		if solid.kind == "box" and solid.center.y > 12 and absf(solid.center.x) < 72 and absf(solid.center.z) < 60:
			buildings += 1
			check(not Contacts._hit_solid(solid, solid.center, 0.1).is_empty(), "city building blocks drone")
	check(rings >= 14 and buildings >= 12, "course and city obstacles exist")
	for angle in range(0, 360, 15):
		var rad := deg_to_rad(float(angle))
		check(app.field.surface_kind(Vector3(cos(rad) * 345, 0, sin(rad) * 242)) == 1, "ocean perimeter %d" % angle)
	check(app.field.crowns.size() > 100, "trees fill free island areas")
	app.free()
	print("ISLAND RESULT: ", failures, " failures")
	quit(0 if failures == 0 else 1)
