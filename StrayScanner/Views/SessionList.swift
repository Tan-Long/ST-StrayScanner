//
//  SessionList.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/15/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI
import CoreData

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
            let fetched: [NSManagedObject] = try dataContext?.fetch(request) ?? []
            sessions = fetched.map { session in
                return session as! Recording
            }

        } catch let error as NSError {
            print("Something went wrong. Error: \(error), \(error.userInfo)")
        }
    }

    @objc func sessionsChanged() {
        fetchSessions()
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
                        ForEach(Array(viewModel.sessions.enumerated()), id: \.element) { i, recording in
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
                            Text(isCreatingFullExport ? "Đang nén..." : "Xuất ZIP toàn bộ")
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
                    Button(action: {
                        showingResetConfirm = true
                    }, label: {
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
