# Lichen Analysis Server — Claude Code Prompt

Create a complete web application deployable on Railway.app.
Users upload a ZIP of one Stray Scanner tree scan and receive
an interactive HTML dashboard with analysis results.

---

## Project structure

```
lichen-server/
  main.py                  — FastAPI app + all routes
  pipeline/
    __init__.py
    read_ply.py            — pure numpy binary PLY reader
    compute_trunk.py       — PCA trunk axis, DBH, normal, aspect
    compute_solar.py       — pysolar monthly solar exposure
    compute_wind.py        — Open-Meteo wind fetch + exposure
    compute_lichen.py      — HSV segmentation from rgb.mp4 frames
  templates/
    index.html             — upload page
    dashboard.html         — results dashboard
  static/
    style.css
  requirements.txt
  Dockerfile
  railway.json
  README.md
```

---

## main.py — FastAPI app

```python
Routes:
  GET  /                    → index.html (upload form)
  POST /analyze             → accept ZIP, run pipeline, return dashboard
  GET  /health              → { status: ok }

On POST /analyze:
1. Accept multipart ZIP (max 500MB)
2. Unzip to temp dir
3. Validate required files:
   - point_cloud_raw.ply
   - location.csv
   - tree_gps_anchor.json
   If missing → return 422 with friendly error page listing missing files
4. Run pipeline steps in sequence (show progress via SSE or just wait)
5. Render dashboard.html with all results
6. Clean up temp dir

Use Jinja2Templates for HTML rendering.
Use python-multipart for file upload.
Keep everything in-process — no Celery, no Redis, no background tasks.
Processing time < 60s for typical scan.
```

---

## pipeline/read_ply.py

```
Implement a pure numpy binary PLY reader.
NO external PLY libraries.

Function: read_ply(filepath) -> np.ndarray shape (N, 4) [x, y, z, confidence]

PLY format from Stray Scanner:
- ASCII header ending with "end_header\n"
- Binary little-endian payload
- 4 x float32 per vertex: x, y, z, confidence

Steps:
1. Open file in binary mode
2. Read lines until b"end_header\n"
3. Parse header for element vertex count
4. Read remaining bytes as float32 little-endian
5. Reshape to (N, 4)
6. Return array

Handle edge cases:
- Empty PLY (0 vertices) → return empty array with warning
- Corrupted header → raise ValueError with clear message
```

---

## pipeline/compute_trunk.py

```
Function: compute_trunk(points: np.ndarray, anchor: dict, location_df: pd.DataFrame) -> dict

Input:
  points     — (N,4) array from read_ply [x,y,z,confidence]
  anchor     — dict from tree_gps_anchor.json
  location_df — pandas DataFrame from location.csv

Steps:

1. Filter trunk band: keep points where 0.3 <= z <= 2.0
   If fewer than 50 points → raise ValueError("Not enough trunk points")

2. DBH — cross-section at breast height:
   Slice z = 1.2 to 1.4m → get (x,y) coords
   Fit circle using algebraic least-squares (Pratt method):
     Build matrix A = [x, y, ones] and vector b = -(x²+y²)
     Solve least squares: [c, d, e] = lstsq(A, b)
     center_x = -c/2, center_y = -d/2
     radius = sqrt(center_x²+center_y²-e)
     dbh_cm = radius * 2 * 100
   Compute fit RMSE in cm
   If fewer than 20 points at breast height → dbh_cm = None, rmse = None

3. Trunk axis via PCA:
   Center the trunk band points (subtract mean)
   Compute covariance matrix of (x,y,z)
   Eigendecomposition → sort by eigenvalue descending
   principal_axis = eigenvector with largest eigenvalue
   Ensure principal_axis points upward (z component > 0), flip if not

4. Lean angle and direction:
   lean_angle_deg = degrees(arccos(abs(dot(principal_axis, [0,0,1]))))
   horizontal_component = principal_axis[:2] / norm(principal_axis[:2])
   lean_azimuth_deg = degrees(arctan2(horizontal_component[0], horizontal_component[1])) % 360
   lean_direction = azimuth_to_16pt_cardinal(lean_azimuth_deg)

5. Trunk normal vector:
   normal = cross(principal_axis, [0,0,1])
   normal = normal / norm(normal)
   If norm is near zero (vertical tree) → normal = [1,0,0]
   trunk_normal = normal.tolist()

6. Aspect classification:
   azimuth = degrees(arctan2(normal[0], normal[1])) % 360
   aspect_8pt = azimuth_to_8pt_cardinal(azimuth)
   aspect_16pt = azimuth_to_16pt_cardinal(azimuth)

7. Tree GPS from anchor + ARKit origin:
   tree_lat = anchor["anchor_lat"] if not None else mean(location_df["latitude"])
   tree_lon = anchor["anchor_lon"] if not None else mean(location_df["longitude"])
   tree_alt = anchor["anchor_alt"] if not None else mean(location_df["altitude_asl_m"])

8. Mean heading and slope from location.csv:
   heading_deg = circular_mean(location_df["heading_degrees"])
   slope_deg = location_df["slope_degrees"].mean()

Return dict:
{
  "dbh_cm": float or None,
  "dbh_rmse_cm": float or None,
  "lean_angle_deg": float,
  "lean_direction": str,
  "trunk_normal": [float, float, float],
  "aspect_8pt": str,
  "aspect_16pt": str,
  "trunk_azimuth_deg": float,
  "tree_lat": float,
  "tree_lon": float,
  "tree_alt_m": float,
  "heading_deg": float,
  "slope_deg": float,
  "n_trunk_points": int,
  "n_dbh_points": int
}

Helper functions (implement in same file):
  azimuth_to_8pt_cardinal(deg) -> str   (N/NE/E/SE/S/SW/W/NW)
  azimuth_to_16pt_cardinal(deg) -> str  (N/NNE/NE/.../NNW)
  circular_mean(angles_deg) -> float    (use sin/cos mean)
```

---

## pipeline/compute_solar.py

```
Function: compute_solar(lat, lon, trunk_normal, scan_timestamp_iso) -> dict

Install pysolar: already in requirements.txt

Steps:
1. Parse scan_timestamp_iso to get year (use for monthly calculations)
2. For each month 1-12:
   dt = datetime(year, month, 15, 6, 0, tzinfo=timezone.utc)  # 6am UTC ~ noon local VN
   azimuth = get_azimuth(lat, lon, dt)
   elevation = get_altitude(lat, lon, dt)
   if elevation < 0: monthly_facing.append(0.0); continue  # sun below horizon
   solar_vec = [
     sin(radians(azimuth)) * cos(radians(elevation)),
     cos(radians(azimuth)) * cos(radians(elevation)),
     sin(radians(elevation))
   ]
   facing = max(0.0, dot(solar_vec, trunk_normal))
   monthly_facing.append(round(facing, 4))

3. sun_facing_fraction = mean(monthly_facing)

4. Peak solar month = month with highest facing value
   month_names = ["Jan","Feb","Mar","Apr","May","Jun",
                  "Jul","Aug","Sep","Oct","Nov","Dec"]

Return:
{
  "sun_facing_fraction": float,        # 0.0–1.0
  "monthly_facing": [float x12],       # Jan–Dec
  "peak_solar_month": str,
  "solar_classification": str          # "Sun-facing" if > 0.5 else "Shade-facing"
}
```

---

## pipeline/compute_wind.py

```
Function: compute_wind(lat, lon, trunk_normal, scan_date_iso) -> dict

Steps:
1. Compute date range: 1 year ending at scan_date_iso
   start_date = (parse(scan_date_iso) - timedelta(days=365)).strftime("%Y-%m-%d")
   end_date = parse(scan_date_iso).strftime("%Y-%m-%d")

2. Call Open-Meteo archive API:
   url = "https://archive.open-meteo.com/v1/archive"
   params = {
     "latitude": lat, "longitude": lon,
     "start_date": start_date, "end_date": end_date,
     "hourly": "winddirection_10m,windspeed_10m",
     "models": "era5_seamless",
     "timezone": "Asia/Bangkok"
   }
   response = requests.get(url, params=params, timeout=30)

3. Parse response:
   directions = response.json()["hourly"]["winddirection_10m"]
   speeds = response.json()["hourly"]["windspeed_10m"]
   Filter out None values (zip directions+speeds, keep both non-None)

4. Dominant wind direction (circular mean weighted by speed):
   sin_sum = sum(speed * sin(radians(d)) for d, speed in zip(directions, speeds))
   cos_sum = sum(speed * cos(radians(d)) for d, speed in zip(directions, speeds))
   dominant_dir = degrees(arctan2(sin_sum, cos_sum)) % 360

5. Wind-facing fraction:
   wind_vec = [sin(radians(dominant_dir)), cos(radians(dominant_dir)), 0.0]
   wind_vec = wind_vec / norm(wind_vec)
   wind_facing_fraction = max(0.0, dot(wind_vec, trunk_normal))

6. Mean wind speed:
   mean_speed_kmh = mean(speeds) * 3.6

7. Wind rose — 8 sectors (counts):
   sectors = {N:0, NE:0, E:0, SE:0, S:0, SW:0, W:0, NW:0}
   for d in directions: sectors[azimuth_to_8pt(d)] += 1

Return:
{
  "dominant_wind_dir_deg": float,
  "dominant_wind_dir_cardinal": str,
  "wind_facing_fraction": float,
  "mean_wind_speed_kmh": float,
  "wind_rose": {N: int, NE: int, ...},
  "wind_classification": str,  # "Windward" if > 0.5 else "Leeward"
  "data_source": "Open-Meteo ERA5",
  "date_range": str
}

On API error or timeout → return all None values with error_message field.
```

---

## pipeline/compute_lichen.py

```
Function: compute_lichen(video_path, trunk_normal, heading_deg) -> dict

Uses: cv2 (opencv-python-headless), numpy
ffmpeg must be available in Docker

Steps:

1. Extract frames using ffmpeg subprocess:
   cmd = ["ffmpeg", "-i", video_path, "-vf", "select=not(mod(n\\,15))",
          "-vsync", "0", f"{tmpdir}/frame_%04d.jpg", "-loglevel", "quiet"]
   subprocess.run(cmd, check=True)
   frames = sorted(glob(f"{tmpdir}/frame_*.jpg"))
   If no frames or video not found → return empty result

2. For each frame:
   img = cv2.imread(frame_path)
   hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)

   Lichen HSV range (grayish-green, low saturation):
   lower1 = [30, 10, 80]   upper1 = [90, 80, 200]   (greenish lichen)
   lower2 = [0,  0,  120]  upper2 = [180, 30, 220]  (pale/white lichen)

   mask1 = cv2.inRange(hsv, lower1, upper1)
   mask2 = cv2.inRange(hsv, lower2, upper2)
   mask = cv2.bitwise_or(mask1, mask2)

   Apply morphological cleanup:
   kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5,5))
   mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
   mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)

   coverage_pct = (mask.sum()/255) / mask.size * 100
   frame_coverages.append(coverage_pct)

3. Mean coverage across all frames:
   lichen_coverage_pct = mean(frame_coverages) if frame_coverages else 0.0

4. Aspect distribution:
   Since we don't have per-frame camera heading in this simplified version,
   distribute lichen proportionally across aspects based on trunk_normal direction:
   primary_aspect = azimuth_to_8pt(trunk_azimuth)
   Assign 60% to primary aspect, 20% each to adjacent aspects
   (This is a simplification — note it in output as "estimated")

5. Estimate area:
   Assume scan covers ~1.5m height × π×r circumference of trunk
   lichen_area_cm2 = lichen_coverage_pct/100 × estimated_surface_area_cm2

Return:
{
  "coverage_pct": float,
  "area_cm2": float,
  "by_aspect": {"N": float, "NE": float, ...},  # pct values
  "n_frames_analyzed": int,
  "method": "HSV_adaptive",
  "note": "Aspect distribution is estimated from trunk normal"
}

If cv2 not available or video missing → return coverage_pct=None with error_message.
```

---

## templates/index.html

Clean, minimal upload page:
- Title: "Lichen Analysis — Stray Scanner"
- Drag-and-drop zone OR click to select ZIP file
- Show selected filename
- "Analyze" button
- Progress indicator while processing (CSS animation)
- Required files checklist shown below form
- On error: show friendly message with list of missing files
- Style: clean white, blue accent (#2E75B6), Vietnamese + English labels

```html
Structure:
<header> project title + subtitle </header>
<main>
  <div class="upload-card">
    <div class="dropzone" id="dropzone">
      📁 Kéo thả file ZIP hoặc click để chọn
    </div>
    <input type="file" id="fileInput" accept=".zip" hidden>
    <div id="fileName" class="file-name"></div>
    <button id="analyzeBtn" disabled>🔬 Phân tích</button>
    <div id="progress" class="progress hidden">
      <div class="spinner"></div>
      <span>Đang xử lý... vui lòng đợi</span>
    </div>
  </div>
  <div class="requirements">
    <h3>File ZIP cần chứa:</h3>
    <ul> point_cloud_raw.ply · location.csv · location.json
         frame_transforms.csv · tree_gps_anchor.json · rgb.mp4 </ul>
  </div>
</main>
```

---

## templates/dashboard.html

Full results dashboard with 5 sections.
Use Plotly.js (CDN) for charts, Leaflet.js for map.
All data passed as Jinja2 template variables from FastAPI.

### Section 1 — Summary cards (top row)
4 cards in a row:
- 🌳 DBH: {{ trunk.dbh_cm | round(1) }} cm
- ⛰️ Altitude: {{ trunk.tree_alt_m | round(0) }} m a.s.l.
- 🧭 Aspect: {{ trunk.aspect_8pt }} ({{ trunk.trunk_azimuth_deg | round(0) }}°)
- 🌿 Lichen: {{ lichen.coverage_pct | round(1) }}% coverage

### Section 2 — 3D Point Cloud (Plotly scatter3d)
```javascript
// Color points by height (z value)
// Lichen points highlighted in green if coverage data available
Plotly.newPlot('pointcloud', [{
  type: 'scatter3d',
  x: xCoords,  // subsample to max 5000 points for performance
  y: yCoords,
  z: zCoords,
  mode: 'markers',
  marker: {
    size: 2,
    color: zCoords,  // color by height
    colorscale: 'Viridis',
    colorbar: { title: 'Height (m)' }
  }
}], {
  scene: { aspectmode: 'data' },
  margin: { l:0, r:0, t:30, b:0 },
  title: 'Point Cloud — ' + treeId
})
```
Pass point data as JSON embedded in template (subsampled to 5000 pts max).

### Section 3 — Lichen distribution (Polar chart)
```javascript
// Polar/radar chart showing lichen % by 8 compass directions
Plotly.newPlot('lichenpolar', [{
  type: 'scatterpolar',
  r: [N_pct, NE_pct, E_pct, SE_pct, S_pct, SW_pct, W_pct, NW_pct, N_pct],
  theta: ['N','NE','E','SE','S','SW','W','NW','N'],
  fill: 'toself',
  fillcolor: 'rgba(46,117,182,0.3)',
  line: { color: '#2E75B6' },
  name: 'Lichen coverage %'
}], {
  polar: { radialaxis: { visible: true, range: [0, 100] } },
  title: 'Phân bố địa y theo hướng'
})
```

### Section 4 — Solar and Wind exposure (side by side)

Left — Solar monthly bar chart:
```javascript
Plotly.newPlot('solar', [{
  type: 'bar',
  x: ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'],
  y: monthly_facing,  // 0.0-1.0
  marker: { color: '#F59E0B' },
  name: 'Sun-facing fraction'
}], { title: 'Solar exposure theo tháng', yaxis: { range: [0,1] } })
```

Right — Wind rose (polar bar):
```javascript
Plotly.newPlot('windrose', [{
  type: 'barpolar',
  r: [N_count, NE_count, E_count, SE_count, S_count, SW_count, W_count, NW_count],
  theta: ['N','NE','E','SE','S','SW','W','NW'],
  marker: { color: '#3B82F6' },
  name: 'Wind frequency'
}], { title: 'Wind rose (hướng gió)' })
```

### Section 5 — Map (Leaflet.js)
```javascript
const map = L.map('map').setView([tree_lat, tree_lon], 15)
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png').addTo(map)

// Tree marker with popup
L.marker([tree_lat, tree_lon])
  .bindPopup(`
    <b>${treeId}</b><br>
    DBH: ${dbh_cm} cm<br>
    Altitude: ${alt_m} m a.s.l.<br>
    Lichen: ${coverage_pct}%<br>
    Aspect: ${aspect_8pt}
  `)
  .openPopup()
  .addTo(map)

// North arrow showing trunk aspect
// Arrow from tree center pointing in trunk_azimuth direction
```

### Section 6 — Raw data table (collapsible)
Show tree_metadata.json as formatted JSON in a <details> block.
Also show download link for tree_metadata.json.

---

## requirements.txt

```
fastapi>=0.110.0
uvicorn[standard]>=0.29.0
python-multipart>=0.0.9
jinja2>=3.1.3
aiofiles>=23.2.1
pysolar>=0.11
numpy>=1.26.0
scipy>=1.13.0
pandas>=2.2.0
opencv-python-headless>=4.9.0
requests>=2.31.0
```

---

## Dockerfile

```dockerfile
FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

---

## railway.json

```json
{
  "$schema": "https://railway.app/railway.schema.json",
  "build": { "builder": "DOCKERFILE" },
  "deploy": {
    "startCommand": "uvicorn main:app --host 0.0.0.0 --port $PORT",
    "healthcheckPath": "/health",
    "restartPolicyType": "ON_FAILURE"
  }
}
```

---

## Constraints and notes

- Pure numpy PLY reader — no open3d, no plyfile library
- OpenCV headless (no GUI) — only for image processing
- All processing synchronous — Railway free tier has 512MB RAM, keep memory lean
  - Subsample PLY to max 50,000 points for processing, 5,000 for visualization
  - Extract max 30 frames from video
- Temp files: always use tempfile.TemporaryDirectory() and clean up after response
- Error handling: never crash — return dashboard with partial results and error notes
- Point cloud visualization: subsample to 5000 points, color by Z height
- If rgb.mp4 missing: skip lichen detection, show "Video not available" in dashboard
- If Open-Meteo API fails: show "Wind data unavailable" in wind section
- Vietnamese labels in UI, English field names in JSON output
- After successful analysis, offer download button for tree_metadata.json

## Test instructions

After building, test with the sample data files from the scanner project:
- location.csv, location.json, tree_gps_anchor.json are available
- Create a minimal test ZIP with those files + a dummy PLY
- Verify /health returns 200
- Verify / returns upload page
- Verify POST /analyze with valid ZIP returns dashboard HTML

Do not use any paid APIs. Open-Meteo is free, pysolar is local computation.
