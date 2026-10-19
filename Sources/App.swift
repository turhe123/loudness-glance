import AppKit
import SwiftUI

/// Opens the project's donation page.
enum Support {
    static func openDonationPage() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}

/// Owns the long-lived meter model and starts capture as soon as the app launches.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MeterModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startCapture()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopCapture()
    }
}

/// Entry point: a window-style menu bar extra plus a Settings scene.
@main
struct LoudnessGlanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.model)
        }
    }
}

/// Menu bar title: the short-term LUFS value, or just an icon.
struct MenuBarLabel: View {
    @ObservedObject var model: MeterModel
    @AppStorage("menuBarShowsText") private var showsText = true

    var body: some View {
        if showsText {
            Label(MeterFormat.value(model.snapshot.shortTerm) + " LUFS", systemImage: "waveform")
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        } else {
            Image(systemName: "waveform")
        }
    }
}
