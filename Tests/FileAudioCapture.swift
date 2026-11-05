import Foundation
import AVFoundation
import Speech
import CoreMedia

// Inject a file at microphone pace into the real engine. Never opens an input device.
final class FileAudioCapture: AudioCapturing, @unchecked Sendable {
    let url: URL
    private var task: Task<Void, Never>?
    private var sink: AsyncStream<AnalyzerInput>.Continuation?
    private(set) var began: Date?
    private(set) var ended: Date?
    private(set) var duration: Double = 0
    init(url: URL) { self.url = url }
    func start(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
               audioURL: URL?, meter: @escaping @Sendable (Double) -> Void,
               failure: @escaping @Sendable (String) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: source, to: format) else { throw ClassScribeError.message("Fixture conversion unavailable") }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / source.sampleRate) + 64)
        let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var consumed = false; var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            if consumed { state.pointee = .endOfStream; return nil }
            consumed = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error else { throw ClassScribeError.message("Fixture conversion failed") }
        duration = Double(converted.frameLength) / format.sampleRate
        sink = continuation; began = Date(); ended = nil
        task = Task { [self] in
            let packet = max(1, Int(format.sampleRate * 0.1))
            var position = 0
            while position < Int(converted.frameLength), !Task.isCancelled {
                let count = min(packet, Int(converted.frameLength) - position)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                let from = UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList)
                let to = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for channel in from.indices {
                    let stride = Int(format.streamDescription.pointee.mBytesPerFrame)
                    memcpy(to[channel].mData!, from[channel].mData!.advanced(by: position * stride), count * stride)
                }
                // The end of each packet becomes available at its real audio time.
                let target = began!.addingTimeInterval(Double(position + count) / format.sampleRate)
                let delay = target.timeIntervalSinceNow
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                if Task.isCancelled { break }
                if case .dropped = continuation.yield(.init(buffer: buffer,
                    bufferStartTime: CMTime(value: Int64(position), timescale: Int32(format.sampleRate)))) {
                    failure("Synthetic audio input overflowed"); break
                }
                meter(0.4); position += count
            }
            ended = Date()
        }
    }
    func waitUntilEnded() async { await task?.value }
    func stop() async {
        task?.cancel(); await task?.value; task = nil
        sink?.finish(); sink = nil
    }
}
