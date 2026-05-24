//
//  SampleSession.swift
//  StrayScanner
//

import SwiftUI
import AVFoundation

private struct SamplePhotoListItem: Identifiable {
    let url: URL

    var id: String { url.lastPathComponent }
    var filename: String { url.lastPathComponent }
}

private enum SamplePhotoListMode: String, CaseIterable, Identifiable, Hashable {
    case active
    case deleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active:
            return "Ảnh mẫu"
        case .deleted:
            return "Đã xoá gần đây"
        }
    }

    var emptyText: String {
        switch self {
        case .active:
            return "Chưa có ảnh mẫu."
        case .deleted:
            return "Chưa có ảnh đã xoá."
        }
    }
}

private enum SamplePhotoListAlert: Identifiable {
    case confirmDelete(SamplePhotoListItem)
    case confirmPermanentDelete(SamplePhotoListItem)
    case operationError(String)

    var id: String {
        switch self {
        case .confirmDelete(let item):
            return "confirm-delete-\(item.id)"
        case .confirmPermanentDelete(let item):
            return "confirm-permanent-delete-\(item.id)"
        case .operationError:
            return "operation-error"
        }
    }
}

private enum SamplePhotoListSheet: Identifiable {
    case preview(SamplePhotoListItem)
    case lidarRecovery

    var id: String {
        switch self {
        case .preview(let item):
            return "preview-\(item.id)"
        case .lidarRecovery:
            return "lidar-recovery"
        }
    }
}

private struct SamplePhotoThumbnail: View {
    let url: URL

    var body: some View {
        ZStack {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundColor(Color("TextColor"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.12))
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct SamplePhotoPreviewView: View {
    let item: SamplePhotoListItem
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(item.filename)
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()

                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .accessibilityIdentifier("samplePhotoPreview.close")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.85))

                if let image = UIImage(contentsOfFile: item.url.path) {
                    GeometryReader { proxy in
                        ScrollView([.horizontal, .vertical], showsIndicators: true) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                } else {
                    Spacer()
                    Text("Không mở được ảnh.")
                        .foregroundColor(.white)
                        .font(.body)
                    Spacer()
                }
            }
        }
    }
}

private final class SamplePhotoListViewModel: ObservableObject {
    @Published var items: [SamplePhotoListItem] = []
    @Published var recentlyDeletedItems: [SamplePhotoListItem] = []

    func load() {
        items = SampleLogger.shared.sampleImageFiles().map { SamplePhotoListItem(url: $0) }
        recentlyDeletedItems = SampleLogger.shared.recentlyDeletedSampleImageFiles().map { SamplePhotoListItem(url: $0) }
    }

    func delete(_ item: SamplePhotoListItem) -> String? {
        do {
            try SampleLogger.shared.deleteSamplePhoto(filename: item.filename)
            load()
            return nil
        } catch {
            return "Không thể xoá ảnh \(item.filename): \(error.localizedDescription)"
        }
    }

    func restore(_ item: SamplePhotoListItem) -> String? {
        do {
            try SampleLogger.shared.restoreSamplePhoto(filename: item.filename)
            load()
            return nil
        } catch {
            return "Không thể khôi phục ảnh \(item.filename): \(error.localizedDescription)"
        }
    }

    func permanentlyDelete(_ item: SamplePhotoListItem) -> String? {
        do {
            try SampleLogger.shared.permanentlyDeleteSamplePhoto(filename: item.filename)
            load()
            return nil
        } catch {
            return "Không thể xoá vĩnh viễn ảnh \(item.filename): \(error.localizedDescription)"
        }
    }
}

private final class LidarSampleRecoveryListViewModel: ObservableObject {
    @Published var candidates: [LidarSampleRecoveryCandidate] = []

    func load() {
        candidates = SampleLogger.shared.lidarSampleRecoveryCandidates()
    }
}

private struct LidarSampleRecoveryListView: View {
    @StateObject private var viewModel = LidarSampleRecoveryListViewModel()
    @Environment(\.presentationMode) private var presentationMode
    let onRecovered: (String) -> Void

    var body: some View {
        NavigationView {
            Group {
                if viewModel.candidates.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Không tìm thấy data LiDAR có thể khôi phục.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundColor(Color("TextColor"))
                            .padding(.horizontal, 32)
                    }
                } else {
                    List {
                        ForEach(viewModel.candidates) { candidate in
                            NavigationLink(
                                destination: LidarFramePickerView(candidate: candidate) { filename in
                                    onRecovered(filename)
                                    presentationMode.wrappedValue.dismiss()
                                }
                            ) {
                                LidarSampleRecoveryRow(candidate: candidate)
                            }
                        }
                    }
                }
            }
            .navigationBarTitle("Khôi phục từ LiDAR", displayMode: .inline)
            .navigationBarItems(leading: Button("Đóng") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear {
                viewModel.load()
            }
        }
    }
}

private struct LidarSampleRecoveryRow: View {
    let candidate: LidarSampleRecoveryCandidate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "video")
                .foregroundColor(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(candidate.sampleID)
                        .font(.headline)
                        .foregroundColor(Color("TextColor"))
                    if candidate.isImportant {
                        Text("*")
                            .font(.headline)
                            .foregroundColor(.yellow)
                    }
                }

                Text(candidate.datasetFolder)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if !candidate.loaiMau.isEmpty || !candidate.site.isEmpty {
                    Text([candidate.loaiMau, candidate.site].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private final class LidarFramePickerViewModel: ObservableObject {
    let candidate: LidarSampleRecoveryCandidate
    @Published var image: UIImage?
    @Published var selectedTime: Double
    @Published var duration: Double
    @Published var loadedFrameTime: Double?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let asset: AVAsset
    private let generator: AVAssetImageGenerator
    private let queue = DispatchQueue(label: "lidarFramePickerQueue", qos: .userInitiated)
    private var requestID = 0
    private let frameRate: Double

    init(candidate: LidarSampleRecoveryCandidate) {
        let asset = AVAsset(url: candidate.videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        let seconds = CMTimeGetSeconds(asset.duration)
        let validDuration = seconds.isFinite && seconds > 0 ? seconds : 0
        let nominalFrameRate = asset.tracks(withMediaType: .video).first?.nominalFrameRate ?? 0
        let resolvedFrameRate = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        let resolvedFrameStep = 1 / max(resolvedFrameRate, 1)
        let initialUpperBound = validDuration > resolvedFrameStep ? validDuration - resolvedFrameStep : validDuration

        self.candidate = candidate
        self.asset = asset
        self.generator = generator
        self.duration = validDuration
        self.selectedTime = initialUpperBound > 0 ? initialUpperBound / 2 : 0
        self.frameRate = resolvedFrameRate

        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: resolvedFrameStep / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
    }

    var sliderUpperBound: Double {
        max(maxSeekTime, 0.01)
    }

    var frameStep: Double {
        1 / max(frameRate, 1)
    }

    var recoveryTime: Double {
        loadedFrameTime ?? selectedTime
    }

    var selectedFrameText: String {
        let frame = max(0, Int((recoveryTime * frameRate).rounded()))
        let total = max(frame, Int((maxSeekTime * frameRate).rounded()))
        return "Frame \(frame) / \(total)"
    }

    var selectedTimeText: String {
        "\(formatTime(recoveryTime)) / \(formatTime(duration))"
    }

    func loadInitialFrame() {
        guard image == nil else { return }
        loadFrame(at: selectedTime)
    }

    func loadFrame(at time: Double) {
        let clamped = min(max(time, 0), maxSeekTime)
        selectedTime = clamped
        loadedFrameTime = nil
        image = nil
        requestID += 1
        let currentRequestID = requestID
        isLoading = true

        queue.async { [weak self] in
            guard let self = self else { return }
            guard currentRequestID == self.requestID else { return }
            do {
                let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
                var actualTime = CMTime.invalid
                let cgImage = try self.generator.copyCGImage(at: cmTime, actualTime: &actualTime)
                let image = UIImage(cgImage: cgImage)
                let actualSeconds = CMTimeGetSeconds(actualTime)
                let loadedTime = actualSeconds.isFinite ? min(max(actualSeconds, 0), self.maxSeekTime) : clamped
                DispatchQueue.main.async {
                    guard currentRequestID == self.requestID else { return }
                    self.image = image
                    self.loadedFrameTime = loadedTime
                    self.selectedTime = loadedTime
                    self.isLoading = false
                    self.errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard currentRequestID == self.requestID else { return }
                    self.isLoading = false
                    self.errorMessage = "Không đọc được frame tại \(self.formatTime(clamped)): \(error.localizedDescription)"
                }
            }
        }
    }

    func stepFrame(_ direction: Int) {
        loadFrame(at: selectedTime + Double(direction) * frameStep)
    }

    private var maxSeekTime: Double {
        guard duration > 0 else { return 0 }
        return duration > frameStep ? duration - frameStep : duration
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "00:00.00" }
        let minutes = Int(seconds) / 60
        let wholeSeconds = Int(seconds) % 60
        let centiseconds = Int((seconds - floor(seconds)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, wholeSeconds, centiseconds)
    }
}

private struct LidarFramePickerView: View {
    @StateObject private var viewModel: LidarFramePickerViewModel
    @State private var alertMessage: String?
    let onRecovered: (String) -> Void

    init(candidate: LidarSampleRecoveryCandidate, onRecovered: @escaping (String) -> Void) {
        _viewModel = StateObject(wrappedValue: LidarFramePickerViewModel(candidate: candidate))
        self.onRecovered = onRecovered
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Color.black
                if let image = viewModel.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if viewModel.isLoading {
                    ProgressView()
                } else {
                    Text("Chưa có frame")
                        .foregroundColor(.white)
                        .font(.body)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)

            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.candidate.sampleID + (viewModel.candidate.isImportant ? " *" : ""))
                    .font(.headline)
                    .foregroundColor(Color("TextColor"))

                Text(viewModel.candidate.datasetFolder)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if !viewModel.candidate.loaiMau.isEmpty || !viewModel.candidate.site.isEmpty {
                    Text([viewModel.candidate.loaiMau, viewModel.candidate.site].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { viewModel.selectedTime },
                        set: { viewModel.loadFrame(at: $0) }
                    ),
                    in: 0...viewModel.sliderUpperBound
                )

                HStack {
                    Text(viewModel.selectedTimeText)
                    Spacer()
                    Text(viewModel.selectedFrameText)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Button(action: { viewModel.stepFrame(-1) }) {
                        Image(systemName: "backward.fill")
                            .frame(width: 44, height: 36)
                    }
                    .buttonStyle(.borderless)

                    Button(action: { viewModel.stepFrame(1) }) {
                        Image(systemName: "forward.fill")
                            .frame(width: 44, height: 36)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(Color("DangerColor"))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: recoverSelectedFrame) {
                HStack {
                    Image(systemName: "arrow.down.doc")
                    Text("Khôi phục ảnh này")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(viewModel.image == nil ? Color.gray : Color.green)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(viewModel.image == nil)

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color("BackgroundColor").edgesIgnoringSafeArea(.all))
        .navigationBarTitle("Chọn frame", displayMode: .inline)
        .onAppear {
            viewModel.loadInitialFrame()
        }
        .alert(item: Binding(
            get: { alertMessage.map { SamplePhotoTextAlert(message: $0) } },
            set: { if $0 == nil { alertMessage = nil } }
        )) { alert in
            Alert(
                title: Text("Khôi phục lỗi"),
                message: Text(alert.message),
                dismissButton: .cancel(Text("OK")) {
                    alertMessage = nil
                }
            )
        }
    }

    private func recoverSelectedFrame() {
        guard let image = viewModel.image,
              let data = image.jpegData(compressionQuality: 0.94)
        else {
            alertMessage = "Không có frame để khôi phục."
            return
        }

        do {
            let filename = try SampleLogger.shared.recoverSamplePhotoFromLidar(
                candidate: viewModel.candidate,
                imageData: data,
                selectedTime: viewModel.recoveryTime
            )
            onRecovered(filename)
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

private struct SamplePhotoTextAlert: Identifiable {
    let id = UUID()
    let message: String
}

struct SamplePhotoManager: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>

    func makeUIViewController(context: Context) -> SamplePhotoViewController {
        let vc = SamplePhotoViewController()
        vc.dismissFunction = { presentationMode.wrappedValue.dismiss() }
        return vc
    }

    func updateUIViewController(_ uiViewController: SamplePhotoViewController, context: Context) {}
}

struct SampleSessionView: View {
    var body: some View {
        SamplePhotoManager()
            .navigationBarTitle("Chụp ảnh mẫu", displayMode: .inline)
            .edgesIgnoringSafeArea(.all)
            .background(NavigationConfigurator { nc in
                nc.navigationBar.barTintColor = UIColor(named: "BackgroundColor")
            })
    }
}

struct SamplePhotoListView: View {
    @StateObject private var viewModel = SamplePhotoListViewModel()
    @State private var selectedMode: SamplePhotoListMode = .active
    @State private var activeAlert: SamplePhotoListAlert?
    @State private var activeSheet: SamplePhotoListSheet?

    private var visibleItems: [SamplePhotoListItem] {
        switch selectedMode {
        case .active:
            return viewModel.items
        case .deleted:
            return viewModel.recentlyDeletedItems
        }
    }

    var body: some View {
        ZStack {
            Color("BackgroundColor")
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                Picker("", selection: $selectedMode) {
                    ForEach(SamplePhotoListMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                if visibleItems.isEmpty {
                    Spacer()
                    Text(selectedMode.emptyText)
                        .font(.body)
                        .foregroundColor(Color("TextColor"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                } else {
                    List {
                        ForEach(visibleItems) { item in
                            row(for: item)
                        }
                        .onDelete { indexSet in
                            handleSwipeDelete(indexSet)
                        }
                    }
                }
            }
        }
        .navigationBarTitle("Ảnh mẫu đã chụp", displayMode: .inline)
        .navigationBarItems(trailing: Button(action: {
            activeSheet = .lidarRecovery
        }) {
            HStack(spacing: 4) {
                Image(systemName: "video")
                Text("LiDAR")
            }
        })
        .onAppear {
            viewModel.load()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .preview(let item):
                SamplePhotoPreviewView(item: item)
            case .lidarRecovery:
                LidarSampleRecoveryListView { _ in
                    viewModel.load()
                    selectedMode = .active
                    activeSheet = nil
                }
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .confirmDelete(let item):
                return Alert(
                    title: Text("Xoá ảnh mẫu?"),
                    message: Text("Ảnh \(item.filename) sẽ được chuyển vào Đã xoá gần đây và có thể khôi phục sau."),
                    primaryButton: .destructive(Text("Xoá")) {
                        deleteAndReport(item)
                    },
                    secondaryButton: .cancel(Text("Huỷ")) {
                        activeAlert = nil
                    }
                )
            case .confirmPermanentDelete(let item):
                return Alert(
                    title: Text("Xoá vĩnh viễn?"),
                    message: Text("Ảnh \(item.filename) và log phục hồi sẽ bị xoá vĩnh viễn."),
                    primaryButton: .destructive(Text("Xoá vĩnh viễn")) {
                        permanentlyDeleteAndReport(item)
                    },
                    secondaryButton: .cancel(Text("Huỷ")) {
                        activeAlert = nil
                    }
                )
            case .operationError(let message):
                return Alert(
                    title: Text("Thao tác lỗi"),
                    message: Text(message),
                    dismissButton: .cancel(Text("OK")) {
                        activeAlert = nil
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func row(for item: SamplePhotoListItem) -> some View {
        HStack(spacing: 12) {
            Button(action: {
                activeSheet = .preview(item)
            }) {
                HStack(spacing: 12) {
                    SamplePhotoThumbnail(url: item.url)

                    Text(item.filename)
                        .font(.footnote)
                        .foregroundColor(Color("TextColor"))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("samplePhotoList.preview.\(item.filename)")

            Spacer()

            if selectedMode == .active {
                Button(action: {
                    activeAlert = .confirmDelete(item)
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(Color("DangerColor"))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("samplePhotoList.delete.\(item.filename)")
            } else {
                Button(action: {
                    restoreAndReport(item)
                }) {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundColor(.green)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("samplePhotoList.restore.\(item.filename)")

                Button(action: {
                    activeAlert = .confirmPermanentDelete(item)
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(Color("DangerColor"))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("samplePhotoList.permanentlyDelete.\(item.filename)")
            }
        }
        .padding(.vertical, 6)
    }

    private func handleSwipeDelete(_ indexSet: IndexSet) {
        guard let item = indexSet.compactMap({ visibleItems[safe: $0] }).first else { return }
        switch selectedMode {
        case .active:
            activeAlert = .confirmDelete(item)
        case .deleted:
            activeAlert = .confirmPermanentDelete(item)
        }
    }

    private func deleteAndReport(_ item: SamplePhotoListItem) {
        if let errorMessage = viewModel.delete(item) {
            activeAlert = nil
            DispatchQueue.main.async {
                activeAlert = .operationError(errorMessage)
            }
        } else {
            activeAlert = nil
        }
    }

    private func restoreAndReport(_ item: SamplePhotoListItem) {
        if let errorMessage = viewModel.restore(item) {
            activeAlert = .operationError(errorMessage)
        }
    }

    private func permanentlyDeleteAndReport(_ item: SamplePhotoListItem) {
        if let errorMessage = viewModel.permanentlyDelete(item) {
            activeAlert = nil
            DispatchQueue.main.async {
                activeAlert = .operationError(errorMessage)
            }
        } else {
            activeAlert = nil
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
