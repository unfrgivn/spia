import AVFoundation
import Foundation
import Observation
import Speech

@MainActor
@Observable final class VoiceNote {
    enum Availability: Equatable {
        case available
        case noOnDeviceRecognition(locale: String)
        case denied
    }

    var transcript = ""
    var isListening = false
    let availability: Availability
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    init() {
        let recognizer = SFSpeechRecognizer(locale: .current)
        self.recognizer = recognizer
        if let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition {
            availability = .available
        } else {
            availability = .noOnDeviceRecognition(locale: Locale.current.identifier)
        }
    }

    func start() async throws {
        guard availability == .available, let recognizer else {
            throw VoiceNoteError.unavailable
        }
        let speech = await requestSpeechPermission()
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, microphone else { throw VoiceNoteError.denied }
        try AudioSession.beginRecording()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            Task { @MainActor in
                self?.transcript = result.bestTranscription.formattedString
            }
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        transcript = ""
        isListening = true
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isListening = false
        AudioSession.endRecording()
    }

    private func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

enum VoiceNoteError: Error, CustomStringConvertible {
    case denied
    case unavailable

    var description: String {
        switch self {
        case .denied:
            return "Allow the microphone and speech recognition in Settings."
        case .unavailable:
            return "On-device dictation isn't available here."
        }
    }
}
