extends Control

const UiSkin = preload("res://scripts/ui_theme.gd")
const Telemetry = preload("res://scripts/telemetry_snapshot.gd")
var app: Node
var hud_scale := 1.0
var clean_screen := false
var snapshot: Dictionary = {}
var font: Font = ThemeDB.fallback_font

func setup(owner: Node) -> void:
	app = owner
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _process(_delta: float) -> void:
	if app.flying and app.craft != null:
		snapshot = Telemetry.capture(app)
	visible = app.flying and not app.paused and not clean_screen
	queue_redraw()

func _draw() -> void:
	if snapshot.is_empty() or not visible:
		return
	var view: Vector2 = size
	var s: float = minf(hud_scale, minf(view.x / 1100.0, view.y / 620.0))
	var left := Rect2(24, view.y - 214 * s, 320 * s, 190 * s)
	var right := Rect2(360 * s, view.y - 214 * s, 320 * s, 190 * s)
	var map := Rect2(view.x - 324 * s, view.y - 276 * s, 300 * s, 252 * s)
	draw_style_box(UiSkin.panel(0.86), left)
	draw_style_box(UiSkin.panel(0.86), right)
	draw_style_box(UiSkin.panel(0.86), map)
	_rows(left, "ПОЛЁТ / " + str(snapshot.camera), [["ВЫСОТА", "%.1f м" % snapshot.altitude], ["СКОРОСТЬ ГОР.", "%.1f м/с" % snapshot.horizontal], ["СКОРОСТЬ ВЕРТ.", "%+.1f м/с" % snapshot.vertical], ["КУРС", "%03.0f°" % snapshot.heading], ["КРЕН / ТАНГАЖ", "%+.0f° / %+.0f°" % [snapshot.roll, snapshot.pitch]], ["ДО СТАРТА", "%.1f м" % snapshot.distance]], left.size.x, s)
	_rows(right, str(snapshot.mode), [["БАТАРЕЯ", "%.0f%%" % snapshot.battery], ["СВЯЗЬ", "%.0f%%" % snapshot.signal], ["МОТОРЫ", "%.0f °C" % snapshot.temperature], ["ВРЕМЯ", Telemetry.clock(snapshot.elapsed)], ["X / Z", "%.1f / %.1f м" % [snapshot.position.x, snapshot.position.z]], ["ОСАДКИ", str(app._precip_name())]], right.size.x, s)
	_draw_map(map, s)
	if app.camera_mode == 1:
		_draw_osd(view, s)
	if snapshot.warning != "":
		_text(str(snapshot.warning), Vector2(24, left.position.y - 14), 13, Color("#f0dfb8"))

func _rows(rect: Rect2, title: String, rows: Array, width: float, s: float) -> void:
	_text(title, rect.position + Vector2(12, 22) * s, int(13 * s), Color("#c8c8c4"))
	draw_line(rect.position + Vector2(12, 31) * s, rect.position + Vector2(width - 12, 31) * s, Color("#777774"))
	for i in rows.size():
		var y: float = rect.position.y + (51 + i * 22) * s
		_text(str(rows[i][0]), Vector2(rect.position.x + 12 * s, y), int(12 * s), Color("#9e9e9a"))
		_text(str(rows[i][1]), Vector2(rect.end.x - 130 * s, y), int(14 * s))

func _map_point(area: Rect2, point: Vector3) -> Vector2:
	return area.position + Vector2((point.x + 340.0) / 680.0, (point.z + 225.0) / 450.0) * area.size


func _map_boundary(area: Rect2, points: PackedVector3Array, fill: Color, edge: Color, s: float) -> void:
	var outline := PackedVector2Array()
	for point in points:
		outline.append(_map_point(area, point))
	draw_colored_polygon(outline, fill)
	outline.append(outline[0])
	draw_polyline(outline, edge, 1.5 * s, true)


func _map_label(value: String, point: Vector2, color: Color, s: float) -> void:
	var fs := int(12 * s)
	var width := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var background := Rect2(point - Vector2(5 * s, 14 * s), Vector2(width + 10 * s, 20 * s))
	draw_rect(background, Color(0.02, 0.04, 0.07, 0.94))
	draw_rect(background, color, false, s)
	draw_string_outline(font, point, value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 1, color)
	draw_string(font, point, value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


func _draw_map(rect: Rect2, s: float) -> void:
	_text("ОСТРОВ  /  СЕВЕР ↑", rect.position + Vector2(12, 22) * s, int(13 * s), Color("#e5edf7"))
	var area := Rect2(rect.position + Vector2(12, 34) * s, Vector2(276, 176) * s)
	draw_rect(area, Color("#071622"))
	for x in range(1, 7):
		var gx := area.position.x + area.size.x * float(x) / 7.0
		draw_line(Vector2(gx, area.position.y), Vector2(gx, area.end.y), Color("#163243"), s)
	for y in range(1, 5):
		var gy := area.position.y + area.size.y * float(y) / 5.0
		draw_line(Vector2(area.position.x, gy), Vector2(area.end.x, gy), Color("#163243"), s)
	var island := PackedVector3Array()
	for i in 96:
		var angle: float = TAU * i / 96.0
		var radius := 1.0 + 0.016 * sin(angle * 5.0) + 0.01 * cos(angle * 9.0)
		island.append(Vector3(cos(angle) * 310 * radius, 0, sin(angle) * 210 * radius))
	_map_boundary(area, island, Color("#194538"), Color("#72b59b"), s)
	var field = app.field
	for i in field.LAKE_CENTERS.size():
		var lake := PackedVector3Array()
		for j in 32:
			var angle: float = TAU * j / 32.0
			lake.append(field.LAKE_CENTERS[i] + Vector3(cos(angle), 0, sin(angle)) * field.LAKE_RADII[i])
		_map_boundary(area, lake, Color("#147fd1"), Color("#86d8ff"), s)
	var city := Rect2(_map_point(area, Vector3(-72, 0, -60)), _map_point(area, Vector3(72, 0, 60)) - _map_point(area, Vector3(-72, 0, -60)))
	draw_rect(city, Color("#56697b"))
	draw_rect(city, Color("#e2edf7"), false, 1.5 * s)
	for x in [-54, 0, 54]:
		for z in [-45, 45]:
			var building := Rect2(_map_point(area, Vector3(x - 8, 0, z - 8)), Vector2(7, 7) * s)
			draw_rect(building, Color("#8b9cae"))
			draw_rect(building, Color.WHITE, false, s)
	var course := Rect2(_map_point(area, Vector3(-250, 0, -40)), _map_point(area, Vector3(-94, 0, 20)) - _map_point(area, Vector3(-250, 0, -40)))
	draw_rect(course, Color("#9a7019"))
	draw_rect(course, Color("#ffdd55"), false, 2 * s)
	for i in 4:
		draw_circle(course.position + Vector2(10 + i * 13, 12) * s, 3 * s, Color("#ffed92"), false, s)
	for hill in field.HILLS:
		var outline := PackedVector3Array()
		for j in 24:
			var angle: float = TAU * j / 24.0
			outline.append(hill + Vector3(cos(angle) * 31, 0, sin(angle) * 28))
		_map_boundary(area, outline, Color("#885234"), Color("#e7a976"), s)
	_map_label("ОЗЕРО", area.position + Vector2(8, 18) * s, Color("#86d8ff"), s)
	_map_label("ГОРОД", area.position + Vector2(151, 18) * s, Color("#e2edf7"), s)
	_map_label("ПОЛИГОН", area.position + Vector2(8, 155) * s, Color("#ffdd55"), s)
	_map_label("АБДО", area.position + Vector2(222, 155) * s, Color("#e7a976"), s)
	# Путь всегда поверх географических зон; сохраняем все его точки.
	var route: Array = snapshot.get("route", [])
	if route.size() > 1:
		var path := PackedVector2Array()
		for point in route:
			path.append(_map_point(area, point).clamp(area.position, area.end))
		draw_polyline(path, Color("#071019"), 6 * s, true)
		draw_polyline(path, Color.WHITE, 4 * s, true)
		draw_polyline(path, Color("#ffe637"), 2.5 * s, true)
	var home := _map_point(area, snapshot.home).clamp(area.position + Vector2.ONE * 8 * s, area.end - Vector2.ONE * 8 * s)
	draw_rect(Rect2(home - Vector2.ONE * 6 * s, Vector2.ONE * 12 * s), Color("#071019"))
	draw_rect(Rect2(home - Vector2.ONE * 5 * s, Vector2.ONE * 10 * s), Color("#5fefff"), false, 2 * s)
	var dot := _map_point(area, snapshot.position).clamp(area.position + Vector2.ONE * 12 * s, area.end - Vector2.ONE * 12 * s)
	var direction := Vector2(snapshot.forward.x, snapshot.forward.z).normalized()
	var side := Vector2(-direction.y, direction.x)
	var arrow := PackedVector2Array([dot + direction * 12 * s, dot - direction * 7 * s + side * 7 * s, dot - direction * 3 * s, dot - direction * 7 * s - side * 7 * s])
	draw_colored_polygon(arrow, Color("#ff941c"))
	arrow.append(arrow[0])
	draw_polyline(arrow, Color("#071019"), 5 * s, true)
	draw_polyline(arrow, Color.WHITE, 2 * s, true)
	var legend := rect.position + Vector2(12, 230) * s
	draw_circle(legend + Vector2(4, -4) * s, 4 * s, Color("#ff941c"))
	_text("Дрон", legend + Vector2(14, 0) * s, int(11 * s))
	draw_rect(Rect2(legend + Vector2(63, -9) * s, Vector2(8, 8) * s), Color("#5fefff"), false, s)
	_text("Старт", legend + Vector2(78, 0) * s, int(11 * s))
	draw_line(legend + Vector2(127, -4) * s, legend + Vector2(142, -4) * s, Color("#ffe637"), 3 * s)
	_text("Путь", legend + Vector2(148, 0) * s, int(11 * s))
	_text("Лес", legend + Vector2(225, 0) * s, int(11 * s), Color("#72b59b"))
	draw_rect(Rect2(legend + Vector2(210, -9) * s, Vector2(8, 8) * s), Color("#194538"))

func _draw_osd(view: Vector2, s: float) -> void:
	var center := view * 0.5
	var line := Color(0.86, 0.95, 0.9, 0.9)
	var horizon: float = center.y + float(snapshot.pitch) * 1.8
	draw_line(Vector2(0, horizon), Vector2(view.x, horizon), line, 1)
	draw_line(center - Vector2(20, 0), center - Vector2(5, 0), Color("#e3b54c"), 2)
	draw_line(center + Vector2(5, 0), center + Vector2(20, 0), Color("#e3b54c"), 2)
	draw_circle(center, 2, Color("#e3b54c"))
	draw_line(Vector2(center.x - 150, 58), Vector2(center.x + 150, 58), line, 1)
	_text("%03d°" % int(snapshot.heading), center + Vector2(-18, -view.y * 0.38), int(16 * s), line)
	_text("ALT %.1f m" % snapshot.altitude, Vector2(22, 34), int(16 * s), line)
	_text("BAT %.0f%%  SIG %.0f%%" % [snapshot.battery, snapshot.signal], Vector2(view.x - 205, 34), int(16 * s), line)

func _text(value: String, point: Vector2, font_size: int, color: Color = Color("#ededeb")) -> void:
	draw_string_outline(font, point, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color(0, 0, 0, 0.7))
	draw_string(font, point, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
