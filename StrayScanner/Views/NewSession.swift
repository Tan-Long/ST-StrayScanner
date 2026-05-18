//
//  NewSession.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI

struct NavigationConfigurator: UIViewControllerRepresentable {
    var configure: (UINavigationController) -> Void = { _ in }

    func makeUIViewController(context: UIViewControllerRepresentableContext<NavigationConfigurator>) -> UIViewController {
        UIViewController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<NavigationConfigurator>) {
        if let nc = uiViewController.navigationController {
            self.configure(nc)
        }
    }
}

struct RecordSessionManager: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    let sampleContext: SampleContext?
    
    func makeUIViewController(context: Context) -> RecordSessionViewController {
        let viewController = RecordSessionViewController(nibName: "RecordSessionView", bundle: nil)
        viewController.setSampleContext(sampleContext)
        viewController.setDismissFunction {
            presentationMode.wrappedValue.dismiss()
            viewController.setDismissFunction(Optional.none)
        }
        return viewController
    }

    func updateUIViewController(_ uiViewController: RecordSessionViewController, context: Context) {
        uiViewController.setSampleContext(sampleContext)
    }
}

struct NewSessionView : View {
    @State private var sampleID = SampleContextStore.shared.current?.sampleID ?? ""
    private let latestSampleContext = SampleContextStore.shared.current

    private var recordingSampleContext: SampleContext? {
        let trimmedSampleID = sampleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSampleID.isEmpty else { return nil }
        return SampleContext(
            sampleID: trimmedSampleID,
            isImportant: latestSampleContext?.isImportant ?? false,
            loaiMau: latestSampleContext?.loaiMau ?? "",
            site: latestSampleContext?.site ?? ""
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            RecordSessionManager(sampleContext: recordingSampleContext)
                .padding(.vertical, 0.0)
                .edgesIgnoringSafeArea(.all)

            sampleIDBar
        }
            .padding(.vertical, 0.0)
            .navigationBarTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
            .edgesIgnoringSafeArea(.all)
            .background(NavigationConfigurator { nc in
                nc.navigationBar.barTintColor = UIColor(named: "BackgroundColor")
            })

    }

    private var sampleIDBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "number")
                .foregroundColor(Color("LightColor"))
            TextField("Sample ID", text: $sampleID)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .accessibilityIdentifier("newSession.sampleIDField")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.72))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

struct NewSessionView_Previews: PreviewProvider {
    static var previews: some View {
        NewSessionView()
    }
}
