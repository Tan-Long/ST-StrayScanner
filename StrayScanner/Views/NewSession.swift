//
//  NewSession.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI

let sampleFlagChangeNotification = Notification.Name("sampleFlagChangeNotification")

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
    let onFlagChange: (Bool) -> Void
    
    func makeUIViewController(context: Context) -> RecordSessionViewController {
        let viewController = RecordSessionViewController(nibName: "RecordSessionView", bundle: nil)
        viewController.setSampleContext(sampleContext)
        viewController.setFlagChangeHandler(onFlagChange)
        viewController.setDismissFunction {
            presentationMode.wrappedValue.dismiss()
            viewController.setDismissFunction(Optional.none)
        }
        return viewController
    }

    func updateUIViewController(_ uiViewController: RecordSessionViewController, context: Context) {
        uiViewController.setSampleContext(sampleContext)
        uiViewController.setFlagChangeHandler(onFlagChange)
    }
}

struct NewSessionView : View {
    @State private var sampleID = SampleContextStore.shared.current?.sampleID ?? ""
    @State private var isImportantTree = SampleContextStore.shared.current?.isImportant ?? false
    private let latestSampleContext = SampleContextStore.shared.current

    private var recordingSampleContext: SampleContext? {
        let trimmedSampleID = sampleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSampleID.isEmpty else { return nil }
        return SampleContext(
            sampleID: trimmedSampleID,
            isImportant: isImportantTree,
            loaiMau: latestSampleContext?.loaiMau ?? "",
            site: latestSampleContext?.site ?? ""
        )
    }

    var body: some View {
        ZStack {
            RecordSessionManager(
                sampleContext: recordingSampleContext,
                onFlagChange: { isImportantTree = $0 }
            )
                .padding(.vertical, 0.0)
                .edgesIgnoringSafeArea(.all)

            VStack {
                Spacer()
                sampleIDBar
                    .padding(.bottom, 140)
            }
        }
            .padding(.vertical, 0.0)
            .navigationBarTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
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
            Button(action: {
                isImportantTree.toggle()
                NotificationCenter.default.post(
                    name: sampleFlagChangeNotification,
                    object: nil,
                    userInfo: ["isImportant": isImportantTree]
                )
            }) {
                Text(isImportantTree ? "*" : "☆")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 44, height: 34)
                    .background(isImportantTree ? Color.yellow : Color("DarkColor"))
                    .foregroundColor(isImportantTree ? .black : Color("LightColor"))
                    .cornerRadius(10)
            }
            .accessibilityLabel("Important tree")
            .accessibilityValue(isImportantTree ? "Important" : "Normal")
            .accessibilityIdentifier("newSession.importantButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.72))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }
}

struct NewSessionView_Previews: PreviewProvider {
    static var previews: some View {
        NewSessionView()
    }
}
