//
//  SamplePhotoViewController.swift
//  StrayScanner
//

import UIKit
import AVFoundation

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

        if let h = LocationMetadataManager.shared.currentHeading, h.headingAccuracy >= 0 {
            parts.append(String(format: "%.0f° %@", h.magneticHeading, cardinal(for: h.magneticHeading)))
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

    private func saveRecord(imageData: Data) {
        let loc     = LocationMetadataManager.shared.currentLocation
        let heading = LocationMetadataManager.shared.currentHeading
        let place   = LocationMetadataManager.shared.currentPlaceName ?? ""

        let tsFile = DateFormatter(); tsFile.dateFormat = "yyyyMMdd_HHmmss"
        let tsDisplay = DateFormatter(); tsDisplay.dateStyle = .medium; tsDisplay.timeStyle = .short

        let sampleID = sampleIDField.text ?? "UNKNOWN"
        let filename = "\(sampleID)_\(tsFile.string(from: Date())).jpg"
        let fileURL  = SampleLogger.shared.samplesDirectory.appendingPathComponent(filename)

        do { try imageData.write(to: fileURL) }
        catch { print("SamplePhoto: failed to write JPEG – \(error)") }

        var headingStr = ""
        if let h = heading, h.headingAccuracy >= 0 {
            headingStr = String(format: "%.0f° %@", h.magneticHeading, cardinal(for: h.magneticHeading))
        }

        let record = SampleRecord(
            sampleID:      sampleID,
            tenMau:        tenMauField.text ?? "",
            latitude:      loc?.coordinate.latitude,
            longitude:     loc?.coordinate.longitude,
            location:      place,
            site:          siteField.text ?? "",
            huongManhXam:  huongManhXamOptions[huongPicker.selectedRow(inComponent: 0)],
            huongLayMau:   selectedHuongLayMau ?? "",
            altitude:      loc?.altitude,
            loaiMau:       currentLoaiMau(),
            ngayLay:       tsDisplay.string(from: Date()),
            fileAnh:       filename
        )

        do { try SampleLogger.shared.append(record: record) }
        catch { print("SamplePhoto: failed to log record – \(error)") }

        DispatchQueue.main.async { [weak self] in
            self?.showHUD()
            self?.advanceSampleID()
        }
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.saveRecord(imageData: data)
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
