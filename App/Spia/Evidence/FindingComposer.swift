import SpiaStore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct FindingComposer: View {
    let title: String
    let editableTitle: Binding<String>?
    let initialText: String
    let files: SpiaFiles
    let save: (FindingDraft) -> Void
    let cancel: () -> Void
    @State private var text: String
    @State private var photos: [Data] = []
    @State private var clips: [URL] = []
    @State private var sounds: [URL] = []
    @State private var pickerPresented = false
    @State private var cameraPresented = false
    @State private var recorder = SoundRecorder()
    @State private var voiceNote = VoiceNote()
    @State private var problem: String?

    init(
        title: String,
        editableTitle: Binding<String>? = nil,
        initialText: String = "",
        files: SpiaFiles,
        save: @escaping (FindingDraft) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.title = title
        self.editableTitle = editableTitle
        self.initialText = initialText
        self.files = files
        self.save = save
        self.cancel = cancel
        _text = State(initialValue: initialText)
    }

    private var draft: FindingDraft {
        FindingDraft(
            title: editableTitle?.wrappedValue ?? title,
            text: text,
            photos: photos,
            clips: clips,
            sounds: sounds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let editableTitle {
                TextField("What you looked at", text: editableTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .padding(8)
                    .background(Palette.base, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
            }
            TextField("What you found", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(8)
                .background(Palette.base, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
            controls
            if voiceNote.availability != .available {
                Text(availabilityText)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
            }
            staged
            HStack {
                Spacer()
                Button("Cancel") { abandon() }
                Button("Save") { save(draft) }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(draft.isEmpty)
            }
        }
        .padding()
        .fileImporter(
            isPresented: $pickerPresented,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true,
            onCompletion: { result in
                if let urls = try? result.get() { importFiles(urls) }
            }
        )
        #if os(macOS)
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls)
                return true
            }
        #endif
        #if os(iOS)
            .fullScreenCover(isPresented: $cameraPresented) {
                CameraCapture(
                    captured: { capture in
                        switch capture {
                        case .photo(let data): photos.append(data)
                        case .clip(let url): clips.append(url)
                        }
                        cameraPresented = false
                    },
                    cancelled: { cameraPresented = false })
            }
        #endif
        .errorAlert($problem)
        .onDisappear {
            recorder.cancel()
            voiceNote.stop()
        }
    }

    private var controls: some View {
        FlowLayout(spacing: 8) {
            #if os(iOS)
                if CameraCapture.isAvailable {
                    Button("Camera") { cameraPresented = true }
                }
            #endif
            Button(platformFileLabel) { pickerPresented = true }
            Button(recorder.isRecording ? "Stop (\(clock(recorder.elapsed)))" : "Sound") {
                if recorder.isRecording {
                    if let url = recorder.stop() { sounds.append(url) }
                } else {
                    Task {
                        do { try await recorder.start() } catch { problem = error.readable }
                    }
                }
            }
            .disabled(voiceNote.isListening)
            Button(voiceNote.isListening ? "Stop listening" : "Voice note") {
                if voiceNote.isListening {
                    voiceNote.stop()
                    appendTranscript()
                } else {
                    Task {
                        do { try await voiceNote.start() } catch { problem = error.readable }
                    }
                }
            }
            .disabled(voiceNote.availability != .available || recorder.isRecording)
        }
        .buttonStyle(OutlineButtonStyle())
    }

    private var staged: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(photos.indices, id: \.self) { index in
                    if let image = Image(data: photos[index]) {
                        image.resizable().scaledToFill().frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(alignment: .topTrailing) { remove(index: index, kind: .photo) }
                    }
                }
                ForEach(clips.indices, id: \.self) { index in
                    stagedIcon("film", index: index, kind: .clip)
                }
                ForEach(sounds.indices, id: \.self) { index in
                    stagedIcon("waveform", index: index, kind: .sound)
                }
            }
        }
    }

    private func stagedIcon(_ name: String, index: Int, kind: StagedKind) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: name).frame(width: 56, height: 56).background(Palette.card)
            remove(index: index, kind: kind)
        }
    }

    private func remove(index: Int, kind: StagedKind) -> some View {
        Button {
            switch kind {
            case .photo: photos.remove(at: index)
            case .clip: removeTemporary(clips.remove(at: index))
            case .sound: removeTemporary(sounds.remove(at: index))
            }
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }.buttonStyle(.plain)
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let type = UTType(filenameExtension: url.pathExtension) else { continue }
            if type.conforms(to: .image) {
                if let data = try? Data(contentsOf: url) { photos.append(data) }
            } else if type.conforms(to: .movie) {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("spia-\(UUID().uuidString).\(url.pathExtension)")
                if (try? FileManager.default.copyItem(at: url, to: destination)) != nil {
                    clips.append(destination)
                }
            }
        }
    }

    private func appendTranscript() {
        let value = voiceNote.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += " " }
        text += value
    }

    private func abandon() {
        clips.forEach(removeTemporary)
        sounds.forEach(removeTemporary)
        cancel()
    }

    private func removeTemporary(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    private func clock(_ value: TimeInterval) -> String {
        let seconds = Int(value.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private var platformFileLabel: String {
        #if os(iOS)
            return "Files"
        #else
            return "Add photo or clip"
        #endif
    }
    private var availabilityText: String {
        switch voiceNote.availability {
        case .available: return ""
        case .noOnDeviceRecognition(let locale):
            return "On-device dictation isn't available for \(locale) here."
        case .denied: return "Allow the microphone and speech recognition in Settings."
        }
    }

    private enum StagedKind { case photo, clip, sound }
}

private extension Image {
    init?(data: Data) {
        #if os(macOS)
            guard let image = NSImage(data: data) else { return nil }
            self.init(nsImage: image)
        #else
            guard let image = UIImage(data: data) else { return nil }
            self.init(uiImage: image)
        #endif
    }
}
