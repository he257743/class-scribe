import Foundation
import AVFoundation
import CoreMedia

@main struct AudioCaptureTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1; print("PASS: " + message)
        }
        let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false)!
        let intFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 16000, channels: 1, interleaved: false)!
        let values: [Float] = [-1, -0.25, 0, 0.125, 0.75, 1]
        let float = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 2048)!
        float.frameLength = AVAudioFrameCount(values.count)
        for (i, sample) in values.enumerated() { float.floatChannelData![0][i] = sample }
        let packet = CapturedAudio(buffer: float, bufferStartTime: CMTime(value: 3200, timescale: 16000))
        let bytes = try QwenSpeechEngine.pcmData(from: packet)
        let expected = values.withUnsafeBytes { Data($0) }
        check(bytes == expected, "Qwen receives original Float32 samples without an Apple Speech bridge or quantization")
        check(bytes.count == values.count * 4, "unused converter capacity is never sent to Qwen")

        // Exercise a real asynchronous handoff; the source has excess capacity,
        // as microphone resampling does, rather than the old exact-size fixture.
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(2))
        continuation.yield(packet); continuation.finish()
        var received: [Data] = []; var times: [Double] = []
        for await audio in stream {
            received.append(try QwenSpeechEngine.pcmData(from: audio))
            times.append(audio.bufferStartTime.seconds)
        }
        check(received == [expected] && times == [0.2], "asynchronous raw capture preserves samples and their start time")

        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48000, channels: 1, interleaved: false)!
        let microphone = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096)!
        microphone.frameLength = 4096
        for i in 0..<4096 { microphone.floatChannelData![0][i] = Float(sin(Double(i) * 0.03) * 0.4) }
        func convert(to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
            let converter = AVAudioConverter(from: source, to: format)!
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1430)!
            var supplied = false; var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return microphone
            }
            if let error { throw error }
            precondition(status != .error && output.frameLength > 0)
            return output
        }
        let converted = try convert(to: floatFormat)
        let convertedPacket = CapturedAudio(buffer: converted, bufferStartTime: .zero)
        let convertedBytes = try QwenSpeechEngine.pcmData(from: convertedPacket)
        check(converted.frameLength < converted.frameCapacity && convertedBytes.count == Int(converted.frameLength) * 4,
            "48kHz microphone resampling delivers only valid 16kHz Float32 frames")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-audio-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let writer = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: converted)
        }
        let afterSave = try QwenSpeechEngine.pcmData(from: convertedPacket)
        check(afterSave == convertedBytes, "saving PCM16 original audio leaves Qwen Float32 input unchanged")
        let saved = try AVAudioFile(forReading: url)
        check(saved.length == Int64(converted.frameLength), "saved original contains the same frame count as recognition input")

        let intBuffer = try convert(to: intFormat)
        let intPacket = CapturedAudio(buffer: intBuffer, bufferStartTime: CMTime(value: 16000, timescale: 16000))
        let apple = try AppleAudioInput.make(intPacket)
        check(apple.bufferStartTime?.seconds == 1, "Apple Int16 input construction preserves the audio timeline without trapping")
        check(apple.buffer.frameLength == intBuffer.frameLength,
            "Apple Int16 input retains the converted audio frame count")
        if #available(macOS 27, *) {
            var refused = false
            do { _ = try AppleAudioInput.make(packet) } catch { refused = true }
            check(refused, "macOS 27 rejects unsafe Float32 Apple input with an error before the system trap")
            let fallback = try AppleAudioInput.format(preferred: floatFormat, supported: [floatFormat, intFormat])
            check(fallback == intFormat, "Apple format negotiation selects a declared supported Int16 alternative")
            refused = false
            do { _ = try AppleAudioInput.format(preferred: floatFormat, supported: [floatFormat]) } catch { refused = true }
            check(refused, "an unavailable safe Apple format produces an actionable error instead of starting capture")
        } else {
            let selected = try AppleAudioInput.format(preferred: floatFormat, supported: [floatFormat])
            check(selected == floatFormat, "macOS 26 retains the analyzer's preferred audio format")
        }
        let preferred = try AppleAudioInput.format(preferred: intFormat, supported: [intFormat])
        check(preferred == intFormat, "supported preferred Int16 format is retained")
        var refused = false
        do { _ = try QwenSpeechEngine.pcmData(from: intPacket) } catch { refused = true }
        check(refused, "Qwen refuses integer PCM instead of interpreting it as floats")
        let wrongRate = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let wrong = AVAudioPCMBuffer(pcmFormat: wrongRate, frameCapacity: 10)!
        refused = false
        do { _ = try QwenSpeechEngine.pcmData(from: CapturedAudio(buffer: wrong, bufferStartTime: .zero)) } catch { refused = true }
        check(refused, "Qwen refuses an incorrect sample rate before the worker receives data")
        print("\(checks) audio capture checks passed; synthetic audio, no microphone")
    }
}
