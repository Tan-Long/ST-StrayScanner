from datetime import datetime, timedelta
from math import sin, cos, radians, degrees
import numpy as np
import requests

from .compute_trunk import azimuth_to_8pt_cardinal


def compute_wind(lat: float, lon: float, trunk_normal: list, scan_date_iso: str) -> dict:
    try:
        scan_dt = datetime.fromisoformat(scan_date_iso.replace("Z", ""))
    except Exception:
        scan_dt = datetime.utcnow()

    start_date = (scan_dt - timedelta(days=365)).strftime("%Y-%m-%d")
    end_date = scan_dt.strftime("%Y-%m-%d")

    try:
        url = "https://archive.open-meteo.com/v1/archive"
        params = {
            "latitude": lat,
            "longitude": lon,
            "start_date": start_date,
            "end_date": end_date,
            "hourly": "winddirection_10m,windspeed_10m",
            "models": "era5_seamless",
            "timezone": "Asia/Bangkok",
        }
        resp = requests.get(url, params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        raw_dirs = data["hourly"]["winddirection_10m"]
        raw_speeds = data["hourly"]["windspeed_10m"]
    except Exception as e:
        return {
            "dominant_wind_dir_deg": None,
            "dominant_wind_dir_cardinal": None,
            "wind_facing_fraction": None,
            "mean_wind_speed_kmh": None,
            "wind_rose": None,
            "wind_classification": None,
            "data_source": "Open-Meteo ERA5",
            "date_range": f"{start_date} to {end_date}",
            "error_message": str(e),
        }

    pairs = [(d, s) for d, s in zip(raw_dirs, raw_speeds) if d is not None and s is not None]
    if not pairs:
        return {
            "dominant_wind_dir_deg": None,
            "dominant_wind_dir_cardinal": None,
            "wind_facing_fraction": None,
            "mean_wind_speed_kmh": None,
            "wind_rose": None,
            "wind_classification": None,
            "data_source": "Open-Meteo ERA5",
            "date_range": f"{start_date} to {end_date}",
            "error_message": "No valid wind data returned",
        }

    directions, speeds = zip(*pairs)

    sin_sum = sum(s * sin(radians(d)) for d, s in zip(directions, speeds))
    cos_sum = sum(s * cos(radians(d)) for d, s in zip(directions, speeds))
    dominant_dir = float(degrees(np.arctan2(sin_sum, cos_sum)) % 360)
    dominant_cardinal = azimuth_to_8pt_cardinal(dominant_dir)

    normal = np.array(trunk_normal, dtype=float)
    wind_vec = np.array([sin(radians(dominant_dir)), cos(radians(dominant_dir)), 0.0])
    wind_facing_fraction = float(max(0.0, np.dot(wind_vec, normal)))

    mean_speed_kmh = float(np.mean(speeds) * 3.6)

    sectors = {"N": 0, "NE": 0, "E": 0, "SE": 0, "S": 0, "SW": 0, "W": 0, "NW": 0}
    for d in directions:
        sectors[azimuth_to_8pt_cardinal(d)] += 1

    wind_classification = "Windward" if wind_facing_fraction > 0.5 else "Leeward"

    return {
        "dominant_wind_dir_deg": round(dominant_dir, 1),
        "dominant_wind_dir_cardinal": dominant_cardinal,
        "wind_facing_fraction": round(wind_facing_fraction, 4),
        "mean_wind_speed_kmh": round(mean_speed_kmh, 2),
        "wind_rose": sectors,
        "wind_classification": wind_classification,
        "data_source": "Open-Meteo ERA5",
        "date_range": f"{start_date} to {end_date}",
    }
