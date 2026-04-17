//
//  SampleLogger.swift
//  StrayScanner
//

import Foundation

struct SampleRecord {
    let sampleID: String
    let tenMau: String
    let latitude: Double?
    let longitude: Double?
    let location: String       // reverse-geocoded place name
    let site: String           // user-entered site
    let huongManhXam: String   // N NE E SE S SW W NW
    let huongLayMau: String    // Upslope / Mid / Downslope
    let altitude: Double?
    let loaiMau: String        // LU / TL / Khác
    let ngayLay: String        // display date string
    let fileAnh: String        // JPEG filename only
}

class SampleLogger {
    static let shared = SampleLogger()

    private let samplesDir: URL
    private let csvURL: URL
    // NOTE: True XLSX (OOXML/ZIP) requires a third-party library (e.g. CoreXLSX).
    // exportXLSX() writes the same data as tab-separated values with a .xlsx
    // extension so Excel / Numbers can open it via their CSV import fallback.
    // Replace the body of exportXLSX() with a real library call for full compatibility.
    private let xlsxURL: URL

    private static let csvHeader =
        "Sample-ID,Tên mẫu,Lat,Long,Location,Site," +
        "Hướng mảnh xăm,Hướng lấy mẫu,Altitude_m," +
        "Loại mẫu,Ngày lấy,File ảnh\n"

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        samplesDir = docs.appendingPathComponent("samples", isDirectory: true)
        csvURL  = samplesDir.appendingPathComponent("samples_log.csv")
        xlsxURL = samplesDir.appendingPathComponent("samples_log.xlsx")
        try? FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)
    }

    var samplesDirectory: URL { samplesDir }

    // MARK: - Next ID

    /// Returns the next Sample ID for the given prefix.
    /// Scans existing CSV for rows whose ID begins with "\(prefix)." and increments
    /// the numeric suffix. e.g. prefix "LU-1", existing "LU-1.3" → "LU-1.4".
    /// If no records for prefix exist yet, returns "\(prefix).1".
    /// If prefix contains no "-" (bare type code like "LU"), prepends "-1" first
    /// so the initial ID is "LU-1.1".
    func nextSampleID(prefix: String) -> String {
        if !prefix.contains("-") {
            return nextSampleID(prefix: "\(prefix)-1")
        }
        let matchPrefix = prefix + "."
        var maxSuffix = 0
        var found = false
        for row in existingDataRows() {
            let id = firstField(of: row)
            guard id.hasPrefix(matchPrefix) else { continue }
            let suffix = String(id.dropFirst(matchPrefix.count))
            if let n = Int(suffix) {
                found = true
                maxSuffix = max(maxSuffix, n)
            }
        }
        return "\(prefix).\(found ? maxSuffix + 1 : 1)"
    }

    // MARK: - Append

    func append(record: SampleRecord) throws {
        if !FileManager.default.fileExists(atPath: csvURL.path) {
            try Self.csvHeader.write(to: csvURL, atomically: true, encoding: .utf8)
        }

        let lat = record.latitude.map  { String($0) } ?? ""
        let lon = record.longitude.map { String($0) } ?? ""
        let alt = record.altitude.map  { String($0) } ?? ""

        let row = [
            escape(record.sampleID), escape(record.tenMau),
            lat, lon,
            escape(record.location), escape(record.site),
            escape(record.huongManhXam), escape(record.huongLayMau),
            alt,
            escape(record.loaiMau), escape(record.ngayLay), escape(record.fileAnh)
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
        guard let csvString = try? String(contentsOf: csvURL, encoding: .utf8) else { return }
        let tsv = csvString
            .components(separatedBy: "\n")
            .map { parseCSVRow($0).joined(separator: "\t") }
            .joined(separator: "\n")
        try? tsv.write(to: xlsxURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private helpers

    private func existingDataRows() -> [String] {
        guard let content = try? String(contentsOf: csvURL, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n")
        return lines.dropFirst().filter { !$0.isEmpty }
    }

    private func firstField(of row: String) -> String {
        parseCSVRow(row).first ?? ""
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
