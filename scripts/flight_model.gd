extends RefCounted

## Общие правила полёта. Не паспорт конкретного аппарата.
## Тягу моторов производители не публикуют, поэтому запас тяги один на всех:
## максимальная тяга вдвое больше веса, висение на половине газа.
## Идея микшера и сопротивления сверена с открытыми учебными моделями,
## код написан здесь, чужие файлы не вставлены. См. CREDITS.md.

const G := 9.81
const RHO := 1.225
const CD := 1.0
const BOX_FILL := 0.35
const THRUST_TO_WEIGHT := 2.0
const CRUISE_TILT_DEG := 25.0
# Масса, размеры и максимальная скорость приходят из паспортного JSON; тяговый запас и коэффициенты осадков — учебные допущения.
# Запас тяги и +15% для дождя не являются измерениями производителя.
const RAIN_DRAG := 1.15
const SNOW_DRAG := 1.10
const SNOW_THRUST := 0.92
const HAIL_DRAG := 1.04


static func air_density(temp_c: float) -> float:
	# Давление как у земли, плотность обратно пропорциональна абсолютной температуре.
	# При 15 °C получается 1,225 кг/м³. Это не прогноз погоды.
	return RHO * 288.15 / maxf(temp_c + 273.15, 150.0)


static func read_number(node: Variant, fallback: float = 0.0) -> float:
	if typeof(node) != TYPE_DICTIONARY:
		return fallback
	var value: Variant = node.get("value", null)
	if value == null:
		return fallback
	return float(value)


static func frontal_area(width: float, height: float) -> float:
	# 0,35 — допущение о заполнении фронтальной площади, а не измерение корпуса.
	# Минимум не даёт делению на ноль, если в файле пустая высота.
	return maxf(BOX_FILL * width * height, 0.001)


static func describe(profile: Dictionary) -> Dictionary:
	var mass := read_number(profile.get("mass_kg"))
	var dims: Dictionary = profile.get("dimensions_m", {})
	var width := maxf(read_number(dims.get("width")), read_number(dims.get("length")))
	var height := read_number(dims.get("height"))
	var vmax := read_number(profile.get("max_airspeed_m_s"))
	var area := frontal_area(width, height)
	var k_geom := 0.5 * RHO * CD * area
	var weight := mass * G
	var max_thrust := THRUST_TO_WEIGHT * weight
	var alpha := deg_to_rad(CRUISE_TILT_DEG)
	if weight / cos(alpha) > max_thrust:
		alpha = acos(weight / max_thrust)
	var horizontal := weight * tan(alpha)
	var drag_k := k_geom
	var scale := 1.0
	var limited := false
	if vmax > 0.1:
		# На паспортной максимальной скорости горизонтальная тяга равна сопротивлению.
		# Иначе плоский Mini по одной только площади вышел бы быстрее Phantom.
		drag_k = horizontal / (vmax * vmax)
		scale = drag_k / k_geom
		limited = true
	var wind_limit := read_number(profile.get("max_wind_m_s"), -1.0)
	return {
		"mass": mass,
		"width": width,
		"height": height,
		"vmax": vmax,
		"area": area,
		"drag_k": drag_k,
		"drag_scale": scale,
		"max_thrust": max_thrust,
		"hover_throttle": 1.0 / THRUST_TO_WEIGHT,
		"weight": weight,
		"limited_by_passport_speed": limited,
		"wind_limit": wind_limit,
		"can_hold_demo_wind": holds_wind(mass, drag_k, vmax, 7.0),
	}


static func holds_wind(mass: float, drag_k: float, vmax: float, wind: float) -> bool:
	if vmax > 0.1 and wind > vmax:
		return false
	var weight := mass * G
	var drag := drag_k * wind * wind
	var tilt := atan2(drag, weight)
	var thrust := weight / cos(tilt)
	return tilt <= deg_to_rad(CRUISE_TILT_DEG) + 0.000001 and thrust <= THRUST_TO_WEIGHT * weight + 0.000001
