import SwiftUI
import AppKit

// MARK: - App Entry Point
//
// This fork's patcher app has no auto-update check and no crash or error
// reporting: it never contacts a server. Update by pulling the repository.

@main
struct SpliceKitApp: App {
    private static let helpURL = URL(string: "https://splicekit.fcp.cafe/installation/")!
    @StateObject private var model = PatcherModel()

    var body: some Scene {
        WindowGroup {
            WizardView(model: model)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button("SpliceKit Help") {
                    NSWorkspace.shared.open(Self.helpURL)
                }
            }
        }

        Window("Logs", id: "log-panel") {
            LogPanelView(model: model)
        }
        .defaultSize(width: 600, height: 400)
    }
}
