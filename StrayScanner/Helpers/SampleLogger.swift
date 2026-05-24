//
//  SampleLogger.swift
//  StrayScanner
//

import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

struct SampleRecord {
    let sampleID: String
    let isImportant: Bool
    let latitude: Double?
    let longitude: Double?
    let gpsAccuracy: Double?
    let location: String       // reverse-geocoded place name
    let site: String           // user-entered site
    let huongCameraDegrees: Double?
    let huongCamera: String    // camera direction into tree
    let huongManhXamDegrees: Double?
    let huongManhXam: String   // N NE E SE S SW W NW
    let huongLayMau: String    // Upslope / Downslope
    let altitude: Double?
    let loaiMau: String        // Địa y / Không địa y
    let ngayLay: String        // display date string
    let fileAnh: String        // JPEG filename only
}

struct LidarSampleRecoveryCandidate: Identifiable {
    let datasetDirectory: URL
    let videoURL: URL
    let metadataURL: URL
    let datasetFolder: String
    let sampleID: String
    let isImportant: Bool
    let loaiMau: String
    let site: String
    let recordedAt: Date?
    let recordedAtText: String

    var id: String { datasetDirectory.path }
}

class SampleLogger {
    static let shared = SampleLogger()
    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    private let samplesDir: URL
    private let recentlyDeletedDir: URL
    private let csvURL: URL
    // NOTE: True XLSX (OOXML/ZIP) requires a third-party library (e.g. CoreXLSX).
    // exportXLSX() writes the same data as tab-separated values with a .xlsx
    // extension so Excel / Numbers can open it via their CSV import fallback.
    // Replace the body of exportXLSX() with a real library call for full compatibility.
    private let xlsxURL: URL
    private let deletedCSVURL: URL

    private static let csvHeader =
        "File ảnh,Sample-ID,Flag,Loại mẫu,Ngày lấy," +
        "Lat,Long,GPS_accuracy_m,Altitude_m," +
        "Hướng camera degree,Hướng camera cardinal," +
        "Hướng mảnh xăm degree,Hướng mảnh xăm cardinal," +
        "Location,Site,Hướng lấy mẫu\n"
    private static let deletedCSVHeader =
        csvHeader.trimmingCharacters(in: .newlines) + ",Deleted at\n"
    private static let currentColumnCount = 16
    private static let noFlagColumnCount = 15
    private static let previousColumnCount = 16
    private static let noCameraWithTenMauColumnCount = 15
    private static let legacyColumnCount = 12
    private static let headingLegacyColumnCount = 14

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        samplesDir = docs.appendingPathComponent("samples", isDirectory: true)
        recentlyDeletedDir = samplesDir.appendingPathComponent("recently_deleted", isDirectory: true)
        csvURL  = samplesDir.appendingPathComponent("samples_log.csv")
        xlsxURL = samplesDir.appendingPathComponent("samples_log.xlsx")
        deletedCSVURL = recentlyDeletedDir.appendingPathComponent("deleted_samples_log.csv")
        try? FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)
    }

    var samplesDirectory: URL {
        try? ensureSamplesDirectory()
        return samplesDir
    }

    func sampleImageFiles() -> [URL] {
        try? ensureSamplesDirectory()
        return imageFiles(in: samplesDir)
    }

    func recentlyDeletedSampleImageFiles() -> [URL] {
        try? ensureRecentlyDeletedDirectory()
        return imageFiles(in: recentlyDeletedDir)
    }

    func deleteSamplePhoto(filename: String) throws {
        try ensureSamplesDirectory()
        try ensureRecentlyDeletedDirectory()
        try ensureCurrentCSVHeader()
        try ensureDeletedCSVHeader()

        let photoURL = samplesDir.appendingPathComponent(filename)
        let deletedURL = recentlyDeletedDir.appendingPathComponent(filename)
        let photoExists = FileManager.default.fileExists(atPath: photoURL.path)
        var rows = rows(forPhotoFilename: filename)
        if rows.isEmpty && photoExists {
            rows = [fallbackCurrentRow(forPhotoFilename: filename, location: "Orphan sample photo")]
        }
        try appendDeletedRows(rows, deletedAt: Date())

        var didMovePhoto = false
        if photoExists {
            if FileManager.default.fileExists(atPath: deletedURL.path) {
                try FileManager.default.removeItem(at: deletedURL)
            }
            do {
                try FileManager.default.moveItem(at: photoURL, to: deletedURL)
                didMovePhoto = true
            } catch {
                try? removeDeletedRows(forPhotoFilename: filename)
                throw error
            }
        }

        do {
            try removeRows(forPhotoFilename: filename)
        } catch {
            if didMovePhoto {
                try? FileManager.default.moveItem(at: deletedURL, to: photoURL)
            }
            try? removeDeletedRows(forPhotoFilename: filename)
            throw error
        }
        exportXLSX()
    }

    func restoreSamplePhoto(filename: String) throws {
        try ensureSamplesDirectory()
        try ensureRecentlyDeletedDirectory()
        try ensureCurrentCSVHeader()
        try ensureDeletedCSVHeader()

        let deletedURL = recentlyDeletedDir.appendingPathComponent(filename)
        let restoredURL = samplesDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: restoredURL.path) {
            throw sampleError("Đã có ảnh cùng tên trong danh sách hiện tại.")
        }

        let hasDeletedPhoto = FileManager.default.fileExists(atPath: deletedURL.path)
        var rows = deletedRows(forPhotoFilename: filename).map(originalRow(fromDeletedRow:))
        if rows.isEmpty && hasDeletedPhoto {
            rows = [fallbackCurrentRow(forPhotoFilename: filename, location: "Restored orphan sample photo")]
        }

        if hasDeletedPhoto {
            try FileManager.default.moveItem(at: deletedURL, to: restoredURL)
        } else {
            throw sampleError("Không tìm thấy file ảnh trong Đã xoá gần đây.")
        }

        do {
            try appendCurrentRows(rows)
        } catch {
            try? FileManager.default.moveItem(at: restoredURL, to: deletedURL)
            throw error
        }
        try removeDeletedRows(forPhotoFilename: filename)
        exportXLSX()
    }

    func permanentlyDeleteSamplePhoto(filename: String) throws {
        try ensureRecentlyDeletedDirectory()
        try ensureDeletedCSVHeader()

        let photoURL = recentlyDeletedDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: photoURL.path) {
            try FileManager.default.removeItem(at: photoURL)
        }

        try removeDeletedRows(forPhotoFilename: filename)
    }

    func lidarSampleRecoveryCandidates() -> [LidarSampleRecoveryCandidate] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .compactMap(lidarSampleRecoveryCandidate(from:))
            .sorted { lhs, rhs in
                let lhsDate = lhs.recordedAt ?? modificationDate(for: lhs.datasetDirectory) ?? .distantPast
                let rhsDate = rhs.recordedAt ?? modificationDate(for: rhs.datasetDirectory) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    @discardableResult
    func recoverSamplePhotoFromLidar(
        candidate: LidarSampleRecoveryCandidate,
        imageData: Data,
        selectedTime: TimeInterval
    ) throws -> String {
        try ensureSamplesDirectory()
        try ensureCurrentCSVHeader()

        guard !imageData.isEmpty else {
            throw sampleError("Frame được chọn không có dữ liệu ảnh.")
        }

        let fileURL = uniqueRecoveredSampleURL(candidate: candidate, selectedTime: selectedTime)
        let annotatedImageData = recoveredLidarImageData(
            imageData: imageData,
            filename: fileURL.lastPathComponent,
            candidate: candidate,
            selectedTime: selectedTime
        )
        let tempURL = samplesDir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp")
        try? FileManager.default.removeItem(at: tempURL)
        try annotatedImageData.write(to: tempURL, options: .atomic)

        let displayDate = DateFormatter()
        displayDate.dateStyle = .medium
        displayDate.timeStyle = .short
        let ngayLay = displayDate.string(from: candidate.recordedAt ?? Date())

        let record = SampleRecord(
            sampleID: candidate.sampleID,
            isImportant: candidate.isImportant,
            latitude: nil,
            longitude: nil,
            gpsAccuracy: nil,
            location: candidate.datasetFolder,
            site: candidate.site,
            huongCameraDegrees: nil,
            huongCamera: "",
            huongManhXamDegrees: nil,
            huongManhXam: "",
            huongLayMau: "",
            altitude: nil,
            loaiMau: candidate.loaiMau,
            ngayLay: ngayLay,
            fileAnh: fileURL.lastPathComponent
        )

        do {
            try append(record: record)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        do {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            try? removeRows(forPhotoFilename: fileURL.lastPathComponent)
            exportXLSX()
            throw error
        }

        SampleContextStore.shared.save(
            sampleID: candidate.sampleID,
            isImportant: candidate.isImportant,
            loaiMau: candidate.loaiMau,
            site: candidate.site
        )
        backupSamplePhotoToLibrary(imageData: annotatedImageData, filename: fileURL.lastPathComponent)
        return fileURL.lastPathComponent
    }

    func backupSamplePhotoToLibrary(imageData: Data, filename: String) {
#if targetEnvironment(simulator)
        return
#else
        let saveToPhotos = {
            PHPhotoLibrary.shared().performChanges({
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: imageData, options: options)
            }, completionHandler: { success, error in
                if !success {
                    print("SampleLogger: failed to save backup to Photos – \(error?.localizedDescription ?? "unknown error")")
                }
            })
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            saveToPhotos()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    saveToPhotos()
                } else {
                    print("SampleLogger: Photos backup permission was not granted")
                }
            }
        case .denied, .restricted:
            print("SampleLogger: Photos backup permission denied or restricted")
        @unknown default:
            print("SampleLogger: Photos backup permission unknown")
        }
#endif
    }

    func prepareStorageForExport() {
        try? ensureSamplesDirectory()
        try? ensureCurrentCSVHeader()
        exportXLSX()
    }

    // MARK: - Next ID

    /// Returns the next Sample ID for the given prefix.
    /// Scans existing CSV for rows whose ID begins with "\(prefix)." and increments
    /// the numeric suffix. e.g. prefix "M-1", existing "M-1.3" → "M-1.4".
    /// If no records for prefix exist yet, returns "\(prefix).1".
    /// If prefix contains no "-" (bare code like "M"), prepends "-1" first
    /// so the initial ID is "M-1.1".
    func nextSampleID(prefix: String) -> String {
        try? ensureCurrentCSVHeader()
        let prefix = normalizedPrefix(prefix)
        let matchPrefix = prefix + "."
        var maxSuffix = 0
        var found = false
        for row in existingDataRows() {
            let id = sampleIDField(of: row)
            guard id.hasPrefix(matchPrefix) else { continue }
            let suffix = String(id.dropFirst(matchPrefix.count))
            if let n = Int(suffix) {
                found = true
                maxSuffix = max(maxSuffix, n)
            }
        }
        return "\(prefix).\(found ? maxSuffix + 1 : 1)"
    }

    /// Returns the first Sample ID under prefix that still misses either
    /// Upslope or Downslope; otherwise returns the next fresh ID.
    func nextSampleIDForHuongPair(prefix: String) -> String {
        try? ensureCurrentCSVHeader()
        let prefix = normalizedPrefix(prefix)
        let matchPrefix = prefix + "."
        var maxSuffix = 0
        var directionsBySuffix: [Int: Set<String>] = [:]

        for row in existingDataRows() {
            let fields = parseCSVRow(row)
            let id = sampleIDField(of: fields)
            guard id.hasPrefix(matchPrefix) else { continue }
            let suffix = String(id.dropFirst(matchPrefix.count))
            guard let n = Int(suffix) else { continue }
            maxSuffix = max(maxSuffix, n)
            let huong = huongLayMauField(of: fields)
            if !huong.isEmpty {
                directionsBySuffix[n, default: []].insert(huong)
            }
        }

        for suffix in directionsBySuffix.keys.sorted() {
            if !hasCompleteHuongPair(directionsBySuffix[suffix] ?? []) {
                return "\(prefix).\(suffix)"
            }
        }

        return "\(prefix).\(maxSuffix + 1)"
    }

    func hasCompleteHuongLayMauPair(sampleID: String) -> Bool {
        try? ensureCurrentCSVHeader()
        var directions = Set<String>()
        for row in existingDataRows() {
            let fields = parseCSVRow(row)
            guard sampleIDField(of: fields) == sampleID else { continue }
            let huong = huongLayMauField(of: fields)
            if !huong.isEmpty {
                directions.insert(huong)
            }
        }
        return hasCompleteHuongPair(directions)
    }

    // MARK: - Append

    func append(record: SampleRecord) throws {
        try ensureSamplesDirectory()
        try ensureCurrentCSVHeader()

        let lat = record.latitude.map  { String($0) } ?? ""
        let lon = record.longitude.map { String($0) } ?? ""
        let gpsAccuracy = record.gpsAccuracy.map { String($0) } ?? ""
        let alt = record.altitude.map  { String($0) } ?? ""
        let cameraHeading = record.huongCameraDegrees.map { String($0) } ?? ""
        let huongManhXamHeading = record.huongManhXamDegrees.map { String($0) } ?? ""
        let flag = record.isImportant ? "*" : ""

        let row = [
            escape(record.fileAnh), escape(record.sampleID),
            flag,
            escape(record.loaiMau), escape(record.ngayLay),
            lat, lon, gpsAccuracy, alt,
            cameraHeading, escape(record.huongCamera),
            huongManhXamHeading, escape(record.huongManhXam),
            escape(record.location), escape(record.site),
            escape(record.huongLayMau)
        ].joined(separator: ",") + "\n"

        guard let data = row.data(using: .utf8) else { return }
        let handle = try FileHandle(forWritingTo: csvURL)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)

        exportXLSX()
    }

    // MARK: - XLSX (TSV fallback)

    func exportXLSX() {
        try? ensureSamplesDirectory()
        try? ensureCurrentCSVHeader()
        guard var csvString = try? String(contentsOf: csvURL, encoding: .utf8) else { return }
        if csvString.hasPrefix("\u{FEFF}") {
            csvString.removeFirst()
        }
        var tsvData = Self.utf8BOM
        let tsv = csvString
            .components(separatedBy: "\n")
            .map { parseCSVRow($0).joined(separator: "\t") }
            .joined(separator: "\n")
        tsvData.append(contentsOf: tsv.utf8)
        try? tsvData.write(to: xlsxURL, options: .atomic)
    }

    // MARK: - Private helpers

    private func imageFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "jpg" || ext == "jpeg"
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private func ensureCurrentCSVHeader() throws {
        try ensureSamplesDirectory()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: csvURL.path) {
            var data = Self.utf8BOM
            data.append(contentsOf: Self.csvHeader.utf8)
            try data.write(to: csvURL, options: .atomic)
            return
        }

        guard var content = try? String(contentsOf: csvURL, encoding: .utf8) else { return }
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }

        let header = Self.csvHeader.trimmingCharacters(in: .newlines)
        var lines = content.components(separatedBy: "\n")
        let oldHeader = lines.first ?? ""
        guard lines.first != header else { return }

        if !lines.isEmpty {
            lines.removeFirst()
        }

        var migrated = Self.utf8BOM
        migrated.append(contentsOf: Self.csvHeader.utf8)

        let migratedRows = lines
            .filter { !$0.isEmpty }
            .map { migrateRow($0, sourceHeader: oldHeader) }
            .joined(separator: "\n")

        if !migratedRows.isEmpty {
            migrated.append(contentsOf: migratedRows.utf8)
            migrated.append(0x0A)
        }

        try migrated.write(to: csvURL, options: .atomic)
    }

    private func ensureSamplesDirectory() throws {
        try FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)
    }

    private func ensureRecentlyDeletedDirectory() throws {
        try FileManager.default.createDirectory(at: recentlyDeletedDir, withIntermediateDirectories: true)
    }

    private func ensureDeletedCSVHeader() throws {
        try ensureRecentlyDeletedDirectory()
        guard !FileManager.default.fileExists(atPath: deletedCSVURL.path) else { return }

        var data = Self.utf8BOM
        data.append(contentsOf: Self.deletedCSVHeader.utf8)
        try data.write(to: deletedCSVURL, options: .atomic)
    }

    private func rows(forPhotoFilename filename: String) -> [String] {
        existingDataRows().filter { row in
            parseCSVRow(row).first == filename
        }
    }

    private func deletedRows(forPhotoFilename filename: String) -> [String] {
        dataRows(from: deletedCSVURL).filter { row in
            parseCSVRow(row).first == filename
        }
    }

    private func fallbackCurrentRow(forPhotoFilename filename: String, location: String) -> String {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let displayDate = DateFormatter()
        displayDate.dateStyle = .medium
        displayDate.timeStyle = .short
        let fields = [
            filename,
            stem,
            "",
            "",
            displayDate.string(from: Date()),
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            location,
            "",
            ""
        ]
        return fields.map(escape).joined(separator: ",")
    }

    private func appendDeletedRows(_ rows: [String], deletedAt: Date) throws {
        guard !rows.isEmpty else { return }

        let filenames = rows.compactMap { parseCSVRow($0).first }
        for filename in filenames {
            try removeDeletedRows(forPhotoFilename: filename)
        }

        let deletedAtText = ISO8601DateFormatter().string(from: deletedAt)
        let rowsWithDeletedAt = rows.map { row -> String in
            var fields = parseCSVRow(row)
            while fields.count < Self.currentColumnCount {
                fields.append("")
            }
            fields = Array(fields.prefix(Self.currentColumnCount))
            fields.append(deletedAtText)
            return fields.map(escape).joined(separator: ",")
        }

        try appendRows(rowsWithDeletedAt, to: deletedCSVURL)
    }

    private func appendCurrentRows(_ rows: [String]) throws {
        guard !rows.isEmpty else { return }

        let activeFilenames = Set(existingDataRows().compactMap { parseCSVRow($0).first })
        let rowsToAppend = rows.filter { row in
            guard let filename = parseCSVRow(row).first else { return true }
            return !activeFilenames.contains(filename)
        }

        try appendRows(rowsToAppend, to: csvURL)
    }

    private func appendRows(_ rows: [String], to url: URL) throws {
        guard !rows.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        let text = rows.joined(separator: "\n") + "\n"
        if let data = text.data(using: .utf8) {
            handle.write(data)
        }
    }

    private func originalRow(fromDeletedRow row: String) -> String {
        var fields = parseCSVRow(row)
        while fields.count < Self.currentColumnCount {
            fields.append("")
        }
        fields = Array(fields.prefix(Self.currentColumnCount))
        return fields.map(escape).joined(separator: ",")
    }

    private func recoveredLidarImageData(
        imageData: Data,
        filename: String,
        candidate: LidarSampleRecoveryCandidate,
        selectedTime: TimeInterval
    ) -> Data {
        guard let image = UIImage(data: imageData) else { return imageData }

        let recoveredAt = Date()
        let displayDate = DateFormatter()
        displayDate.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines: [String] = [
            "Recovered from LiDAR",
            "File: \(filename)",
            "Sample ID: \(candidate.sampleID)",
            "Flag: \(candidate.isImportant ? "*" : "")",
            "Loai mau: \(candidate.loaiMau)",
            "Dataset: \(candidate.datasetFolder)",
            String(format: "Video time: %.2fs", selectedTime),
            "Recovered: \(displayDate.string(from: recoveredAt))"
        ]

        if !candidate.recordedAtText.isEmpty {
            lines.append("Recorded: \(candidate.recordedAtText)")
        }
        if !candidate.site.isEmpty {
            lines.append("Site: \(candidate.site)")
        }

        let text = lines.joined(separator: "\n")
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale

        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let annotatedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))

            let width = image.size.width
            let margin = max(16, width * 0.025)
            let padding = max(10, width * 0.012)
            let fontSize = min(max(width * 0.018, 18), 44)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = max(3, fontSize * 0.12)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let maxTextSize = CGSize(
                width: image.size.width - (margin + padding) * 2,
                height: .greatestFiniteMagnitude
            )
            let textRect = text.boundingRect(
                with: maxTextSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            ).integral
            let backgroundRect = CGRect(
                x: margin,
                y: margin,
                width: textRect.width + padding * 2,
                height: textRect.height + padding * 2
            )

            UIColor.black.withAlphaComponent(0.58).setFill()
            UIBezierPath(
                roundedRect: backgroundRect,
                cornerRadius: max(6, fontSize * 0.2)
            ).fill()

            text.draw(
                with: backgroundRect.insetBy(dx: padding, dy: padding),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
        }

        let metadata = recoveredLidarJPEGMetadata(
            filename: filename,
            candidate: candidate,
            selectedTime: selectedTime,
            recoveredAt: recoveredAt
        )
        return jpegData(image: annotatedImage, metadata: metadata) ?? annotatedImage.jpegData(compressionQuality: 0.94) ?? imageData
    }

    private func recoveredLidarJPEGMetadata(
        filename: String,
        candidate: LidarSampleRecoveryCandidate,
        selectedTime: TimeInterval,
        recoveredAt: Date
    ) -> [CFString: Any] {
        let recoveredAtText = ISO8601DateFormatter().string(from: recoveredAt)
        let sampleData: [String: Any] = [
            "file_anh": filename,
            "sample_id": candidate.sampleID,
            "flag": candidate.isImportant ? "*" : "",
            "is_important": candidate.isImportant,
            "loai_mau": candidate.loaiMau,
            "site": candidate.site,
            "recovered_from_lidar": true,
            "recovered_at": recoveredAtText,
            "source_dataset_folder": candidate.datasetFolder,
            "source_video": candidate.videoURL.lastPathComponent,
            "source_video_time_seconds": selectedTime,
            "source_recorded_at": candidate.recordedAtText
        ]

        let jsonData = try? JSONSerialization.data(withJSONObject: sampleData, options: [.sortedKeys])
        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        return [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: jsonString
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFImageDescription: jsonString,
                kCGImagePropertyTIFFSoftware: "Stray Scanner TestLab"
            ]
        ]
    }

    private func jpegData(image: UIImage, metadata: [CFString: Any]) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func lidarSampleRecoveryCandidate(from directory: URL) -> LidarSampleRecoveryCandidate? {
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return nil }

        let videoURL = directory.appendingPathComponent("rgb.mp4")
        let metadataURL = directory.appendingPathComponent("sample_metadata.json")
        guard
            FileManager.default.fileExists(atPath: videoURL.path),
            FileManager.default.fileExists(atPath: metadataURL.path),
            let data = try? Data(contentsOf: metadataURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let sampleID = metadataString(json["sample_id"])
        guard !sampleID.isEmpty else { return nil }

        let datasetFolder = metadataString(json["dataset_folder"], fallback: directory.lastPathComponent)
        let sampleFlag = metadataString(json["sample_flag"])
        let flag = metadataString(json["flag"])
        let isImportant = metadataBool(json["is_important"]) ||
            sampleFlag == "*" ||
            flag == "*" ||
            directory.lastPathComponent.hasSuffix("*")
        let recordedAtText = metadataString(json["recorded_at"])
        let recordedAt = parseISO8601(recordedAtText)

        return LidarSampleRecoveryCandidate(
            datasetDirectory: directory,
            videoURL: videoURL,
            metadataURL: metadataURL,
            datasetFolder: datasetFolder,
            sampleID: sampleID,
            isImportant: isImportant,
            loaiMau: metadataString(json["sample_loai_mau"], fallback: "Khôi phục từ LiDAR"),
            site: metadataString(json["sample_site"]),
            recordedAt: recordedAt,
            recordedAtText: recordedAtText
        )
    }

    private func uniqueRecoveredSampleURL(
        candidate: LidarSampleRecoveryCandidate,
        selectedTime: TimeInterval
    ) -> URL {
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.dateFormat = "yyyyMMdd_HHmmss"

        let sampleID = SampleContextStore.folderSafeSampleID(candidate.sampleID)
        let dataset = SampleContextStore.folderSafeSampleID(candidate.datasetFolder)
        let flag = candidate.isImportant ? "*" : ""
        let frame = String(format: "f%05d", max(0, Int(selectedTime * 100)))
        let base = "\(sampleID)\(flag)_lidar_\(dataset)_\(frame)_\(timestamp.string(from: Date()))"

        var candidateURL = samplesDir.appendingPathComponent("\(base).jpg")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateURL = samplesDir.appendingPathComponent("\(base)_\(counter).jpg")
            counter += 1
        }
        return candidateURL
    }

    private func metadataString(_ value: Any?, fallback: String = "") -> String {
        guard let value = value, !(value is NSNull) else { return fallback }
        if let string = value as? String {
            return string.isEmpty ? fallback : string
        }
        return "\(value)"
    }

    private func metadataBool(_ value: Any?) -> Bool {
        guard let value = value, !(value is NSNull) else { return false }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["true", "1", "yes", "*"].contains(string.lowercased())
        }
        return false
    }

    private func parseISO8601(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func migrateRow(_ row: String, sourceHeader: String) -> String {
        let fields = parseCSVRow(row)
        let migratedFields: [String]

        switch fields.count {
        case Self.previousColumnCount:
            if sourceHeader.contains("Hướng camera degree") || sourceHeader.contains("Huong camera degree") {
                migratedFields = fields
            } else if sourceHeader.contains("Tên mẫu") || sourceHeader.contains("Ten mau") {
                migratedFields = [
                    fields[0], fields[1], "", fields[3], fields[4],
                    fields[5], fields[6], fields[7], fields[8],
                    "", fields[13], fields[9], fields[14],
                    fields[11], fields[12], fields[15]
                ]
            } else if sourceHeader.contains("Heading_degree") {
                migratedFields = [
                    fields[0], fields[1], fields[2], fields[3], fields[4],
                    fields[5], fields[6], fields[7], fields[8],
                    "", fields[13], fields[9], fields[14],
                    fields[11], fields[12], fields[15]
                ]
            } else {
                migratedFields = fields
            }
        case Self.noFlagColumnCount where !(sourceHeader.contains("Tên mẫu") || sourceHeader.contains("Ten mau")):
            migratedFields = [
                fields[0], fields[1], "", fields[2], fields[3],
                fields[4], fields[5], fields[6], fields[7],
                "", fields[12], fields[8], fields[13],
                fields[10], fields[11], fields[14]
            ]
        case Self.noCameraWithTenMauColumnCount:
            migratedFields = [
                fields[0], fields[1], "", fields[3], fields[4],
                fields[5], fields[6], fields[7], fields[8],
                "", "", fields[9], fields[13],
                fields[11], fields[12], fields[14]
            ]
        case Self.headingLegacyColumnCount:
            migratedFields = [
                fields[13], fields[0], "", fields[11], fields[12],
                fields[2], fields[3], "", fields[8],
                "", "", fields[9], fields[10],
                fields[4], fields[5], fields[7]
            ]
        case Self.legacyColumnCount:
            migratedFields = [
                fields[11], fields[0], "", fields[9], fields[10],
                fields[2], fields[3], "", fields[8],
                "", "", "", fields[6],
                fields[4], fields[5], fields[7]
            ]
        default:
            var padded = fields
            while padded.count < Self.currentColumnCount {
                padded.append("")
            }
            migratedFields = Array(padded.prefix(Self.currentColumnCount))
        }

        return migratedFields
            .map(escape)
            .joined(separator: ",")
    }

    private func existingDataRows() -> [String] {
        dataRows(from: csvURL)
    }

    private func dataRows(from url: URL) -> [String] {
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }
        let lines = content.components(separatedBy: "\n")
        return lines.dropFirst().filter { !$0.isEmpty }
    }

    private func removeRows(forPhotoFilename filename: String) throws {
        guard var content = try? String(contentsOf: csvURL, encoding: .utf8) else { return }
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }

        let lines = content.components(separatedBy: "\n")
        let rowsToKeep = lines
            .dropFirst()
            .filter { !$0.isEmpty }
            .filter { row in
                parseCSVRow(row).first != filename
            }

        var data = Self.utf8BOM
        data.append(contentsOf: Self.csvHeader.utf8)
        if !rowsToKeep.isEmpty {
            data.append(contentsOf: rowsToKeep.joined(separator: "\n").utf8)
            data.append(0x0A)
        }
        try data.write(to: csvURL, options: .atomic)
    }

    private func removeDeletedRows(forPhotoFilename filename: String) throws {
        guard var content = try? String(contentsOf: deletedCSVURL, encoding: .utf8) else { return }
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }

        let lines = content.components(separatedBy: "\n")
        let rowsToKeep = lines
            .dropFirst()
            .filter { !$0.isEmpty }
            .filter { row in
                parseCSVRow(row).first != filename
            }

        var data = Self.utf8BOM
        data.append(contentsOf: Self.deletedCSVHeader.utf8)
        if !rowsToKeep.isEmpty {
            data.append(contentsOf: rowsToKeep.joined(separator: "\n").utf8)
            data.append(0x0A)
        }
        try data.write(to: deletedCSVURL, options: .atomic)
    }

    private func sampleError(_ message: String) -> NSError {
        NSError(
            domain: "SampleLogger",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func sampleIDField(of row: String) -> String {
        sampleIDField(of: parseCSVRow(row))
    }

    private func sampleIDField(of fields: [String]) -> String {
        if fields.count >= 2 {
            return fields[1]
        }
        return fields.first ?? ""
    }

    private func huongLayMauField(of fields: [String]) -> String {
        guard fields.count >= Self.currentColumnCount else { return "" }
        return fields[15]
    }

    private func normalizedPrefix(_ prefix: String) -> String {
        prefix.contains("-") ? prefix : "\(prefix)-1"
    }

    private func hasCompleteHuongPair(_ directions: Set<String>) -> Bool {
        directions.contains("Upslope") && directions.contains("Downslope")
    }

    private func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = row.startIndex
        while i < row.endIndex {
            let c = row[i]
            if c == "\"" {
                let next = row.index(after: i)
                if inQuotes && next < row.endIndex && row[next] == "\"" {
                    current.append("\"")
                    i = row.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i = row.index(after: i)
        }
        fields.append(current)
        return fields
    }
}

struct SampleContext {
    let sampleID: String
    let isImportant: Bool
    let loaiMau: String
    let site: String
}

class SampleContextStore {
    static let shared = SampleContextStore()

    private let sampleIDKey = "current_sample_id"
    private let isImportantKey = "current_sample_is_important"
    private let loaiMauKey = "current_sample_loai_mau"
    private let siteKey = "current_sample_site"
    private let defaults = UserDefaults.standard

    private init() {}

    var current: SampleContext? {
        guard let sampleID = defaults.string(forKey: sampleIDKey), !sampleID.isEmpty else {
            return nil
        }
        return SampleContext(
            sampleID: sampleID,
            isImportant: defaults.bool(forKey: isImportantKey),
            loaiMau: defaults.string(forKey: loaiMauKey) ?? "",
            site: defaults.string(forKey: siteKey) ?? ""
        )
    }

    func save(sampleID: String, isImportant: Bool, loaiMau: String, site: String) {
        defaults.set(sampleID, forKey: sampleIDKey)
        defaults.set(isImportant, forKey: isImportantKey)
        defaults.set(loaiMau, forKey: loaiMauKey)
        defaults.set(site, forKey: siteKey)
    }

    func clear() {
        defaults.removeObject(forKey: sampleIDKey)
        defaults.removeObject(forKey: isImportantKey)
        defaults.removeObject(forKey: loaiMauKey)
        defaults.removeObject(forKey: siteKey)
    }

    static func folderSafeSampleID(_ sampleID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = sampleID.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}
