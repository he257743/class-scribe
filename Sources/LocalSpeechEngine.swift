import Foundation
import AVFoundation
import Speech
import CoreMedia

enum ClassScribeError: LocalizedError {
    case message(String)
    case speechAssetsUnavailable
    case qwenAssetsUnavailable
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .qwenAssetsUnavailable: return "请先在设置中准备千问识别组件。"
        case .speechAssetsUnavailable: return "请先点击“准备语言包”，安装英语识别包。"
        }
    }
}

enum SpeechAssets {
    static func englishModule() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw ClassScribeError.message("这台 Mac 暂不支持本机连续转录。需要 Apple 芯片与 macOS 26 或更新版本。")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw ClassScribeError.message("系统暂未提供英语识别。请检查网络后重新检查语言包。")
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    static func status() async throws -> AssetInventory.Status {
        let module = try await englishModule()
        if let locale = module.selectedLocales.first { try await AssetInventory.reserve(locale: locale) }
        return await AssetInventory.status(forModules: [module])
    }

    static func install(progress: @escaping @Sendable (Double) async -> Void) async throws {
        let module = try await englishModule()
        guard let locale = module.selectedLocales.first else {
            throw ClassScribeError.message("无法取得英语语言配置，请重试。")
        }
        try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let observer = Task {
                while !Task.isCancelled {
                    await progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
            defer { observer.cancel() }
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw ClassScribeError.message("英语语音包尚未安装完成，请连接网络后重试。")
        }
        await progress(1)
    }
}

protocol AudioCapturing: AnyObject {
    func start(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
               audioURL: URL?, meter: @escaping @Sendable (Double) -> Void,
               failure: @escaping @Sendable (String) -> Void) throws
    func stop() async
}

final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "local.classscribe.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var accepting = false
    private var failed = false
    private var tapInstalled = false
    private var converter: AVAudioConverter?
    private var writer: AVAudioFile?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var position: Int64 = 0
    private var lastMeter = Date.distantPast

    func start(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
               audioURL: URL?, meter: @escaping @Sendable (Double) -> Void,
               failure: @escaping @Sendable (String) -> Void) throws {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let converter = AVAudioConverter(from: source, to: format) else {
            throw ClassScribeError.message("未找到可用麦克风。请在系统声音设置中选择输入设备。")
        }
        self.converter = converter
        self.continuation = continuation
        if let audioURL {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: Int(format.channelCount),
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            writer = try AVAudioFile(forWriting: audioURL, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        accepting = true
        input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            guard self.accepting && !self.failed else { self.lock.unlock(); return }
            guard self.pending < 32 else {
                self.failed = true; self.lock.unlock()
                failure("处理速度跟不上收音，已停止以避免静默漏字。请关闭其他高负载软件后继续。")
                return
            }
            self.pending += 1; self.lock.unlock()
            guard let copy = Self.copy(buffer) else {
                self.lock.lock(); self.pending -= 1; self.lock.unlock()
                self.reportFailure("无法保留麦克风音频，已停止收音。", callback: failure)
                return
            }
            self.queue.async {
                defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
                do {
                    let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * format.sampleRate / source.sampleRate) + 64)
                    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                        throw ClassScribeError.message("无法分配音频缓冲区。")
                    }
                    var supplied = false
                    var conversionError: NSError?
                    let status = converter.convert(to: output, error: &conversionError) { _, state in
                        if supplied { state.pointee = .noDataNow; return nil }
                        supplied = true; state.pointee = .haveData; return copy
                    }
                    if let conversionError { throw conversionError }
                    guard status != .error else { throw ClassScribeError.message("麦克风音频转换失败。") }
                    guard output.frameLength > 0 else { return }
                    try self.writer?.write(from: output)
                    let time = CMTime(value: self.position, timescale: Int32(format.sampleRate.rounded()))
                    self.position += Int64(output.frameLength)
                    let yield = continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time))
                    if case .dropped = yield {
                        throw ClassScribeError.message("识别积压过多，已停止以避免静默漏字。原音已保存，可稍后回听。")
                    }
                    if Date().timeIntervalSince(self.lastMeter) >= 0.12 {
                        self.lastMeter = Date()
                        meter(Self.level(copy))
                    }
                } catch {
                    self.reportFailure(error.localizedDescription, callback: failure)
                }
            }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0); tapInstalled = false; accepting = false
            writer = nil; continuation.finish(); throw error
        }
    }

    func stop() async {
        lock.withLock { accepting = false }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        await withCheckedContinuation { done in
            queue.async {
                self.writer = nil // Flush the audio file before reporting a completed stop.
                self.continuation?.finish(); self.continuation = nil
                done.resume()
            }
        }
    }

    private func reportFailure(_ message: String, callback: @escaping @Sendable (String) -> Void) {
        lock.lock()
        let report = !failed
        failed = true
        lock.unlock()
        if report { callback(message) }
    }

    private static func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
        copy.frameLength = input.frameLength
        let sources = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let targets = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in sources.indices {
            guard let source = sources[index].mData, let target = targets[index].mData else { return nil }
            memcpy(target, source, Int(sources[index].mDataByteSize))
            targets[index].mDataByteSize = sources[index].mDataByteSize
        }
        return copy
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let stride = Int(buffer.stride)
        let count = Int(buffer.frameLength)
        var sum = 0.0
        for index in Swift.stride(from: 0, to: count, by: 8) {
            let sample = Double(channel[index * stride]); sum += sample * sample
        }
        let rms = sqrt(sum / Double(max(1, (count + 7) / 8)))
        return min(1, max(0, (20 * log10(max(rms, 0.00001)) + 55) / 55))
    }
}

protocol SpeechRecording: AnyObject {
    func start(audioURL: URL?, contextualWords: [String], offset: Double,
               receive: @escaping @Sendable (RecognitionUpdate) async -> Void,
               meter: @escaping @Sendable (Double) -> Void,
               failure: @escaping @Sendable (String) -> Void) async throws
    func stop() async -> String?
}

final class LocalSpeechEngine: SpeechRecording, @unchecked Sendable {
    private let capture: any AudioCapturing
    init(capture: any AudioCapturing = MicrophoneCapture()) { self.capture = capture }
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?

    func start(audioURL: URL?, contextualWords: [String], offset: Double,
               receive: @escaping @Sendable (RecognitionUpdate) async -> Void,
               meter: @escaping @Sendable (Double) -> Void,
               failure: @escaping @Sendable (String) -> Void) async throws {
        let transcriber = try await SpeechAssets.englishModule()
        if let locale = transcriber.selectedLocales.first { try await AssetInventory.reserve(locale: locale) }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw ClassScribeError.speechAssetsUnavailable
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ClassScribeError.message("系统无法提供识别所需的音频格式。")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        self.analyzer = analyzer
        if !contextualWords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualWords
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    var confidences: [Double] = []
                    for run in result.text.runs {
                        if let confidence = run.transcriptionConfidence { confidences.append(confidence) }
                    }
                    let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                    await receive(RecognitionUpdate(start: max(0, result.range.start.seconds) + offset,
                        end: max(0, CMTimeRangeGetEnd(result.range).seconds) + offset,
                        text: String(result.text.characters), isFinal: result.isFinal, confidence: confidence))
                }
            } catch {
                if !Task.isCancelled { failure("本机识别中断：\(error.localizedDescription)") }
            }
        }
        inputTask = Task {
            do { try await analyzer.start(inputSequence: stream) }
            catch { if !Task.isCancelled { failure("音频分析失败：\(error.localizedDescription)") } }
        }
        do { try capture.start(format: format, continuation: continuation, audioURL: audioURL, meter: meter, failure: failure) }
        catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel(); inputTask?.cancel()
            throw error
        }
    }

    func stop() async -> String? {
        await capture.stop()
        var problem: String?
        if let analyzer {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch {
                problem = "末段未能完全定稿，已保留草稿：\(error.localizedDescription)"
                await analyzer.cancelAndFinishNow()
            }
        }
        await resultsTask?.value
        inputTask?.cancel(); await inputTask?.value
        resultsTask = nil; inputTask = nil; analyzer = nil
        return problem
    }
}
