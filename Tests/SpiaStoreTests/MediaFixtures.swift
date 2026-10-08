import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SpiaStore

func imageData() throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: 1200, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let image = context.makeImage()
    else { throw MediaError.unreadable }
    let output = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, "public.png" as CFString, 1, nil)
    else { throw MediaError.unreadable }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw MediaError.unreadable }
    return output as Data
}

func makeClip() async throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    do {
        return try await writeClip(at: url, codec: .h264)
    } catch {
        print("H.264 test clip encoding failed: \(error). Trying HEVC.")
        try? FileManager.default.removeItem(at: url)
        return try await writeClip(at: url, codec: .hevc)
    }
}

private func writeClip(at url: URL, codec: AVVideoCodecType) async throws -> URL {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
    guard writer.canAdd(input) else { throw MediaError.unreadable }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? MediaError.unreadable }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<12 {
        while !input.isReadyForMoreMediaData { await Task.yield() }
        guard let buffer = makePixelBuffer() else { throw MediaError.unreadable }
        guard
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 12))
        else { throw writer.error ?? MediaError.unreadable }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? MediaError.unreadable }
    return url
}

private func makePixelBuffer() -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard
        CVPixelBufferCreate(
            kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
            == kCVReturnSuccess,
        let buffer
    else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    base.initializeMemory(as: UInt8.self, repeating: 96, count: CVPixelBufferGetDataSize(buffer))
    return buffer
}

func makeSound(seconds: Double, sampleRate: Double = 22_050) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096),
        let channel = buffer.floatChannelData?[0]
    else { throw MediaError.unreadable }
    let totalFrames = Int(seconds * sampleRate)
    var written = 0
    while written < totalFrames {
        let count = min(Int(buffer.frameCapacity), totalFrames - written)
        for index in 0..<count {
            channel[index] =
                seconds > 60
                ? 0 : Float(sin(2 * Double.pi * 440 * Double(written + index) / sampleRate))
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
        written += count
    }
    return url
}
