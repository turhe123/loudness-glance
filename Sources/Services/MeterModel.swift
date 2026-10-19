import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

/// Where audio is measured from.
enum AudioSource: String, CaseIterable, Identifiable {
    case microphone, system
    var id: String { rawValue }
    var title: String { self == .microphone ? "Microphone" : "System Audio" }
}

/// Common delivery loudness targets in LUFS.
enum LoudnessTarget: Int, CaseIterable, Identifiable {
    case streaming = -14, podcast = -16, broadcast = -23
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .streaming: return "Streaming (−14)"
        case .podcast: return "Podcast (−16)"
        case .broadcast: return "Broadcast (−23)"
        }
    }

    /// Green near target, amber when moderately off, red when far off.
    func color(for lufs: Double) -> Color {
        guard lufs.isFinite else { return .secondary }
        let distance = abs(lufs - Double(rawValue))
        if distance <= 1.5 { return .green }
        if distance <= 4 { return .orange }
        return .red
    }
}

/// Permission status for the currently selected source.
enum PermissionState {
    case granted, notDetermined, denied
}

/// Display helpers shared by the panel and the menu bar label.
enum MeterFormat {
    static func value(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "–"
    }
}

/// Owns the capture sources and the loudness engine, handles permissions, sleep/wake,
/// and publishes a fresh snapshot to SwiftUI at the configured refresh rate.
@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var snapshot = LoudnessSnapshot.silent
    @Published private(set) var permission: PermissionState = .notDetermined
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPaused = false
    @Published private(set) var source: AudioSource

    private let engine = LoudnessEngine()
    private var microphone: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let screenRequestedKey = "screenCaptureRequested"

    init() {
        source = AudioSource(rawValue: UserDefaults.standard.string(forKey: "source") ?? "") ?? .microphone
        restartTimer()
        observeSleepWake()
    }

    // MARK: Source control

    func select(_ newSource: AudioSource) {
        guard newSource != source else { return }
        stopCapture()
        engine.reset()
        snapshot = .silent
        source = newSource
        startCapture()
    }

    /// Starts the selected source if permission allows; otherwise updates `permission`.
    func startCapture() {
        guard microphone == nil, system == nil else { return }
        errorMessage = nil
        switch source {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                permission = .granted
                startMicrophone()
            case .notDetermined:
                permission = .notDetermined
            default:
                permission = .denied
            }
        case .system:
            if CGPreflightScreenCaptureAccess() {
                permission = .granted
                startSystemAudio()
            } else {
                permission = UserDefaults.standard.bool(forKey: screenRequestedKey) ? .denied : .notDetermined
            }
        }
    }

    func stopCapture() {
        microphone?.stop()
        microphone = nil
        system?.stop()
        system = nil
    }

    /// Re-checks permission when the panel opens (the user may have changed it in System Settings).
    func refresh() {
        if microphone == nil && system == nil { startCapture() }
    }

    func requestPermission() {
        switch source {
        case .microphone:
            guard permission == .notDetermined else { return openPrivacyPane("Privacy_Microphone") }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.startCapture() }
            }
        case .system:
            guard permission == .notDetermined else { return openPrivacyPane("Privacy_ScreenCapture") }
            UserDefaults.standard.set(true, forKey: screenRequestedKey)
            if CGRequestScreenCaptureAccess() { startCapture() } else { permission = .denied }
        }
    }

    func togglePause() {
        isPaused.toggle()
        engine.setPaused(isPaused)
    }

    func reset() {
        engine.reset()
        snapshot = .silent
    }

    // MARK: Private

    private func startMicrophone() {
        let capture = MicrophoneCapture(sink: engine)
        capture.onError = { [weak self] message in self?.errorMessage = message }
        do {
            try capture.start()
            microphone = capture
        } catch {
            errorMessage = "Microphone unavailable: \(error.localizedDescription)"
        }
    }

    private func startSystemAudio() {
        let capture = SystemAudioCapture(sink: engine)
        capture.onError = { [weak self] message in
            self?.system = nil
            self?.errorMessage = "System audio stopped: \(message)"
        }
        system = capture
        Task { [weak self] in
            do {
                try await capture.start()
            } catch {
                guard let self, self.system === capture else { return }
                self.system = nil
                self.errorMessage = "System audio unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func restartTimer() {
        timer?.invalidate()
        let stored = UserDefaults.standard.integer(forKey: "refreshRate")
        let fps = stored > 0 ? Double(stored) : 15
        let timer = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let next = engine.currentSnapshot()
        if next != snapshot { snapshot = next }
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopCapture() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            // Give audio devices a moment to come back before restarting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { self?.startCapture() }
            }
        })
    }
}
