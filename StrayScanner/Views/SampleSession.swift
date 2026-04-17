//
//  SampleSession.swift
//  StrayScanner
//

import SwiftUI

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
