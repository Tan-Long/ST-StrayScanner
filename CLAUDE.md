# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Stray Scanner is an iOS app for collecting RGB-D datasets using LiDAR-enabled iOS devices (iPhone 12 Pro+, iPad Pro). It records synchronized camera frames, depth maps, confidence maps, camera pose (odometry), IMU data, and optional lens distortion tables.

## Build & Test

**Requirements:** Xcode, iOS device with LiDAR sensor (cannot run on simulator due to ARKit/LiDAR dependency)

**Current Mac note:** This working Mac only has Command Line Tools selected, not full Xcode, so `xcodebuild` is not expected to work here. Use `swiftc -parse`, `plutil -lint`, and `git diff --check` for local validation, then build in Xcode on a machine with full Xcode installed.

**Build:** Open `StrayScanner.xcworkspace` (not `.xcodeproj`) in Xcode, select an iOS device target, and build with `Cmd+B`.

**Run tests:** `Cmd+U` in Xcode, or via the `StrayScannerTests` scheme. The test suite is minimal — currently only tests NPY array creation.

**CocoaPods:** The Podfile is set up but has no external pod dependencies. Run `pod install` if workspace is missing.

## Architecture

### Recording Pipeline

ARKit drives everything. `RecordSessionViewController` acts as the `ARSessionDelegate` and receives `ARFrame`s, which it passes to two parallel systems:

1. **`CameraRenderer`** — Metal-based GPU renderer that composites the RGB camera feed and depth map into the on-screen preview.
2. **`DatasetEncoder`** — Orchestrates writing all sensor data to disk. Each modality has its own encoder:
   - `VideoEncoder` → `rgb.mp4` (HEVC via AVFoundation)
   - `DepthEncoder` → `depth/NNNNNN.png` (16-bit grayscale, 192×256, millimeters)
   - `ConfidenceEncoder` → `confidence/NNNNNN.png` (values 0–2)
   - `OdometryEncoder` → `odometry.csv` (pose + per-frame intrinsics)
   - `IMUEncoder` → `imu.csv` (accelerometer + gyroscope via CoreMotion)
   - `DistortionEncoder` → `distortion/NNNNNN.bin` (float32 radial LUT, optional)

PNG encoding is handled by the C++ `lodepng` library via an Objective-C++ bridge (`CCode/PngEncoder.mm`).

### Data Storage

Each recording is saved as a folder named by a random hash in the app's Documents directory. Metadata (name, creation date, folder path) is persisted in Core Data (`Stray_Scanner.xcdatamodeld`). `AppDaemon` handles cleanup — it deletes dataset folders on disk when their Core Data records are removed.

### UI Layer

- **SwiftUI** views (`Views/`) handle the session list, session detail, and new session flow.
- **UIKit + XIB** (`RecordSessionView.xib`) handles the live recording screen with the Metal preview.
- `ShareUtility` zips a dataset folder and presents the system share sheet for export.

### Data Format

See `docs/format.md` for the complete specification. Key conventions:
- Depth values are in **millimeters** as 16-bit PNG
- Camera pose quaternions follow ARKit's convention (right-handed, Y-up)
- `odometry.csv` has per-frame intrinsics; `camera_matrix.csv` is kept only for backwards compatibility
- `distortion/` folder is optional — only present when the device exposes lens calibration data
