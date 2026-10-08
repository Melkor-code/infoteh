extends RefCounted

## Листва не стена. Ствол останавливает отдельно, крона только растит сопротивление
## и слегка трясёт. Проверка — расстояние до центра кроны, не физическое тело.


static func apply(craft: Node, crowns: Array, delta: float) -> void:
	var pos: Vector3 = craft.get("position")
	var amount := sample(pos, crowns)
	craft.set("canopy", amount)
	var previous: Vector3 = craft.get("canopy_gust")
	craft.set("canopy_gust", _gust(amount, previous, delta))


static func sample(pos: Vector3, crowns: Array) -> float:
	var best := 0.0
	for crown in crowns:
		if typeof(crown) != TYPE_DICTIONARY:
			continue
		var item: Dictionary = crown
		var reach := float(item.get("reach", 0.0))
		if reach < 0.05:
			continue
		var flat := Vector2(pos.x - float(item.get("x", 0.0)), pos.z - float(item.get("z", 0.0))).length()
		if flat > reach:
			continue
		if pos.y < float(item.get("base", 0.0)) or pos.y > float(item.get("top", 0.0)):
			continue
		best = maxf(best, 1.0 - flat / reach)
	return best


static func drag_scale(amount: float) -> float:
	# Допущение, не паспорт. На полном входе в крону сопротивление примерно в 5 раз выше.
	if amount < 0.08:
		return 1.0
	return 1.0 + 4.4 * amount


static func _gust(amount: float, previous: Vector3, delta: float) -> Vector3:
	if amount < 0.12:
		return previous.move_toward(Vector3.ZERO, 3.0 * delta)
	var target := Vector3(randf_range(-1.0, 1.0), randf_range(-0.2, 0.25), randf_range(-1.0, 1.0))
	if target.length() < 0.05:
		target = Vector3.RIGHT
	target = target.normalized() * amount * 1.7
	return previous.move_toward(target, 3.5 * delta)
