//
//  SampleLogger.swift
//  StrayScanner
//

import Foundation

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

class SampleLogger {
    static let shared = SampleLogger()
    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    private let samplesDir: URL
    private let csvURL: URL
    // NOTE: True XLSX (OOXML/ZIP) requires a third-party library (e.g. CoreXLSX).
    // exportXLSX() writes the same data as tab-separated values with a .xlsx
    // extension so Excel / Numbers can open it via their CSV import fallback.
    // Replace the body of exportXLSX() with a real library call for full compatibility.
    private let xlsxURL: URL

    private static let csvHeader =
        "File ảnh,Sample-ID,Flag,Loại mẫu,Ngày lấy," +
        "Lat,Long,GPS_accuracy_m,Altitude_m," +
        "Hướng camera degree,Hướng camera cardinal," +
        "Hướng mảnh xăm degree,Hướng mảnh xăm cardinal," +
        "Location,Site,Hướng lấy mẫu\n"
    private static let currentColumnCount = 16
    private static let noFlagColumnCount = 15
    private static let previousColumnCount = 16
    private static let noCameraWithTenMauColumnCount = 15
    private static let legacyColumnCount = 12
    private static let headingLegacyColumnCount = 14

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        samplesDir = docs.appendingPathComponent("samples", isDirectory: true)
        csvURL  = samplesDir.appendingPathComponent("samples_log.csv")
        xlsxURL = samplesDir.appendingPathComponent("samples_log.xlsx")
        try? FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)
    }

    var samplesDirectory: URL {
        try? ensureSamplesDirectory()
        return samplesDir
    }

    func sampleImageFiles() -> [URL] {
        try? ensureSamplesDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: samplesDir,
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

    func deleteSamplePhoto(filename: String) throws {
        try ensureSamplesDirectory()
        try ensureCurrentCSVHeader()

        let photoURL = samplesDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: photoURL.path) {
            try FileManager.default.removeItem(at: photoURL)
        }

        try removeRows(forPhotoFilename: filename)
        exportXLSX()
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
        guard let content = try? String(contentsOf: csvURL, encoding: .utf8) else { return [] }
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
