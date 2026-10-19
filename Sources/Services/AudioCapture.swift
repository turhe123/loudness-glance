import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Errors raised while starting an audio source.
enum CaptureError: LocalizedError {
    case noInputDevice
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input is available."
        case .noDisplay: return "No display is available for system audio capture."
        }
    }
}

/// Feeds microphone samples into a `LoudnessEngine` via an AVAudioEngine input tap.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let sink: LoudnessEngine
    private var configObserver: NSObjectProtocol?
    var onError: ((String) -> Void)?

    init(sink: LoudnessEngine) { self.sink = sink }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak sink] buffer, _ in
            guard let sink, let data = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            let interleaved = buffer.format.isInterleaved
            sink.append(frames: Int(buffer.frameLength), channels: channels,
                        sampleRate: buffer.format.sampleRate, stride: interleaved ? channels : 1) { ch in
                UnsafePointer(interleaved ? data[0] + ch : data[ch])
            }
        }
        engine.prepare()
        try engine.start()
        if configObserver == nil {
            // Device or sample-rate changes stop the engine; rebuild the tap with the new format.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.restart() }
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func restart() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try start() } catch { onError?(error.localizedDescription) }
    }
}

/// Captures system audio with an audio-only ScreenCaptureKit stream (tiny, 1 fps video).
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sink: LoudnessEngine
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.turhe123.loudnessglance.sck", qos: .userInitiated)
    var onError: ((String) -> Void)?

    init(sink: LoudnessEngine) { self.sink = sink }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // A screen output avoids "dropping frame" log spam; its frames are ignored.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return }
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = sampleBuffer.numSamples
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            sink.append(frames: frames, channels: channels, sampleRate: asbd.mSampleRate,
                        stride: nonInterleaved ? 1 : channels) { ch in
                let index = nonInterleaved ? ch : 0
                guard index < buffers.count, let raw = buffers[index].mData else { return nil }
                let base = raw.assumingMemoryBound(to: Float.self)
                return UnsafePointer(nonInterleaved ? base : base + ch)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.stream = nil
            self?.onError?(error.localizedDescription)
        }
    }
}
