//
//  LocationMetadataManager.swift
//  StrayScanner
//

import Foundation
import CoreLocation
import CoreMotion
import ARKit

struct FrameLocationMetadata {
    let timestamp_iso: String
    let timestamp_unix: Double
    let latitude: Double?
    let longitude: Double?
    let altitude_asl_m: Double?
    let gps_accuracy_m: Double?
    let heading_degrees: Double?
    let heading_cardinal: String?
    let place_name: String?
    let locality: String?
    let cam_yaw: Double
    let cam_pitch: Double
    let cam_roll: Double
    let slope_degrees: Double?
    let gravity_x: Double?
    let gravity_y: Double?
    let gravity_z: Double?
}

// Note: Apple recommends one CMMotionManager per app. This singleton uses
// startDeviceMotionUpdates (fused gravity) while RecordSessionViewController
// uses startAccelerometerUpdates / startGyroUpdates (raw sensors) on its own
// instance. The two APIs operate independently and do not conflict in practice.
class LocationMetadataManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationMetadataManager()

    private let locationManager = CLLocationManager()
    // Separate CMMotionManager for device-motion / gravity; raw IMU uses the
    // one owned by RecordSessionViewController.
    private let motionManager = CMMotionManager()
    private let geocoder = CLGeocoder()
    private let motionQueue = OperationQueue()
    private let lock = NSLock()

    private var latestLocation: CLLocation?
    private var latestHeading: CLHeading?
    private var latestMotion: CMDeviceMotion?
    private var cachedPlaceName: String?
    private var cachedLocality: String?
    private var lastGeocodeTime: Date = .distantPast
    private var isGeocoding = false

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let cardinalDirections = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
    ]

    private override init() {
        super.init()
        motionQueue.qualityOfService = .userInitiated
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1.0
        locationManager.headingFilter = 1.0
    }

    func start() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
            motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
                guard let self = self, let motion = motion else { return }
                self.lock.lock()
                self.latestMotion = motion
                self.lock.unlock()
            }
        }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }

    /// The most recently received GPS fix. Thread-safe; may be nil before first fix.
    var currentLocation: CLLocation? {
        lock.lock()
        defer { lock.unlock() }
        return latestLocation
    }

    /// The most recently received compass heading. Thread-safe; may be nil.
    var currentHeading: CLHeading? {
        lock.lock()
        defer { lock.unlock() }
        return latestHeading
    }

    /// The cached reverse-geocoded place name. Thread-safe; may be nil.
    var currentPlaceName: String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedPlaceName
    }

    /// Returns a metadata snapshot synchronised with the given ARFrame.
    /// Safe to call from any thread.
    func snapshot(arFrame: ARFrame) -> FrameLocationMetadata {
        lock.lock()
        let location = latestLocation
        let heading = latestHeading
        let motion = latestMotion
        let placeName = cachedPlaceName
        let locality = cachedLocality
        lock.unlock()

        // Trigger geocode outside the lock to avoid blocking callers
        if let loc = location {
            maybeReverseGeocode(location: loc)
        }

        let now = Date()
        let timestamp_iso = isoFormatter.string(from: now)
        // ARFrame.timestamp is seconds since device boot — use it for frame sync.
        let timestamp_unix = arFrame.timestamp

        // Camera Euler angles (radians → degrees)
        let euler = arFrame.camera.eulerAngles
        let cam_pitch = Double(euler.x) * 180.0 / .pi
        let cam_yaw   = Double(euler.y) * 180.0 / .pi
        let cam_roll  = Double(euler.z) * 180.0 / .pi

        // Heading (only valid when headingAccuracy >= 0)
        var heading_degrees: Double?
        var heading_cardinal: String?
        if let h = heading, h.headingAccuracy >= 0 {
            heading_degrees = h.trueHeading
            heading_cardinal = Self.cardinal(for: h.trueHeading)
        }

        // Gravity and slope from CMDeviceMotion
        var slope_degrees: Double?
        var gravity_x: Double?
        var gravity_y: Double?
        var gravity_z: Double?
        if let m = motion {
            let g = m.gravity
            gravity_x = g.x
            gravity_y = g.y
            gravity_z = g.z
            // Angle from horizontal: 0° = device lying flat, 90° = device vertical.
            // gravity.z ≈ -1 when face-up flat; ≈ 0 when standing upright.
            slope_degrees = acos(min(abs(g.z), 1.0)) * 180.0 / .pi
        }

        return FrameLocationMetadata(
            timestamp_iso: timestamp_iso,
            timestamp_unix: timestamp_unix,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            altitude_asl_m: location?.altitude,
            gps_accuracy_m: location.map { max($0.horizontalAccuracy, 0) },
            heading_degrees: heading_degrees,
            heading_cardinal: heading_cardinal,
            place_name: placeName,
            locality: locality,
            cam_yaw: cam_yaw,
            cam_pitch: cam_pitch,
            cam_roll: cam_roll,
            slope_degrees: slope_degrees,
            gravity_x: gravity_x,
            gravity_y: gravity_y,
            gravity_z: gravity_z
        )
    }

    // MARK: - Reverse geocoding

    private func maybeReverseGeocode(location: CLLocation) {
        lock.lock()
        let shouldGeocode = !isGeocoding && Date().timeIntervalSince(lastGeocodeTime) >= 30.0
        if shouldGeocode {
            isGeocoding = true
            lastGeocodeTime = Date()
        }
        lock.unlock()

        guard shouldGeocode else { return }

        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self = self else { return }
            let placemark = placemarks?.first
            self.lock.lock()
            self.cachedPlaceName = placemark?.name
            self.cachedLocality = placemark?.locality
            self.isGeocoding = false
            self.lock.unlock()
        }
    }

    // MARK: - Helpers

    private static func cardinal(for degrees: Double) -> String {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        let index = Int((d + 11.25) / 22.5) % 16
        return cardinalDirections[index]
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lock.lock()
        latestLocation = loc
        lock.unlock()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        lock.lock()
        latestHeading = newHeading
        lock.unlock()
    }
}
