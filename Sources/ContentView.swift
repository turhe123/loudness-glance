import SwiftUI

/// The menu bar panel: big short-term readout, momentary and peak bars, integrated value, controls.
struct ContentView: View {
    @EnvironmentObject private var model: MeterModel
    @AppStorage("source") private var sourceRaw = AudioSource.microphone.rawValue
    @AppStorage("target") private var targetRaw = LoudnessTarget.podcast.rawValue

    private var target: LoudnessTarget { LoudnessTarget(rawValue: targetRaw) ?? .podcast }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: $sourceRaw) {
                ForEach(AudioSource.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.permission == .granted {
                meters
            } else {
                PermissionPrompt(source: model.source, state: model.permission, action: model.requestPermission)
            }

            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            controls
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            if let stored = AudioSource(rawValue: sourceRaw), stored != model.source { model.select(stored) }
            model.refresh()
        }
        .onChange(of: sourceRaw) { _, newValue in
            if let source = AudioSource(rawValue: newValue) { model.select(source) }
        }
    }

    private var meters: some View {
        let s = model.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(MeterFormat.value(s.shortTerm))
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(target.color(for: s.shortTerm))
                    Text("LUFS").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    if model.isPaused { Text("PAUSED").font(.caption.bold()).foregroundStyle(.orange) }
                }
                Text("Short-term (3 s) · target \(target.rawValue) LUFS")
                    .font(.caption).foregroundStyle(.secondary)
            }

            labeledRow("Momentary", value: s.momentary, unit: "LUFS")
            MeterBar(value: s.momentary, color: target.color(for: s.momentary),
                     marker: Double(target.rawValue), hold: nil, height: 10)

            labeledRow("Peak", value: s.peak, unit: "dBFS")
            MeterBar(value: s.peak, color: peakColor(s.peak), marker: nil, hold: s.peakHold, height: 4)

            HStack {
                Text("Integrated").foregroundStyle(.secondary)
                Spacer()
                Text("\(MeterFormat.value(s.integrated)) LUFS")
                    .monospacedDigit()
                    .foregroundStyle(target.color(for: s.integrated))
            }
            .font(.callout)
        }
    }

    private var controls: some View {
        HStack {
            Picker("Target", selection: $targetRaw) {
                ForEach(LoudnessTarget.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
            Spacer()
            Button("Reset", action: model.reset)
            Button(model.isPaused ? "Resume" : "Pause", action: model.togglePause)
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            Button("Support / Donate ❤️") { Support.openDonationPage() }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit LoudnessGlance")
        }
        .buttonStyle(.borderless)
    }

    private func labeledRow(_ title: String, value: Double, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(MeterFormat.value(value)) \(unit)").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func peakColor(_ dbfs: Double) -> Color {
        if dbfs > -1 { return .red }
        if dbfs > -6 { return .orange }
        return .green
    }
}

/// Horizontal bar spanning −60…0 dB with an optional target marker and peak-hold tick.
struct MeterBar: View {
    let value: Double
    let color: Color
    let marker: Double?
    let hold: Double?
    let height: CGFloat

    private static let floor = -60.0

    private func fraction(_ db: Double) -> CGFloat {
        guard db.isFinite else { return 0 }
        return CGFloat(min(max((db - Self.floor) / -Self.floor, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: geo.size.width * fraction(value))
                if let marker {
                    Rectangle().fill(Color.primary.opacity(0.6))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * fraction(marker))
                }
                if let hold, hold.isFinite {
                    Rectangle().fill(hold > -1 ? Color.red : Color.primary)
                        .frame(width: 2, height: height + 4)
                        .offset(x: max(0, geo.size.width * fraction(hold) - 2))
                }
            }
            .animation(.linear(duration: 0.06), value: value)
        }
        .frame(height: height)
    }
}

/// Shown instead of the meters when the chosen source lacks permission.
struct PermissionPrompt: View {
    let source: AudioSource
    let state: PermissionState
    let action: () -> Void

    private var reason: String {
        source == .microphone
            ? "Microphone access is needed to measure your input level."
            : "Screen Recording access is needed to capture system audio (no video is stored)."
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(reason).font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(state == .denied ? "Open System Settings" : "Grant Access", action: action)
                .buttonStyle(.borderedProminent)
            if state == .denied && source == .system {
                Text("After enabling, quit and reopen LoudnessGlance. Microphone mode still works.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
