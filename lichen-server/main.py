import json
import os
import tempfile
import traceback
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
from fastapi import FastAPI, Request, UploadFile, File
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from pipeline.read_ply import read_ply
from pipeline.compute_trunk import compute_trunk
from pipeline.compute_solar import compute_solar
from pipeline.compute_wind import compute_wind
from pipeline.compute_lichen import compute_lichen

app = FastAPI(title="Lichen Analysis Server")

BASE_DIR = Path(__file__).parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

REQUIRED_FILES = ["point_cloud_raw.ply", "location.csv", "tree_gps_anchor.json"]
MAX_UPLOAD_BYTES = 500 * 1024 * 1024  # 500 MB


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse(request, "index.html", {"request": request})


@app.post("/analyze", response_class=HTMLResponse)
async def analyze(request: Request, file: UploadFile = File(...)):
    with tempfile.TemporaryDirectory() as tmpdir:
        # Save upload
        zip_path = os.path.join(tmpdir, "upload.zip")
        content = await file.read()
        if len(content) > MAX_UPLOAD_BYTES:
            return _error_page(request, "File too large (max 500 MB)")

        with open(zip_path, "wb") as f:
            f.write(content)

        # Unzip
        try:
            with zipfile.ZipFile(zip_path, "r") as zf:
                zf.extractall(tmpdir)
        except zipfile.BadZipFile:
            return _error_page(request, "Invalid ZIP file")

        # Find dataset root (may be nested in a subfolder)
        scan_dir = _find_scan_root(tmpdir, REQUIRED_FILES)
        if scan_dir is None:
            present = _list_files(tmpdir)
            missing = [f for f in REQUIRED_FILES if not any(f in p for p in present)]
            return _error_page(
                request,
                "Required files missing from ZIP",
                missing_files=missing,
                present_files=present,
            )

        errors = {}
        trunk_result = {}
        solar_result = {}
        wind_result = {}
        lichen_result = {}
        points_sample = []
        scan_timestamp = datetime.now(tz=timezone.utc).isoformat()
        tree_id = file.filename or "unknown"

        # --- Read PLY ---
        try:
            ply_path = os.path.join(scan_dir, "point_cloud_raw.ply")
            all_points = read_ply(ply_path)
            # Subsample for processing
            if len(all_points) > 50_000:
                idx = np.random.choice(len(all_points), 50_000, replace=False)
                proc_points = all_points[idx]
            else:
                proc_points = all_points
        except Exception as e:
            errors["ply"] = str(e)
            proc_points = np.empty((0, 4), dtype=np.float32)

        # --- Read location.csv ---
        try:
            loc_df = pd.read_csv(os.path.join(scan_dir, "location.csv"))
            # Try to extract scan timestamp from first row
            for col in ["timestamp", "time", "datetime"]:
                if col in loc_df.columns:
                    scan_timestamp = str(loc_df[col].iloc[0])
                    break
        except Exception as e:
            errors["location_csv"] = str(e)
            loc_df = pd.DataFrame({
                "latitude": [0.0], "longitude": [0.0],
                "altitude_asl_m": [0.0], "heading_degrees": [0.0], "slope_degrees": [0.0],
            })

        # --- Read tree_gps_anchor.json ---
        try:
            with open(os.path.join(scan_dir, "tree_gps_anchor.json")) as f:
                anchor = json.load(f)
        except Exception as e:
            errors["anchor_json"] = str(e)
            anchor = {}

        # --- Compute trunk ---
        try:
            trunk_result = compute_trunk(proc_points, anchor, loc_df)
        except Exception as e:
            errors["trunk"] = str(e)
            trunk_result = {
                "dbh_cm": None, "dbh_rmse_cm": None,
                "lean_angle_deg": 0.0, "lean_direction": "N",
                "trunk_normal": [1.0, 0.0, 0.0],
                "aspect_8pt": "N", "aspect_16pt": "N",
                "trunk_azimuth_deg": 0.0,
                "tree_lat": 0.0, "tree_lon": 0.0, "tree_alt_m": 0.0,
                "heading_deg": 0.0, "slope_deg": 0.0,
                "n_trunk_points": 0, "n_dbh_points": 0,
            }

        # --- Compute solar ---
        try:
            solar_result = compute_solar(
                trunk_result["tree_lat"], trunk_result["tree_lon"],
                trunk_result["trunk_normal"], scan_timestamp,
            )
        except Exception as e:
            errors["solar"] = str(e)
            solar_result = {"sun_facing_fraction": None, "monthly_facing": [0] * 12,
                            "peak_solar_month": None, "solar_classification": None}

        # --- Compute wind ---
        try:
            wind_result = compute_wind(
                trunk_result["tree_lat"], trunk_result["tree_lon"],
                trunk_result["trunk_normal"], scan_timestamp,
            )
        except Exception as e:
            errors["wind"] = str(e)
            wind_result = {"error_message": str(e)}

        # --- Compute lichen ---
        video_path = os.path.join(scan_dir, "rgb.mp4")
        try:
            lichen_result = compute_lichen(
                video_path if os.path.exists(video_path) else "",
                trunk_result["trunk_normal"],
                trunk_result["heading_deg"],
                trunk_result.get("dbh_cm"),
            )
        except Exception as e:
            errors["lichen"] = str(e)
            lichen_result = {"coverage_pct": None, "area_cm2": None,
                             "by_aspect": None, "n_frames_analyzed": 0,
                             "error_message": str(e)}

        # --- Subsample points for visualization (5000 max) ---
        if len(proc_points) > 0:
            vis_n = min(5000, len(proc_points))
            vis_idx = np.random.choice(len(proc_points), vis_n, replace=False)
            vis_pts = proc_points[vis_idx]
            points_sample = {
                "x": vis_pts[:, 0].tolist(),
                "y": vis_pts[:, 1].tolist(),
                "z": vis_pts[:, 2].tolist(),
            }
        else:
            points_sample = {"x": [], "y": [], "z": []}

        # --- Assemble metadata ---
        tree_metadata = {
            "tree_id": tree_id,
            "scan_timestamp": scan_timestamp,
            "trunk": trunk_result,
            "solar": solar_result,
            "wind": wind_result,
            "lichen": lichen_result,
            "errors": errors,
        }

        context = {
            "request": request,
            "tree_id": tree_id,
            "trunk": trunk_result,
            "solar": solar_result,
            "wind": wind_result,
            "lichen": lichen_result,
            "points_json": json.dumps(points_sample),
            "tree_metadata_json": json.dumps(tree_metadata, indent=2),
            "errors": errors,
            "wind_rose_json": json.dumps(wind_result.get("wind_rose") or {}),
            "monthly_facing_json": json.dumps(solar_result.get("monthly_facing") or [0] * 12),
            "lichen_by_aspect_json": json.dumps(lichen_result.get("by_aspect") or {}),
        }

        return templates.TemplateResponse(request, "dashboard.html", context)


def _find_scan_root(tmpdir: str, required: list) -> str | None:
    """Walk extracted dirs to find the folder containing all required files."""
    for root, dirs, files in os.walk(tmpdir):
        if all(f in files for f in required):
            return root
    return None


def _list_files(tmpdir: str) -> list:
    result = []
    for root, dirs, files in os.walk(tmpdir):
        for f in files:
            result.append(os.path.relpath(os.path.join(root, f), tmpdir))
    return result


def _error_page(request: Request, message: str, missing_files=None, present_files=None):
    return templates.TemplateResponse(
        request,
        "index.html",
        {
            "error": message,
            "missing_files": missing_files or [],
            "present_files": present_files or [],
        },
        status_code=422,
    )
