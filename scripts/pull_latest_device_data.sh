#!/usr/bin/env bash
set -euo pipefail

DEVICE_ID="${1:-00008150-000A3418228B401C}"
BUNDLE_ID="${2:-com.anhnguyen.strayscanner.testlab}"
DEST_ROOT="${3:-device_exports}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST_DIR="${DEST_ROOT}/${STAMP}"

mkdir -p "${DEST_DIR}"

xcrun devicectl device copy from \
  --device "${DEVICE_ID}" \
  --domain-type appDataContainer \
  --domain-identifier "${BUNDLE_ID}" \
  --source Documents \
  --destination "${DEST_DIR}"

echo "Pulled app data container to ${DEST_DIR}"
find "${DEST_DIR}" -name location.csv -o -name location.json -o -name rgb.mp4 -o -name imu.csv -o -name odometry.csv
