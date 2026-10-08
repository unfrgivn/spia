import AVFoundation
import Foundation
import Observation
import SpiaStore

@MainActor
@Observable final class SoundRecorder {
    var elapsed: TimeInterval = 0
    var isRecording = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?

    func start() async throws {
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { throw SoundRecorderError.denied }
        try AudioSession.beginRecording()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("spia-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(
            url: destination,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ])
        recorder.prepareToRecord()
        recorder.record()
        self.recorder = recorder
        url = destination
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            let current = recorder.currentTime
            Task { @MainActor [weak self] in
                guard let self else { return }
                elapsed = current
                if elapsed >= Double(MediaPreparation.maximumSeconds) {
                    _ = stop()
                }
            }
        }
    }

    func stop() -> URL? {
        guard isRecording else { return nil }
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        AudioSession.endRecording()
        let result = url
        recorder = nil
        url = nil
        return result
    }

    func cancel() {
        let result = stop()
        if let result { try? FileManager.default.removeItem(at: result) }
        elapsed = 0
    }
}

enum SoundRecorderError: Error, CustomStringConvertible {
    case denied

    var description: String {
        "Allow the microphone in Settings / System Settings to record a sound."
    }
}

/// The iPhone routes the microphone through a session; the Mac just listens.
enum AudioSession {
    static func beginRecording() throws {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: .defaultToSpeaker)
            try session.setActive(true)
        #endif
    }

    static func endRecording() {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(.playback)
        #endif
    }
}
