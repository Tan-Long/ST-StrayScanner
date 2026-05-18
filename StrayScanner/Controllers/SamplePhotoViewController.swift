//
//  SamplePhotoViewController.swift
//  StrayScanner
//

import UIKit
import AVFoundation
import CoreLocation
import ImageIO
import UniformTypeIdentifiers

class SamplePhotoViewController: UIViewController {

    // MARK: - Camera

    private let captureSession = AVCaptureSession()
    private let photoOutput    = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "sampleCameraQueue", qos: .userInitiated)

    // MARK: - UI

    private let previewView    = UIView()
    private let overlayLabel   = UILabel()
    private let scrollView     = UIScrollView()
    private let sampleIDField  = UITextField()
    private let tenMauField    = UITextField()
    private let loaiMauSegment = UISegmentedControl(items: ["LU", "TL", "Khác"])
    private let siteField      = UITextField()
    private let huongPicker    = UIPickerView()
    private let upslopeBtn     = UIButton(type: .system)
    private let midBtn         = UIButton(type: .system)
    private let downslopeBtn   = UIButton(type: .system)
    private let captureButton  = UIButton(type: .system)
    private let hudLabel       = UILabel()

    // MARK: - State

    private var selectedHuongLayMau: String?
    private var overlayTimer: Timer?
    private let huongManhXamOptions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    var dismissFunction: (() -> Void)?

    private typealias HeadingInfo = (degrees: Double, cardinal: String)
    private struct SampleCaptureSnapshot {
        let location: CLLocation?
        let heading: HeadingInfo?
        let place: String
        let capturedAt: Date
        let sampleID: String
        let tenMau: String
        let site: String
        let huongManhXam: String
        let huongLayMau: String
        let loaiMau: String
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "BackgroundColor") ?? .black
        buildPreviewArea()
        buildForm()
        buildCaptureButton()
        buildHUD()
        requestCameraAndSetup()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        LocationMetadataManager.shared.start()
        startOverlayTimer()
        refreshSampleID()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        LocationMetadataManager.shared.stop()
        overlayTimer?.invalidate()
        overlayTimer = nil
        sessionQueue.async { self.captureSession.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
    }

    // MARK: - Camera setup

    private func requestCameraAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.setupCamera() } }
            }
        default:
            break
        }
    }

    private func setupCamera() {
        captureSession.sessionPreset = .photo
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input  = try? AVCaptureDeviceInput(device: device),
            captureSession.canAddInput(input),
            captureSession.canAddOutput(photoOutput)
        else { return }

        captureSession.addInput(input)
        captureSession.addOutput(photoOutput)

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewView.bounds
        previewView.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        sessionQueue.async { self.captureSession.startRunning() }
    }

    // MARK: - Build UI

    private func buildPreviewArea() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        previewView.clipsToBounds = true
        view.addSubview(previewView)

        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        overlayLabel.numberOfLines = 0
        overlayLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        overlayLabel.textColor = .white
        overlayLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        overlayLabel.layer.cornerRadius = 4
        overlayLabel.clipsToBounds = true
        previewView.addSubview(overlayLabel)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.38),

            overlayLabel.topAnchor.constraint(equalTo: previewView.topAnchor, constant: 8),
            overlayLabel.leadingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: 8),
            overlayLabel.trailingAnchor.constraint(lessThanOrEqualTo: previewView.trailingAnchor, constant: -8),
        ])
    }

    private func buildForm() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .onDrag
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        stack.isLayoutMarginsRelativeArrangement = true
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: previewView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // bottom pinned after captureButton is built

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // Sample ID
        stack.addArrangedSubview(fieldLabel("Sample ID"))
        sampleIDField.borderStyle = .roundedRect
        sampleIDField.clearButtonMode = .whileEditing
        sampleIDField.autocorrectionType = .no
        sampleIDField.addTarget(self, action: #selector(sampleIDEdited), for: .editingChanged)
        stack.addArrangedSubview(sampleIDField)

        // Tên mẫu
        stack.addArrangedSubview(fieldLabel("Tên mẫu"))
        tenMauField.borderStyle = .roundedRect
        tenMauField.clearButtonMode = .whileEditing
        stack.addArrangedSubview(tenMauField)

        // Loại mẫu
        stack.addArrangedSubview(fieldLabel("Loại mẫu"))
        loaiMauSegment.selectedSegmentIndex = 0
        loaiMauSegment.addTarget(self, action: #selector(loaiMauChanged), for: .valueChanged)
        stack.addArrangedSubview(loaiMauSegment)

        // Site
        stack.addArrangedSubview(fieldLabel("Site"))
        siteField.borderStyle = .roundedRect
        siteField.clearButtonMode = .whileEditing
        siteField.placeholder = "Tự điền từ địa chỉ GPS"
        stack.addArrangedSubview(siteField)

        // Hướng mảnh xăm
        stack.addArrangedSubview(fieldLabel("Hướng mảnh xăm"))
        huongPicker.dataSource = self
        huongPicker.delegate   = self
        huongPicker.heightAnchor.constraint(equalToConstant: 100).isActive = true
        stack.addArrangedSubview(huongPicker)

        // Hướng lấy mẫu
        stack.addArrangedSubview(fieldLabel("Hướng lấy mẫu"))
        let huongRow = UIStackView(arrangedSubviews: [upslopeBtn, midBtn, downslopeBtn])
        huongRow.axis = .horizontal
        huongRow.spacing = 8
        huongRow.distribution = .fillEqually
        styleHuongBtn(upslopeBtn,  "Upslope")
        styleHuongBtn(midBtn,      "Mid")
        styleHuongBtn(downslopeBtn,"Downslope")
        stack.addArrangedSubview(huongRow)
    }

    private func buildCaptureButton() {
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.setTitle("📷 CHỤP MẪU", for: .normal)
        captureButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        captureButton.backgroundColor = .systemGreen
        captureButton.setTitleColor(.white, for: .normal)
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        view.addSubview(captureButton)

        NSLayoutConstraint.activate([
            captureButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            captureButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            captureButton.heightAnchor.constraint(equalToConstant: 64),
            scrollView.bottomAnchor.constraint(equalTo: captureButton.topAnchor),
        ])
    }

    private func buildHUD() {
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hudLabel.text = "✓ Đã lưu"
        hudLabel.textColor = .white
        hudLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.92)
        hudLabel.textAlignment = .center
        hudLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        hudLabel.layer.cornerRadius = 14
        hudLabel.clipsToBounds = true
        hudLabel.alpha = 0
        view.addSubview(hudLabel)
        NSLayoutConstraint.activate([
            hudLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            hudLabel.widthAnchor.constraint(equalToConstant: 160),
            hudLabel.heightAnchor.constraint(equalToConstant: 60),
        ])
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = UIColor(named: "TextColor") ?? .label
        return l
    }

    private func styleHuongBtn(_ btn: UIButton, _ title: String) {
        btn.setTitle(title, for: .normal)
        btn.layer.borderWidth  = 1.5
        btn.layer.borderColor  = UIColor.systemGreen.cgColor
        btn.layer.cornerRadius = 8
        btn.titleLabel?.font   = .systemFont(ofSize: 14, weight: .medium)
        btn.setTitleColor(.systemGreen, for: .normal)
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        btn.addTarget(self, action: #selector(huongLayMauTapped(_:)), for: .touchUpInside)
    }

    private func refreshHuongBtns() {
        for btn in [upslopeBtn, midBtn, downslopeBtn] {
            let selected = btn.title(for: .normal) == selectedHuongLayMau
            btn.backgroundColor = selected ? .systemGreen : .clear
            btn.setTitleColor(selected ? .white : .systemGreen, for: .normal)
        }
    }

    // MARK: - Overlay

    private func startOverlayTimer() {
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateOverlay()
        }
        updateOverlay()
    }

    private func updateOverlay() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var parts: [String] = [df.string(from: Date())]

        if let loc = LocationMetadataManager.shared.currentLocation {
            let lat = String(format: "%.4f", loc.coordinate.latitude)
            let lon = String(format: "%.4f", loc.coordinate.longitude)
            let acc = String(format: "±%.0fm", max(loc.horizontalAccuracy, 0))
            parts.append("\(lat),\(lon) \(acc)")
            parts.append(String(format: "%.0fm alt", loc.altitude))
        }

        if let heading = headingInfo(from: LocationMetadataManager.shared.currentHeading) {
            parts.append(String(format: "%.0f° %@", heading.degrees, heading.cardinal))
        }

        if let place = LocationMetadataManager.shared.currentPlaceName {
            parts.append(place)
            // Auto-fill Site once if still empty
            if siteField.text?.isEmpty ?? true {
                siteField.text = place
            }
        }

        overlayLabel.text = " " + parts.joined(separator: " · ") + " "
    }

    private func cardinal(for degrees: Double) -> String {
        let dirs = ["N","NE","E","SE","S","SW","W","NW"]
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return dirs[Int((d + 22.5) / 45.0) % 8]
    }

    private func headingInfo(from heading: CLHeading?) -> HeadingInfo? {
        guard let heading = heading, heading.headingAccuracy >= 0 else { return nil }
        let degrees = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        return (degrees, cardinal(for: degrees))
    }

    // MARK: - Sample ID

    private func currentLoaiMau() -> String {
        ["LU", "TL", "Khác"][loaiMauSegment.selectedSegmentIndex]
    }

    private func refreshSampleID() {
        let prefix = "\(currentLoaiMau())-1"
        sampleIDField.text = SampleLogger.shared.nextSampleID(prefix: prefix)
        syncTenMau()
    }

    private func syncTenMau() {
        guard let id = sampleIDField.text, !id.isEmpty else { return }
        if let dot = id.range(of: ".", options: .backwards) {
            tenMauField.text = String(id[..<dot.lowerBound])
        } else {
            tenMauField.text = id
        }
    }

    private func advanceSampleID() {
        guard let id = sampleIDField.text, !id.isEmpty else { return }
        if let dot = id.range(of: ".", options: .backwards) {
            let prefix = String(id[..<dot.lowerBound])
            sampleIDField.text = SampleLogger.shared.nextSampleID(prefix: prefix)
            syncTenMau()
        }
    }

    // MARK: - Actions

    @objc private func sampleIDEdited()      { syncTenMau() }
    @objc private func loaiMauChanged()      { refreshSampleID() }

    @objc private func huongLayMauTapped(_ sender: UIButton) {
        selectedHuongLayMau = sender.title(for: .normal)
        refreshHuongBtns()
    }

    @objc private func captureTapped() {
        guard selectedHuongLayMau != nil else {
            let alert = UIAlertController(
                title: "Thiếu thông tin",
                message: "Vui lòng chọn Hướng lấy mẫu trước khi chụp.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .auto
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Save record

    private func currentCaptureSnapshot() -> SampleCaptureSnapshot {
        let location = LocationMetadataManager.shared.currentLocation
        let heading = headingInfo(from: LocationMetadataManager.shared.currentHeading)
        let place = LocationMetadataManager.shared.currentPlaceName ?? ""
        return SampleCaptureSnapshot(
            location: location,
            heading: heading,
            place: place,
            capturedAt: Date(),
            sampleID: sampleIDField.text ?? "UNKNOWN",
            tenMau: tenMauField.text ?? "",
            site: siteField.text ?? "",
            huongManhXam: huongManhXamOptions[huongPicker.selectedRow(inComponent: 0)],
            huongLayMau: selectedHuongLayMau ?? "",
            loaiMau: currentLoaiMau()
        )
    }

    private func saveRecord(imageData: Data, snapshot: SampleCaptureSnapshot) {
        let tsFile = DateFormatter(); tsFile.dateFormat = "yyyyMMdd_HHmmss"
        let tsDisplay = DateFormatter(); tsDisplay.dateStyle = .medium; tsDisplay.timeStyle = .short

        let filename = "\(snapshot.sampleID)_\(tsFile.string(from: snapshot.capturedAt)).jpg"
        let fileURL  = SampleLogger.shared.samplesDirectory.appendingPathComponent(filename)
        let annotatedImageData = imageDataWithMetadataOverlay(
            imageData: imageData,
            filename: filename,
            sampleID: snapshot.sampleID,
            capturedAt: snapshot.capturedAt,
            location: snapshot.location,
            heading: snapshot.heading,
            place: snapshot.place,
            snapshot: snapshot
        )

        do { try annotatedImageData.write(to: fileURL) }
        catch { print("SamplePhoto: failed to write JPEG – \(error)") }

        let record = SampleRecord(
            sampleID:      snapshot.sampleID,
            tenMau:        snapshot.tenMau,
            latitude:      snapshot.location?.coordinate.latitude,
            longitude:     snapshot.location?.coordinate.longitude,
            gpsAccuracy:   snapshot.location.map { max($0.horizontalAccuracy, 0) },
            location:      snapshot.place,
            site:          snapshot.site,
            huongManhXam:  snapshot.huongManhXam,
            huongLayMau:   snapshot.huongLayMau,
            altitude:      snapshot.location?.altitude,
            headingDegrees: snapshot.heading?.degrees,
            headingCardinal: snapshot.heading?.cardinal,
            loaiMau:       snapshot.loaiMau,
            ngayLay:       tsDisplay.string(from: snapshot.capturedAt),
            fileAnh:       filename
        )

        do { try SampleLogger.shared.append(record: record) }
        catch { print("SamplePhoto: failed to log record – \(error)") }

        DispatchQueue.main.async { [weak self] in
            self?.showHUD()
            self?.advanceSampleID()
        }
    }

    private func imageDataWithMetadataOverlay(
        imageData: Data,
        filename: String,
        sampleID: String,
        capturedAt: Date,
        location: CLLocation?,
        heading: HeadingInfo?,
        place: String,
        snapshot: SampleCaptureSnapshot
    ) -> Data {
        guard let image = UIImage(data: imageData) else { return imageData }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines: [String] = [
            "File: \(filename)",
            "Sample ID: \(sampleID)",
            "Ten mau: \(snapshot.tenMau)",
            "Loai mau: \(snapshot.loaiMau)",
            df.string(from: capturedAt)
        ]

        if !snapshot.site.isEmpty {
            lines.append("Site: \(snapshot.site)")
        }
        lines.append("Huong manh xam: \(snapshot.huongManhXam)")
        lines.append("Huong lay mau: \(snapshot.huongLayMau)")

        if let loc = location {
            lines.append(String(
                format: "GPS: %.6f, %.6f ±%.0fm",
                loc.coordinate.latitude,
                loc.coordinate.longitude,
                max(loc.horizontalAccuracy, 0)
            ))
            lines.append(String(format: "Altitude: %.1fm", loc.altitude))
        }

        if let heading = heading {
            lines.append(String(format: "Heading: %.0f° %@", heading.degrees, heading.cardinal))
        }

        if !place.isEmpty {
            lines.append(place)
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

        let metadata = jpegMetadata(
            filename: filename,
            sampleID: sampleID,
            capturedAt: capturedAt,
            location: location,
            heading: heading,
            place: place,
            snapshot: snapshot
        )
        return jpegData(image: annotatedImage, metadata: metadata) ?? annotatedImage.jpegData(compressionQuality: 0.94) ?? imageData
    }

    private func jpegMetadata(
        filename: String,
        sampleID: String,
        capturedAt: Date,
        location: CLLocation?,
        heading: HeadingInfo?,
        place: String,
        snapshot: SampleCaptureSnapshot
    ) -> [CFString: Any] {
        let iso = ISO8601DateFormatter().string(from: capturedAt)
        var sampleData: [String: Any] = [
            "file_anh": filename,
            "sample_id": sampleID,
            "ten_mau": snapshot.tenMau,
            "loai_mau": snapshot.loaiMau,
            "ngay_lay": iso,
            "location": place,
            "site": snapshot.site,
            "huong_manh_xam": snapshot.huongManhXam,
            "huong_lay_mau": snapshot.huongLayMau
        ]

        if let location = location {
            sampleData["lat"] = location.coordinate.latitude
            sampleData["long"] = location.coordinate.longitude
            sampleData["gps_accuracy_m"] = max(location.horizontalAccuracy, 0)
            sampleData["altitude_m"] = location.altitude
        }
        if let heading = heading {
            sampleData["heading_degree"] = heading.degrees
            sampleData["heading_cardinal"] = heading.cardinal
        }

        let jsonData = try? JSONSerialization.data(withJSONObject: sampleData, options: [.sortedKeys])
        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        let exif: [CFString: Any] = [
            kCGImagePropertyExifUserComment: jsonString
        ]

        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFImageDescription: jsonString,
            kCGImagePropertyTIFFSoftware: "Stray Scanner TestLab"
        ]

        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff
        ]

        if let location = location {
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(location.coordinate.latitude),
                kCGImagePropertyGPSLatitudeRef: location.coordinate.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(location.coordinate.longitude),
                kCGImagePropertyGPSLongitudeRef: location.coordinate.longitude >= 0 ? "E" : "W",
                kCGImagePropertyGPSAltitude: abs(location.altitude),
                kCGImagePropertyGPSAltitudeRef: location.altitude >= 0 ? 0 : 1,
                kCGImagePropertyGPSHPositioningError: max(location.horizontalAccuracy, 0)
            ]
            if let heading = heading {
                gps[kCGImagePropertyGPSImgDirection] = heading.degrees
                gps[kCGImagePropertyGPSImgDirectionRef] = "T"
            }
            properties[kCGImagePropertyGPSDictionary] = gps
        }

        return properties
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

    private func showHUD() {
        hudLabel.alpha = 1.0
        UIView.animate(withDuration: 0.4, delay: 1.5) { [weak self] in
            self?.hudLabel.alpha = 0
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension SamplePhotoViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            print("SamplePhoto: capture error – \(String(describing: error))")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let snapshot = self.currentCaptureSnapshot()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.saveRecord(imageData: data, snapshot: snapshot)
            }
        }
    }
}

// MARK: - UIPickerView

extension SamplePhotoViewController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        huongManhXamOptions.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        huongManhXamOptions[row]
    }
}
