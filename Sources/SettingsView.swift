import ServiceManagement
import SwiftUI

/// Preferences: menu bar style, meter refresh rate, launch at login, and About/Support.
struct SettingsView: View {
    @EnvironmentObject private var model: MeterModel
    @AppStorage("menuBarShowsText") private var showsText = true
    @AppStorage("refreshRate") private var refreshRate = 15
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Display") {
                Picker("Menu bar shows", selection: $showsText) {
                    Text("Short-term LUFS").tag(true)
                    Text("Icon only").tag(false)
                }
                Picker("Meter refresh rate", selection: $refreshRate) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("About") {
                Text("LoudnessGlance \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.headline)
                Text("Momentary, short-term and integrated loudness use K-weighting and gating modeled on the common broadcast measurement standard. Values are an approximation intended for quick checks, not certified compliance measurements.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Support / Donate ❤️") { Support.openDonationPage() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .onChange(of: refreshRate) { _, _ in model.restartTimer() }
        .onChange(of: launchAtLogin) { _, enabled in updateLaunchAtLogin(enabled) }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Could not update login item: \(error.localizedDescription)"
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}
