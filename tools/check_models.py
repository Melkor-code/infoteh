"""Проверка трёх аппаратов без Godot.

Формулы должны совпадать со scripts/flight_model.gd.
Запуск: python3 tools/check_models.py
"""

import json
import math
from pathlib import Path

G = 9.81
RHO = 1.225
CD = 1.0
BOX_FILL = 0.35
THRUST_TO_WEIGHT = 2.0
CRUISE_TILT_DEG = 25.0
DEMO_WIND = 7.0


def num(node, default=0.0):
    if not isinstance(node, dict):
        return default
    value = node.get("value", None)
    if value is None:
        return default
    return float(value)


def calibrate(mass, width, height, vmax):
    area = max(BOX_FILL * width * height, 0.001)
    k_geom = 0.5 * RHO * CD * area
    weight = mass * G
    max_thrust = THRUST_TO_WEIGHT * weight
    alpha = math.radians(CRUISE_TILT_DEG)
    if weight / math.cos(alpha) > max_thrust:
        alpha = math.acos(weight / max_thrust)
    horizontal = weight * math.tan(alpha)
    if vmax <= 0.1:
        return {
            "drag_k": k_geom,
            "scale": 1.0,
            "max_thrust": max_thrust,
            "limited_by_passport": False,
        }
    k = horizontal / (vmax * vmax)
    return {
        "drag_k": k,
        "scale": k / k_geom,
        "max_thrust": max_thrust,
        "limited_by_passport": True,
    }


def holds_wind(mass, drag_k, vmax, wind):
    if vmax > 0.1 and wind > vmax:
        return False
    weight = mass * G
    drag = drag_k * wind * wind
    tilt = math.atan2(drag, weight)
    thrust = weight / math.cos(tilt)
    return tilt <= math.radians(CRUISE_TILT_DEG) + 1e-6 and thrust <= THRUST_TO_WEIGHT * weight + 1e-6


def main():
    root = Path(__file__).resolve().parents[1] / "data" / "vehicles"
    print(f"{'аппарат':<28} {'м/с макс':>8} {'удержит 7 м/с':>14} {'множитель':>10}")
    for path in sorted(root.glob("*.json")):
        if path.name.startswith("_"):
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        mass = num(data.get("mass_kg"))
        dims = data.get("dimensions_m", {})
        width = max(num(dims.get("width")), num(dims.get("length")))
        height = num(dims.get("height"))
        vmax = num(data.get("max_airspeed_m_s"))
        model = calibrate(mass, width, height, vmax)
        ok = holds_wind(mass, model["drag_k"], vmax, DEMO_WIND)
        print(
            f"{data.get('display_name', path.name):<28} {vmax:8.2f} "
            f"{'да' if ok else 'нет':>14} {model['scale']:10.1f}"
        )


if __name__ == "__main__":
    main()
