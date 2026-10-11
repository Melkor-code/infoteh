extends RefCounted
const PAPER := Color("#ededeb")
const MUTED := Color("#a5a5a2")
static var shared: Theme

static func panel(alpha: float = 0.94) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.065, 0.065, 0.065, alpha)
	box.border_color = Color("#424240")
	box.set_border_width_all(1)
	box.set_corner_radius_all(4)
	box.set_content_margin_all(16)
	return box

static func get_theme() -> Theme:
	if shared != null:
		return shared
	shared = Theme.new()
	shared.default_font_size = 16
	shared.set_color("font_color", "Label", PAPER)
	shared.set_stylebox("panel", "PanelContainer", panel())
	for type in ["Button", "OptionButton", "CheckButton"]:
		shared.set_color("font_color", type, PAPER)
		shared.set_color("font_hover_color", type, Color.WHITE)
		shared.set_color("font_pressed_color", type, Color.WHITE)
		shared.set_color("font_disabled_color", type, MUTED)
		for state in ["normal", "hover", "pressed", "focus", "disabled"]:
			var box := panel()
			box.set_content_margin_all(9)
			box.bg_color = Color("#272727") if state in ["hover", "pressed"] else Color("#161616")
			box.border_color = PAPER if state == "focus" else Color("#444442")
			shared.set_stylebox(state, type, box)
	shared.set_constant("separation", "VBoxContainer", 10)
	shared.set_constant("separation", "HBoxContainer", 12)
	return shared

static func button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 38
	b.pressed.connect(action)
	return b

static func label(text: String, font_size: int = 16) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	return l
