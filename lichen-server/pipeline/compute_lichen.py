import os
import subprocess
import tempfile
import warnings
from glob import glob
from math import pi

import numpy as np

try:
    import cv2
    CV2_OK = True
except ImportError:
    CV2_OK = False

from .compute_trunk import azimuth_to_8pt_cardinal


def compute_lichen(video_path: str, trunk_normal: list, heading_deg: float, dbh_cm: float = None) -> dict:
    if not CV2_OK:
        return {
            "coverage_pct": None,
            "area_cm2": None,
            "by_aspect": None,
            "n_frames_analyzed": 0,
            "method": "HSV_adaptive",
            "note": "opencv not available",
            "error_message": "cv2 not installed",
        }

    if not video_path or not os.path.exists(video_path):
        return {
            "coverage_pct": None,
            "area_cm2": None,
            "by_aspect": None,
            "n_frames_analyzed": 0,
            "method": "HSV_adaptive",
            "note": "Video not available",
            "error_message": "rgb.mp4 not found",
        }

    frame_coverages = []

    with tempfile.TemporaryDirectory() as tmpdir:
        cmd = [
            "ffmpeg", "-i", video_path,
            "-vf", "select=not(mod(n\\,15))",
            "-vsync", "0",
            f"{tmpdir}/frame_%04d.jpg",
            "-loglevel", "quiet",
        ]
        try:
            subprocess.run(cmd, check=True, timeout=120)
        except Exception as e:
            return {
                "coverage_pct": None,
                "area_cm2": None,
                "by_aspect": None,
                "n_frames_analyzed": 0,
                "method": "HSV_adaptive",
                "note": "ffmpeg extraction failed",
                "error_message": str(e),
            }

        frames = sorted(glob(f"{tmpdir}/frame_*.jpg"))[:30]

        if not frames:
            return {
                "coverage_pct": 0.0,
                "area_cm2": 0.0,
                "by_aspect": {d: 0.0 for d in ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]},
                "n_frames_analyzed": 0,
                "method": "HSV_adaptive",
                "note": "No frames extracted from video",
            }

        lower1 = np.array([30, 10, 80], dtype=np.uint8)
        upper1 = np.array([90, 80, 200], dtype=np.uint8)
        lower2 = np.array([0, 0, 120], dtype=np.uint8)
        upper2 = np.array([180, 30, 220], dtype=np.uint8)

        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))

        for frame_path in frames:
            img = cv2.imread(frame_path)
            if img is None:
                continue
            hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
            mask1 = cv2.inRange(hsv, lower1, upper1)
            mask2 = cv2.inRange(hsv, lower2, upper2)
            mask = cv2.bitwise_or(mask1, mask2)
            mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
            mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
            coverage_pct = (float(mask.sum()) / 255.0) / mask.size * 100.0
            frame_coverages.append(coverage_pct)

    lichen_coverage_pct = float(np.mean(frame_coverages)) if frame_coverages else 0.0

    # Aspect distribution estimate from trunk normal
    normal = np.array(trunk_normal, dtype=float)
    trunk_azimuth = float(np.degrees(np.arctan2(normal[0], normal[1])) % 360)
    primary = azimuth_to_8pt_cardinal(trunk_azimuth)
    dirs8 = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    primary_idx = dirs8.index(primary)
    by_aspect = {d: 0.0 for d in dirs8}
    by_aspect[dirs8[primary_idx]] = lichen_coverage_pct * 0.60
    by_aspect[dirs8[(primary_idx - 1) % 8]] = lichen_coverage_pct * 0.20
    by_aspect[dirs8[(primary_idx + 1) % 8]] = lichen_coverage_pct * 0.20

    # Estimate surface area
    radius_cm = (dbh_cm / 2.0) if dbh_cm else 10.0
    circumference_cm = 2 * pi * radius_cm
    height_cm = 150.0  # 1.5m scan height
    surface_area_cm2 = circumference_cm * height_cm
    lichen_area_cm2 = (lichen_coverage_pct / 100.0) * surface_area_cm2

    return {
        "coverage_pct": round(lichen_coverage_pct, 2),
        "area_cm2": round(lichen_area_cm2, 1),
        "by_aspect": {k: round(v, 2) for k, v in by_aspect.items()},
        "n_frames_analyzed": len(frame_coverages),
        "method": "HSV_adaptive",
        "note": "Aspect distribution is estimated from trunk normal",
    }
