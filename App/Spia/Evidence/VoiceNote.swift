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
        let speech = await Self.speechPermission()
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, microphone else { throw VoiceNoteError.denied }
        try AudioSession.beginRecording()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.transcriber(for: self))
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0),
            block: Self.feeder(for: request))
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

    // TCC, Speech and the audio engine call these blocks on their own threads. A closure written
    // inside this class inherits its main-actor isolation, and Swift 6 traps when one runs off
    // the main thread (the permission reply crashed the app that way), so each is built here,
    // outside the actor.

    private nonisolated static func speechPermission() async
        -> SFSpeechRecognizerAuthorizationStatus
    {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private nonisolated static func transcriber(
        for note: VoiceNote
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak note] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor [note] in note?.transcript = text }
        }
    }

    private nonisolated static func feeder(
        for request: SFSpeechAudioBufferRecognitionRequest
    ) -> AVAudioNodeTapBlock {
        { [weak request] buffer, _ in request?.append(buffer) }
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
