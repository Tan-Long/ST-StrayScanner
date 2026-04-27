from datetime import datetime, timezone
from math import sin, cos, radians, degrees
import numpy as np

try:
    from pysolar.solar import get_azimuth, get_altitude
    PYSOLAR_OK = True
except ImportError:
    PYSOLAR_OK = False


def compute_solar(lat: float, lon: float, trunk_normal: list, scan_timestamp_iso: str) -> dict:
    if not PYSOLAR_OK:
        return {
            "sun_facing_fraction": None,
            "monthly_facing": None,
            "peak_solar_month": None,
            "solar_classification": None,
            "error_message": "pysolar not installed",
        }

    try:
        year = datetime.fromisoformat(scan_timestamp_iso.replace("Z", "+00:00")).year
    except Exception:
        year = 2024

    month_names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    normal = np.array(trunk_normal, dtype=float)
    monthly_facing = []

    for month in range(1, 13):
        dt = datetime(year, month, 15, 6, 0, tzinfo=timezone.utc)
        try:
            az = get_azimuth(lat, lon, dt)
            el = get_altitude(lat, lon, dt)
        except Exception:
            monthly_facing.append(0.0)
            continue

        if el < 0:
            monthly_facing.append(0.0)
            continue

        solar_vec = np.array([
            sin(radians(az)) * cos(radians(el)),
            cos(radians(az)) * cos(radians(el)),
            sin(radians(el)),
        ])
        facing = float(max(0.0, np.dot(solar_vec, normal)))
        monthly_facing.append(round(facing, 4))

    sun_facing_fraction = float(np.mean(monthly_facing))
    peak_idx = int(np.argmax(monthly_facing))
    peak_solar_month = month_names[peak_idx]
    solar_classification = "Sun-facing" if sun_facing_fraction > 0.5 else "Shade-facing"

    return {
        "sun_facing_fraction": round(sun_facing_fraction, 4),
        "monthly_facing": monthly_facing,
        "peak_solar_month": peak_solar_month,
        "solar_classification": solar_classification,
    }
