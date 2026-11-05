import Foundation
import AVFoundation
import Speech
import Darwin

enum SpeechBackend: String, CaseIterable, Sendable {
    case apple, qwen
    var title: String { self == .apple ? "苹果连续识别" : "千问 Qwen3-ASR" }
}

struct QwenInstallation: Sendable {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassScribe/QwenASR", isDirectory: true)
    }
    var python: URL { root.appendingPathComponent("runtime/bin/python3.12") }
    var model: URL { root.appendingPathComponent("model", isDirectory: true) }
    var ready: Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: model.appendingPathComponent("model.safetensors").path),
              let data = try? Data(contentsOf: root.appendingPathComponent("ready.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (marker["runtime_revision"] as? Int ?? 0) >= 2
    }
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONHOME"] = root.appendingPathComponent("runtime").path
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONPATH"] = nil
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"; env["TOKENIZERS_PARALLELISM"] = "false"
        return env
    }
}

enum QwenRecognitionWindow: String, CaseIterable, Sendable {
    case context, quick
    var title: String { self == .context ? "上下文优先" : "快速定稿" }
    var seconds: Int { self == .context ? 30 : 12 }
    // At EOF, context mode keeps up to 1.5 seconds of boundary lookahead in
    // the final window rather than generating a tiny independent tail.
    var maximumEventDuration: Double { Double(seconds) + (self == .context ? 1.6 : 0.05) }
    func accepts(duration: Double) -> Bool { duration.isFinite && duration > 0 && duration <= maximumEventDuration }
}

// A single owned child process. Bounded JSON output; PCM stays in an anonymous
// pipe. A broken child cannot terminate the app with SIGPIPE.
final class JSONLineProcess: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var log: FileHandle?
    private let writeLock = NSLock()
    private var inputClosed = false
    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(256))
    }
    func launch(executable: URL, arguments: [String], environment: [String: String], logURL: URL) throws {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        log = try FileHandle(forWritingTo: logURL)
        try log?.truncate(atOffset: 0)
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = log
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        continuation.onTermination = { [weak self] status in if case .cancelled = status { self?.terminate() } }
        DispatchQueue(label: "local.classscribe.qwen.output", qos: .userInitiated).async { [self] in
            var pending = Data()
            do {
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    guard pending.count <= 131072 else { throw ClassScribeError.message("千问识别回复异常过长。") }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                        if line.isEmpty { continue }
                        if case .dropped = continuation.yield(line) {
                            throw ClassScribeError.message("识别文字积压过多，已停止以避免漏字。")
                        }
                    }
                }
                guard pending.isEmpty else { throw ClassScribeError.message("千问识别回复未完整结束。") }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw ClassScribeError.message("千问识别进程提前结束，请检查识别组件后重试。") }
                continuation.finish()
            } catch { continuation.finish(throwing: error); terminate() }
            try? output.fileHandleForReading.close(); try? log?.close()
        }
    }
    func write(_ data: Data) throws {
        try writeLock.withLock {
            guard !inputClosed, process.isRunning else { throw ClassScribeError.message("千问识别进程已关闭。") }
            try input.fileHandleForWriting.write(contentsOf: data)
        }
    }
    func closeInput() {
        writeLock.withLock {
            if !inputClosed { inputClosed = true; try? input.fileHandleForWriting.close() }
        }
    }
    func terminate() {
        if process.isRunning { process.terminate() }
        closeInput()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private final class QwenReadySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    func resolve(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result; let current = waiter; waiter = nil; return current
        }
        continuation?.resume(with: result)
    }
    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let previous = lock.withLock { () -> Result<Void, Error>? in
                    if let result { return result }; waiter = continuation; return nil
                }
                if let previous { continuation.resume(with: previous) }
            }
        } onCancel: { self.resolve(.failure(CancellationError())) }
    }
}

struct QwenWorkerEvent: Decodable {
    var kind: String
    var start: Double?
    var end: Double?
    var text: String?
    var final: Bool?
    var message: String?
    var processingSeconds: Double?
    var firstTokenSeconds: Double?
    var peakMlxBytes: Double?
    var workerPeakRssBytes: Double?
    var workerCpuSeconds: Double?
    var modelLoadSeconds: Double?
    var progress: Double?
    var issue: RecognitionIssue?
}

actor QwenSpeechEngine: SpeechRecording {
    private let capture: any AudioCapturing
    private let installation: QwenInstallation
    private let workerURL: URL?
    nonisolated let recognitionWindow: QwenRecognitionWindow
    private var child: JSONLineProcess?
    private var inputTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var stopping = false
    private(set) var workerPeakRSS: Double = 0
    private(set) var workerPeakMLX: Double = 0
    private(set) var workerCPU: Double = 0
    private(set) var modelLoadSeconds: Double = 0
    private var problem: String?

    init(capture: any AudioCapturing = MicrophoneCapture(), installation: QwenInstallation = .init(), workerURL: URL? = nil, recognitionWindow: QwenRecognitionWindow = .context) {
        self.capture = capture; self.installation = installation
        self.recognitionWindow = recognitionWindow
        self.workerURL = workerURL ?? Bundle.main.url(forResource: "QwenASRWorker", withExtension: "py")
    }
    func start(audioURL: URL?, contextualWords: [String], offset: Double,
               receive: @escaping @Sendable (RecognitionUpdate) async -> Void,
               meter: @escaping @Sendable (Double) -> Void,
               failure: @escaping @Sendable (String) -> Void) async throws {
        guard installation.ready, let workerURL else {
            throw ClassScribeError.qwenAssetsUnavailable
        }
        stopping = false; problem = nil
        let process = JSONLineProcess(); child = process
        let ready = QwenReadySignal()
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        try process.launch(executable: installation.python,
            arguments: ["-I", workerURL.path, "--model", installation.model.path],
            environment: installation.environment, logURL: installation.root.appendingPathComponent("worker.log"))
        try process.write(JSONSerialization.data(withJSONObject: ["terms": Array(contextualWords.prefix(100)),
            "window_seconds": recognitionWindow.seconds] as [String: Any]) + Data([10]))
        resultsTask = Task { [self] in
            do {
                var stoppedNormally = false
                for try await line in process.stream {
                    let event = try decoder.decode(QwenWorkerEvent.self, from: line)
                    if let rss = event.workerPeakRssBytes { workerPeakRSS = max(workerPeakRSS, rss) }
                    if let peak = event.peakMlxBytes { workerPeakMLX = max(workerPeakMLX, peak) }
                    if let cpu = event.workerCpuSeconds { workerCPU = cpu }
                    switch event.kind {
                    case "ready": modelLoadSeconds = event.modelLoadSeconds ?? 0; ready.resolve(.success(()))
                    case "result", "rejected":
                        guard let start = event.start, let end = event.end, let text = event.text,
                              start.isFinite, end.isFinite, start >= 0, end > start,
                              recognitionWindow.accepts(duration: end - start), !text.isEmpty, text.count <= 6000 else {
                            throw ClassScribeError.message("千问识别返回了无效片段，已保留原音。")
                        }
                        let issue = event.issue ?? RecognitionSanity.issue(text, seconds: end - start)
                        guard event.kind != "rejected" || issue != nil else {
                            throw ClassScribeError.message("千问识别未提供异常片段的核查原因。")
                        }
                        await receive(.init(start: start + offset, end: end + offset, text: text,
                            isFinal: event.final == true, confidence: nil, recognitionIssue: issue))
                    case "error": throw ClassScribeError.message(event.message ?? "千问识别未完成。")
                    case "stopped": stoppedNormally = true
                    default: throw ClassScribeError.message("千问识别回复格式不匹配，请重新准备组件。")
                    }
                }
                guard stoppedNormally else { throw ClassScribeError.message("千问末段识别未确认结束，请回听原音。") }
                ready.resolve(.failure(ClassScribeError.message("千问识别未能就绪。")))
                if !stopping { throw ClassScribeError.message("千问识别意外停止。") }
            } catch {
                ready.resolve(.failure(error))
                if problem == nil { problem = error.localizedDescription }; if !stopping { failure(error.localizedDescription) }; process.terminate()
            }
        }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(90)); ready.resolve(.failure(ClassScribeError.message("千问识别启动超时，请关闭其他高负载软件后重试。"))); process.terminate() }
            catch {}
        }
        defer { watchdog.cancel() }
        do {
            try await ready.wait()
            try Task.checkCancellation()
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
            inputTask = Task { [self] in
                do {
                    for await input in stream {
                        guard let samples = input.buffer.floatChannelData?[0] else { throw ClassScribeError.message("无法读取千问识别音频缓冲。") }
                        try process.write(Data(bytes: samples, count: Int(input.buffer.frameLength) * MemoryLayout<Float>.size))
                    }
                } catch { if !stopping { problem = error.localizedDescription; failure(error.localizedDescription) } }
            }
            try capture.start(format: format, continuation: continuation, audioURL: audioURL, meter: meter, failure: failure)
        } catch { stopping = true; process.terminate(); await resultsTask?.value; throw error }
    }
    func stop() async -> String? {
        stopping = true
        await capture.stop(); await inputTask?.value; inputTask = nil
        child?.closeInput()
        let child = child
        let deadline = Task { [self] in
            do { try await Task.sleep(for: .seconds(30)); problem = "千问末段识别未能及时结束，已保留已有文字和原音，请回听核对。"; child?.terminate() }
            catch {}
        }
        await resultsTask?.value; resultsTask = nil; deadline.cancel()
        self.child = nil
        return problem
    }
}
