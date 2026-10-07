extends RefCounted

# One snapshot feeds HUD, OSD and map. East +X, north -Z.
static func capture(app: Node) -> Dictionary:
	if not is_instance_valid(app.craft):
		return {}
	var c = app.craft
	var p: Vector3 = c.global_position
	var v: Vector3 = c.velocity
	var f: Vector3 = c.forward()
	var home: Vector3 = app.home_position
	return {
		"position": p, "home": home, "forward": f,
		"altitude": c.height_above_surface(),
		"horizontal": Vector2(v.x, v.z).length(), "vertical": v.y,
		"heading": fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0),
		"roll": c.sensor_roll, "pitch": c.sensor_pitch,
		"battery": c.sensor_battery, "signal": c.sensor_signal,
		"temperature": c.sensor_motor_temp,
		"elapsed": app.flight_seconds, "distance": p.distance_to(home),
		"mode": "АВТОПИЛОТ" if c.autopilot_on else ("РУЧНОЙ" if c.motors_on else "МОТОРЫ ВЫКЛ"),
		"camera": ["СЛЕЖЕНИЕ", "FPV", "ОРБИТА", "ОСТРОВ"][app.camera_mode],
		"warning": app.status_flash if app.status_flash_time > 0 else c.warning,
		"camera_basis": app.camera.global_basis, "camera_fov": app.camera.fov,
		"route": app.route_points,
	}

static func number(value: Variant, pattern: String) -> String:
	if value == null or not is_finite(float(value)):
		return "—"
	return pattern % float(value)

static func clock(value: float) -> String:
	return "%02d:%02d" % [int(value) / 60, int(value) % 60]
