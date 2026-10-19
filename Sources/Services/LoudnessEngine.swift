import Accelerate
import Foundation

/// Immutable set of meter readings handed from the DSP queue to the UI.
struct LoudnessSnapshot: Equatable {
    var momentary = -Double.infinity
    var shortTerm = -Double.infinity
    var integrated = -Double.infinity
    var peak = -Double.infinity
    var peakHold = -Double.infinity

    static let silent = LoudnessSnapshot()
}

/// Approximate BS.1770-style loudness meter.
///
/// Audio threads call `append` which only copies samples into a lock-protected ring buffer.
/// A serial utility queue drains the ring, applies K-weighting with vDSP biquads, accumulates
/// 100 ms block energies and derives momentary, short-term and gated integrated loudness.
/// Only block energies are stored, never raw samples.
final class LoudnessEngine {
    static let maxChannels = 2
    private static let capacity = 192_000      // frames, ≈4 s at 48 kHz
    private static let chunk = 4_096
    private static let maxGatingBlocks = 360_000 // ≈10 h of 100 ms hops

    // MARK: Shared state (guarded by `lock`)
    private let lock = NSLock()
    private var ring: [[Float]]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var inputRate: Double = 0
    private var inputChannels = 0
    private var formatChanged = false
    private var drainScheduled = false
    private var paused = false
    private var snapshot = LoudnessSnapshot.silent

    // MARK: DSP state (only touched on `queue`)
    private let queue = DispatchQueue(label: "com.turhe123.loudnessglance.dsp", qos: .utility)
    private var setup: vDSP_biquad_Setup?
    private var channels = 0
    private var delays: [[Float]] = []
    private var scratchIn: [[Float]] = []
    private var scratchOut = [Float](repeating: 0, count: LoudnessEngine.chunk)
    private var blockSize = 4_800
    private var blockFill = 0
    private var blockSums: [Double] = []
    private var blockPeak: Float = 0
    private var recentEnergies: [Double] = []
    private var gatingEnergies: [Double] = []
    private var peakHistory: [Float] = []

    init() {
        ring = Array(repeating: [Float](repeating: 0, count: Self.capacity), count: Self.maxChannels)
    }

    deinit {
        if let setup { vDSP_biquad_DestroySetup(setup) }
    }

    // MARK: Producer API (any thread, real-time safe-ish: no allocation)

    /// Copies `frames` samples per channel into the ring. `channelPointer(ch)` returns the first
    /// sample of channel `ch`; consecutive samples are `stride` floats apart.
    func append(frames: Int, channels: Int, sampleRate: Double, stride: Int,
                channelPointer: (Int) -> UnsafePointer<Float>?) {
        guard frames > 0, channels > 0, sampleRate > 0, stride > 0 else { return }
        let used = min(channels, Self.maxChannels)
        let count = min(frames, Self.capacity)
        lock.lock()
        defer { lock.unlock() }
        if paused { return }
        if sampleRate != inputRate || used != inputChannels {
            inputRate = sampleRate
            inputChannels = used
            readIndex = 0; writeIndex = 0; available = 0
            formatChanged = true
        }
        for ch in 0..<used {
            guard let src = channelPointer(ch) else { continue }
            var w = writeIndex
            ring[ch].withUnsafeMutableBufferPointer { dst in
                for i in 0..<count {
                    dst[w] = src[i * stride]
                    w += 1
                    if w == Self.capacity { w = 0 }
                }
            }
        }
        writeIndex = (writeIndex + count) % Self.capacity
        let overflow = max(0, available + count - Self.capacity)
        readIndex = (readIndex + overflow) % Self.capacity
        available = min(available + count, Self.capacity)
        if !drainScheduled {
            drainScheduled = true
            queue.async { [weak self] in self?.drain() }
        }
    }

    // MARK: Consumer API

    func currentSnapshot() -> LoudnessSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func setPaused(_ value: Bool) {
        lock.lock(); paused = value; lock.unlock()
    }

    /// Clears all measurements, including integrated loudness.
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.resetMeasurement()
            self.lock.lock()
            self.snapshot = .silent
            self.lock.unlock()
        }
    }

    // MARK: Processing

    private func drain() {
        while true {
            lock.lock()
            let n = min(available, Self.chunk)
            if n == 0 {
                drainScheduled = false
                lock.unlock()
                return
            }
            if formatChanged {
                formatChanged = false
                configure(sampleRate: inputRate, channels: inputChannels)
            }
            for ch in 0..<channels {
                var r = readIndex
                let src = ring[ch]
                scratchIn[ch].withUnsafeMutableBufferPointer { dst in
                    for i in 0..<n {
                        dst[i] = src[r]
                        r += 1
                        if r == Self.capacity { r = 0 }
                    }
                }
            }
            readIndex = (readIndex + n) % Self.capacity
            available -= n
            lock.unlock()
            process(frames: n)
        }
    }

    /// Rebuilds K-weighting filters for a new sample rate / channel layout.
    private func configure(sampleRate: Double, channels: Int) {
        if let setup { vDSP_biquad_DestroySetup(setup) }
        setup = vDSP_biquad_CreateSetup(Self.kWeightingCoefficients(sampleRate: sampleRate), 2)
        self.channels = channels
        delays = Array(repeating: [Float](repeating: 0, count: 6), count: channels)
        scratchIn = Array(repeating: [Float](repeating: 0, count: Self.chunk), count: channels)
        blockSize = max(1, Int(sampleRate / 10))
        blockFill = 0
        blockSums = Array(repeating: 0, count: channels)
        blockPeak = 0
    }

    private func process(frames: Int) {
        guard let setup else { return }
        var offset = 0
        while offset < frames {
            let take = min(frames - offset, blockSize - blockFill)
            for ch in 0..<channels {
                scratchIn[ch].withUnsafeBufferPointer { input in
                    delays[ch].withUnsafeMutableBufferPointer { delay in
                        scratchOut.withUnsafeMutableBufferPointer { output in
                            guard let inBase = input.baseAddress, let dBase = delay.baseAddress,
                                  let outBase = output.baseAddress else { return }
                            let src = inBase + offset
                            let len = vDSP_Length(take)
                            vDSP_biquad(setup, dBase, src, 1, outBase, 1, len)
                            var sumSquares: Float = 0
                            vDSP_svesq(outBase, 1, &sumSquares, len)
                            var maxMagnitude: Float = 0
                            vDSP_maxmgv(src, 1, &maxMagnitude, len)
                            blockSums[ch] += Double(sumSquares)
                            blockPeak = max(blockPeak, maxMagnitude)
                        }
                    }
                }
            }
            blockFill += take
            offset += take
            if blockFill >= blockSize { finishBlock() }
        }
    }

    private func finishBlock() {
        // Channel weights are 1.0 for mono/stereo, so the block energy is a plain sum.
        let energy = blockSums.reduce(0, +) / Double(blockSize)
        recentEnergies.append(energy)
        if recentEnergies.count > 30 { recentEnergies.removeFirst() }
        peakHistory.append(blockPeak)
        if peakHistory.count > 20 { peakHistory.removeFirst() }

        let momentaryEnergy = Self.mean(recentEnergies.suffix(4))
        if recentEnergies.count >= 4 {
            gatingEnergies.append(momentaryEnergy)
            if gatingEnergies.count > Self.maxGatingBlocks { gatingEnergies.removeFirst(gatingEnergies.count / 10) }
        }

        let next = LoudnessSnapshot(
            momentary: Self.lufs(momentaryEnergy),
            shortTerm: Self.lufs(Self.mean(recentEnergies[...])),
            integrated: integratedLoudness(),
            peak: Self.dbfs(blockPeak),
            peakHold: Self.dbfs(peakHistory.max() ?? 0)
        )
        lock.lock(); snapshot = next; lock.unlock()

        blockFill = 0
        for i in blockSums.indices { blockSums[i] = 0 }
        blockPeak = 0
    }

    /// Two-stage gating: absolute gate at −70 LUFS, relative gate 10 LU below the ungated mean.
    private func integratedLoudness() -> Double {
        let absoluteGate = pow(10, (-70 + 0.691) / 10)
        let aboveAbsolute = gatingEnergies.filter { $0 > absoluteGate }
        guard !aboveAbsolute.isEmpty else { return -.infinity }
        let relativeGate = Self.mean(aboveAbsolute[...]) * 0.1
        let gated = aboveAbsolute.filter { $0 > relativeGate }
        return Self.lufs(Self.mean(gated[...]))
    }

    private func resetMeasurement() {
        recentEnergies.removeAll()
        gatingEnergies.removeAll()
        peakHistory.removeAll()
        blockFill = 0
        for i in blockSums.indices { blockSums[i] = 0 }
        blockPeak = 0
    }

    // MARK: Math helpers

    private static func mean(_ values: ArraySlice<Double>) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func lufs(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    static func dbfs(_ amplitude: Float) -> Double {
        amplitude > 0 ? 20 * log10(Double(amplitude)) : -.infinity
    }

    /// High-shelf pre-filter followed by the RLB high-pass, as [b0, b1, b2, a1, a2] per section.
    static func kWeightingCoefficients(sampleRate fs: Double) -> [Double] {
        // Stage 1: high shelf (+4 dB above ~1.7 kHz).
        let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0,
                     2 * (k * k - vh) / a0,
                     (vh - vb * k / q + k * k) / a0,
                     2 * (k * k - 1) / a0,
                     (1 - k / q + k * k) / a0]
        // Stage 2: high-pass at ~38 Hz.
        let f1 = 38.13547087602444, q1 = 0.5003270373238773
        let k1 = tan(Double.pi * f1 / fs)
        let d = 1 + k1 / q1 + k1 * k1
        let highPass = [1.0, -2.0, 1.0,
                        2 * (k1 * k1 - 1) / d,
                        (1 - k1 / q1 + k1 * k1) / d]
        return shelf + highPass
    }
}
