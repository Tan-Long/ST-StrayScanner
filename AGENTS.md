# Repository Guidelines

## Project Structure & Module Organization

This is an iOS LiDAR scanning app. Main app code lives in `StrayScanner/`: UIKit controllers are in `Controllers/`, SwiftUI screens in `Views/`, data encoders and utilities in `Helpers/`, Core Data models in `Models/`, Metal shaders in `Shaders/`, and app assets in `Assets.xcassets` / `Resources/`. Tests are split between `StrayScannerTests/` and `StrayScannerUITests/`. Documentation lives in `docs/`; sample/readme images live in `images/`. The `lichen-server/` folder is a separate server-side component.

## Build, Test, and Development Commands

Open `StrayScanner.xcworkspace` in full Xcode to build or run on a LiDAR-capable iOS device; use the workspace, not the `.xcodeproj`.

Useful local checks on this Mac:

```sh
swiftc -parse StrayScanner/Helpers/SampleLogger.swift StrayScanner/Views/SampleSession.swift
plutil -lint StrayScanner/Info.plist StrayScanner/Info-debug.plist
git diff --check
```

This working Mac has Command Line Tools selected instead of full Xcode, so `xcodebuild` is not expected to work here.

## Coding Style & Naming Conventions

Use Swift conventions: 4-space indentation, `PascalCase` for types, `camelCase` for properties/functions, and concise `// MARK:` groupings for large files. Prefer existing helpers such as `SampleLogger`, `SampleContextStore`, and encoder classes over new parallel abstractions. Keep generated/export filenames compatible with current patterns, for example `M-1.1*_video_20260524_121530`, day folders such as `24052026`, and sample `.jpg` files under `samples/`.

## Testing Guidelines

Tests use XCTest. Keep unit tests in `StrayScannerTests/` and UI tests in `StrayScannerUITests/`. Name tests around behavior, e.g. `testSampleRestoreKeepsCSVRows`. For app behavior touching ARKit/LiDAR, validate on a real LiDAR device in Xcode. At minimum, run parse/plist/diff checks before handing off changes.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects such as `Add editable video sample ID` and `Fix reset sample export and video list refresh`. Follow that style: start with `Add`, `Fix`, `Update`, or `Remove`, and keep the subject specific. Pull requests should include a clear summary, test/validation notes, screenshots for UI changes, and any data migration or export-format impact.

## Data Safety Notes

Sample photos and logs are user data. Avoid destructive changes without confirmation. Soft-delete sample photos into `samples/recently_deleted` when possible, keep ZIP exports grouped by day with photos before CSV/XLSX logs, and do not alter unrelated generated files such as `lichen-server/__pycache__/`.
