# Kế hoạch dự án địa y — Các phase tiếp theo

## Tổng quan timeline

```
Phase 1 (hiện tại)  → Thu thập thực địa        → 500–600 cây · 2–3 sites
Phase 2             → Xử lý data local          → Python pipeline per-tree
Phase 3             → Human-in-the-Loop         → Validation 3 checkpoint
Phase 4             → Server pipeline            → Upload ZIP → nhận kết quả
Phase 5             → Phân tích thống kê         → GLM · publication
```

---

## Phase 1 — Thu thập thực địa (hiện tại)

**Mục tiêu:** 500–600 cây tại 2–3 sites, mỗi cây có đủ 9 file output.

**Checklist mỗi cây:**
- [ ] point_cloud_raw.ply > 0 bytes
- [ ] location.csv — 100+ rows (≥ vài giây scan)
- [ ] location.json — frame count khớp với location.csv
- [ ] frame_transforms.csv — khớp frame count
- [ ] tree_gps_anchor.json — anchor_lat/lon không null
- [ ] RGB frames / depth đủ
- [ ] HITL #1 passed tại thực địa (preview OK)

**Cấu trúc thư mục output:**
```
field_data/
  site_01_thanh_hoa/
    tree_001/
      point_cloud_raw.ply
      location.csv
      location.json
      frame_transforms.csv
      tree_gps_anchor.json
      odometry.csv
      imu.csv
      rgb.mp4
    tree_002/
    ...
  site_02_yen_bai/
  site_03_lao_cai/
```

---

## Phase 2 — Xử lý data local (Python pipeline)

**Mục tiêu:** Chạy `compute_variables.py` cho từng cây, output `tree_metadata.json`.

### 2.1. Script `compute_variables.py`

```
Input:  <tree_folder>/
Output: <tree_folder>/tree_metadata.json

Các bước:
1. Đọc tree_gps_anchor.json + location.csv → tree GPS (lat/lon/alt)
2. Đọc point_cloud_raw.ply → RANSAC cylinder → DBH
3. PCA trunk axis → lean angle, trunk normal, aspect
4. Đọc location.csv → mean heading, mean slope
5. pysolar (lat/lon + timestamp) → solar azimuth/elevation 12 tháng
   → sun_facing_fraction = dot(solar_vec, trunk_normal)
6. Open-Meteo IFS API (lat/lon + date range) → wind direction
   → wind_facing_fraction = dot(wind_vec, trunk_normal)
7. HSV + texture segmentation trên RGB frames → lichen coverage per aspect
8. Ghi tree_metadata.json
```

### 2.2. Script `fetch_site_variables.py`

```
Input:  site bounding box (lat/lon min/max), date range
Output: site_variables.json

Các bước:
1. Google Earth Engine API → NDVI mean 5 năm (Sentinel-2, 10m)
2. ERA5-Land API → mean temp, humidity, rain cho date range
3. Ghi site_variables.json
```

### 2.3. Script `build_dataset.py`

```
Input:  field_data/ (toàn bộ thư mục)
Output: dataset.csv, dataset.json

Các bước:
1. Đọc tất cả tree_metadata.json
2. Join với site_variables.json theo site_id
3. Export dataset.csv (mỗi hàng = 1 cây, tất cả biến)
4. Export dataset.json (nested, giữ phân bố địa y per aspect)
```

---

## Phase 3 — Human-in-the-Loop validation

### HITL #2 — Labeling UI

Cần viết web app đơn giản (Flask hoặc Streamlit) để review polygon confidence thấp:

```
Input:  tree_folder/ + lichen_segments/ (output từ HSV step)
UI:     Hiển thị mesh màu + RGB overlay
        Với mỗi polygon confidence < 70%:
          → Người review click: ✅ Địa y | ❌ Không phải | 🗑️ Loại
        Majority vote: 2/3 người accept → label confirmed
Output: lichen_labels_validated.json
```

### HITL #3 — Spatial validation

Script `validate_spatial.py` tạo report HTML cho từng cây:
- Hiển thị trunk axis vector trên map
- So sánh slope IMU với DEM xung quanh (nếu có)
- Flag cây có lean angle > 30° hoặc aspect inconsistent với địa hình

---

## Phase 4 — Server pipeline (Upload ZIP → nhận kết quả)

**Mục tiêu:** Upload ZIP một cây hoặc toàn bộ site → server xử lý tự động → trả về `tree_metadata.json` + báo cáo PDF.

### 4.1. Kiến trúc server

```
Client (iPhone / Mac)
    │
    │  POST /upload  (multipart ZIP)
    ▼
FastAPI server
    │
    ├── Unzip → validate structure
    ├── Queue job (Redis / SQLite)
    │
    ▼
Worker (Celery hoặc subprocess)
    ├── compute_variables.py
    ├── fetch_site_variables.py (cache 24h)
    ├── HSV segmentation
    ├── Generate report PDF
    │
    ▼
    ├── POST /status/<job_id>  → { status, progress }
    └── GET  /result/<job_id>  → ZIP (tree_metadata.json + report.pdf)
```

### 4.2. API endpoints

```
POST /upload
  Body: multipart/form-data
    file: <tree_scan.zip>
    site_id: "site_01_thanh_hoa"
    tree_id: "tree_042"
  Response: { job_id: "abc123", status: "queued" }

GET /status/<job_id>
  Response: {
    job_id, status, progress_pct,
    steps_done: ["gps", "dbh", "solar", ...],
    eta_seconds
  }

GET /result/<job_id>
  Response: ZIP containing:
    tree_metadata.json
    lichen_coverage_report.pdf
    point_cloud_colored.ply  (địa y highlight)
    thumbnails/              (RGB frames key)

GET /dataset/<site_id>
  Response: ZIP containing:
    dataset.csv
    dataset.json
    site_variables.json
```

### 4.3. Cấu trúc ZIP upload

```
tree_042.zip
  ├── point_cloud_raw.ply      (required)
  ├── location.csv             (required)
  ├── location.json            (required)
  ├── frame_transforms.csv     (required)
  ├── tree_gps_anchor.json     (required)
  ├── rgb.mp4                  (required for lichen detection)
  ├── odometry.csv             (optional)
  └── imu.csv                  (optional)
```

### 4.4. Tech stack

```
Server:   FastAPI (Python) — nhẹ, async, tự sinh docs
Queue:    Redis + Celery (hoặc SQLite + subprocess nếu scale nhỏ)
Storage:  Local disk / S3-compatible (MinIO)
Deploy:   Docker Compose (1 container API + 1 container worker)
Hosting:  VPS Ubuntu (4 CPU, 8GB RAM đủ cho 10 jobs song song)
```

---

## Phase 5 — Phân tích thống kê và publication

### 5.1. Dataset cuối

```
dataset.csv — mỗi hàng = 1 cây, các cột:
  tree_id, site_id,
  lat, lon, altitude_m,
  heading_deg, slope_deg, aspect_cardinal,
  dbh_cm, lean_angle_deg,
  sun_facing_fraction, wind_facing_fraction,
  lichen_coverage_pct, lichen_area_cm2,
  lichen_upslope_pct, lichen_downslope_pct,
  lichen_north_pct, lichen_south_pct,
  lichen_east_pct, lichen_west_pct,
  ndvi_5yr_mean,       [per-site]
  era5_temp_mean,      [per-site]
  era5_humidity_mean,  [per-site]
  era5_rain_annual,    [per-site]
  dominant_wind_dir    [per-site]
```

### 5.2. Mô hình thống kê

```python
# GLM với response variable là lichen coverage
model = smf.glm(
    formula="""lichen_coverage_pct ~
        sun_facing_fraction +
        wind_facing_fraction +
        slope_deg +
        C(aspect_cardinal) +
        dbh_cm +
        altitude_m +
        ndvi_5yr_mean +
        era5_rain_annual""",
    data=df,
    family=sm.families.Binomial()  # hoặc Gamma nếu continuous
).fit()
```

### 5.3. Visualizations

- Map phân bố địa y theo lat/lon (folium / kepler.gl)
- Polar plot: lichen coverage theo 8 hướng vỏ cây
- Regression plot: lichen ~ sun_facing_fraction
- Heatmap: correlation matrix toàn bộ biến

---

## Prompt Claude Code — Build server pipeline

Paste prompt này vào Claude Code trong thư mục mới `lichen-server/`:

---

```
Create a FastAPI server that processes Stray Scanner tree scan data.
The server accepts ZIP uploads and returns processed tree_metadata.json.

## Project structure to create

lichen-server/
  api/
    main.py          — FastAPI app, endpoints
    models.py        — Pydantic schemas
    worker.py        — processing pipeline functions
    pipeline/
      compute_dbh.py      — RANSAC cylinder fitting from PLY
      compute_trunk.py    — PCA trunk axis, normal, aspect
      compute_solar.py    — pysolar solar exposure per month
      compute_wind.py     — Open-Meteo wind fetch + dot product
      compute_lichen.py   — HSV + texture segmentation on frames
      fetch_remote.py     — ERA5-Land + Sentinel-2 NDVI (stub OK)
  storage/
    uploads/         — incoming ZIPs
    results/         — output ZIPs
    jobs.db          — SQLite job tracking
  requirements.txt
  Dockerfile
  docker-compose.yml
  README.md

## API endpoints (implement all)

POST /upload
  - Accept multipart/form-data: file (ZIP), site_id (str), tree_id (str)
  - Validate ZIP contains: point_cloud_raw.ply, location.csv,
    location.json, frame_transforms.csv, tree_gps_anchor.json, rgb.mp4
  - Return: { job_id, status: "queued", message }
  - On missing required files: 422 with list of missing files

GET /status/{job_id}
  - Return: { job_id, status, progress_pct, steps_done[], eta_seconds, error? }
  - Status values: queued | processing | done | failed

GET /result/{job_id}
  - If done: stream ZIP file (tree_metadata.json + point_cloud_colored.ply)
  - If not done: 202 with current status
  - If failed: 500 with error detail

GET /dataset/{site_id}
  - Aggregate all done jobs for site_id
  - Return ZIP: dataset.csv + dataset.json

GET /health
  - Return: { status: "ok", jobs_queued, jobs_processing, jobs_done }

## Processing pipeline (worker.py)

Run these steps in order, updating job progress after each:

Step 1 — Unzip and validate (progress: 5%)
  Unzip to storage/uploads/<job_id>/
  Check all required files exist

Step 2 — GPS and orientation (progress: 15%)
  Read tree_gps_anchor.json → anchor coordinates
  Read location.csv → mean lat/lon/altitude, mean heading_degrees, mean slope_degrees
  Compute tree_lat, tree_lon, tree_alt (anchor + ARKit offset from frame_transforms.csv)

Step 3 — DBH from point cloud (progress: 30%)
  Read point_cloud_raw.ply using numpy (pure numpy, no open3d dependency)
  Slice points at z = 1.2m to 1.4m (breast height cross-section)
  Fit circle using least-squares (Pratt method or simple RANSAC loop)
  Output: dbh_cm, fit_rmse_cm

Step 4 — Trunk axis and aspect (progress: 45%)
  Apply PCA to trunk point cloud (filter z = 0.3m to 2.0m)
  Principal axis → lean_angle_deg, lean_direction
  Trunk normal vector (perpendicular to axis, pointing outward)
  Aspect classification: N/NE/E/SE/S/SW/W/NW based on trunk_normal dot compass vectors

Step 5 — Solar exposure (progress: 60%)
  Install pysolar if not present
  For each month 1-12, compute:
    solar_azimuth = get_azimuth(lat, lon, datetime(year, month, 15, 12, 0, tzinfo=utc))
    solar_elevation = get_altitude(lat, lon, datetime(year, month, 15, 12, 0, tzinfo=utc))
    solar_vec = [sin(azimuth)*cos(elevation), cos(azimuth)*cos(elevation), sin(elevation)]
    monthly_facing = max(0, dot(solar_vec, trunk_normal))
  sun_facing_fraction = mean(monthly_facing) across 12 months

Step 6 — Wind exposure (progress: 70%)
  Call Open-Meteo historical API:
    URL: https://archive.open-meteo.com/v1/archive
    Params: latitude, longitude, start_date (1yr ago), end_date (today)
    hourly: winddirection_10m, windspeed_10m
    models: era5_seamless
  Compute dominant_wind_dir = circular mean of winddirection_10m
  wind_vec = [sin(dominant_wind_dir_rad), cos(dominant_wind_dir_rad), 0]
  wind_facing_fraction = max(0, dot(wind_vec, trunk_normal))
  Cache API response for 24h by (lat_rounded_1dp, lon_rounded_1dp)

Step 7 — Lichen detection (progress: 85%)
  Extract frames from rgb.mp4 (every 10th frame using subprocess ffmpeg)
  For each frame:
    Convert BGR to HSV
    Apply adaptive HSV threshold for lichen (greenish-gray, low saturation)
    Apply texture filter (simple LBP proxy using local variance)
    Compute confidence = hsv_score * texture_score
  Map detections to trunk aspect using camera heading + trunk normal
  Output: lichen_coverage_pct, lichen_area_cm2,
          lichen_by_aspect: {N, NE, E, SE, S, SW, W, NW: pct}
          mean_confidence

Step 8 — Write output (progress: 95%)
  Write tree_metadata.json with all computed fields
  Write colored PLY (add lichen label as 4th channel or separate color)
  Zip results to storage/results/<job_id>.zip
  Update job status to "done"

## tree_metadata.json schema

{
  "tree_id": str,
  "site_id": str,
  "scan_timestamp": str (ISO8601),
  "tree_position": {
    "latitude": float, "longitude": float, "altitude_m": float,
    "gps_accuracy_m": float
  },
  "orientation": {
    "heading_deg": float, "heading_cardinal": str,
    "slope_deg": float
  },
  "trunk_geometry": {
    "dbh_cm": float, "dbh_fit_rmse_cm": float,
    "lean_angle_deg": float, "lean_direction": str,
    "trunk_normal": [float, float, float],
    "aspect_cardinal": str
  },
  "solar_exposure": {
    "sun_facing_fraction": float,
    "monthly_facing": [float x12],
    "method": "pysolar"
  },
  "wind_exposure": {
    "dominant_wind_dir_deg": float,
    "wind_facing_fraction": float,
    "data_source": "open-meteo-era5"
  },
  "lichen": {
    "coverage_pct": float,
    "area_cm2": float,
    "mean_confidence": float,
    "by_aspect": {"N": float, "NE": float, ...},
    "upslope_pct": float,
    "downslope_pct": float
  },
  "pipeline_version": "1.0.0",
  "processing_timestamp": str
}

## Job tracking (SQLite, jobs.db)

Table: jobs
  job_id TEXT PRIMARY KEY
  site_id TEXT
  tree_id TEXT
  status TEXT  (queued|processing|done|failed)
  progress_pct INTEGER
  steps_done TEXT  (JSON array)
  error_message TEXT
  created_at TEXT
  updated_at TEXT
  result_path TEXT

## requirements.txt (must include)

fastapi>=0.110.0
uvicorn[standard]>=0.29.0
python-multipart>=0.0.9
pysolar>=0.11
numpy>=1.26
scipy>=1.13
requests>=2.31
aiofiles>=23.2

## Dockerfile

FROM python:3.11-slim
RUN apt-get update && apt-get install -y ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]

## docker-compose.yml

version: "3.9"
services:
  api:
    build: .
    ports: ["8000:8000"]
    volumes:
      - ./storage:/app/storage
    environment:
      - MAX_CONCURRENT_JOBS=3
      - CACHE_TTL_HOURS=24

## README.md

Include:
1. Quick start: docker compose up
2. Upload example using curl
3. Poll status example
4. Download result example
5. Input ZIP format specification
6. tree_metadata.json field descriptions
7. Known limitations (ERA5 9km resolution, HSV accuracy ~70%)

## Constraints

- Pure Python only — no open3d, no GDAL, no heavy GIS libs
- PLY reading: implement simple binary PLY parser with numpy (no external PLY lib)
- FFmpeg: assume installed in Docker, call via subprocess
- No authentication required (internal research use)
- All processing synchronous within the request worker (no Celery/Redis needed at this scale)
  Use asyncio.create_task or ThreadPoolExecutor for background processing
- Handle all errors gracefully — never crash the server, always update job status to "failed"
- Log each step with timestamp to stdout
- Test with the sample data files: location.csv, location.json, tree_gps_anchor.json
  that may exist in the project (check parent directory)
```
