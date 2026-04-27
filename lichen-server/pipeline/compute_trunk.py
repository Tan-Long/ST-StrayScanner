import numpy as np
import pandas as pd
from numpy.linalg import lstsq, norm, eigh


def azimuth_to_8pt_cardinal(deg: float) -> str:
    dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    idx = int((deg + 22.5) / 45) % 8
    return dirs[idx]


def azimuth_to_16pt_cardinal(deg: float) -> str:
    dirs = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
    ]
    idx = int((deg + 11.25) / 22.5) % 16
    return dirs[idx]


def circular_mean(angles_deg) -> float:
    rads = np.radians(angles_deg)
    return float(np.degrees(np.arctan2(np.nanmean(np.sin(rads)), np.nanmean(np.cos(rads)))) % 360)


def compute_trunk(points: np.ndarray, anchor: dict, location_df: pd.DataFrame) -> dict:
    # 1. Filter trunk band
    trunk_mask = (points[:, 2] >= 0.3) & (points[:, 2] <= 2.0)
    trunk_pts = points[trunk_mask]
    if len(trunk_pts) < 50:
        raise ValueError(f"Not enough trunk points: {len(trunk_pts)} (need ≥50)")

    # 2. DBH — circle fit at breast height
    dbh_mask = (points[:, 2] >= 1.2) & (points[:, 2] <= 1.4)
    dbh_pts = points[dbh_mask]
    n_dbh = len(dbh_pts)
    dbh_cm = None
    dbh_rmse_cm = None

    if n_dbh >= 20:
        x, y = dbh_pts[:, 0], dbh_pts[:, 1]
        A = np.column_stack([x, y, np.ones(n_dbh)])
        b = -(x ** 2 + y ** 2)
        result, _, _, _ = lstsq(A, b, rcond=None)
        c, d, e = result
        cx = -c / 2
        cy = -d / 2
        r2 = cx ** 2 + cy ** 2 - e
        if r2 > 0:
            radius = np.sqrt(r2)
            dbh_cm = float(radius * 2 * 100)
            residuals = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) - radius
            dbh_rmse_cm = float(np.sqrt(np.mean(residuals ** 2)) * 100)

    # 3. Trunk axis via PCA
    xyz = trunk_pts[:, :3]
    centered = xyz - xyz.mean(axis=0)
    cov = np.cov(centered.T)
    eigenvalues, eigenvectors = eigh(cov)
    # eigh returns ascending order; largest is last
    principal_axis = eigenvectors[:, -1]
    if principal_axis[2] < 0:
        principal_axis = -principal_axis

    # 4. Lean angle and direction
    lean_angle_deg = float(np.degrees(np.arccos(np.clip(abs(np.dot(principal_axis, [0, 0, 1])), 0, 1))))
    horiz = principal_axis[:2]
    h_norm = norm(horiz)
    if h_norm > 1e-9:
        horiz_unit = horiz / h_norm
        lean_azimuth_deg = float(np.degrees(np.arctan2(horiz_unit[0], horiz_unit[1])) % 360)
    else:
        lean_azimuth_deg = 0.0
    lean_direction = azimuth_to_16pt_cardinal(lean_azimuth_deg)

    # 5. Trunk normal
    cross = np.cross(principal_axis, [0, 0, 1])
    cross_norm = norm(cross)
    if cross_norm < 1e-9:
        normal = np.array([1.0, 0.0, 0.0])
    else:
        normal = cross / cross_norm
    trunk_normal = normal.tolist()

    # 6. Aspect
    azimuth = float(np.degrees(np.arctan2(normal[0], normal[1])) % 360)
    aspect_8pt = azimuth_to_8pt_cardinal(azimuth)
    aspect_16pt = azimuth_to_16pt_cardinal(azimuth)

    # 7. Tree GPS
    def _safe(val):
        return val if val is not None else float("nan")

    anchor_lat = anchor.get("anchor_lat")
    anchor_lon = anchor.get("anchor_lon")
    anchor_alt = anchor.get("anchor_alt")

    tree_lat = float(anchor_lat) if anchor_lat is not None else float(location_df["latitude"].mean())
    tree_lon = float(anchor_lon) if anchor_lon is not None else float(location_df["longitude"].mean())

    alt_col = "altitude_asl_m" if "altitude_asl_m" in location_df.columns else "altitude"
    tree_alt = float(anchor_alt) if anchor_alt is not None else float(location_df[alt_col].mean())

    # 8. Heading and slope
    heading_deg = circular_mean(location_df["heading_degrees"]) if "heading_degrees" in location_df.columns else 0.0
    slope_deg = float(location_df["slope_degrees"].mean()) if "slope_degrees" in location_df.columns else 0.0

    return {
        "dbh_cm": dbh_cm,
        "dbh_rmse_cm": dbh_rmse_cm,
        "lean_angle_deg": lean_angle_deg,
        "lean_direction": lean_direction,
        "trunk_normal": trunk_normal,
        "aspect_8pt": aspect_8pt,
        "aspect_16pt": aspect_16pt,
        "trunk_azimuth_deg": azimuth,
        "tree_lat": tree_lat,
        "tree_lon": tree_lon,
        "tree_alt_m": tree_alt,
        "heading_deg": heading_deg,
        "slope_deg": slope_deg,
        "n_trunk_points": int(len(trunk_pts)),
        "n_dbh_points": int(n_dbh),
    }
