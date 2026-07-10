//
//  SessionList.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/15/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI
import CoreData
import AVFoundation
import CoreLocation

class SessionListViewModel: ObservableObject {
    private var dataContext: NSManagedObjectContext?
    @Published var sessions: [Recording] = []
    @Published var resetError: String?

    init() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        dataContext = appDelegate.persistentContainer.viewContext
        self.sessions = []
        NotificationCenter.default.addObserver(self, selector: #selector(sessionsChanged), name: NSNotification.Name("sessionsChanged"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func fetchSessions() {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            try restoreMissingRecordingsFromFiles()
            let fetched: [NSManagedObject] = try dataContext?.fetch(request) ?? []
            sessions = fetched.map { session in
                return session as! Recording
            }

        } catch let error as NSError {
            print("Something went wrong. Error: \(error), \(error.userInfo)")
        }
    }

    private func restoreMissingRecordingsFromFiles() throws {
        guard let dataContext = dataContext else { return }
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        let existingRecordings = (try dataContext.fetch(request) as? [Recording]) ?? []
        let existingDirectories = Set(existingRecordings.compactMap { recording in
            recording.directoryPath()?.standardizedFileURL.path
        })
        let folders = try fileManager.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var didRestore = false
        for folder in folders {
            let values = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            guard folder.lastPathComponent != "samples" else { continue }
            let rgbURL = folder.appendingPathComponent("rgb.mp4")
            guard fileManager.fileExists(atPath: rgbURL.path) else { continue }
            guard !existingDirectories.contains(folder.standardizedFileURL.path) else { continue }

            let entity = NSEntityDescription.entity(forEntityName: "Recording", in: dataContext)!
            let recording = Recording(entity: entity, insertInto: dataContext)
            recording.id = UUID()
            recording.name = folder.lastPathComponent
            recording.createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
            recording.duration = videoDuration(url: rgbURL)
            recording.rgbFilePath = "\(folder.lastPathComponent)/rgb.mp4"

            let depthURL = folder.appendingPathComponent("depth", isDirectory: true)
            if fileManager.fileExists(atPath: depthURL.path) {
                recording.depthFilePath = "\(folder.lastPathComponent)/depth"
            }
            didRestore = true
        }

        if didRestore {
            try dataContext.save()
        }
    }

    private func videoDuration(url: URL) -> Double {
        let duration = AVURLAsset(url: url).duration
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }

    @objc func sessionsChanged() {
        DispatchQueue.main.async {
            self.fetchSessions()
        }
    }

    func resetAllData() {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        let fileManager = FileManager.default

        do {
            let fetched: [NSManagedObject] = try dataContext?.fetch(request) ?? []
            for object in fetched {
                if let recording = object as? Recording {
                    recording.deleteFiles()
                }
                dataContext?.delete(object)
            }
            try dataContext?.save()

            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let urls = try fileManager.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for url in urls where shouldDeleteExportItem(url) {
                try? fileManager.removeItem(at: url)
            }

            SampleContextStore.shared.clear()
            UserDefaults.standard.removeObject(forKey: "sample_last_gps_site")
            SampleLogger.shared.prepareStorageForExport()
            sessions = []
            NotificationCenter.default.post(name: NSNotification.Name("sessionsChanged"), object: nil)
        } catch let error as NSError {
            resetError = "Không thể xoá toàn bộ data: \(error.localizedDescription)"
        }
    }

    private func shouldDeleteExportItem(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let name = url.lastPathComponent
        if name == "samples" || name == "surveys" || name.hasPrefix("cay_") || name.hasSuffix(".zip") {
            return true
        }
        return fileManager.fileExists(atPath: url.appendingPathComponent("rgb.mp4").path)
    }

}

struct SessionList: View {
    @ObservedObject var viewModel = SessionListViewModel()
    @State private var showingInfo = false
    @State private var showingResetConfirm = false
    @State private var resetConfirmationCode = ""
    @State private var resetConfirmationInput = ""
    @State private var showingShareSheet = false
    @State private var fullExportURL: URL?
    @State private var isCreatingFullExport = false
    @State private var fullExportProgress: ShareUtility.FullDataArchiveProgress?
    @State private var exportError: String?

    var body: some View {
        ZStack {
        Color.black
        .ignoresSafeArea()
        NavigationView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Recordings")
                        .foregroundColor(Color("TextColor"))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                        .padding([.top, .leading], 15.0)
                    Spacer()
                    Button(action: {
                        showingInfo.toggle()
                    }, label: {
                        Image(systemName: "info.circle")
                            .resizable()
                            .frame(width: 25, height: 25, alignment: .center)
                            .padding(.top, 17)
                            .padding(.trailing, 20)
                            .foregroundColor(Color("TextColor"))
                    })
                    .accessibilityIdentifier("sessionList.infoButton")
                    .sheet(isPresented: $showingInfo) {
                        InformationView()
                    }
                }

                if !viewModel.sessions.isEmpty {
                    List {
                        ForEach(viewModel.sessions, id: \.objectID) { recording in
                            NavigationLink(destination: SessionDetailView(recording: recording)) {
                                SessionRow(session: recording)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    Spacer()
                } else {
                    Spacer()
                    Text("No recorded sessions. Record one, and it will appear here.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 50.0)
                }
                HStack {
                    Spacer()
                    NavigationLink(destination: NewSessionView(), label: {
                        Text("Record new session")
                            .font(.title3)
                            .padding(20)
                            .background(Color("TextColor"))
                            .foregroundColor(Color("LightColor"))
                            .cornerRadius(35)
                            .padding(20)
                    })
                    .accessibilityIdentifier("sessionList.recordNewSession")
                    Spacer()
                }
                HStack {
                    Spacer()
                    NavigationLink(destination: SampleSessionView(), label: {
                        Text("📷 Chụp ảnh mẫu")
                            .font(.title3)
                            .padding(20)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(35)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                    })
                    .accessibilityIdentifier("sessionList.samplePhoto")
                    Spacer()
                }
                HStack {
                    Spacer()
                    NavigationLink(destination: DurianSurveyView(), label: {
                        HStack {
                            Image(systemName: "list.bullet.rectangle")
                            Text("Bảng hỏi vườn")
                                .fixedSize()
                        }
                        .font(.body)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(24)
                        .padding(.bottom, 8)
                    })
                    .accessibilityIdentifier("sessionList.durianSurvey")
                    Spacer()
                }
                HStack {
                    Spacer()
                    NavigationLink(destination: SamplePhotoListView(), label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle")
                            Text("Quản lý ảnh mẫu")
                                .fixedSize()
                        }
                        .font(.body)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                        .background(Color("TextColor"))
                        .foregroundColor(Color("LightColor"))
                        .cornerRadius(24)
                        .padding(.bottom, 8)
                    })
                    .accessibilityIdentifier("sessionList.manageSamplePhotos")
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button(action: exportAllData) {
                        HStack {
                            if isCreatingFullExport {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "archivebox")
                            }
                            Text(exportAllButtonTitle)
                                .fixedSize()
                        }
                        .font(.body)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                        .background(isCreatingFullExport ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(24)
                        .padding(.bottom, 8)
                    }
                    .disabled(isCreatingFullExport)
                    .accessibilityIdentifier("sessionList.exportAllZip")
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button(action: prepareResetConfirmation, label: {
                        Text("Format / Reset data")
                            .font(.body)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 18)
                            .background(Color("DangerColor"))
                            .foregroundColor(.white)
                            .cornerRadius(24)
                            .padding(.bottom, 16)
                    })
                    .accessibilityIdentifier("sessionList.resetData")
                    Spacer()
                }
                if (viewModel.sessions.isEmpty) {
                    Spacer()
                }
            }
            .navigationBarHidden(true)
            .background(Color("BackgroundColor").ignoresSafeArea())
            .onAppear {
                DispatchQueue.main.async {
                    viewModel.fetchSessions()
                }
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).forEach({ url in
                    let relative = url.relativeString
                    print("relative url: \(relative)")
                })
                let delegate = UIApplication.shared.delegate as! AppDelegate
                delegate.appDaemon?.removeDeletedEntries()
        }
        }
        .background(Color("BackgroundColor").edgesIgnoringSafeArea(.all))
        .alert("Xoá toàn bộ data?", isPresented: $showingResetConfirm) {
            TextField("Nhập mã xác nhận", text: $resetConfirmationInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Huỷ", role: .cancel) {
                clearResetConfirmation()
            }
            Button("Xoá hết", role: .destructive) {
                guard resetConfirmationInput.uppercased() == resetConfirmationCode else { return }
                viewModel.resetAllData()
                clearResetConfirmation()
            }
            .disabled(resetConfirmationInput.uppercased() != resetConfirmationCode)
        } message: {
            Text("Thao tác này xoá toàn bộ video folders, ảnh sample, file data export và danh sách recording trong app. Nhập mã \(resetConfirmationCode) để xác nhận. Không thể hoàn tác.")
        }
        .alert("Reset lỗi", isPresented: Binding(
            get: { viewModel.resetError != nil },
            set: { if !$0 { viewModel.resetError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.resetError = nil }
        } message: {
            Text(viewModel.resetError ?? "")
        }
        .alert("Xuất ZIP lỗi", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .sheet(isPresented: $showingShareSheet) {
            if let fullExportURL = fullExportURL {
                ShareSheet(activityItems: [fullExportURL]) { _, _, _, _ in
                    DispatchQueue.main.async {
                        try? FileManager.default.removeItem(at: fullExportURL)
                        self.fullExportURL = nil
                        showingShareSheet = false
                    }
                }
            }
        }
        }
    }

    private func prepareResetConfirmation() {
        resetConfirmationCode = Self.makeResetConfirmationCode()
        resetConfirmationInput = ""
        showingResetConfirm = true
    }

    private func clearResetConfirmation() {
        resetConfirmationCode = ""
        resetConfirmationInput = ""
    }

    private func exportAllData() {
        isCreatingFullExport = true
        fullExportProgress = nil
        Task {
            do {
                let url = try await ShareUtility.createFullDataArchive { progress in
                    DispatchQueue.main.async {
                        fullExportProgress = progress
                    }
                }
                await MainActor.run {
                    fullExportURL = url
                    isCreatingFullExport = false
                    fullExportProgress = nil
                    showingShareSheet = true
                }
            } catch {
                await MainActor.run {
                    isCreatingFullExport = false
                    fullExportProgress = nil
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private static func makeResetConfirmationCode() -> String {
        let characters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<5).compactMap { _ in characters.randomElement() })
    }

    private var exportAllButtonTitle: String {
        guard isCreatingFullExport else { return "Xuất ZIP toàn bộ" }
        if let progress = fullExportProgress {
            return "Đang nén \(progress.percent)%"
        }
        return "Đang chuẩn bị..."
    }
}

struct DurianSurveySection: Identifiable {
    let title: String
    let questions: [DurianSurveyQuestion]

    var id: String { title }
}

struct DurianSurveyQuestion: Identifiable {
    enum Kind {
        case text
        case yesNo
        case choice([String])
    }

    let id: String
    let text: String
    let kind: Kind
}

private let durianSurveySections: [DurianSurveySection] = [
    DurianSurveySection(title: "A. Thông tin chung", questions: [
        DurianSurveyQuestion(id: "A1", text: "Mã số hộ/vườn", kind: .text),
        DurianSurveyQuestion(id: "A2", text: "Họ và tên chủ vườn", kind: .text),
        DurianSurveyQuestion(id: "A3", text: "Số điện thoại", kind: .text),
        DurianSurveyQuestion(id: "A4", text: "Địa chỉ (xã, huyện, tỉnh)", kind: .text),
        DurianSurveyQuestion(id: "A6", text: "Diện tích trồng sầu riêng (ha)", kind: .text),
        DurianSurveyQuestion(id: "A7", text: "Vườn đang lấy mẫu trồng từ năm nào (vườn khoảng bao nhiêu tuổi)?", kind: .text)
    ]),
    DurianSurveySection(title: "B. Đặc điểm vườn", questions: [
        DurianSurveyQuestion(id: "B1", text: "Vườn hiện đang trồng giống sầu riêng nào?", kind: .text)
    ]),
    DurianSurveySection(title: "C. Phân bón", questions: [
        DurianSurveyQuestion(id: "C1", text: "Vườn mình dùng loại phân bón đất gì? (Đạm, Lân, Kali, Tổng hợp, Hữu cơ)", kind: .text),
        DurianSurveyQuestion(id: "C2", text: "Nếu có, lượng bón (kg/cây/năm)", kind: .text),
        DurianSurveyQuestion(id: "C3", text: "Có sử dụng phân bón lá không?", kind: .yesNo),
        DurianSurveyQuestion(id: "C4", text: "Nếu có dùng loại gì?", kind: .text),
        DurianSurveyQuestion(id: "C5", text: "Liều lượng phân bón lá như thế nào?", kind: .text)
    ]),
    DurianSurveySection(title: "D. Nước tưới", questions: [
        DurianSurveyQuestion(id: "D1", text: "Nguồn nước tưới chính", kind: .choice(["Giếng", "Hồ", "Sông", "Khác"])),
        DurianSurveyQuestion(id: "D2", text: "Phương pháp tưới", kind: .choice(["Nhỏ giọt", "Phun", "Béc", "Khác"]))
    ]),
    DurianSurveySection(title: "E. Ra hoa và quản lý quả (xin thuốc kích mầm/tên/vỏ nếu có)", questions: [
        DurianSurveyQuestion(id: "E1", text: "Có sử dụng thuốc kích mầm hoa không?", kind: .yesNo),
        DurianSurveyQuestion(id: "E2", text: "Nếu có, dùng loại gì?", kind: .text),
        DurianSurveyQuestion(id: "E3", text: "Liều lượng dùng như thế nào?", kind: .text),
        DurianSurveyQuestion(id: "E4", text: "Dùng thời điểm nào?", kind: .text),
        DurianSurveyQuestion(id: "E5", text: "Có tỉa quả không?", kind: .yesNo),
        DurianSurveyQuestion(id: "E6", text: "Mỗi cây thường khoảng bao nhiêu quả?", kind: .text)
    ]),
    DurianSurveySection(title: "G. Thuốc BVTV (xin thuốc/tên/vỏ nếu có)", questions: [
        DurianSurveyQuestion(id: "G1", text: "Dùng thuốc bảo vệ thực vật gì?", kind: .text),
        DurianSurveyQuestion(id: "G2", text: "Thời điểm dùng?", kind: .text),
        DurianSurveyQuestion(id: "G3", text: "Có sử dụng thuốc diệt cỏ không?", kind: .yesNo),
        DurianSurveyQuestion(id: "G4", text: "Nếu có, dùng loại gì?", kind: .text),
        DurianSurveyQuestion(id: "G5", text: "Liều lượng như thế nào?", kind: .text)
    ]),
    DurianSurveySection(title: "H. Thu hoạch", questions: [
        DurianSurveyQuestion(id: "H1", text: "Năng suất trung bình (kg/cây)", kind: .text)
    ]),
    DurianSurveySection(title: "K. Lấy mẫu", questions: [
        DurianSurveyQuestion(id: "K1", text: "Lấy mẫu đất", kind: .yesNo),
        DurianSurveyQuestion(id: "K2", text: "Lấy mẫu lá", kind: .yesNo),
        DurianSurveyQuestion(id: "K3", text: "Lấy mẫu quả", kind: .yesNo),
        DurianSurveyQuestion(id: "K4", text: "Lấy mẫu nước", kind: .yesNo),
        DurianSurveyQuestion(id: "K5", text: "Phân bón", kind: .yesNo),
        DurianSurveyQuestion(id: "K6", text: "Kích mầm", kind: .yesNo)
    ])
]

private var durianSurveyQuestions: [DurianSurveyQuestion] {
    durianSurveySections.flatMap { $0.questions }
}

struct DurianSurveyRecord: Codable, Identifiable {
    let id: String
    let formVersion: Int?
    let createdAt: String
    let latitude: Double?
    let longitude: Double?
    let gpsAccuracyM: Double?
    let altitudeM: Double?
    let placeName: String?
    let audioConsent: Bool?
    let audioFile: String?
    let answers: [String: String]
}

struct DurianSurveyAnswerSummary: Identifiable {
    let answer: String
    let count: Int
    let totalCount: Int
    let answeredCount: Int

    var id: String { answer }

    var percentOfTotal: Double {
        guard totalCount > 0 else { return 0 }
        return Double(count) / Double(totalCount)
    }

    var percentOfAnswered: Double {
        guard answeredCount > 0 else { return 0 }
        return Double(count) / Double(answeredCount)
    }
}

struct DurianSurveyQuestionSummary: Identifiable {
    let question: DurianSurveyQuestion
    let totalCount: Int
    let answeredCount: Int
    let answerStats: [DurianSurveyAnswerSummary]

    var id: String { question.id }
    var blankCount: Int { max(totalCount - answeredCount, 0) }
}

struct DurianSurveySummary {
    let totalCount: Int
    let gpsCount: Int
    let questions: [DurianSurveyQuestionSummary]

    var averageAnsweredPercent: Double {
        guard !questions.isEmpty, totalCount > 0 else { return 0 }
        let answered = questions.reduce(0) { $0 + $1.answeredCount }
        return Double(answered) / Double(questions.count * totalCount)
    }
}

private enum DurianSurveyStats {
    static func make(records: [DurianSurveyRecord]) -> DurianSurveySummary {
        let total = records.count
        let gpsCount = records.filter { $0.latitude != nil && $0.longitude != nil }.count
        let questions = durianSurveyQuestions.map { question -> DurianSurveyQuestionSummary in
            let answers = records
                .map { normalizedAnswer($0.answers[question.id] ?? "") }
                .filter { !$0.isEmpty }
            let counts = Dictionary(grouping: answers, by: { $0 }).mapValues(\.count)
            let answerStats = stats(for: question, counts: counts, totalCount: total, answeredCount: answers.count)
            return DurianSurveyQuestionSummary(
                question: question,
                totalCount: total,
                answeredCount: answers.count,
                answerStats: answerStats
            )
        }
        return DurianSurveySummary(totalCount: total, gpsCount: gpsCount, questions: questions)
    }

    private static func stats(
        for question: DurianSurveyQuestion,
        counts: [String: Int],
        totalCount: Int,
        answeredCount: Int
    ) -> [DurianSurveyAnswerSummary] {
        let knownOptions: [String]
        switch question.kind {
        case .yesNo:
            knownOptions = ["Có", "Không"]
        case .choice(let options):
            knownOptions = options
        case .text:
            knownOptions = []
        }

        if !knownOptions.isEmpty {
            let optionSet = Set(knownOptions)
            let knownStats = knownOptions.map {
                DurianSurveyAnswerSummary(
                    answer: $0,
                    count: counts[$0] ?? 0,
                    totalCount: totalCount,
                    answeredCount: answeredCount
                )
            }
            let otherStats = counts
                .filter { !optionSet.contains($0.key) }
                .map {
                    DurianSurveyAnswerSummary(
                        answer: $0.key,
                        count: $0.value,
                        totalCount: totalCount,
                        answeredCount: answeredCount
                    )
                }
                .sorted(by: sortAnswers)
            return knownStats + otherStats
        }

        return counts
            .map {
                DurianSurveyAnswerSummary(
                    answer: $0.key,
                    count: $0.value,
                    totalCount: totalCount,
                    answeredCount: answeredCount
                )
            }
            .sorted(by: sortAnswers)
    }

    private static func sortAnswers(_ lhs: DurianSurveyAnswerSummary, _ rhs: DurianSurveyAnswerSummary) -> Bool {
        if lhs.count != rhs.count {
            return lhs.count > rhs.count
        }
        return lhs.answer < rhs.answer
    }

    private static func normalizedAnswer(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class DurianSurveyStore {
    static let shared = DurianSurveyStore()
    private static let currentFormVersion = 2

    private let fileManager = FileManager.default
    private let surveysDirectory: URL
    private let audioDirectory: URL
    private let csvURL: URL
    private let xlsxURL: URL
    private let statsCSVURL: URL
    private let statsXLSXURL: URL
    private let statsJSONURL: URL

    private init() {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        surveysDirectory = documentsURL.appendingPathComponent("surveys", isDirectory: true)
        audioDirectory = surveysDirectory.appendingPathComponent("audio", isDirectory: true)
        csvURL = surveysDirectory.appendingPathComponent("surveys.csv")
        xlsxURL = surveysDirectory.appendingPathComponent("surveys.xlsx")
        statsCSVURL = surveysDirectory.appendingPathComponent("surveys_statistics.csv")
        statsXLSXURL = surveysDirectory.appendingPathComponent("surveys_statistics.xlsx")
        statsJSONURL = surveysDirectory.appendingPathComponent("surveys_statistics.json")
    }

    func save(
        answers: [String: String],
        location: CLLocation?,
        placeName: String?,
        audioConsent: Bool,
        audioFile: String?
    ) throws -> URL {
        try ensureSurveyDirectory()
        let createdAt = Self.isoString(from: Date())
        let id = UUID().uuidString
        let record = DurianSurveyRecord(
            id: id,
            formVersion: Self.currentFormVersion,
            createdAt: createdAt,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            gpsAccuracyM: location.map { max($0.horizontalAccuracy, 0) },
            altitudeM: location?.altitude,
            placeName: placeName,
            audioConsent: audioConsent,
            audioFile: audioFile,
            answers: answers
        )
        let jsonURL = surveysDirectory.appendingPathComponent(jsonFilename(for: record))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: jsonURL, options: .atomic)
        try writeCSV()
        try writeXLSX()
        try writeStatsFiles()
        return jsonURL
    }

    func prepareExportFiles() throws {
        guard fileManager.fileExists(atPath: surveysDirectory.path) else { return }
        try ensureSurveyDirectory()
        try writeCSV()
        try writeXLSX()
        try writeStatsFiles()
    }

    func savedRecords() -> [DurianSurveyRecord] {
        guard fileManager.fileExists(atPath: surveysDirectory.path) else { return [] }
        let urls = (try? fileManager.contentsOfDirectory(
            at: surveysDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> DurianSurveyRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let record = try? decoder.decode(DurianSurveyRecord.self, from: data) else { return nil }
                return record.formVersion == Self.currentFormVersion ? record : nil
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func summary() -> DurianSurveySummary {
        DurianSurveyStats.make(records: savedRecords())
    }

    func newAudioURL(sampleCode: String) throws -> URL {
        try ensureSurveyDirectory()
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let safeCode = SampleContextStore.folderSafeSampleID(sampleCode.isEmpty ? "survey" : sampleCode)
        let timestamp = Self.fileTimestamp(from: Date())
        return audioDirectory.appendingPathComponent("\(safeCode)_audio_\(timestamp)_\(UUID().uuidString.prefix(8)).m4a")
    }

    func relativeAudioPath(for url: URL?) -> String? {
        guard let url = url else { return nil }
        return "audio/\(url.lastPathComponent)"
    }

    func audioURL(for relativePath: String?) -> URL? {
        guard let relativePath = relativePath, !relativePath.isEmpty else { return nil }
        return surveysDirectory.appendingPathComponent(relativePath)
    }

    private func ensureSurveyDirectory() throws {
        try fileManager.createDirectory(at: surveysDirectory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: csvURL.path) {
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(contentsOf: csvHeader().utf8)
            try data.write(to: csvURL, options: .atomic)
        }
    }

    private func headerFields() -> [String] {
        let base = [
            "survey_id",
            "form_version",
            "created_at",
            "latitude",
            "longitude",
            "gps_accuracy_m",
            "altitude_m",
            "place_name",
            "audio_consent",
            "audio_file"
        ]
        let questionHeaders = durianSurveyQuestions.map { "\($0.id) \($0.text)" }
        return base + questionHeaders
    }

    private func csvHeader() -> String {
        headerFields().map(Self.csvField).joined(separator: ",") + "\n"
    }

    private func rowFields(record: DurianSurveyRecord) -> [String] {
        let base = [
            record.id,
            record.formVersion.map(String.init) ?? "",
            record.createdAt,
            Self.number(record.latitude, digits: 8),
            Self.number(record.longitude, digits: 8),
            Self.number(record.gpsAccuracyM, digits: 1),
            Self.number(record.altitudeM, digits: 1),
            record.placeName ?? "",
            (record.audioConsent ?? false) ? "Có" : "Không",
            record.audioFile ?? ""
        ]
        let answerFields = durianSurveyQuestions.map { record.answers[$0.id] ?? "" }
        return base + answerFields
    }

    private func csvRow(record: DurianSurveyRecord) -> String {
        rowFields(record: record).map(Self.csvField).joined(separator: ",") + "\n"
    }

    private func writeCSV() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: csvHeader().utf8)
        let rows = savedRecords().reversed().map(csvRow).joined()
        data.append(contentsOf: rows.utf8)
        try data.write(to: csvURL, options: .atomic)
    }

    private func writeXLSX() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        let rows = [headerFields()] + savedRecords().reversed().map(rowFields)
        let text = rows
            .map { $0.map(Self.tsvField).joined(separator: "\t") }
            .joined(separator: "\n") + "\n"
        data.append(contentsOf: text.utf8)
        try data.write(to: xlsxURL, options: .atomic)
    }

    private func writeStatsFiles() throws {
        let summary = summary()
        try statsCSVData(summary: summary).write(to: statsCSVURL, options: .atomic)
        try statsXLSXData(summary: summary).write(to: statsXLSXURL, options: .atomic)
        try statsJSONData(summary: summary).write(to: statsJSONURL, options: .atomic)
    }

    private func statsHeaderFields() -> [String] {
        [
            "question_id",
            "question",
            "type",
            "answer",
            "count",
            "total_forms",
            "answered_forms",
            "blank_forms",
            "percent_of_total",
            "percent_of_answered"
        ]
    }

    private func statsRows(summary: DurianSurveySummary) -> [[String]] {
        summary.questions.flatMap { questionSummary -> [[String]] in
            let answerRows = questionSummary.answerStats.map { answer in
                statsRow(questionSummary: questionSummary, answer: answer.answer, count: answer.count)
            }
            return answerRows + [
                statsRow(
                    questionSummary: questionSummary,
                    answer: "Chưa nhập",
                    count: questionSummary.blankCount,
                    includeAnsweredPercent: false
                )
            ]
        }
    }

    private func statsRow(
        questionSummary: DurianSurveyQuestionSummary,
        answer: String,
        count: Int,
        includeAnsweredPercent: Bool = true
    ) -> [String] {
        [
            questionSummary.question.id,
            questionSummary.question.text,
            questionType(questionSummary.question),
            answer,
            "\(count)",
            "\(questionSummary.totalCount)",
            "\(questionSummary.answeredCount)",
            "\(questionSummary.blankCount)",
            Self.percent(count, of: questionSummary.totalCount),
            includeAnsweredPercent ? Self.percent(count, of: questionSummary.answeredCount) : ""
        ]
    }

    private func statsCSVData(summary: DurianSurveySummary) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        let rows = [statsHeaderFields()] + statsRows(summary: summary)
        let text = rows
            .map { $0.map(Self.csvField).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
        data.append(contentsOf: text.utf8)
        return data
    }

    private func statsXLSXData(summary: DurianSurveySummary) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        let rows = [statsHeaderFields()] + statsRows(summary: summary)
        let text = rows
            .map { $0.map(Self.tsvField).joined(separator: "\t") }
            .joined(separator: "\n") + "\n"
        data.append(contentsOf: text.utf8)
        return data
    }

    private func statsJSONData(summary: DurianSurveySummary) throws -> Data {
        let payload: [String: Any] = [
            "total_forms": summary.totalCount,
            "gps_forms": summary.gpsCount,
            "average_answered_percent": Self.percentValue(summary.averageAnsweredPercent),
            "questions": summary.questions.map { questionSummary in
                [
                    "question_id": questionSummary.question.id,
                    "question": questionSummary.question.text,
                    "type": questionType(questionSummary.question),
                    "total_forms": questionSummary.totalCount,
                    "answered_forms": questionSummary.answeredCount,
                    "blank_forms": questionSummary.blankCount,
                    "answers": questionSummary.answerStats.map { answer in
                        [
                            "answer": answer.answer,
                            "count": answer.count,
                            "percent_of_total": Self.percentValue(answer.percentOfTotal),
                            "percent_of_answered": Self.percentValue(answer.percentOfAnswered)
                        ] as [String: Any]
                    }
                ] as [String: Any]
            }
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private func questionType(_ question: DurianSurveyQuestion) -> String {
        switch question.kind {
        case .text:
            return "text"
        case .yesNo:
            return "yes_no"
        case .choice:
            return "choice"
        }
    }

    private func jsonFilename(for record: DurianSurveyRecord) -> String {
        let code = record.answers["A1"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let safeCode = SampleContextStore.folderSafeSampleID(code.isEmpty ? "survey" : code)
        let timestamp = record.createdAt
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "Z", with: "")
        return "\(safeCode)_survey_\(timestamp).json"
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func fileTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }

    private static func number(_ value: Double?, digits: Int) -> String {
        guard let value = value else { return "" }
        return String(format: "%.\(digits)f", value)
    }

    private static func percent(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "0.0" }
        return String(format: "%.1f", Double(value) * 100 / Double(total))
    }

    private static func percentValue(_ value: Double) -> Double {
        (value * 1000).rounded() / 10
    }

    private static func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func tsvField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

private final class SurveyAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var consentGiven = false
    @Published var isRecording = false
    @Published var audioURL: URL?
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?

    var audioFileName: String? {
        audioURL?.lastPathComponent
    }

    var relativeAudioPath: String? {
        DurianSurveyStore.shared.relativeAudioPath(for: audioURL)
    }

    func start(sampleCode: String) {
        guard consentGiven else {
            errorMessage = "Cần xác nhận đã xin phép ghi âm."
            return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard allowed else {
                    self.errorMessage = "Chưa được cấp quyền microphone."
                    return
                }

                do {
                    try self.startNow(sampleCode: sampleCode)
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func reset(deleteFile: Bool) {
        stop()
        if deleteFile, let audioURL = audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        audioURL = nil
        errorMessage = nil
        consentGiven = false
    }

    func clearSavedReference() {
        audioURL = nil
        errorMessage = nil
        consentGiven = false
    }

    private func startNow(sampleCode: String) throws {
        let url = try DurianSurveyStore.shared.newAudioURL(sampleCode: sampleCode.trimmingCharacters(in: .whitespacesAndNewlines))
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.prepareToRecord()
        recorder.record()
        self.recorder = recorder
        audioURL = url
        isRecording = true
        errorMessage = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isRecording = false
            if !flag {
                self.errorMessage = "Ghi âm chưa hoàn tất."
            }
        }
    }
}

private final class SurveyAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?

    func toggle(url: URL) {
        if isPlaying {
            stop()
        } else {
            play(url: url)
        }
    }

    func play(url: URL) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Không tìm thấy file ghi âm."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            isPlaying = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

private struct DurianSurveyView: View {
    @State private var answers: [String: String] = [:]
    @State private var currentLocation: CLLocation?
    @State private var savedFilename: String?
    @State private var saveError: String?
    @State private var savedRecords: [DurianSurveyRecord] = []
    @State private var summary = DurianSurveyStats.make(records: [])
    @StateObject private var audioRecorder = SurveyAudioRecorder()
    @StateObject private var audioPlayer = SurveyAudioPlayer()

    var body: some View {
        Form {
            dashboardSection
            gpsSection
            audioSection

            ForEach(durianSurveySections) { section in
                Section(header: Text(section.title)) {
                    ForEach(section.questions) { question in
                        DurianSurveyQuestionField(
                            question: question,
                            answer: binding(for: question.id)
                        )
                    }
                }
            }

            Section {
                Button(action: saveSurvey) {
                    HStack {
                        Image(systemName: "tray.and.arrow.down")
                        Text("Lưu phiếu offline")
                    }
                }
                .accessibilityIdentifier("durianSurvey.save")

                if let savedFilename = savedFilename {
                    Text("Đã lưu: \(savedFilename)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Phiếu đã lưu")) {
                if savedRecords.isEmpty {
                    Text("Chưa có phiếu đã lưu.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(savedRecords) { record in
                        NavigationLink(destination: DurianSurveyRecordDetailView(record: record)) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(recordTitle(record))
                                        .font(.body)
                                    if record.audioFile != nil {
                                        Image(systemName: "mic.fill")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                }
                                Text(record.createdAt)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationBarTitle("Bảng hỏi vườn", displayMode: .inline)
        .navigationBarItems(trailing: Button("Mới") {
            answers = [:]
            savedFilename = nil
            audioPlayer.stop()
            audioRecorder.reset(deleteFile: true)
            refreshLocation()
        })
        .onAppear {
            LocationMetadataManager.shared.start()
            refreshLocation()
            loadSavedRecords()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                refreshLocation()
            }
        }
        .onDisappear {
            audioPlayer.stop()
            audioRecorder.stop()
            LocationMetadataManager.shared.stop()
        }
        .alert("Không lưu được phiếu", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var dashboardSection: some View {
        Section {
            NavigationLink(destination: DurianSurveyDashboardView()) {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundColor(.orange)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dashboard tổng hợp")
                            .font(.body)
                        Text("\(summary.totalCount) phiếu · \(summary.gpsCount) có GPS · \(Self.percentText(summary.averageAnsweredPercent)) đã trả lời")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var gpsSection: some View {
        Section(header: Text("A5. Tọa độ GPS")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(gpsText)
                    .font(.body)
                    .foregroundColor(Color("TextColor"))
                Button(action: updateLocation) {
                    HStack {
                        Image(systemName: "location")
                        Text("Cập nhật location")
                    }
                }
                .accessibilityIdentifier("durianSurvey.refreshGPS")
            }
            .padding(.vertical, 4)
        }
    }

    private var audioSection: some View {
        Section(header: Text("Ghi âm phỏng vấn")) {
            Toggle("Đã xin phép ghi âm", isOn: $audioRecorder.consentGiven)

            Button(action: toggleAudioRecording) {
                HStack {
                    Image(systemName: audioRecorder.isRecording ? "stop.circle" : "mic.circle")
                    Text(audioRecorder.isRecording ? "Dừng ghi âm" : "Ghi âm")
                }
            }
            .disabled(!audioRecorder.consentGiven)
            .foregroundColor(audioRecorder.isRecording ? Color("DangerColor") : .blue)
            .accessibilityIdentifier("durianSurvey.audioRecord")

            if let audioFileName = audioRecorder.audioFileName {
                Text("Audio: \(audioFileName)")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button(action: toggleAudioPlayback) {
                    HStack {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle" : "play.circle")
                        Text(audioPlayer.isPlaying ? "Dừng nghe" : "Nghe lại ghi âm")
                    }
                }
                .disabled(audioRecorder.isRecording)
                .accessibilityIdentifier("durianSurvey.audioPlayback")
            }

            if let errorMessage = audioRecorder.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(Color("DangerColor"))
            }
            if let errorMessage = audioPlayer.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(Color("DangerColor"))
            }
        }
    }

    private var gpsText: String {
        guard let location = currentLocation else {
            return "Chưa có GPS"
        }
        return String(
            format: "Lat %.8f, Long %.8f, ±%.1f m",
            location.coordinate.latitude,
            location.coordinate.longitude,
            max(location.horizontalAccuracy, 0)
        )
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { answers[id, default: ""] },
            set: { answers[id] = $0 }
        )
    }

    private func refreshLocation() {
        currentLocation = LocationMetadataManager.shared.currentLocation
    }

    private func updateLocation() {
        LocationMetadataManager.shared.start()
        refreshLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshLocation()
        }
    }

    private func toggleAudioRecording() {
        if audioRecorder.isRecording {
            audioRecorder.stop()
        } else {
            audioPlayer.stop()
            audioRecorder.start(sampleCode: answers["A1"] ?? "")
        }
    }

    private func toggleAudioPlayback() {
        guard let url = audioRecorder.audioURL else { return }
        audioPlayer.toggle(url: url)
    }

    private func saveSurvey() {
        refreshLocation()
        if audioRecorder.isRecording {
            audioRecorder.stop()
        }
        audioPlayer.stop()
        do {
            let url = try DurianSurveyStore.shared.save(
                answers: answers,
                location: currentLocation,
                placeName: LocationMetadataManager.shared.currentPlaceName,
                audioConsent: audioRecorder.consentGiven,
                audioFile: audioRecorder.relativeAudioPath
            )
            savedFilename = url.lastPathComponent
            audioRecorder.clearSavedReference()
            loadSavedRecords()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func loadSavedRecords() {
        let records = DurianSurveyStore.shared.savedRecords()
        savedRecords = records
        summary = DurianSurveyStats.make(records: records)
        try? DurianSurveyStore.shared.prepareExportFiles()
    }

    private func recordTitle(_ record: DurianSurveyRecord) -> String {
        let code = record.answers["A1"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let owner = record.answers["A2"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = [code, owner].filter { !$0.isEmpty }.joined(separator: " - ")
        return title.isEmpty ? "Phiếu khảo sát" : title
    }

    private static func percentText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

private struct DurianSurveyQuestionField: View {
    let question: DurianSurveyQuestion
    @Binding var answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(question.id). \(question.text)")
                .font(.body)
                .foregroundColor(Color("TextColor"))

            switch question.kind {
            case .text:
                TextField("Nhập câu trả lời", text: $answer)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            case .yesNo:
                HStack(spacing: 8) {
                    yesNoButton("Có")
                    yesNoButton("Không")
                }
            case .choice(let options):
                Picker("Chọn", selection: $answer) {
                    Text("Chưa chọn").tag("")
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func yesNoButton(_ value: String) -> some View {
        let isSelected = answer == value
        return Button(action: {
            answer = isSelected ? "" : value
        }) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                Text(value)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .foregroundColor(isSelected ? .blue : Color("TextColor"))
            .background(isSelected ? Color.blue.opacity(0.12) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("durianSurvey.\(question.id).\(value)")
    }
}

private struct DurianSurveyDashboardView: View {
    @State private var summary = DurianSurveyStats.make(records: [])

    var body: some View {
        Form {
            Section(header: Text("Tổng quan")) {
                SurveyMetricRow(title: "Số phiếu", value: "\(summary.totalCount)")
                SurveyMetricRow(title: "Phiếu có GPS", value: "\(summary.gpsCount)")
                SurveyMetricRow(title: "Tỷ lệ trả lời trung bình", value: percentText(summary.averageAnsweredPercent))
            }

            if summary.totalCount == 0 {
                Section {
                    Text("Chưa có phiếu khảo sát để tổng hợp.")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(summary.questions) { questionSummary in
                    DurianSurveyQuestionSummarySection(summary: questionSummary)
                }
            }
        }
        .navigationBarTitle("Dashboard bảng hỏi", displayMode: .inline)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        try? DurianSurveyStore.shared.prepareExportFiles()
        summary = DurianSurveyStore.shared.summary()
    }
}

private struct DurianSurveyQuestionSummarySection: View {
    let summary: DurianSurveyQuestionSummary

    var body: some View {
        Section(header: Text("\(summary.question.id). \(summary.question.text)")) {
            HStack {
                SurveyMetricRow(title: "Đã trả lời", value: "\(summary.answeredCount)")
                Spacer()
                SurveyMetricRow(title: "Chưa nhập", value: "\(summary.blankCount)")
            }

            if summary.answerStats.isEmpty {
                Text("Chưa có câu trả lời.")
                    .foregroundColor(.secondary)
            } else {
                if showsPieChart {
                    SurveyPieChart(stats: displayStats)
                        .padding(.vertical, 6)
                }
                ForEach(displayStats) { answer in
                    SurveyAnswerStatRow(answer: answer, color: color(for: answer))
                }
                if hiddenAnswerCount > 0 {
                    Text("Còn \(hiddenAnswerCount) câu trả lời trong file thống kê.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var displayStats: [DurianSurveyAnswerSummary] {
        switch summary.question.kind {
        case .text:
            return Array(summary.answerStats.prefix(10))
        case .yesNo, .choice:
            return summary.answerStats
        }
    }

    private var showsPieChart: Bool {
        guard summary.answeredCount > 0 else { return false }
        switch summary.question.kind {
        case .yesNo, .choice:
            return true
        case .text:
            return false
        }
    }

    private var hiddenAnswerCount: Int {
        max(summary.answerStats.count - displayStats.count, 0)
    }

    private func color(for answer: DurianSurveyAnswerSummary) -> Color {
        let index = displayStats.firstIndex { $0.id == answer.id } ?? 0
        return SurveyChartPalette.color(at: index)
    }
}

private struct SurveyAnswerStatRow: View {
    let answer: DurianSurveyAnswerSummary
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(answer.answer)
                    .font(.body)
                    .foregroundColor(Color("TextColor"))
                    .lineLimit(2)
                Spacer()
                Text("\(answer.count) · \(percentText(answer.percentOfAnswered))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            SurveyPercentBar(value: answer.percentOfAnswered, color: color)
        }
        .padding(.vertical, 4)
    }
}

private struct SurveyPercentBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 8)
    }
}

private struct SurveyPieChart: View {
    let stats: [DurianSurveyAnswerSummary]

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                if segments.isEmpty {
                    Circle()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 10)
                } else {
                    ForEach(segments) { segment in
                        SurveyPieSlice(startAngle: segment.startAngle, endAngle: segment.endAngle)
                            .fill(segment.color)
                    }
                }
            }
            .frame(width: 112, height: 112)
            .accessibilityLabel("Pie chart")

            VStack(alignment: .leading, spacing: 8) {
                ForEach(legendItems) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.color)
                            .frame(width: 10, height: 10)
                        Text(item.title)
                            .font(.caption)
                            .foregroundColor(Color("TextColor"))
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        Text("\(item.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var segments: [SurveyPieSegment] {
        let total = stats.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }

        var cursor = -90.0
        return stats.enumerated().compactMap { index, stat in
            guard stat.count > 0 else { return nil }
            let sweep = Double(stat.count) / Double(total) * 360.0
            let segment = SurveyPieSegment(
                id: stat.id,
                startAngle: Angle(degrees: cursor),
                endAngle: Angle(degrees: cursor + sweep),
                color: SurveyChartPalette.color(at: index)
            )
            cursor += sweep
            return segment
        }
    }

    private var legendItems: [SurveyPieLegendItem] {
        stats.enumerated().map { index, stat in
            SurveyPieLegendItem(
                id: stat.id,
                title: stat.answer,
                count: stat.count,
                color: SurveyChartPalette.color(at: index)
            )
        }
    }
}

private struct SurveyPieSegment: Identifiable {
    let id: String
    let startAngle: Angle
    let endAngle: Angle
    let color: Color
}

private struct SurveyPieLegendItem: Identifiable {
    let id: String
    let title: String
    let count: Int
    let color: Color
}

private struct SurveyPieSlice: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private enum SurveyChartPalette {
    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }

    private static let colors: [Color] = [
        .orange,
        .blue,
        .green,
        .purple,
        .red,
        .yellow,
        .gray
    ]
}

private struct SurveyMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundColor(Color("TextColor"))
                .monospacedDigit()
        }
    }
}

private struct DurianSurveyRecordDetailView: View {
    let record: DurianSurveyRecord
    @StateObject private var audioPlayer = SurveyAudioPlayer()

    var body: some View {
        Form {
            Section(header: Text("Thông tin")) {
                SurveyValueRow(title: "Thời gian lưu", value: record.createdAt)
                SurveyValueRow(title: "GPS", value: gpsText)
                SurveyValueRow(title: "Tên địa điểm", value: record.placeName ?? "")
                SurveyValueRow(title: "Xin phép ghi âm", value: (record.audioConsent ?? false) ? "Có" : "Không")
                SurveyValueRow(title: "File ghi âm", value: record.audioFile ?? "")
                if let audioURL = audioURL {
                    Button(action: { audioPlayer.toggle(url: audioURL) }) {
                        HStack {
                            Image(systemName: audioPlayer.isPlaying ? "pause.circle" : "play.circle")
                            Text(audioPlayer.isPlaying ? "Dừng nghe" : "Nghe lại ghi âm")
                        }
                    }
                    .accessibilityIdentifier("durianSurvey.savedAudioPlayback")
                }
                if let errorMessage = audioPlayer.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(Color("DangerColor"))
                }
            }

            ForEach(durianSurveySections) { section in
                Section(header: Text(section.title)) {
                    ForEach(section.questions) { question in
                        SurveyValueRow(
                            title: "\(question.id). \(question.text)",
                            value: record.answers[question.id] ?? ""
                        )
                    }
                }
            }
        }
        .navigationBarTitle("Chi tiết phiếu", displayMode: .inline)
        .onDisappear {
            audioPlayer.stop()
        }
    }

    private var audioURL: URL? {
        DurianSurveyStore.shared.audioURL(for: record.audioFile)
    }

    private var gpsText: String {
        guard let latitude = record.latitude, let longitude = record.longitude else {
            return ""
        }
        let accuracy = record.gpsAccuracyM.map { String(format: ", ±%.1f m", $0) } ?? ""
        return String(format: "%.8f, %.8f", latitude, longitude) + accuracy
    }
}

private func percentText(_ value: Double) -> String {
    String(format: "%.0f%%", value * 100)
}

private struct SurveyValueRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Chưa nhập" : value)
                .font(.body)
                .foregroundColor(Color("TextColor"))
        }
        .padding(.vertical, 2)
    }
}

struct SessionList_Previews: PreviewProvider {
    static var previews: some View {
        SessionList()
    }
}
