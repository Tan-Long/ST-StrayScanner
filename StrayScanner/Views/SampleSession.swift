//
//  SampleSession.swift
//  StrayScanner
//

import SwiftUI

private struct SamplePhotoListItem: Identifiable {
    let url: URL

    var id: String { url.lastPathComponent }
    var filename: String { url.lastPathComponent }
}

private final class SamplePhotoListViewModel: ObservableObject {
    @Published var items: [SamplePhotoListItem] = []
    @Published var deleteError: String?

    func load() {
        items = SampleLogger.shared.sampleImageFiles().map { SamplePhotoListItem(url: $0) }
    }

    func delete(_ item: SamplePhotoListItem) {
        do {
            try SampleLogger.shared.deleteSamplePhoto(filename: item.filename)
            load()
        } catch {
            deleteError = "Không thể xoá ảnh \(item.filename): \(error.localizedDescription)"
        }
    }
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

    var body: some View {
        ZStack {
            Color("BackgroundColor")
                .edgesIgnoringSafeArea(.all)

            if viewModel.items.isEmpty {
                Text("Chưa có ảnh mẫu.")
                    .font(.body)
                    .foregroundColor(Color("TextColor"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                List {
                    ForEach(viewModel.items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "photo")
                                .foregroundColor(Color("TextColor"))

                            Text(item.filename)
                                .font(.footnote)
                                .foregroundColor(Color("TextColor"))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Spacer()

                            Button(action: {
                                viewModel.delete(item)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(Color("DangerColor"))
                            }
                            .accessibilityIdentifier("samplePhotoList.delete.\(item.filename)")
                        }
                        .padding(.vertical, 6)
                    }
                    .onDelete { indexSet in
                        indexSet.map { viewModel.items[$0] }.forEach(viewModel.delete)
                    }
                }
            }
        }
        .navigationBarTitle("Ảnh mẫu đã chụp", displayMode: .inline)
        .onAppear {
            viewModel.load()
        }
        .alert("Xoá ảnh lỗi", isPresented: Binding(
            get: { viewModel.deleteError != nil },
            set: { if !$0 { viewModel.deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.deleteError = nil }
        } message: {
            Text(viewModel.deleteError ?? "")
        }
    }
}
