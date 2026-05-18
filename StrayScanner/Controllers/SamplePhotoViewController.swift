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
    private let diaYBtn        = UIButton(type: .system)
    private let khongDiaYBtn   = UIButton(type: .system)
    private let siteField      = UITextField()
    private let siteStatusLabel = UILabel()
    private let huongPicker    = UIPickerView()
    private let upslopeBtn     = UIButton(type: .system)
    private let downslopeBtn   = UIButton(type: .system)
    private let importantButton = UIButton(type: .system)
    private let captureButton  = UIButton(type: .system)
    private let hudLabel       = UILabel()

    // MARK: - State

    private var selectedHuongLayMau: String?
    private var selectedLoaiMau: String = "Địa y"
    private var isImportantSample: Bool = false
    private var isSiteManuallyEdited: Bool = false
    private var overlayTimer: Timer?
    private var simulatorPreviewBuilt = false
    private let huongManhXamOptions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    private let lastSiteDefaultsKey = "sample_last_gps_site"
    private let noGPSFallbackSite = "Không có GPS"
    var dismissFunction: (() -> Void)?

    private typealias HeadingInfo = (degrees: Double, cardinal: String)
    private struct SampleCaptureSnapshot {
        let location: CLLocation?
        let heading: HeadingInfo?
        let place: String
        let capturedAt: Date
        let sampleID: String
        let site: String
        let huongCamera: String
        let huongManhXam: String
        let huongLayMau: String
        let loaiMau: String
        let isImportant: Bool
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
#if targetEnvironment(simulator)
        seedSimulatorDefaults()
#else
        LocationMetadataManager.shared.start()
#endif
        startOverlayTimer()
        refreshSampleID()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
#if !targetEnvironment(simulator)
        LocationMetadataManager.shared.stop()
#endif
        overlayTimer?.invalidate()
        overlayTimer = nil
#if !targetEnvironment(simulator)
        sessionQueue.async { self.captureSession.stopRunning() }
#endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
    }

    // MARK: - Camera setup

    private func requestCameraAndSetup() {
#if targetEnvironment(simulator)
        setupSimulatorPreview()
#else
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
#endif
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

    private func setupSimulatorPreview() {
        guard !simulatorPreviewBuilt else { return }
        simulatorPreviewBuilt = true

        let mockView = UIView()
        mockView.translatesAutoresizingMaskIntoConstraints = false
        mockView.backgroundColor = UIColor(red: 0.08, green: 0.12, blue: 0.10, alpha: 1)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "SIMULATOR MOCK CAMERA"
        title.textColor = .white
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.text = "Bấm CHỤP MẪU để tạo ảnh/data giả trong thư mục samples"
        subtitle.textColor = UIColor.white.withAlphaComponent(0.82)
        subtitle.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 2

        mockView.addSubview(title)
        mockView.addSubview(subtitle)
        previewView.insertSubview(mockView, at: 0)

        NSLayoutConstraint.activate([
            mockView.topAnchor.constraint(equalTo: previewView.topAnchor),
            mockView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            mockView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            mockView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),

            title.centerXAnchor.constraint(equalTo: mockView.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: mockView.centerYAnchor, constant: -12),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: mockView.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: mockView.trailingAnchor, constant: -16),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: mockView.leadingAnchor, constant: 24),
            subtitle.trailingAnchor.constraint(equalTo: mockView.trailingAnchor, constant: -24),
        ])
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
        stack.addArrangedSubview(sampleIDField)

        // Flag
        stack.addArrangedSubview(fieldLabel("Flag"))
        importantButton.setTitle("☆", for: .normal)
        importantButton.titleLabel?.font = .systemFont(ofSize: 30, weight: .semibold)
        importantButton.layer.cornerRadius = 8
        importantButton.layer.masksToBounds = true
        importantButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        importantButton.addTarget(self, action: #selector(importantTapped), for: .touchUpInside)
        stack.addArrangedSubview(importantButton)
        refreshImportantButton()

        // Loại mẫu
        stack.addArrangedSubview(fieldLabel("Loại mẫu"))
        let loaiMauRow = UIStackView(arrangedSubviews: [diaYBtn, khongDiaYBtn])
        loaiMauRow.axis = .horizontal
        loaiMauRow.spacing = 8
        loaiMauRow.distribution = .fillEqually
        styleChoiceBtn(diaYBtn, "Địa y")
        styleChoiceBtn(khongDiaYBtn, "Không địa y")
        stack.addArrangedSubview(loaiMauRow)
        refreshLoaiMauBtns()

        // Site
        stack.addArrangedSubview(fieldLabel("Site (GPS)"))
        siteField.borderStyle = .roundedRect
        siteField.placeholder = "Tự lấy GPS hoặc nhập tay"
        siteField.clearButtonMode = .whileEditing
        siteField.addTarget(self, action: #selector(siteEdited), for: .editingChanged)
        stack.addArrangedSubview(siteField)
        siteStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        siteStatusLabel.textColor = .secondaryLabel
        siteStatusLabel.numberOfLines = 0
        siteStatusLabel.text = "Đang lấy GPS..."
        stack.addArrangedSubview(siteStatusLabel)

        // Hướng camera / mảnh xăm
        stack.addArrangedSubview(fieldLabel("Hướng camera / Hướng mảnh xăm"))
        huongPicker.dataSource = self
        huongPicker.delegate   = self
        huongPicker.isUserInteractionEnabled = false
        huongPicker.alpha = 0.78
        huongPicker.heightAnchor.constraint(equalToConstant: 100).isActive = true
        stack.addArrangedSubview(huongPicker)

        // Hướng lấy mẫu
        stack.addArrangedSubview(fieldLabel("Hướng lấy mẫu"))
        let huongRow = UIStackView(arrangedSubviews: [upslopeBtn, downslopeBtn])
        huongRow.axis = .horizontal
        huongRow.spacing = 8
        huongRow.distribution = .fillEqually
        styleHuongBtn(upslopeBtn,  "Upslope")
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
        styleChoiceBtn(btn, title)
        btn.removeTarget(self, action: #selector(loaiMauTapped(_:)), for: .touchUpInside)
        btn.addTarget(self, action: #selector(huongLayMauTapped(_:)), for: .touchUpInside)
    }

    private func styleChoiceBtn(_ btn: UIButton, _ title: String) {
        btn.setTitle(title, for: .normal)
        btn.layer.borderWidth  = 1.5
        btn.layer.borderColor  = UIColor.systemGreen.cgColor
        btn.layer.cornerRadius = 8
        btn.titleLabel?.font   = .systemFont(ofSize: 14, weight: .medium)
        btn.setTitleColor(.systemGreen, for: .normal)
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        btn.addTarget(self, action: #selector(loaiMauTapped(_:)), for: .touchUpInside)
    }

    private func refreshHuongBtns() {
        for btn in [upslopeBtn, downslopeBtn] {
            let selected = btn.title(for: .normal) == selectedHuongLayMau
            btn.backgroundColor = selected ? .systemGreen : .clear
            btn.setTitleColor(selected ? .white : .systemGreen, for: .normal)
        }
    }

    private func refreshLoaiMauBtns() {
        for btn in [diaYBtn, khongDiaYBtn] {
            let selected = btn.title(for: .normal) == selectedLoaiMau
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
#if targetEnvironment(simulator)
        updateSimulatorOverlay()
        return
#endif
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

        let heading = headingInfo(from: LocationMetadataManager.shared.currentHeading)
        syncRealtimeHuongManhXam(heading: heading)

        if let heading = heading {
            parts.append(String(
                format: "Camera %.0f° %@",
                heading.degrees,
                heading.cardinal
            ))
            let outward = outwardFacingInfo(from: heading)
            parts.append(String(format: "Mảnh xăm %.0f° %@", outward.degrees, outward.cardinal))
        }

        if let huongLayMau = selectedHuongLayMau {
            parts.append(huongLayMau)
        }
        if isImportantSample {
            parts.append("*")
        }

        let place = LocationMetadataManager.shared.currentPlaceName
        syncSiteFromGPS(place: place, location: LocationMetadataManager.shared.currentLocation)
        if let place = place {
            parts.append(place)
        }

        overlayLabel.text = " " + parts.joined(separator: " · ") + " "
    }

    private func updateSimulatorOverlay() {
        syncRealtimeHuongManhXam(heading: (degrees: 72.0, cardinal: "NE"))
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let parts = [
            df.string(from: Date()),
            "21.0285,105.8048 ±5m",
            "12m alt",
            "Camera 72° NE",
            "Mảnh xăm 252° SW",
            isImportantSample ? "*" : "Không flag",
            selectedHuongLayMau ?? "Chưa chọn hướng lấy mẫu",
            "Mock Site - Hanoi"
        ]
        overlayLabel.text = " " + parts.joined(separator: " · ") + " "
    }

    private func seedSimulatorDefaults() {
        if siteField.text?.isEmpty ?? true {
            siteField.text = "Mock Site - Hanoi"
        }
    }

    private func syncSiteFromGPS(place: String?, location: CLLocation?) {
        guard !isSiteManuallyEdited || siteField.text?.isEmpty == true || siteField.text == noGPSFallbackSite else {
            updateSiteStatus("Site nhập tay")
            return
        }
        siteField.text = siteTextFromGPS(place: place, location: location)
        updateSiteStatus(siteStatusText(place: place, location: location))
    }

    private func siteTextFromGPS(place: String?, location: CLLocation?) -> String {
        if let place = place, !place.isEmpty {
            saveLastSite(place)
            return place
        }
        if let location = location {
            let coordinates = String(
                format: "%.6f, %.6f",
                location.coordinate.latitude,
                location.coordinate.longitude
            )
            saveLastSite(coordinates)
            return coordinates
        }
        return lastSavedSite() ?? noGPSFallbackSite
    }

    private func saveLastSite(_ site: String) {
        UserDefaults.standard.set(site, forKey: lastSiteDefaultsKey)
    }

    private func lastSavedSite() -> String? {
        guard let site = UserDefaults.standard.string(forKey: lastSiteDefaultsKey), !site.isEmpty else {
            return nil
        }
        return site
    }

    private func siteStatusText(place: String?, location: CLLocation?) -> String {
        if let place = place, !place.isEmpty {
            return "Site từ GPS"
        }
        if location != nil {
            return "Site từ tọa độ GPS"
        }
        if lastSavedSite() != nil {
            return "Đang dùng site GPS gần nhất"
        }
        return "Không có GPS, vui lòng nhập Site"
    }

    private func updateSiteStatus(_ text: String) {
        siteStatusLabel.text = text
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

    private func outwardFacingInfo(from cameraHeading: HeadingInfo) -> HeadingInfo {
        let degrees = normalizeDegrees(cameraHeading.degrees + 180)
        return (degrees, cardinal(for: degrees))
    }

    private func syncRealtimeHuongManhXam(heading: HeadingInfo?) {
        guard let heading = heading else { return }
        let outward = outwardFacingInfo(from: heading)
        if let row = huongManhXamOptions.firstIndex(of: outward.cardinal) {
            huongPicker.selectRow(row, inComponent: 0, animated: true)
        }
    }

    private func normalizeDegrees(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    private func huongManhXam(from heading: HeadingInfo?) -> HeadingInfo? {
        guard let heading = heading else { return nil }
        return outwardFacingInfo(from: heading)
    }

    private func selectedHuongManhXamCardinal() -> String {
        huongManhXamOptions[huongPicker.selectedRow(inComponent: 0)]
    }

    private func selectedCameraCardinal(from heading: HeadingInfo?) -> String {
        if let heading = heading {
            return heading.cardinal
        }
        let selected = selectedHuongManhXamCardinal()
        if let index = huongManhXamOptions.firstIndex(of: selected) {
            return huongManhXamOptions[(index + 4) % huongManhXamOptions.count]
        }
        return ""
    }

    // MARK: - Sample ID

    private func currentLoaiMau() -> String {
        selectedLoaiMau
    }

    private func refreshImportantButton() {
        importantButton.setTitle(isImportantSample ? "*" : "☆", for: .normal)
        importantButton.backgroundColor = isImportantSample ? UIColor.systemYellow : UIColor.clear
        importantButton.layer.borderWidth = 1.5
        importantButton.layer.borderColor = UIColor.systemYellow.cgColor
        importantButton.setTitleColor(isImportantSample ? UIColor.black : UIColor.systemYellow, for: .normal)
    }

    private func refreshSampleID() {
        let prefix = sampleIDPrefix()
        sampleIDField.text = SampleLogger.shared.nextSampleIDForHuongPair(prefix: prefix)
    }

    private func sampleIDPrefix() -> String {
        let id = sampleIDField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let dot = id.range(of: ".", options: .backwards), dot.lowerBound > id.startIndex {
            return String(id[..<dot.lowerBound])
        }
        return id.isEmpty ? "M-1" : id
    }

    private func advanceSampleID() {
        guard let id = sampleIDField.text, !id.isEmpty else { return }
        guard SampleLogger.shared.hasCompleteHuongLayMauPair(sampleID: id) else { return }
        if let dot = id.range(of: ".", options: .backwards) {
            let prefix = String(id[..<dot.lowerBound])
            sampleIDField.text = SampleLogger.shared.nextSampleIDForHuongPair(prefix: prefix)
        }
    }

    // MARK: - Actions

    @objc private func loaiMauTapped(_ sender: UIButton) {
        selectedLoaiMau = sender.title(for: .normal) ?? "Địa y"
        refreshLoaiMauBtns()
    }

    @objc private func importantTapped() {
        isImportantSample.toggle()
        refreshImportantButton()
    }

    @objc private func siteEdited() {
        isSiteManuallyEdited = !(siteField.text?.isEmpty ?? true)
        updateSiteStatus(isSiteManuallyEdited ? "Site nhập tay" : "Đang lấy GPS...")
    }

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
#if targetEnvironment(simulator)
        let snapshot = currentCaptureSnapshot()
        let imageData = simulatorMockImageData(snapshot: snapshot)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.saveRecord(imageData: imageData, snapshot: snapshot)
        }
#else
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .auto
        photoOutput.capturePhoto(with: settings, delegate: self)
#endif
    }

    // MARK: - Save record

    private func currentCaptureSnapshot() -> SampleCaptureSnapshot {
#if targetEnvironment(simulator)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 21.028511, longitude: 105.804817),
            altitude: 12.4,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 3.0,
            timestamp: Date()
        )
        return SampleCaptureSnapshot(
            location: location,
            heading: (degrees: 72.0, cardinal: "NE"),
            place: "Mock Site - Hanoi",
            capturedAt: Date(),
            sampleID: sampleIDField.text ?? "TC-001-1.1",
            site: siteField.text ?? "Mock Site - Hanoi",
            huongCamera: "NE",
            huongManhXam: "SW",
            huongLayMau: selectedHuongLayMau ?? "Upslope",
            loaiMau: currentLoaiMau(),
            isImportant: isImportantSample
        )
#else
        let location = LocationMetadataManager.shared.currentLocation
        let heading = headingInfo(from: LocationMetadataManager.shared.currentHeading)
        syncRealtimeHuongManhXam(heading: heading)
        let huongManhXam = self.huongManhXam(from: heading)?.cardinal ?? selectedHuongManhXamCardinal()
        let place = LocationMetadataManager.shared.currentPlaceName ?? ""
        let manualSite = siteField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let site = manualSite.isEmpty ? siteTextFromGPS(place: place, location: location) : manualSite
        return SampleCaptureSnapshot(
            location: location,
            heading: heading,
            place: place,
            capturedAt: Date(),
            sampleID: sampleIDField.text ?? "UNKNOWN",
            site: site,
            huongCamera: selectedCameraCardinal(from: heading),
            huongManhXam: huongManhXam,
            huongLayMau: selectedHuongLayMau ?? "",
            loaiMau: currentLoaiMau(),
            isImportant: isImportantSample
        )
#endif
    }

    private func saveRecord(imageData: Data, snapshot: SampleCaptureSnapshot) {
        let tsFile = DateFormatter(); tsFile.dateFormat = "yyyyMMdd_HHmmss"
        let tsDisplay = DateFormatter(); tsDisplay.dateStyle = .medium; tsDisplay.timeStyle = .short

        let filename = samplePhotoFilename(snapshot: snapshot, timestamp: tsFile.string(from: snapshot.capturedAt))
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

        let outwardHeading = snapshot.heading.map { outwardFacingInfo(from: $0) }
        let record = SampleRecord(
            sampleID:      snapshot.sampleID,
            isImportant:   snapshot.isImportant,
            latitude:      snapshot.location?.coordinate.latitude,
            longitude:     snapshot.location?.coordinate.longitude,
            gpsAccuracy:   snapshot.location.map { max($0.horizontalAccuracy, 0) },
            location:      snapshot.place,
            site:          snapshot.site,
            huongCamera:   snapshot.huongCamera,
            huongManhXam:  snapshot.huongManhXam,
            huongLayMau:   snapshot.huongLayMau,
            altitude:      snapshot.location?.altitude,
            headingDegrees: outwardHeading?.degrees,
            headingCardinal: outwardHeading?.cardinal,
            loaiMau:       snapshot.loaiMau,
            ngayLay:       tsDisplay.string(from: snapshot.capturedAt),
            fileAnh:       filename
        )

        do { try SampleLogger.shared.append(record: record) }
        catch { print("SamplePhoto: failed to log record – \(error)") }

        SampleContextStore.shared.save(
            sampleID: snapshot.sampleID,
            isImportant: snapshot.isImportant,
            loaiMau: snapshot.loaiMau,
            site: snapshot.site
        )

        DispatchQueue.main.async { [weak self] in
            self?.showHUD()
            self?.advanceSampleID()
        }
    }

    private func samplePhotoFilename(snapshot: SampleCaptureSnapshot, timestamp: String) -> String {
        let sampleID = SampleContextStore.folderSafeSampleID(snapshot.sampleID)
        let flagSuffix = snapshot.isImportant ? "*" : ""
        let huong = SampleContextStore.folderSafeSampleID(snapshot.huongLayMau)
        return "\(sampleID)\(flagSuffix)_\(huong)_\(timestamp).jpg"
    }

    private func simulatorMockImageData(snapshot: SampleCaptureSnapshot) -> Data {
        let size = CGSize(width: 1600, height: 1200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            UIColor(red: 0.10, green: 0.14, blue: 0.12, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

            UIColor(red: 0.22, green: 0.38, blue: 0.26, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 1020, y: 190, width: 260, height: 260)).fill()

            UIColor(red: 0.48, green: 0.35, blue: 0.22, alpha: 1).setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 720, y: 220, width: 150, height: 820),
                cornerRadius: 28
            ).fill()

            UIColor(red: 0.25, green: 0.47, blue: 0.28, alpha: 1).setFill()
            for rect in [
                CGRect(x: 560, y: 150, width: 280, height: 190),
                CGRect(x: 800, y: 120, width: 320, height: 220),
                CGRect(x: 610, y: 340, width: 430, height: 190)
            ] {
                UIBezierPath(ovalIn: rect).fill()
            }

            let title = "MOCK SAMPLE PHOTO"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.88)
            ]
            title.draw(at: CGPoint(x: 70, y: 70), withAttributes: attrs)

            let flag = snapshot.isImportant ? " · *" : ""
            let subtitle = "\(snapshot.sampleID)\(flag) · \(snapshot.loaiMau) · \(snapshot.huongLayMau)"
            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.72)
            ]
            subtitle.draw(at: CGPoint(x: 74, y: 140), withAttributes: subtitleAttrs)
        }

        return image.jpegData(compressionQuality: 0.95) ?? Data()
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
            "Flag: \(snapshot.isImportant ? "*" : "")",
            "Loai mau: \(snapshot.loaiMau)",
            df.string(from: capturedAt)
        ]

        if !snapshot.site.isEmpty {
            lines.append("Site: \(snapshot.site)")
        }
        lines.append("Huong camera: \(snapshot.huongCamera)")
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
            let outward = outwardFacingInfo(from: heading)
            lines.append(String(format: "Camera heading: %.0f° %@", heading.degrees, heading.cardinal))
            lines.append(String(format: "Manh xam heading: %.0f° %@", outward.degrees, outward.cardinal))
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
            "flag": snapshot.isImportant ? "*" : "",
            "is_important": snapshot.isImportant,
            "loai_mau": snapshot.loaiMau,
            "ngay_lay": iso,
            "location": place,
            "site": snapshot.site,
            "huong_camera": snapshot.huongCamera,
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
            let outward = outwardFacingInfo(from: heading)
            sampleData["camera_heading_degree"] = heading.degrees
            sampleData["camera_heading_cardinal"] = heading.cardinal
            sampleData["heading_degree"] = outward.degrees
            sampleData["heading_cardinal"] = outward.cardinal
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
                gps[kCGImagePropertyGPSImgDirection] = outwardFacingInfo(from: heading).degrees
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
