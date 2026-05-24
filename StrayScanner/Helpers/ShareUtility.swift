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

    private struct CentralDirectoryEntry {
        let path: String
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let modifiedAt: Date
    }
    
    /// Creates a shareable ZIP archive from a recording's dataset
    /// - Parameter recording: The recording to create a ZIP archive for
    /// - Returns: URL of the created ZIP file
    static func createShareableArchive(for recording: Recording) async throws -> URL {
        guard let sourceDirectory = recording.directoryPath() else {
            throw NSError(domain: "ShareError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to get recording directory path"])
        }
        
        let tempDirectory = FileManager.default.temporaryDirectory
        let archiveURL = tempDirectory.appendingPathComponent(sourceDirectory.lastPathComponent + ".zip")
        
        // Remove existing archive if it exists
        try? FileManager.default.removeItem(at: archiveURL)
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try createZipArchive(sourceDirectory: sourceDirectory, destinationURL: archiveURL)
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
        let timestamp = exportTimestamp()
        let packageName = "StrayScanner_export_\(timestamp)"
        let archiveURL = tempDirectory.appendingPathComponent("\(packageName).zip")

        try? fileManager.removeItem(at: archiveURL)

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

        let sourceFiles = try archiveSourceFiles(from: exportItems, rootFolderName: packageName)
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
        rootFolderName: String
    ) throws -> [ArchiveSourceFile] {
        var sourceFiles: [ArchiveSourceFile] = []
        let fileManager = FileManager.default
        let sortedItems = exportItems.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for item in sortedItems {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            if values.isDirectory == true {
                let basePath = item.standardizedFileURL.path
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
                    let relativePath = rootFolderName + "/" + item.lastPathComponent + "/" + relativeChildPath
                    sourceFiles.append(ArchiveSourceFile(
                        fileURL: fileURL,
                        relativePath: zipPath(relativePath),
                        size: UInt64(fileValues.fileSize ?? 0),
                        modifiedAt: fileValues.contentModificationDate ?? Date()
                    ))
                }
            } else if values.isRegularFile == true {
                sourceFiles.append(ArchiveSourceFile(
                    fileURL: item,
                    relativePath: zipPath(rootFolderName + "/" + item.lastPathComponent),
                    size: UInt64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? Date()
                ))
            }
        }

        return sourceFiles.sorted { $0.relativePath < $1.relativePath }
    }

    private static func zipPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
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
    
    private static func createZipArchive(sourceDirectory: URL, destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: sourceDirectory, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                try FileManager.default.copyItem(at: zipURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let error = coordinatorError ?? copyError {
            throw error
        }
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
