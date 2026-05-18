//
//  ShareUtility.swift
//  StrayScanner
//
//  Created by Claude on 6/24/25.
//

import Foundation

/// Utility class for creating shareable archives from recording datasets
class ShareUtility {
    
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
    static func createFullDataArchive() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let archiveURL = try createFullDataArchiveSync()
                    continuation.resume(returning: archiveURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func createFullDataArchiveSync() throws -> URL {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        SampleLogger.shared.prepareStorageForExport()
        let tempDirectory = fileManager.temporaryDirectory
        let timestamp = exportTimestamp()
        let packageName = "StrayScanner_export_\(timestamp)"
        let stagingURL = tempDirectory.appendingPathComponent(packageName, isDirectory: true)
        let archiveURL = tempDirectory.appendingPathComponent("\(packageName).zip")

        try? fileManager.removeItem(at: stagingURL)
        try? fileManager.removeItem(at: archiveURL)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        let exportItems = try fileManager.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { shouldIncludeInFullExport($0) }

        guard !exportItems.isEmpty else {
            throw NSError(
                domain: "ShareError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Không có data để xuất ZIP."]
            )
        }

        for item in exportItems {
            try fileManager.copyItem(
                at: item,
                to: stagingURL.appendingPathComponent(item.lastPathComponent)
            )
        }

        try createZipArchive(sourceDirectory: stagingURL, destinationURL: archiveURL)
        try? fileManager.removeItem(at: stagingURL)
        return archiveURL
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
