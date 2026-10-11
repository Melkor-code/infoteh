extends SceneTree

const App = preload("res://scripts/app.gd")
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
	print(("PASS " if condition else "FAIL ") + label)

func _run() -> void:
	var app := App.new()
	root.add_child(app)
	await process_frame
	app._start_flight()
	await process_frame
	app._save_log()
	check(app.paused, "report pauses flight")
	var elapsed: float = app.flight_seconds
	var position: Vector3 = app.craft.position
	var hour: float = app.day_night.hour
	app._physics_process(1.0)
	app._process(1.0)
	check(app.flight_seconds == elapsed and app.craft.position == position and app.day_night.hour == hour, "flight and weather remain frozen")
	app.report_dialog.hide()
	app._report_closed()
	check(app.paused and app.pause_panel.visible, "cancel returns to pause")
	app.sample_lines = PackedStringArray([
		"0.0;10;2;-5;3;20;95;35;90;0.5;2;0",
		"2.5;20;4;5;-3;30;90;40;85;0.5;2;0",
		"10.0;30;6;0;0;40;85;45;80;0.5;2;0"
	])
	var svg: String = app._chart_svg("Высота", 1, "м", "#123456")
	check(svg.contains("Время полёта (с)") and svg.contains("Высота (м)"), "Russian axes and units")
	check(svg.count("text-anchor='end'") == 6 and svg.count("y='256'") == 6, "six ticks on both axes")
	check(svg.contains("247.5,") and svg.contains(">10.0</text>"), "actual timestamps determine x coordinates")
	app.sample_lines = PackedStringArray(["0;10;0;0;0;0;100;20;100;0;0;0"])
	check(not app._chart_svg("Высота", 1, "м", "#123456").contains("nan"), "constant and one-point series")
	var folder := "res://tests/output/report_" + str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(folder)
	app._write_report(folder)
	var dir := DirAccess.open(folder)
	check(dir.get_files().size() == 2, "only HTML and event log exported")
	check(FileAccess.file_exists(folder.path_join("графики_полёта.html")) and FileAccess.file_exists(folder.path_join("журнал_событий.txt")), "both expected files saved")
	check(app.paused and app.pause_panel.visible, "export keeps simulation paused")
	app._toggle_pause()
	check(not app.paused, "explicit resume works")
	print("REPORT CHECKS: %d failures" % failures)
	quit(1 if failures > 0 else 0)

