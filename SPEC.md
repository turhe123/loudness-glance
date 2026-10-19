# LoudnessGlance — specification

**Tagline:** A menu bar loudness meter showing LUFS and peak levels of your mic or system audio in real time.

**Category:** Audio

**Inspired by (paid):** LOUDMETER ($9.99 one-time)

**Frameworks:** SwiftUI, AppKit, AVFoundation, ScreenCaptureKit, Accelerate, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: LOUDMETER is a Mac App Store menu bar app sold for 9.99 dollars that shows real-time LUFS loudness, true peak, peak and phase for any audio, so podcasters and video editors can check levels without opening a plugin window. A Sonic State write-up in 2026 featured it, which shows interest among audio creators, though the store rating count is small. Our clean-room LoudnessGlance reproduces a simplified version of the idea.

Feature set: a live meter with momentary loudness (400 ms window), short-term loudness (3 s window), and integrated loudness since reset, all in LUFS following the K-weighting and gating approach of the common broadcast measurement standard. Also sample peak in dBFS with a hold marker, a target selector (podcast minus 16, streaming minus 14, broadcast minus 23) with green, amber and red coloring relative to target, a reset button, and a source picker between the microphone and system audio. The menu bar title shows the short-term value. About 400 to 600 lines.

UI spec: a MenuBarExtra in window style. The top shows a large numeric short-term LUFS value in the target color, below it a horizontal bar meter for momentary loudness and a second thin bar for peak with hold tick. A row shows integrated loudness and loudness range is omitted for simplicity. Controls: Source segmented picker (Microphone, System Audio), Target picker, Reset, and Pause. Settings: whether the menu bar shows text or just an icon, meter refresh rate, launch at login. Empty and permission states: if the permission for the chosen source is missing, the panel shows a single button to grant it with a one-line reason.

Technical approach: for the microphone, use AVAudioEngine input node with an installed tap, which needs the NSMicrophoneUsageDescription key and an AVCaptureDevice requestAccess call. For system audio, use ScreenCaptureKit SCStream configured for audio capture only with a minimal video size, which needs the Screen Recording permission, requested with CGRequestScreenCaptureAccess, and the stream output delivers audio sample buffers. Convert incoming samples to mono-summed float arrays per channel. Implement K-weighting as two cascaded biquad filters (a high shelf pre-filter and a high-pass) with coefficients computed for the actual sample rate, run them with vDSP biquad functions from Accelerate, compute mean square over 100 ms blocks, and derive momentary and short-term values from rolling block windows. Integrated loudness applies the absolute gate at minus 70 LUFS and a relative gate ten units below. Convert with minus 0.691 plus 10 times log10 of the weighted mean square. Update the UI at about 15 frames per second from a lock-protected snapshot. Persist the target and source in AppStorage.

Edge cases: silence yields negative infinity, which should be displayed as a dash. Sample rate changes mid-stream require recomputing filter coefficients, so rebuild them when the format changes. If screen capture permission is denied, keep the microphone mode usable. Sleep and wake should restart the stream. Avoid heavy work on the audio thread by copying samples into a ring buffer processed on a utility queue. Make clear in the About text that values are an approximation intended for quick checks, not certified compliance measurements. Limit memory use for integrated loudness by storing only block energies, not raw samples.
