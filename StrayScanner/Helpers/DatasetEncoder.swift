//
//  DatasetEncoder.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 1/2/21.
//  Copyright © 2021 Stray Robots. All rights reserved.
//

import Foundation
import ARKit
import CoreMotion

// MARK: - Location writers

private class LocationCSVWriter {
    private let fileHandle: FileHandle
    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    init(url: URL) {
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            self.fileHandle = try FileHandle(forWritingTo: url)
            let header = "timestamp_iso,timestamp_unix,latitude,longitude,altitude_asl_m,gps_accuracy_m,heading_degrees,heading_cardinal,place_name,locality,cam_yaw,cam_pitch,cam_roll,slope_degrees,gravity_x,gravity_y,gravity_z\n"
            fileHandle.write(Self.utf8BOM)
            fileHandle.write(header.data(using: .utf8)!)
        } catch let error {
            print("Can't create location.csv: \(error.localizedDescription)")
            preconditionFailure("Can't open location.csv for writing.")
        }
    }

    func add(metadata: FrameLocationMetadata) {
        let lat   = metadata.latitude.map           { "\($0)" } ?? ""
        let lon   = metadata.longitude.map          { "\($0)" } ?? ""
        let alt   = metadata.altitude_asl_m.map     { "\($0)" } ?? ""
        let acc   = metadata.gps_accuracy_m.map     { "\($0)" } ?? ""
        let hdg   = metadata.heading_degrees.map    { "\($0)" } ?? ""
        let card  = metadata.heading_cardinal       ?? ""
        let place = metadata.place_name   ?? ""
        let loc   = metadata.locality     ?? ""
        let slope = metadata.slope_degrees.map  { "\($0)" } ?? ""
        let gx    = metadata.gravity_x.map      { "\($0)" } ?? ""
        let gy    = metadata.gravity_y.map      { "\($0)" } ?? ""
        let gz    = metadata.gravity_z.map      { "\($0)" } ?? ""

        let fields = [
            metadata.timestamp_iso,
            "\(metadata.timestamp_unix)",
            lat,
            lon,
            alt,
            acc,
            hdg,
            card,
            place,
            loc,
            "\(metadata.cam_yaw)",
            "\(metadata.cam_pitch)",
            "\(metadata.cam_roll)",
            slope,
            gx,
            gy,
            gz
        ]
        let line = fields.map(Self.csvField).joined(separator: ",") + "\n"
        fileHandle.write(line.data(using: .utf8)!)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func done() {
        do {
            try fileHandle.close()
        } catch let error {
            print("Closing location.csv failed: \(error.localizedDescription)")
        }
    }
}

private class LocationJSONWriter {
    private let url: URL
    private var frames: [[String: Any]] = []

    init(url: URL) {
        self.url = url
    }

    func add(metadata: FrameLocationMetadata, frameNumber: Int) {
        var dict: [String: Any] = [
            "frame": frameNumber,
            "timestamp_iso": metadata.timestamp_iso,
            "timestamp_unix": metadata.timestamp_unix,
            "cam_yaw": metadata.cam_yaw,
            "cam_pitch": metadata.cam_pitch,
            "cam_roll": metadata.cam_roll
        ]
        if let v = metadata.latitude          { dict["latitude"] = v }
        if let v = metadata.longitude         { dict["longitude"] = v }
        if let v = metadata.altitude_asl_m    { dict["altitude_asl_m"] = v }
        if let v = metadata.gps_accuracy_m    { dict["gps_accuracy_m"] = v }
        if let v = metadata.heading_degrees   { dict["heading_degrees"] = v }
        if let v = metadata.heading_cardinal  { dict["heading_cardinal"] = v }
        if let v = metadata.place_name        { dict["place_name"] = v }
        if let v = metadata.locality          { dict["locality"] = v }
        if let v = metadata.slope_degrees     { dict["slope_degrees"] = v }
        if let v = metadata.gravity_x         { dict["gravity_x"] = v }
        if let v = metadata.gravity_y         { dict["gravity_y"] = v }
        if let v = metadata.gravity_z         { dict["gravity_z"] = v }
        frames.append(dict)
    }

    func done() {
        guard !frames.isEmpty else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted])
            try data.write(to: url)
        } catch let error {
            print("Could not write location.json: \(error.localizedDescription)")
        }
    }
}

// MARK: - Point cloud encoder

private class PointCloudEncoder {
    // Deduplicated by ARKit identifier; always stores the latest (most refined) position.
    private var points: [UInt64: (position: simd_float3, confidence: Float)] = [:]
    private var frameTransforms: [(frame: Int, timestamp: Double, transform: simd_float4x4)] = []
    private let datasetDirectory: URL

    init(datasetDirectory: URL) {
        self.datasetDirectory = datasetDirectory
        writeGPSAnchor()
    }

    func add(frame: ARFrame, frameNumber: Int) {
        // Accumulate feature points; overwrite with latest position so the
        // final PLY has the most refined coordinate for each tracked point.
        if let cloud = frame.rawFeaturePoints {
            let conf: Float = frame.capturedDepthData != nil ? 1.0 : 0.5
            for (i, identifier) in cloud.identifiers.enumerated() {
                points[identifier] = (position: cloud.points[i], confidence: conf)
            }
        }
        frameTransforms.append((
            frame: frameNumber,
            timestamp: frame.timestamp,
            transform: frame.camera.transform
        ))
    }

    func done() {
        writePLY()
        writeFrameTransforms()
    }

    // MARK: - GPS anchor

    private func writeGPSAnchor() {
        let url = datasetDirectory.appendingPathComponent("tree_gps_anchor.json")
        let location = LocationMetadataManager.shared.currentLocation

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNow = formatter.string(from: Date())

        var dict: [String: Any] = ["scan_start_iso": isoNow]
        if let loc = location {
            dict["anchor_lat"]        = loc.coordinate.latitude
            dict["anchor_lon"]        = loc.coordinate.longitude
            dict["anchor_alt"]        = loc.altitude
            dict["anchor_accuracy_m"] = max(loc.horizontalAccuracy, 0)
        } else {
            dict["anchor_lat"]        = NSNull()
            dict["anchor_lon"]        = NSNull()
            dict["anchor_alt"]        = NSNull()
            dict["anchor_accuracy_m"] = NSNull()
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch let error {
            print("Could not write tree_gps_anchor.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Binary PLY

    private func writePLY() {
        let url = datasetDirectory.appendingPathComponent("point_cloud_raw.ply")
        let pointList = Array(points.values)
        let count = pointList.count

        var header = ""
        header += "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "element vertex \(count)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        header += "property float confidence\n"
        header += "end_header\n"

        var data = Data()
        data.append(contentsOf: header.utf8)

        for p in pointList {
            appendF32LE(p.position.x, to: &data)
            appendF32LE(p.position.y, to: &data)
            appendF32LE(p.position.z, to: &data)
            appendF32LE(p.confidence,  to: &data)
        }

        do {
            try data.write(to: url)
        } catch let error {
            print("Could not write point_cloud_raw.ply: \(error.localizedDescription)")
        }
    }

    // MARK: - Frame transforms CSV

    private func writeFrameTransforms() {
        let url = datasetDirectory.appendingPathComponent("frame_transforms.csv")
        var csv = "frame,timestamp_unix,t_x,t_y,t_z,m00,m01,m02,m03,m10,m11,m12,m13,m20,m21,m22,m23,m30,m31,m32,m33\n"

        for entry in frameTransforms {
            let c = entry.transform.columns
            // Translation (last column)
            let tx = c.3.x, ty = c.3.y, tz = c.3.z
            // Full matrix in row-major order: m_ij = columns[j][i]
            // row 0: m00 m01 m02 m03
            // row 1: m10 m11 m12 m13
            // row 2: m20 m21 m22 m23
            // row 3: m30 m31 m32 m33
            let mat = "\(c.0.x),\(c.1.x),\(c.2.x),\(c.3.x)," +
                      "\(c.0.y),\(c.1.y),\(c.2.y),\(c.3.y)," +
                      "\(c.0.z),\(c.1.z),\(c.2.z),\(c.3.z)," +
                      "\(c.0.w),\(c.1.w),\(c.2.w),\(c.3.w)"
            csv += "\(entry.frame),\(entry.timestamp),\(tx),\(ty),\(tz),\(mat)\n"
        }

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch let error {
            print("Could not write frame_transforms.csv: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func appendF32LE(_ value: Float, to data: inout Data) {
        // iOS ARM is little-endian; .littleEndian is a no-op here but makes intent explicit.
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

// MARK: - DatasetEncoder

class DatasetEncoder {
    enum Status {
        case allGood
        case videoEncodingError
        case directoryCreationError
    }
    private let rgbEncoder: VideoEncoder
    private let depthEncoder: DepthEncoder
    private let confidenceEncoder: ConfidenceEncoder
    private let datasetDirectory: URL
    private let odometryEncoder: OdometryEncoder
    private let imuEncoder: IMUEncoder
    private let distortionEncoder: DistortionEncoder
    private let locationCSVWriter: LocationCSVWriter
    private let locationJSONWriter: LocationJSONWriter
    private let pointCloudEncoder: PointCloudEncoder
    private var lastFrame: ARFrame?
    private var dispatchGroup = DispatchGroup()
    private var currentFrame: Int = -1
    private var savedFrames: Int = 0
    private let frameInterval: Int // Only save every frameInterval-th frame.
    private let encodingSemaphore = DispatchSemaphore(value: 3) // Limit queued frames to avoid ARFrame retention
    public let id: UUID
    public let rgbFilePath: URL // Relative to app document directory.
    public let depthFilePath: URL // Relative to app document directory.
    public let cameraMatrixPath: URL
    public let odometryPath: URL
    public let imuPath: URL
    public let sampleID: String?
    public let sampleIsImportant: Bool
    public var status = Status.allGood
    private let queue: DispatchQueue
    
    private var latestAccelerometerData: (timestamp: Double, data: simd_double3)?
    private var latestGyroscopeData: (timestamp: Double, data: simd_double3)?


    init(
        arConfiguration: ARWorldTrackingConfiguration,
        fpsDivider: Int = 1,
        isImportant: Bool = false,
        sampleContext: SampleContext? = nil
    ) {
        self.frameInterval = fpsDivider
        self.queue = DispatchQueue(label: "encoderQueue")
        self.sampleID = sampleContext?.sampleID
        self.sampleIsImportant = isImportant || (sampleContext?.isImportant ?? false)
        
        let width = arConfiguration.videoFormat.imageResolution.width
        let height = arConfiguration.videoFormat.imageResolution.height
        let theId = UUID()
        datasetDirectory = DatasetEncoder.createDirectory(
            sampleID: sampleContext?.sampleID,
            isImportant: self.sampleIsImportant
        )
        self.id = theId
        self.rgbFilePath = datasetDirectory.appendingPathComponent("rgb.mp4")
        self.rgbEncoder = VideoEncoder(file: self.rgbFilePath, width: width, height: height)
        self.depthFilePath = datasetDirectory.appendingPathComponent("depth", isDirectory: true)
        self.depthEncoder = DepthEncoder(outDirectory: self.depthFilePath)
        let confidenceFilePath = datasetDirectory.appendingPathComponent("confidence", isDirectory: true)
        self.confidenceEncoder = ConfidenceEncoder(outDirectory: confidenceFilePath)
        self.cameraMatrixPath = datasetDirectory.appendingPathComponent("camera_matrix.csv", isDirectory: false)
        self.odometryPath = datasetDirectory.appendingPathComponent("odometry.csv", isDirectory: false)
        self.odometryEncoder = OdometryEncoder(url: self.odometryPath)
        self.imuPath = datasetDirectory.appendingPathComponent("imu.csv", isDirectory: false)
        self.imuEncoder = IMUEncoder(url: self.imuPath)
        self.distortionEncoder = DistortionEncoder(datasetDirectory: datasetDirectory)
        let locationCSVPath = datasetDirectory.appendingPathComponent("location.csv")
        self.locationCSVWriter = LocationCSVWriter(url: locationCSVPath)
        let locationJSONPath = datasetDirectory.appendingPathComponent("location.json")
        self.locationJSONWriter = LocationJSONWriter(url: locationJSONPath)
        self.pointCloudEncoder = PointCloudEncoder(datasetDirectory: datasetDirectory)
        writeSampleMetadata(sampleContext: sampleContext)
    }

    func add(frame: ARFrame, locationMetadata: FrameLocationMetadata? = nil) {
        let totalFrames: Int = currentFrame
        currentFrame = currentFrame + 1
        if (currentFrame % frameInterval != 0) {
            return
        }
        // Drop frame if encoding is backed up to avoid accumulating ARFrame references.
        guard encodingSemaphore.wait(timeout: .now()) == .success else {
            return
        }
        let frameNumber: Int = savedFrames
        savedFrames = savedFrames + 1
        dispatchGroup.enter()
        queue.async {
            defer {
                self.encodingSemaphore.signal()
                self.dispatchGroup.leave()
            }
            if let sceneDepth = frame.sceneDepth {
                self.depthEncoder.encodeFrame(frame: sceneDepth.depthMap, frameNumber: frameNumber)
                if let confidence = sceneDepth.confidenceMap {
                    self.confidenceEncoder.encodeFrame(frame: confidence, frameNumber: frameNumber)
                } else {
                    print("warning: confidence map missing.")
                }
            } else {
                print("warning: scene depth missing.")
            }
            self.rgbEncoder.add(frame: VideoEncoderInput(buffer: frame.capturedImage, time: frame.timestamp), currentFrame: totalFrames)
            self.odometryEncoder.add(frame: frame, currentFrame: frameNumber)
            self.distortionEncoder.add(frame: frame, currentFrame: frameNumber)
            if let meta = locationMetadata {
                self.locationCSVWriter.add(metadata: meta)
                self.locationJSONWriter.add(metadata: meta, frameNumber: frameNumber)
            }
            self.pointCloudEncoder.add(frame: frame, frameNumber: frameNumber)
            self.lastFrame = frame
        }
    }
    
   func addRawAccelerometer(data: CMAccelerometerData) {
        let acceleration = simd_double3(data.acceleration.x, data.acceleration.y, data.acceleration.z)
        latestAccelerometerData = (timestamp: data.timestamp, data: acceleration)
        tryWritingIMUData()
    }

    func addRawGyroscope(data: CMGyroData) {
        let rotationRate = simd_double3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
        latestGyroscopeData = (timestamp: data.timestamp, data: rotationRate)
        tryWritingIMUData()
    }

    private func tryWritingIMUData() {
        guard
            let accelerometer = latestAccelerometerData,
            let gyroscope = latestGyroscopeData
        else {
            return
        }

        // Write the row to the CSV with the most recent timestamp
        let timestamp = max(accelerometer.timestamp, gyroscope.timestamp)
        imuEncoder.add(
            timestamp: timestamp,
            linear: accelerometer.data,
            angular: gyroscope.data
        )

        // Clear the buffers after writing
        latestAccelerometerData = nil
        latestGyroscopeData = nil
    }

    func wrapUp() {
        dispatchGroup.wait()
        self.rgbEncoder.finishEncoding()
        self.imuEncoder.done()
        self.odometryEncoder.done()
        self.distortionEncoder.done()
        self.locationCSVWriter.done()
        self.locationJSONWriter.done()
        self.pointCloudEncoder.done()
        writeIntrinsics()
        switch self.rgbEncoder.status {
            case .allGood:
                status = .allGood
            case .error:
                status = .videoEncodingError
        }
        switch self.depthEncoder.status {
            case .allGood:
                status = .allGood
            case .frameEncodingError:
                status = .videoEncodingError
                print("Something went wrong encoding depth.")
        }
        switch self.confidenceEncoder.status {
            case .allGood:
                status = .allGood
            case .encodingError:
                status = .videoEncodingError
                print("Something went wrong encoding confidence values.")
        }
    }

    private func writeIntrinsics() {
        if let cameraMatrix = lastFrame?.camera.intrinsics {
            let rows = cameraMatrix.transpose.columns
            var csv: [String] = []
            for row in [rows.0, rows.1, rows.2] {
                let csvLine = "\(row.x), \(row.y), \(row.z)"
                csv.append(csvLine)
            }
            let contents = csv.joined(separator: "\n")
            do {
                try contents.write(to: self.cameraMatrixPath, atomically: true, encoding: String.Encoding.utf8)
            } catch let error {
                print("Could not write camera matrix. \(error.localizedDescription)")
            }
        }
    }

    private func writeSampleMetadata(sampleContext: SampleContext?) {
        let url = datasetDirectory.appendingPathComponent("sample_metadata.json")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var dict: [String: Any] = [
            "dataset_folder": datasetDirectory.lastPathComponent,
            "recorded_at": formatter.string(from: Date()),
            "flag": sampleIsImportant ? "*" : "",
            "is_important": sampleIsImportant
        ]

        if let sampleContext = sampleContext {
            dict["sample_id"] = sampleContext.sampleID
            dict["sample_loai_mau"] = sampleContext.loaiMau
            dict["sample_site"] = sampleContext.site
            dict["sample_flag"] = sampleContext.isImportant ? "*" : ""
        } else {
            dict["sample_id"] = NSNull()
            dict["sample_loai_mau"] = NSNull()
            dict["sample_site"] = NSNull()
            dict["sample_flag"] = NSNull()
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch let error {
            print("Could not write sample_metadata.json: \(error.localizedDescription)")
        }
    }

    static private func createDirectory(sampleID: String?, isImportant: Bool) -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let timestamp = datasetTimestampString()
        let baseDirectoryName = datasetFolderName(
            timestamp: timestamp,
            sampleID: sampleID,
            isImportant: isImportant
        )
        var directoryName = baseDirectoryName
        var directory = URL(fileURLWithPath: directoryName, relativeTo: url)
        var duplicateCounter = 2

        while FileManager.default.fileExists(atPath: directory.path) {
            directoryName = "\(baseDirectoryName)_\(duplicateCounter)"
            directory = URL(fileURLWithPath: directoryName, relativeTo: url)
            duplicateCounter += 1
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            print("Error creating directory. \(error), \(error.userInfo)")
        }
        return directory
    }

    static private func datasetFolderName(timestamp: String, sampleID: String?, isImportant: Bool) -> String {
        let safeSampleID = sampleID
            .map { SampleContextStore.folderSafeSampleID($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let flag = isImportant ? "*" : ""

        if let safeSampleID = safeSampleID {
            return "\(safeSampleID)\(flag)_video_\(timestamp)"
        }
        return "video_\(timestamp)\(flag)"
    }

    static private func datasetTimestampString(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
}
