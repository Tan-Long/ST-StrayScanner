//
//  ShareUtility.swift
//  StrayScanner
//
//  Created by Claude on 6/24/25.
//

import Foundation

/// Utility class for creating shareable archives from recording datasets
class ShareUtility {
    struct FullDataArchiveProgress {
        let processedBytes: Int64
        let totalBytes: Int64
        let currentItem: String

        var fraction: Double {
            guard totalBytes > 0 else { return 1 }
            return min(max(Double(processedBytes) / Double(totalBytes), 0), 1)
        }

        var percent: Int {
            Int((fraction * 100).rounded(.down))
        }
    }

    private struct ArchiveSourceFile {
        let fileURL: URL
        let relativePath: String
        let size: UInt64
        let modifiedAt: Date
    }

    private struct SampleLogRow {
        let text: String
        let date: Date
    }

    private struct ExportItemInfo {
        let url: URL
        let exportName: String
        let exportDate: Date

        var dayFolder: String {
            ShareUtility.exportDayString(from: exportDate)
        }
    }

    private struct CentralDirectoryEntry {
        let path: String
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let modifiedAt: Date
    }

    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])
    private static let sampleLogCSVHeader =
        "File ảnh,Sample-ID,Flag,Loại mẫu,Ngày lấy," +
        "Lat,Long,GPS_accuracy_m,Altitude_m," +
        "Hướng camera degree,Hướng camera cardinal," +
        "Hướng mảnh xăm degree,Hướng mảnh xăm cardinal," +
        "Location,Site,Hướng lấy mẫu\n"
    
    /// Creates a shareable ZIP archive from a recording's dataset
    /// - Parameter recording: The recording to create a ZIP archive for
    /// - Returns: URL of the created ZIP file
    static func createShareableArchive(for recording: Recording) async throws -> URL {
        guard let sourceDirectory = recording.directoryPath() else {
            throw NSError(domain: "ShareError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to get recording directory path"])
        }
        
        let tempDirectory = FileManager.default.temporaryDirectory
        let archiveName = exportFolderName(for: sourceDirectory, fallback: sourceDirectory.lastPathComponent)
        let archiveURL = tempDirectory.appendingPathComponent(archiveName + ".zip")
        
        // Remove existing archive if it exists
        try? FileManager.default.removeItem(at: archiveURL)
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let sourceFiles = try archiveSourceFiles(
                        from: [sourceDirectory],
                        rootFolderName: nil,
                        groupByDay: false
                    )
                    try createStoredZipArchive(
                        sourceFiles: sourceFiles,
                        destinationURL: archiveURL
                    ) { _, _ in }
                    continuation.resume(returning: archiveURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Creates one ZIP containing sample photos/data and all exported recording folders.
    static func createFullDataArchive(
        progress: ((FullDataArchiveProgress) -> Void)? = nil
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let archiveURL = try createFullDataArchiveSync(progress: progress)
                    continuation.resume(returning: archiveURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func createFullDataArchiveSync(
        progress: ((FullDataArchiveProgress) -> Void)?
    ) throws -> URL {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        SampleLogger.shared.prepareStorageForExport()
        let tempDirectory = fileManager.temporaryDirectory
        let generatedDirectory = tempDirectory.appendingPathComponent(
            "StrayScanner_export_generated_\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: generatedDirectory) }

        let exportItems = try fileManager.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { shouldIncludeInFullExport($0) }

        guard !exportItems.isEmpty else {
            throw NSError(
                domain: "ShareError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Không có data để xuất ZIP."]
            )
        }

        let exportInfos = exportItems.map(exportItemInfo(from:))
        let packageName = fullExportPackageName(exportInfos: exportInfos)
        let archiveURL = tempDirectory.appendingPathComponent("\(packageName).zip")
        try? fileManager.removeItem(at: archiveURL)

        let sourceFiles = try archiveSourceFiles(
            from: exportInfos,
            rootFolderName: packageName,
            groupByDay: true,
            generatedDirectory: generatedDirectory
        )
        guard !sourceFiles.isEmpty else {
            throw NSError(
                domain: "ShareError",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy file nào để đưa vào ZIP."]
            )
        }

        let totalBytes = sourceFiles.reduce(Int64(0)) { partial, source in
            partial + Int64(min(source.size, UInt64(Int64.max)))
        }
        var processedBytes: Int64 = 0
        var lastReportedPercent = -1

        func report(_ currentItem: String, force: Bool = false) {
            let progressValue = FullDataArchiveProgress(
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                currentItem: currentItem
            )
            if force || progressValue.percent != lastReportedPercent {
                lastReportedPercent = progressValue.percent
                progress?(progressValue)
            }
        }

        report("Đang chuẩn bị ZIP", force: true)
        do {
            try createStoredZipArchive(
                sourceFiles: sourceFiles,
                destinationURL: archiveURL
            ) { bytesWritten, currentItem in
                processedBytes += Int64(bytesWritten)
                report(currentItem)
            }
            processedBytes = totalBytes
            report("Hoàn tất ZIP", force: true)
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }
        return archiveURL
    }

    private static func archiveSourceFiles(
        from exportItems: [URL],
        rootFolderName: String?,
        groupByDay: Bool,
        generatedDirectory: URL? = nil
    ) throws -> [ArchiveSourceFile] {
        try archiveSourceFiles(
            from: exportItems.map(exportItemInfo(from:)),
            rootFolderName: rootFolderName,
            groupByDay: groupByDay,
            generatedDirectory: generatedDirectory
        )
    }

    private static func archiveSourceFiles(
        from exportInfos: [ExportItemInfo],
        rootFolderName: String?,
        groupByDay: Bool,
        generatedDirectory: URL? = nil
    ) throws -> [ArchiveSourceFile] {
        var sourceFiles: [ArchiveSourceFile] = []
        let fileManager = FileManager.default
        let sortedInfos = exportInfos.sorted {
            if groupByDay, $0.dayFolder != $1.dayFolder {
                return $0.exportDate < $1.exportDate
            }
            return $0.exportName < $1.exportName
        }
        var usedExportNamesByGroup: [String: Set<String>] = [:]

        for info in sortedInfos {
            let item = info.url
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            if values.isDirectory == true {
                if groupByDay, item.lastPathComponent == "samples" {
                    try appendSampleDirectoryFiles(
                        from: item,
                        rootFolderName: rootFolderName,
                        generatedDirectory: generatedDirectory,
                        sourceFiles: &sourceFiles
                    )
                    continue
                }

                let basePath = item.standardizedFileURL.path
                let groupKey = groupByDay ? info.dayFolder : ""
                var usedNamesForGroup = usedExportNamesByGroup[groupKey] ?? []
                let exportedFolderName = uniqueExportName(
                    info.exportName,
                    usedNames: &usedNamesForGroup
                )
                usedExportNamesByGroup[groupKey] = usedNamesForGroup
                let itemRootPath = archiveRootPath(
                    rootFolderName: rootFolderName,
                    dayFolder: groupByDay ? info.dayFolder : nil,
                    itemName: groupByDay ? "01_videos/\(exportedFolderName)" : exportedFolderName
                )
                guard let enumerator = fileManager.enumerator(
                    at: item,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                for case let fileURL as URL in enumerator {
                    let fileValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard fileValues.isRegularFile == true else { continue }
                    var relativeChildPath = String(fileURL.standardizedFileURL.path.dropFirst(basePath.count))
                    if relativeChildPath.hasPrefix("/") {
                        relativeChildPath.removeFirst()
                    }
                    let relativePath = itemRootPath + "/" + relativeChildPath
                    sourceFiles.append(ArchiveSourceFile(
                        fileURL: fileURL,
                        relativePath: zipPath(relativePath),
                        size: UInt64(fileValues.fileSize ?? 0),
                        modifiedAt: fileValues.contentModificationDate ?? Date()
                    ))
                }
            } else if values.isRegularFile == true {
                let itemRootPath = archiveRootPath(
                    rootFolderName: rootFolderName,
                    dayFolder: groupByDay ? info.dayFolder : nil,
                    itemName: item.lastPathComponent
                )
                sourceFiles.append(ArchiveSourceFile(
                    fileURL: item,
                    relativePath: zipPath(itemRootPath),
                    size: UInt64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? Date()
                ))
            }
        }

        return sourceFiles.sorted { $0.relativePath < $1.relativePath }
    }

    private static func appendSampleDirectoryFiles(
        from samplesDirectory: URL,
        rootFolderName: String?,
        generatedDirectory: URL?,
        sourceFiles: inout [ArchiveSourceFile]
    ) throws {
        let fileManager = FileManager.default
        let basePath = samplesDirectory.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: samplesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let sampleDefaultDate = samplePhotoDates(in: samplesDirectory).max() ?? fallbackDate(for: samplesDirectory)
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            guard !isCurrentSampleLogFile(fileURL) else { continue }

            var relativeChildPath = String(fileURL.standardizedFileURL.path.dropFirst(basePath.count))
            if relativeChildPath.hasPrefix("/") {
                relativeChildPath.removeFirst()
            }

            let itemRootPath = archiveRootPath(
                rootFolderName: rootFolderName,
                dayFolder: exportDayString(from: sampleFileExportDate(for: fileURL, defaultDate: sampleDefaultDate)),
                itemName: sampleArchiveFolderName(for: fileURL)
            )
            sourceFiles.append(ArchiveSourceFile(
                fileURL: fileURL,
                relativePath: zipPath(itemRootPath + "/" + relativeChildPath),
                size: UInt64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? Date()
            ))
        }

        if let generatedDirectory = generatedDirectory {
            try appendDailySampleLogFiles(
                from: samplesDirectory,
                rootFolderName: rootFolderName,
                generatedDirectory: generatedDirectory,
                defaultDate: sampleDefaultDate,
                sourceFiles: &sourceFiles
            )
        }
    }

    private static func appendDailySampleLogFiles(
        from samplesDirectory: URL,
        rootFolderName: String?,
        generatedDirectory: URL,
        defaultDate: Date,
        sourceFiles: inout [ArchiveSourceFile]
    ) throws {
        let rowsByDay = Dictionary(grouping: sampleLogRows(in: samplesDirectory, defaultDate: defaultDate)) { row in
            exportDayString(from: row.date)
        }
        guard !rowsByDay.isEmpty else { return }

        for dayFolder in rowsByDay.keys.sorted() {
            let rows = (rowsByDay[dayFolder] ?? []).sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                return lhs.text < rhs.text
            }
            let generatedDayDirectory = generatedDirectory.appendingPathComponent(dayFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: generatedDayDirectory, withIntermediateDirectories: true)

            let csvFilename = "samples_log_\(dayFolder).csv"
            let csvData = sampleLogCSVData(rows: rows.map(\.text))
            let csvURL = generatedDayDirectory.appendingPathComponent(csvFilename)
            try csvData.write(to: csvURL, options: .atomic)
            appendGeneratedSampleLogFile(
                csvURL,
                filename: csvFilename,
                dayFolder: dayFolder,
                rootFolderName: rootFolderName,
                size: UInt64(csvData.count),
                modifiedAt: rows.map(\.date).max() ?? defaultDate,
                sourceFiles: &sourceFiles
            )

            let xlsxFilename = "samples_log_\(dayFolder).xlsx"
            let xlsxData = sampleLogXLSXData(rows: rows.map(\.text))
            let xlsxURL = generatedDayDirectory.appendingPathComponent(xlsxFilename)
            try xlsxData.write(to: xlsxURL, options: .atomic)
            appendGeneratedSampleLogFile(
                xlsxURL,
                filename: xlsxFilename,
                dayFolder: dayFolder,
                rootFolderName: rootFolderName,
                size: UInt64(xlsxData.count),
                modifiedAt: rows.map(\.date).max() ?? defaultDate,
                sourceFiles: &sourceFiles
            )
        }
    }

    private static func appendGeneratedSampleLogFile(
        _ fileURL: URL,
        filename: String,
        dayFolder: String,
        rootFolderName: String?,
        size: UInt64,
        modifiedAt: Date,
        sourceFiles: inout [ArchiveSourceFile]
    ) {
        let itemRootPath = archiveRootPath(
            rootFolderName: rootFolderName,
            dayFolder: dayFolder,
            itemName: "03_sample_logs"
        )
        sourceFiles.append(ArchiveSourceFile(
            fileURL: fileURL,
            relativePath: zipPath(itemRootPath + "/" + filename),
            size: size,
            modifiedAt: modifiedAt
        ))
    }

    private static func sampleLogRows(in samplesDirectory: URL, defaultDate: Date) -> [SampleLogRow] {
        let csvURL = samplesDirectory.appendingPathComponent("samples_log.csv")
        guard var content = try? String(contentsOf: csvURL, encoding: .utf8) else { return [] }
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }

        let lines = content.components(separatedBy: "\n")
        return lines
            .dropFirst()
            .filter { !$0.isEmpty }
            .map { row in
                SampleLogRow(
                    text: row,
                    date: sampleLogDate(from: row) ?? defaultDate
                )
            }
    }

    private static func sampleLogCSVData(rows: [String]) -> Data {
        var data = utf8BOM
        data.append(contentsOf: sampleLogCSVHeader.utf8)
        if !rows.isEmpty {
            data.append(contentsOf: rows.joined(separator: "\n").utf8)
            data.append(0x0A)
        }
        return data
    }

    private static func sampleLogXLSXData(rows: [String]) -> Data {
        var data = utf8BOM
        let header = sampleLogCSVHeader.trimmingCharacters(in: .newlines)
        let tsv = ([header] + rows)
            .map { parseCSVRow($0).joined(separator: "\t") }
            .joined(separator: "\n")
        data.append(contentsOf: tsv.utf8)
        return data
    }

    private static func fullExportPackageName(exportInfos: [ExportItemInfo]) -> String {
        let dates = exportInfos.flatMap { info -> [Date] in
            guard info.url.lastPathComponent == "samples" else {
                return [info.exportDate]
            }
            let sampleDates = samplePhotoDates(in: info.url)
            return sampleDates.isEmpty ? [info.exportDate] : sampleDates
        }
        guard let startDate = dates.min(), let endDate = dates.max() else {
            return "StrayScanner_export_\(exportTimestamp())"
        }

        let start = exportDayString(from: startDate)
        let end = exportDayString(from: endDate)
        if start == end {
            return "StrayScanner_export_\(start)"
        }
        return "StrayScanner_export_\(start)_to_\(end)"
    }

    private static func exportItemInfo(from item: URL) -> ExportItemInfo {
        let fileManager = FileManager.default
        let name = item.lastPathComponent
        if name == "samples" {
            return ExportItemInfo(
                url: item,
                exportName: name,
                exportDate: sampleDirectoryExportDate(in: item)
            )
        }
        if fileManager.fileExists(atPath: item.appendingPathComponent("rgb.mp4").path) {
            return ExportItemInfo(
                url: item,
                exportName: exportFolderName(for: item, fallback: name),
                exportDate: recordingDate(for: item) ?? fallbackDate(for: item)
            )
        }
        return ExportItemInfo(
            url: item,
            exportName: name,
            exportDate: fallbackDate(for: item)
        )
    }

    private static func archiveRootPath(
        rootFolderName: String?,
        dayFolder: String?,
        itemName: String
    ) -> String {
        zipPath([rootFolderName, dayFolder, itemName].compactMap { $0 }.joined(separator: "/"))
    }

    private static func exportDayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "ddMMyyyy"
        return formatter.string(from: date)
    }

    private static func recordingDate(for directory: URL) -> Date? {
        let metadataURL = directory.appendingPathComponent("sample_metadata.json")
        guard
            let data = try? Data(contentsOf: metadataURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return recordedDate(from: metadataString(json["recorded_at"]))
    }

    private static func sampleDirectoryExportDate(in directory: URL) -> Date {
        samplePhotoDates(in: directory).min() ?? fallbackDate(for: directory)
    }

    private static func samplePhotoDates(in directory: URL) -> [Date] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var dates: [Date] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard isSampleImageFile(fileURL) else { continue }
            dates.append(fileExportDate(for: fileURL))
        }
        return dates
    }

    private static func sampleArchiveFolderName(for fileURL: URL) -> String {
        isSampleImageFile(fileURL) ? "02_sample_photos" : "04_sample_data"
    }

    private static func isSampleImageFile(_ fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg"
    }

    private static func isCurrentSampleLogFile(_ fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "csv" || ext == "xlsx" else { return false }
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return stem == "samples_log" || stem.hasPrefix("samples_log_")
    }

    private static func sampleLogDate(from row: String) -> Date? {
        let fields = parseCSVRow(row)
        if let filename = fields.first, let date = timestampDate(fromFilename: filename) {
            return date
        }
        if fields.count > 4 {
            return sampleLogDisplayDate(from: fields[4])
        }
        return nil
    }

    private static func sampleFileExportDate(for fileURL: URL, defaultDate: Date) -> Date {
        if let timestampDate = timestampDate(fromFilename: fileURL.lastPathComponent) {
            return timestampDate
        }

        if isSampleImageFile(fileURL) {
            return fallbackDate(for: fileURL)
        }
        return defaultDate
    }

    private static func fileExportDate(for fileURL: URL) -> Date {
        if let timestampDate = timestampDate(fromFilename: fileURL.lastPathComponent) {
            return timestampDate
        }
        return fallbackDate(for: fileURL)
    }

    private static func timestampDate(fromFilename filename: String) -> Date? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        for index in 0..<(parts.count - 1) {
            let candidate = "\(parts[index])_\(parts[index + 1])"
            if let date = formatter.date(from: candidate) {
                return date
            }
        }
        return nil
    }

    private static func sampleLogDisplayDate(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return date
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "dd/MM/yyyy HH:mm:ss",
            "dd/MM/yyyy HH:mm"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        for locale in [Locale.current, Locale(identifier: "vi_VN"), Locale(identifier: "en_US")] {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private static func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var index = row.startIndex
        while index < row.endIndex {
            let character = row[index]
            if character == "\"" {
                let next = row.index(after: index)
                if inQuotes && next < row.endIndex && row[next] == "\"" {
                    current.append("\"")
                    index = row.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = row.index(after: index)
        }
        fields.append(current)
        return fields
    }

    private static func fallbackDate(for url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private static func zipPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
    }

    private static func uniqueExportName(_ preferredName: String, usedNames: inout Set<String>) -> String {
        guard usedNames.contains(preferredName) else {
            usedNames.insert(preferredName)
            return preferredName
        }

        var counter = 2
        while usedNames.contains("\(preferredName)_\(counter)") {
            counter += 1
        }
        let uniqueName = "\(preferredName)_\(counter)"
        usedNames.insert(uniqueName)
        return uniqueName
    }

    private static func exportFolderName(for directory: URL, fallback: String) -> String {
        guard fallback != "samples" else { return fallback }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("rgb.mp4").path) else {
            return fallback
        }

        let metadataURL = directory.appendingPathComponent("sample_metadata.json")
        guard
            let data = try? Data(contentsOf: metadataURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return fallback
        }

        let sampleID = metadataString(json["sample_id"])
        guard !sampleID.isEmpty else { return fallback }
        let isImportant = metadataBool(json["is_important"]) ||
            metadataString(json["sample_flag"]) == "*" ||
            metadataString(json["flag"]) == "*"
        let timestamp = exportTimestamp(fromRecordedAt: metadataString(json["recorded_at"]))
        let safeSampleID = SampleContextStore.folderSafeSampleID(sampleID)
        guard !safeSampleID.isEmpty else { return fallback }
        let flag = isImportant ? "*" : ""
        return "\(safeSampleID)\(flag)_video_\(timestamp)"
    }

    private static func metadataString(_ value: Any?) -> String {
        guard let value = value, !(value is NSNull) else { return "" }
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func metadataBool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["true", "yes", "1", "*"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
    }

    private static func exportTimestamp(fromRecordedAt recordedAtText: String) -> String {
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.dateFormat = "yyyyMMdd_HHmmss"

        if let date = recordedDate(from: recordedAtText) {
            return output.string(from: date)
        }
        return output.string(from: Date())
    }

    private static func recordedDate(from recordedAtText: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: recordedAtText) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: recordedAtText) {
            return date
        }
        return nil
    }

    private static func shouldIncludeInFullExport(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let name = url.lastPathComponent
        if name == "samples" || name.hasPrefix("cay_") {
            return true
        }
        return fileManager.fileExists(atPath: url.appendingPathComponent("rgb.mp4").path)
    }

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func createStoredZipArchive(
        sourceFiles: [ArchiveSourceFile],
        destinationURL: URL,
        progress: (UInt64, String) -> Void
    ) throws {
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? fileHandle.close() }

        var offset: UInt64 = 0
        var centralDirectoryEntries: [CentralDirectoryEntry] = []

        func write(_ data: Data) {
            fileHandle.write(data)
            offset += UInt64(data.count)
        }

        for source in sourceFiles {
            let localHeaderOffset = offset
            let fileNameData = Data(source.relativePath.utf8)
            let usesZip64Size = source.size > UInt64(UInt32.max)
            let extraField = usesZip64Size
                ? zip64ExtraField(uncompressedSize: source.size, compressedSize: source.size)
                : Data()
            let (dosTime, dosDate) = dosDateTime(from: source.modifiedAt)

            var localHeader = Data()
            localHeader.appendUInt32LE(0x04034b50)
            localHeader.appendUInt16LE(usesZip64Size ? 45 : 20)
            localHeader.appendUInt16LE(0x0808)
            localHeader.appendUInt16LE(0)
            localHeader.appendUInt16LE(dosTime)
            localHeader.appendUInt16LE(dosDate)
            localHeader.appendUInt32LE(0)
            localHeader.appendUInt32LE(usesZip64Size ? UInt32.max : 0)
            localHeader.appendUInt32LE(usesZip64Size ? UInt32.max : 0)
            localHeader.appendUInt16LE(UInt16(fileNameData.count))
            localHeader.appendUInt16LE(UInt16(extraField.count))
            localHeader.append(fileNameData)
            localHeader.append(extraField)
            write(localHeader)

            var crc32 = CRC32()
            let input = try FileHandle(forReadingFrom: source.fileURL)

            while true {
                let chunk = input.readData(ofLength: 1024 * 1024)
                guard !chunk.isEmpty else { break }
                crc32.update(chunk)
                write(chunk)
                progress(UInt64(chunk.count), source.relativePath)
            }
            try? input.close()

            var descriptor = Data()
            descriptor.appendUInt32LE(0x08074b50)
            descriptor.appendUInt32LE(crc32.checksum)
            if usesZip64Size {
                descriptor.appendUInt64LE(source.size)
                descriptor.appendUInt64LE(source.size)
            } else {
                descriptor.appendUInt32LE(UInt32(source.size))
                descriptor.appendUInt32LE(UInt32(source.size))
            }
            write(descriptor)

            centralDirectoryEntries.append(CentralDirectoryEntry(
                path: source.relativePath,
                crc32: crc32.checksum,
                compressedSize: source.size,
                uncompressedSize: source.size,
                localHeaderOffset: localHeaderOffset,
                modifiedAt: source.modifiedAt
            ))
        }

        let centralDirectoryOffset = offset
        for entry in centralDirectoryEntries {
            let fileNameData = Data(entry.path.utf8)
            let needsZip64Size = entry.uncompressedSize > UInt64(UInt32.max) || entry.compressedSize > UInt64(UInt32.max)
            let needsZip64Offset = entry.localHeaderOffset > UInt64(UInt32.max)
            let extraField = zip64ExtraField(
                uncompressedSize: needsZip64Size ? entry.uncompressedSize : nil,
                compressedSize: needsZip64Size ? entry.compressedSize : nil,
                localHeaderOffset: needsZip64Offset ? entry.localHeaderOffset : nil
            )
            let usesZip64 = !extraField.isEmpty
            let (dosTime, dosDate) = dosDateTime(from: entry.modifiedAt)

            var centralHeader = Data()
            centralHeader.appendUInt32LE(0x02014b50)
            centralHeader.appendUInt16LE(usesZip64 ? 45 : 20)
            centralHeader.appendUInt16LE(usesZip64 ? 45 : 20)
            centralHeader.appendUInt16LE(0x0808)
            centralHeader.appendUInt16LE(0)
            centralHeader.appendUInt16LE(dosTime)
            centralHeader.appendUInt16LE(dosDate)
            centralHeader.appendUInt32LE(entry.crc32)
            centralHeader.appendUInt32LE(needsZip64Size ? UInt32.max : UInt32(entry.compressedSize))
            centralHeader.appendUInt32LE(needsZip64Size ? UInt32.max : UInt32(entry.uncompressedSize))
            centralHeader.appendUInt16LE(UInt16(fileNameData.count))
            centralHeader.appendUInt16LE(UInt16(extraField.count))
            centralHeader.appendUInt16LE(0)
            centralHeader.appendUInt16LE(0)
            centralHeader.appendUInt16LE(0)
            centralHeader.appendUInt32LE(0)
            centralHeader.appendUInt32LE(needsZip64Offset ? UInt32.max : UInt32(entry.localHeaderOffset))
            centralHeader.append(fileNameData)
            centralHeader.append(extraField)
            write(centralHeader)
        }

        let centralDirectorySize = offset - centralDirectoryOffset
        let needsZip64End = centralDirectoryEntries.count > Int(UInt16.max)
            || centralDirectorySize > UInt64(UInt32.max)
            || centralDirectoryOffset > UInt64(UInt32.max)

        if needsZip64End {
            let zip64EndOffset = offset
            var zip64End = Data()
            zip64End.appendUInt32LE(0x06064b50)
            zip64End.appendUInt64LE(44)
            zip64End.appendUInt16LE(45)
            zip64End.appendUInt16LE(45)
            zip64End.appendUInt32LE(0)
            zip64End.appendUInt32LE(0)
            zip64End.appendUInt64LE(UInt64(centralDirectoryEntries.count))
            zip64End.appendUInt64LE(UInt64(centralDirectoryEntries.count))
            zip64End.appendUInt64LE(centralDirectorySize)
            zip64End.appendUInt64LE(centralDirectoryOffset)
            write(zip64End)

            var locator = Data()
            locator.appendUInt32LE(0x07064b50)
            locator.appendUInt32LE(0)
            locator.appendUInt64LE(zip64EndOffset)
            locator.appendUInt32LE(1)
            write(locator)
        }

        var end = Data()
        end.appendUInt32LE(0x06054b50)
        end.appendUInt16LE(0)
        end.appendUInt16LE(0)
        end.appendUInt16LE(needsZip64End ? UInt16.max : UInt16(centralDirectoryEntries.count))
        end.appendUInt16LE(needsZip64End ? UInt16.max : UInt16(centralDirectoryEntries.count))
        end.appendUInt32LE(needsZip64End ? UInt32.max : UInt32(centralDirectorySize))
        end.appendUInt32LE(needsZip64End ? UInt32.max : UInt32(centralDirectoryOffset))
        end.appendUInt16LE(0)
        write(end)
    }

    private static func zip64ExtraField(
        uncompressedSize: UInt64? = nil,
        compressedSize: UInt64? = nil,
        localHeaderOffset: UInt64? = nil
    ) -> Data {
        var payload = Data()
        if let uncompressedSize = uncompressedSize {
            payload.appendUInt64LE(uncompressedSize)
        }
        if let compressedSize = compressedSize {
            payload.appendUInt64LE(compressedSize)
        }
        if let localHeaderOffset = localHeaderOffset {
            payload.appendUInt64LE(localHeaderOffset)
        }
        guard !payload.isEmpty else { return Data() }

        var field = Data()
        field.appendUInt16LE(0x0001)
        field.appendUInt16LE(UInt16(payload.count))
        field.append(payload)
        return field
    }

    private static func dosDateTime(from date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(components.year ?? 1980, 1980), 2107)
        let month = min(max(components.month ?? 1, 1), 12)
        let day = min(max(components.day ?? 1, 1), 31)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let second = min(max(components.second ?? 0, 0), 59)
        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private struct CRC32 {
    private static let table: [UInt32] = (0...255).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = 0xedb88320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    private var value: UInt32 = 0xffffffff

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<rawBuffer.count {
                let byte = UInt32(bytes[index])
                value = Self.table[Int((value ^ byte) & 0xff)] ^ (value >> 8)
            }
        }
    }

    var checksum: UInt32 {
        value ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        appendIntegerLE(value)
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        appendIntegerLE(value)
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        appendIntegerLE(value)
    }

    private mutating func appendIntegerLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
