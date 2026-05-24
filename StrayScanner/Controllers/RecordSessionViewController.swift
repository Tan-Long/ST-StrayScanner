//
//  RecordSessionViewController.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import Foundation
import UIKit
import Metal
import ARKit
import CoreData
import CoreMotion

let FpsDividers: [Int] = [1, 2, 4, 12, 60]
let AvailableFpsSettings: [Int] = FpsDividers.map { Int(60 / $0) }
let FpsUserDefaultsKey: String = "FPS"

class MetalView : UIView {
    override class var layerClass: AnyClass {
        get {
            return CAMetalLayer.self
        }
    }
    override var layer: CAMetalLayer {
        return super.layer as! CAMetalLayer
    }
}

class RecordSessionViewController : UIViewController, ARSessionDelegate {
    private struct FinishedRecording {
        let started: Date
        let encoder: DatasetEncoder
    }

    private var unsupported: Bool = false
    private var arConfiguration: ARWorldTrackingConfiguration?
    private let session = ARSession()
    private let motionManager = CMMotionManager()
    private var renderer: CameraRenderer?
    private var updateLabelTimer: Timer?
    private var startedRecording: Date?
    private var dataContext: NSManagedObjectContext!
    private var datasetEncoder: DatasetEncoder?
    private var selectedSampleContext: SampleContext?
    private var hasAppliedInitialSampleContext = false
    private let imuOperationQueue = OperationQueue()
    private var chosenFpsSetting: Int = 0
    private var isImportantTree: Bool = false
    private var flagChangeHandler: ((Bool) -> Void)?
    private let pauseButton = UIButton(type: .system)
    @IBOutlet private var rgbView: MetalView!
    @IBOutlet private var depthView: MetalView!
    @IBOutlet private var recordButton: RecordButton!
    @IBOutlet private var timeLabel: UILabel!
    @IBOutlet weak var fpsButton: UIButton!
    var dismissFunction: Optional<() -> Void> = Optional.none

    deinit {
        NotificationCenter.default.removeObserver(self, name: sampleFlagChangeNotification, object: nil)
    }
    
    func setDismissFunction(_ fn: Optional<() -> Void>) {
        self.dismissFunction = fn
    }

    func setFlagChangeHandler(_ handler: @escaping (Bool) -> Void) {
        flagChangeHandler = handler
        handler(isImportantTree)
    }

    func setSampleContext(_ context: SampleContext?) {
        selectedSampleContext = context
        guard startedRecording == nil else { return }
        if !hasAppliedInitialSampleContext {
            isImportantTree = context?.isImportant ?? false
            hasAppliedInitialSampleContext = true
        }
        if isViewLoaded {
            flagChangeHandler?(isImportantTree)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        self.chosenFpsSetting = UserDefaults.standard.integer(forKey: FpsUserDefaultsKey)
        updateFpsSetting()
        setSampleContext(selectedSampleContext)
    }

    override func viewDidLoad() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        self.dataContext = appDelegate.persistentContainer.viewContext
        self.renderer = CameraRenderer(rgbLayer: rgbView.layer, depthLayer: depthView.layer)

        depthView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped)))
        rgbView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped)))
        
        setViewProperties()
        configurePauseButton()
        observeSampleFlagChanges()
        setAccessibilityIdentifiers()
        session.delegate = self

        recordButton.setCallback { (recording: Bool) in
            self.toggleRecording(recording)
        }
        fpsButton.layer.masksToBounds = true
        fpsButton.layer.cornerRadius = 12.0
        
        imuOperationQueue.qualityOfService = .userInitiated
    }

    override func viewDidDisappear(_ animated: Bool) {
        session.pause();
    }

    override func viewWillDisappear(_ animated: Bool) {
        updateLabelTimer?.invalidate()
        datasetEncoder = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        startSession()
    }

    private func startSession() {
        let config = ARWorldTrackingConfiguration()
        arConfiguration = config
        if !ARWorldTrackingConfiguration.isSupported || !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            print("AR is not supported.")
            unsupported = true
        } else {
            config.frameSemantics.insert(.sceneDepth)
            session.run(config)
        }
    }
    
    private func startRawIMU() {
        if self.motionManager.isAccelerometerAvailable {
            self.motionManager.accelerometerUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startAccelerometerUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving accelerometer data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawAccelerometer(data: data)
            }
        } else {
            print("Accelerometer not available on this device.")
        }

        if self.motionManager.isGyroAvailable {
            self.motionManager.gyroUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startGyroUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving gyroscope data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawGyroscope(data: data)
            }
        } else {
            print("Gyroscope not available on this device.")
        }
    }

    private func stopRawIMU() {
        if self.motionManager.isAccelerometerActive {
            self.motionManager.stopAccelerometerUpdates()
            print("Stopped accelerometer updates.")
        }
        if self.motionManager.isGyroActive {
            self.motionManager.stopGyroUpdates()
            print("Stopped gyroscope updates.")
        }
    }
    
    private func toggleRecording(_ recording: Bool) {
        if unsupported {
            showUnsupportedAlert()
            return
        }
        if recording && self.startedRecording == nil {
            if !startRecording() {
                recordButton.setRecording(false)
            }
        } else if self.startedRecording != nil && !recording {
            stopRecording()
        } else {
            print("This should not happen. We are either not recording and want to stop, or we are recording and want to start.")
        }
    }

    @discardableResult
    private func startRecording() -> Bool {
        guard let arConfiguration = arConfiguration else {
            showUnsupportedAlert()
            return false
        }
        self.startedRecording = Date()
        updateTime()
        updateLabelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.updateTime()
        }
        // Start location/motion before DatasetEncoder so writeGPSAnchor() sees a
        // fresh location fix rather than a stale or nil value.
        LocationMetadataManager.shared.start()
        let sampleContext = sampleContextForRecording()
        datasetEncoder = DatasetEncoder(
            arConfiguration: arConfiguration,
            fpsDivider: FpsDividers[chosenFpsSetting],
            isImportant: isImportantTree,
            sampleContext: sampleContext
        )
        updateRecordingControls(isRecording: true)
        startRawIMU()
        return true
    }

    private func stopRecording() {
        guard let finished = finishActiveRecording(resetRecordButton: false) else { return }
        switch finished.encoder.status {
            case .allGood:
                if saveRecording(finished.started, finished.encoder) {
                    self.dismissFunction?()
                }
            case .videoEncodingError:
                showError()
            case .directoryCreationError:
                showError()
        }
    }

    @objc private func pauseButtonTapped() {
        guard let finished = finishActiveRecording(resetRecordButton: true) else { return }
        switch finished.encoder.status {
            case .allGood:
                showPausedRecordingActions(finished)
            case .videoEncodingError:
                showError()
            case .directoryCreationError:
                showError()
        }
    }

    private func finishActiveRecording(resetRecordButton: Bool) -> FinishedRecording? {
        guard let started = self.startedRecording else {
            print("Hasn't started recording. Something is wrong.")
            return nil
        }
        guard let encoder = datasetEncoder else {
            print("No dataset encoder. Something is wrong.")
            startedRecording = nil
            updateRecordingControls(isRecording: false)
            if resetRecordButton {
                recordButton.setRecording(false)
            }
            return nil
        }

        startedRecording = nil
        updateLabelTimer?.invalidate()
        updateLabelTimer = nil
        stopRawIMU()
        LocationMetadataManager.shared.stop()
        encoder.wrapUp()
        datasetEncoder = nil
        updateRecordingControls(isRecording: false)
        if resetRecordButton {
            recordButton.setRecording(false)
        }
        return FinishedRecording(started: started, encoder: encoder)
    }

    @discardableResult
    private func saveRecording(_ started: Date, _ encoder: DatasetEncoder) -> Bool {
        let sessionCount = countSessions()
        
        let duration = Date().timeIntervalSince(started)
        let entity = NSEntityDescription.entity(forEntityName: "Recording", in: self.dataContext)!
        let recording: Recording = Recording(entity: entity, insertInto: self.dataContext)
        recording.setValue(encoder.id, forKey: "id")
        recording.setValue(duration, forKey: "duration")
        recording.setValue(started, forKey: "createdAt")
        recording.setValue("Recording \(sessionCount)", forKey: "name")
        recording.setValue(encoder.rgbFilePath.relativeString, forKey: "rgbFilePath")
        recording.setValue(encoder.depthFilePath.relativeString, forKey: "depthFilePath")
        do {
            try self.dataContext.save()
            NotificationCenter.default.post(name: NSNotification.Name("sessionsChanged"), object: nil)
            return true
        } catch let error as NSError {
            print("Could not save recording. \(error), \(error.userInfo)")
            self.dataContext.delete(recording)
            showSaveError()
            return false
        }
    }

    private func showError() {
        let controller = UIAlertController(title: "Error",
            message: "Something went wrong when encoding video. This should not have happened. You might want to file a bug report.",
            preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Default Action"), style: .default, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        }))
        self.present(controller, animated: true, completion: nil)
    }

    private func showSaveError() {
        let controller = UIAlertController(
            title: "Không lưu được recording",
            message: "Đoạn quay đã dừng nhưng app không ghi được vào danh sách recording.",
            preferredStyle: .alert
        )
        controller.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(controller, animated: true)
    }

    private func showDeleteError(_ error: Error) {
        let controller = UIAlertController(
            title: "Không xoá được đoạn quay",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        controller.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(controller, animated: true)
    }

    private func showPausedRecordingActions(_ finished: FinishedRecording) {
        let controller = UIAlertController(
            title: "Đã pause quay",
            message: "Đoạn vừa quay đã được dừng hẳn. Bạn muốn xoá đoạn này hay lưu lại rồi quay tiếp?",
            preferredStyle: .alert
        )
        controller.addAction(UIAlertAction(title: "Xoá đoạn này", style: .destructive) { [weak self] _ in
            self?.deleteRecordingFiles(for: finished.encoder)
        })
        controller.addAction(UIAlertAction(title: "Lưu & tiếp tục quay", style: .default) { [weak self] _ in
            guard let self = self else { return }
            guard self.saveRecording(finished.started, finished.encoder) else { return }
            if self.startRecording() {
                self.recordButton.setRecording(true)
            }
        })
        self.present(controller, animated: true)
    }

    private func deleteRecordingFiles(for encoder: DatasetEncoder) {
        let directory = encoder.rgbFilePath.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            timeLabel.text = "00:00:00"
            return
        }
        do {
            try FileManager.default.removeItem(at: directory)
            timeLabel.text = "00:00:00"
        } catch {
            showDeleteError(error)
        }
    }

    private func updateTime() {
        guard let started = self.startedRecording else { return }
        let seconds = Date().timeIntervalSince(started)
        let minutes: Int = Int(floor(seconds / 60).truncatingRemainder(dividingBy: 60))
        let hours: Int = Int(floor(seconds / 3600))
        let roundSeconds: Int = Int(floor(seconds.truncatingRemainder(dividingBy: 60)))
        self.timeLabel.text = String(format: "%02d:%02d:%02d", hours, minutes, roundSeconds)
    }

    @objc func viewTapped() {
        switch renderer!.renderMode {
            case .depth:
                renderer!.renderMode = RenderMode.rgb
                rgbView.isHidden = false
                depthView.isHidden = true
            case .rgb:
                renderer!.renderMode = RenderMode.depth
                depthView.isHidden = false
                rgbView.isHidden = true
        }
    }
    
    @IBAction func fpsButtonTapped() {
        chosenFpsSetting = (chosenFpsSetting + 1) % AvailableFpsSettings.count
        updateFpsSetting()
        UserDefaults.standard.set(chosenFpsSetting, forKey: FpsUserDefaultsKey)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        self.renderer!.render(frame: frame)
        if startedRecording != nil {
            if let encoder = datasetEncoder {
                let locationMetadata = LocationMetadataManager.shared.snapshot(arFrame: frame)
                encoder.add(frame: frame, locationMetadata: locationMetadata)
            } else {
                print("There is no video encoder. That can't be good.")
            }
        }
    }

    private func setViewProperties() {
        self.view.backgroundColor = UIColor(named: "BackgroundColor")
    }

    private func configurePauseButton() {
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        pauseButton.tintColor = UIColor(named: "LightColor")
        pauseButton.backgroundColor = UIColor(named: "DarkColor")
        pauseButton.layer.cornerRadius = 27
        pauseButton.layer.masksToBounds = true
        pauseButton.isHidden = true
        pauseButton.isEnabled = false
        pauseButton.addTarget(self, action: #selector(pauseButtonTapped), for: .touchUpInside)
        view.addSubview(pauseButton)

        NSLayoutConstraint.activate([
            pauseButton.leadingAnchor.constraint(equalTo: recordButton.trailingAnchor, constant: 22),
            pauseButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor, constant: 20),
            pauseButton.widthAnchor.constraint(equalToConstant: 54),
            pauseButton.heightAnchor.constraint(equalToConstant: 54)
        ])
    }

    private func updateRecordingControls(isRecording: Bool) {
        pauseButton.isHidden = !isRecording
        pauseButton.isEnabled = isRecording
        recordButton.accessibilityLabel = isRecording ? "Stop recording" : "Record"
        recordButton.accessibilityValue = isRecording ? "Recording" : "Idle"
    }

    private func observeSampleFlagChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sampleFlagChanged(_:)),
            name: sampleFlagChangeNotification,
            object: nil
        )
    }

    @objc private func sampleFlagChanged(_ notification: Notification) {
        guard startedRecording == nil else { return }
        guard let isImportant = notification.userInfo?["isImportant"] as? Bool else { return }
        isImportantTree = isImportant
        flagChangeHandler?(isImportantTree)
    }

    private func sampleContextForRecording() -> SampleContext? {
        guard let context = selectedSampleContext else { return nil }
        let sampleID = context.sampleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sampleID.isEmpty else { return nil }
        return SampleContext(
            sampleID: sampleID,
            isImportant: isImportantTree,
            loaiMau: context.loaiMau,
            site: context.site
        )
    }

    private func setAccessibilityIdentifiers() {
        view.accessibilityIdentifier = "recordSession.screen"
        rgbView.accessibilityIdentifier = "recordSession.rgbView"
        depthView.accessibilityIdentifier = "recordSession.depthView"
        recordButton.isAccessibilityElement = true
        recordButton.accessibilityIdentifier = "recordSession.recordButton"
        recordButton.accessibilityLabel = "Record"
        recordButton.accessibilityTraits = [.button]
        pauseButton.accessibilityIdentifier = "recordSession.pauseButton"
        pauseButton.accessibilityLabel = "Pause recording"
        pauseButton.accessibilityTraits = [.button]
        timeLabel.accessibilityIdentifier = "recordSession.timeLabel"
        fpsButton.accessibilityIdentifier = "recordSession.fpsButton"
    }
    
    private func updateFpsSetting() {
        let fps = AvailableFpsSettings[chosenFpsSetting]
        let buttonLabel: String = "\(fps) fps"
        fpsButton.setTitle(buttonLabel, for: UIControl.State.normal)
    }
    
    private func showUnsupportedAlert() {
        let alert = UIAlertController(title: "Unsupported device", message: "This device doesn't seem to have the required level of ARKit support.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            self.dismissFunction?()
        }))
        self.present(alert, animated: true)
    }
    
    private func countSessions() -> Int {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return 0 }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        do {
            let fetched: [NSManagedObject] = try appDelegate.persistentContainer.viewContext.fetch(request)
            return fetched.count
        } catch let error {
            print("Could not fetch sessions for counting. \(error.localizedDescription)")
        }
        return 0
    }
}
