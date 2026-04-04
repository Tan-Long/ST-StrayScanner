//
//  InformationView.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 2/28/21.
//  Copyright © 2021 Stray Robots. All rights reserved.
//

import SwiftUI

struct InformationView: View {
    let paddingLeftRight: CGFloat = 15
    let paddingTextTop: CGFloat = 10
    var body: some View {
        ZStack {
            Color("BackgroundColor").ignoresSafeArea()
            ScrollView {
            VStack(alignment: .leading) {
                Text("About This App").font(.title)
                    .fontWeight(.bold)
                Group {
                bodyText("""
This app lets you record video and depth datasets using the camera and LIDAR scanner.
""")

                heading("Transfering Datasets To Your Desktop Computer")
                
                bodyText("""
The recorded datasets can be exported in several ways:

1. Share directly from the app: Tap the "Share" button inside any recording to export it as a ZIP archive via AirDrop, email, or save to Files.

2. Connect your device with the lightning cable:
   • On Mac, access files through Finder sidebar > your device > "Files" tab > Stray Scanner
   • On Windows, access files through iTunes
   • Drag folders to your desired location (one folder per dataset)

3. Use the Files app: Browse > On My iPhone > Stray Scanner, then export to another app or iCloud drive.
""")
}
                Group {
                heading("Source Code")
                bodyText("This app is open source. You can find the source code behind the link below. The Github project also contains documentation and links to other related projects.")
                    
                bodyText("To report bugs, please open an issue on the Github project. Contributions are more than welcome.")
                    
                link(text: "Github project", destination:
                    "https://github.com/StrayRobots/scanner")

                }
                Group {
                heading("Disclaimer")
                bodyText("This application is provided as is.\nIn no event shall the authors or copyright holders be liable for any claim, damages or other liability arising from using, or in connection with using the software.")
                Spacer()
                }
            }.padding(.all, paddingLeftRight)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        
        }
    }
    
    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .fontWeight(.bold)
            .padding(.top, 20)
    }
    
    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .multilineTextAlignment(.leading)
            .lineSpacing(1.25)
            .padding(.top, paddingTextTop)
    }
    
    private func link(text: String, destination: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundColor(Color.blue)
            .padding(.top, paddingTextTop)
            .onTapGesture {
                let url = URL.init(string: destination)
                guard let destinationUrl = url else { return }
                UIApplication.shared.open(destinationUrl)
            }
    }
}

struct InformationView_Previews: PreviewProvider {
    static var previews: some View {
        InformationView()
    }
}
