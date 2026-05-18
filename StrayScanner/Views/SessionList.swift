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
        if name == "samples" || name.hasPrefix("cay_") || name.hasSuffix(".zip") {
            return true
        }
        return fileManager.fileExists(atPath: url.appendingPathComponent("rgb.mp4").path)
    }

}

struct SessionList: View {
    @ObservedObject var viewModel = SessionListViewModel()
    @State private var showingInfo = false
    @State private var showingResetConfirm = false
    @State private var showingShareSheet = false
    @State private var fullExportURL: URL?
    @State private var isCreatingFullExport = false
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
            Button("Huỷ", role: .cancel) {}
            Button("Xoá hết", role: .destructive) {
                viewModel.resetAllData()
            }
        } message: {
            Text("Thao tác này xoá toàn bộ video folders, ảnh sample, file data export và danh sách recording trong app. Không thể hoàn tác.")
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

    private func exportAllData() {
        isCreatingFullExport = true
        Task {
            do {
                let url = try await ShareUtility.createFullDataArchive()
                await MainActor.run {
                    fullExportURL = url
                    isCreatingFullExport = false
                    showingShareSheet = true
                }
            } catch {
                await MainActor.run {
                    isCreatingFullExport = false
                    exportError = error.localizedDescription
                }
            }
        }
    }
}

struct SessionList_Previews: PreviewProvider {
    static var previews: some View {
        SessionList()
    }
}
