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
	var map := Rect2(view.x - 280 * s, view.y - 214 * s, 256 * s, 190 * s)
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

func _draw_map(rect: Rect2, s: float) -> void:
	_text("ОСТРОВ  N ↑   |   100 м", rect.position + Vector2(12, 22) * s, int(13 * s), Color("#c8c8c4"))
	var area := Rect2(rect.position + Vector2(12, 32) * s, Vector2(232, 135) * s)
	draw_rect(area, Color("#132527"))
	var island := PackedVector2Array()
	for i in 32:
		var a: float = TAU * i / 32.0
		island.append(area.get_center() + Vector2(cos(a) * area.size.x * 0.42, sin(a) * area.size.y * 0.38))
	draw_colored_polygon(island, Color("#566e51"))
	# Карта показывает реальные зоны полигона, города, озера и холмов.
	var city := Rect2(area.position + Vector2(99, 53) * s, Vector2(45, 28) * s)
	draw_rect(city, Color("#6f7780"), true)
	for x in range(3):
		for y in range(2):
			draw_rect(Rect2(city.position + Vector2(5 + x * 13, 5 + y * 10) * s, Vector2(8, 6) * s), Color("#b9c1c4"), true)
	_text("ГОРОД", city.position + Vector2(2, -3) * s, int(9 * s), Color("#e5e8d5"))
	var lake := area.position + Vector2(34, 24) * s
	draw_circle(lake, 15 * s, Color("#398cb0"))
	_text("ОЗЕРО", lake + Vector2(-13, 25) * s, int(8 * s), Color("#b9d9df"))
	var course := Rect2(area.position + Vector2(14, 72) * s, Vector2(56, 25) * s)
	draw_rect(course, Color("#d2b66b"), true)
	for x in range(4):
		draw_circle(course.position + Vector2(10 + x * 13, 12) * s, 4 * s, Color("#efe3a0"), false, 1.5 * s)
	_text("ПОЛИГОН", course.position + Vector2(2, -3) * s, int(8 * s), Color("#f1dfae"))
	var hills := area.position + Vector2(185, 98) * s
	for i in range(3):
		draw_circle(hills + Vector2(i * 10, -i * 3) * s, (13 - i) * s, Color("#777064"))
	_text("АБДО", hills + Vector2(-8, 22) * s, int(9 * s), Color("#eee4c5"))
	var p: Vector3 = snapshot.position
	var dot := area.get_center() + Vector2(p.x / 310.0 * area.size.x * 0.42, p.z / 210.0 * area.size.y * 0.38)
	var home := area.get_center() + Vector2(snapshot.home.x / 310.0 * area.size.x * 0.42, snapshot.home.z / 210.0 * area.size.y * 0.38)
	draw_rect(Rect2(home - Vector2(4, 4), Vector2(8, 8)), Color.WHITE, false, 1.5)
	draw_circle(dot, 5, Color("#e3b54c"))
	var d := Vector2(snapshot.forward.x, snapshot.forward.z).normalized() * 11
	draw_line(dot, dot + d, Color.WHITE, 2)

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
