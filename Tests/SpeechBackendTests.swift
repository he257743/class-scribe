import Foundation

actor SetupFixture: QwenPreparing {
    var isAvailable = false
    var calls = 0
    var delay: Double = 0.05
    func available() -> Bool { isAvailable }
    func setDelay(_ value: Double) { delay = value; isAvailable = false }
    func count() -> Int { calls }
    func prepare(progress: @escaping @Sendable (Double, String) async -> Void) async throws {
        calls += 1
        await progress(0.4, "Synthetic setup progress")
        try await Task.sleep(for: .seconds(delay))
        isAvailable = true
        await progress(1, "Synthetic components ready")
    }
}

final class MissingQwenFixture: SpeechRecording {
    func start(audioURL: URL?, contextualWords: [String], offset: Double,
               receive: @escaping @Sendable (RecognitionUpdate) async -> Void,
               meter: @escaping @Sendable (Double) -> Void,
               failure: @escaping @Sendable (String) -> Void) async throws { throw ClassScribeError.qwenAssetsUnavailable }
    func stop() async -> String? { nil }
}

@main struct SpeechBackendTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1; print("PASS: " + message)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-backend-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ClassScribe.BackendTests.\(UUID())"; let prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "contextEnabled")
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let legacy = QwenInstallation(root: root.appendingPathComponent("legacy-runtime"))
        try FileManager.default.createDirectory(at: legacy.python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy.model, withIntermediateDirectories: true)
        try Data().write(to: legacy.python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacy.python.path)
        try Data().write(to: legacy.model.appendingPathComponent("model.safetensors"))
        try Data("{\"ready\":true}".utf8).write(to: legacy.root.appendingPathComponent("ready.json"))
        check(!legacy.ready, "old ASR components require the speech-detection upgrade")
        try Data("{\"ready\":true,\"runtime_revision\":2}".utf8).write(to: legacy.root.appendingPathComponent("ready.json"))
        check(legacy.ready, "successful speech-detection preparation enables the upgraded component revision")
        let setup = SetupFixture()
        let model = AppModel(storageRoot: root.appendingPathComponent("records"), preferences: prefs, qwenAssets: setup)
        check(model.speechBackend == .apple, "existing installations retain Apple as the default recognizer")
        check(model.makeSpeechEngine() is LocalSpeechEngine, "Apple selection constructs the native recognizer without starting it")
        model.speechBackend = .qwen
        check(model.makeSpeechEngine() is QwenSpeechEngine, "Qwen selection routes to the local Qwen recognizer")
        check(prefs.string(forKey: "speechBackend") == "qwen", "recognizer selection is persisted")
        await model.refreshSpeechAvailability()
        check(!model.speechReady && model.speechStatus.contains("千问"), "missing Qwen components have their own readiness state")
        model.translationReady = true
        model.prepareLanguages()
        check(model.speechPreparing, "component preparation starts before listening can be enabled")
        for _ in 0..<200 { if model.speechReady { break }; try await Task.sleep(for: .milliseconds(10)) }
        let count = await setup.count()
        check(count == 1 && model.speechReady && !model.speechPreparing, "Qwen setup completion updates selected-backend readiness")
        await setup.setDelay(5)
        model.speechReady = false; model.prepareLanguages()
        for _ in 0..<100 { if await setup.count() == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        model.cancelSpeechPreparation()
        for _ in 0..<100 { if !model.speechPreparing { break }; try await Task.sleep(for: .milliseconds(10)) }
        check(!model.speechPreparing && !model.speechReady && model.errorMessage == nil,
            "cancelling setup releases preparation state without a false ready flag")
        model.speechReady = false; model.prepareLanguages()
        for _ in 0..<100 { if await setup.count() == 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
        await model.finishBeforeQuit()
        check(!model.speechPreparing && !model.speechReady, "quit cancels a pending ASR preparation before returning")
        let missing = QwenSpeechEngine(installation: QwenInstallation(root: root.appendingPathComponent("missing")),
            workerURL: root.appendingPathComponent("unused.py"))
        var needsSetup = false
        do { try await missing.start(audioURL: nil, contextualWords: [], offset: 0, receive: { _ in }, meter: { _ in }, failure: { _ in }) }
        catch { needsSetup = error.localizedDescription.contains("准备千问") }
        check(needsSetup, "missing Qwen components fail before any microphone capture or process is started")
        let reopened = AppModel(storageRoot: root.appendingPathComponent("reopened"), preferences: prefs, qwenAssets: setup)
        check(reopened.speechBackend == .qwen, "selected recognizer survives reopening")
        await model.finishBeforeQuit(); await reopened.finishBeforeQuit()

        let unavailable = AppModel(storageRoot: root.appendingPathComponent("unavailable"), preferences: prefs,
            engineFactory: { MissingQwenFixture() }, microphoneAccess: { true }, qwenAssets: setup)
        unavailable.newLecture(); unavailable.speechReady = true; unavailable.translationReady = true
        await unavailable.start()
        check(!unavailable.speechReady && unavailable.phase == .idle, "lost Qwen files reset readiness so component preparation reappears")
        check(unavailable.current != nil && unavailable.errorMessage?.contains("准备千问") == true,
            "missing-component failure preserves the classroom and an actionable explanation")
        await unavailable.finishBeforeQuit()

        let process = JSONLineProcess()
        let code = "import sys,json;print(json.dumps({'kind':'ready'}),flush=True);data=sys.stdin.buffer.read();print(json.dumps({'bytes':len(data)}),flush=True)"
        try process.launch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-c", code],
            environment: ProcessInfo.processInfo.environment, logURL: root.appendingPathComponent("protocol.log"))
        let watchdog = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { process.terminate() } }
        var iterator = process.stream.makeAsyncIterator()
        let start = Date()
        let ready = try await iterator.next()
        check(ready != nil && String(data: ready!, encoding: .utf8)!.contains("ready") && Date().timeIntervalSince(start) < 2,
            "small ready messages arrive before EOF and cannot deadlock startup")
        try process.write(Data([1, 2, 3, 4, 5])); process.closeInput()
        let result = try await iterator.next()
        check(result != nil && String(data: result!, encoding: .utf8)!.contains("5"), "anonymous pipe preserves audio bytes until an explicit end of input")
        let end = try await iterator.next(); watchdog.cancel()
        check(end == nil, "normal child shutdown drains final messages and closes the stream")
        var refused = false
        do { try process.write(Data([1])) } catch { refused = true }
        check(refused, "writes after shutdown throw instead of crashing the application")

        let closedInput = JSONLineProcess()
        try closedInput.launch(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", "-c", "import os,sys,time;os.close(0);print('ready',flush=True);time.sleep(2)"],
            environment: ProcessInfo.processInfo.environment, logURL: root.appendingPathComponent("closed-input.log"))
        var closedIterator = closedInput.stream.makeAsyncIterator()
        _ = try await closedIterator.next()
        var brokenPipeHandled = false
        do { try closedInput.write(Data([1, 2, 3])) } catch { brokenPipeHandled = true }
        closedInput.terminate()
        do { while try await closedIterator.next() != nil {} } catch {}
        check(brokenPipeHandled, "a live child closing stdin reports a broken pipe without SIGPIPE terminating the app")

        let oversized = JSONLineProcess()
        try oversized.launch(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", "-c", "import sys;sys.stdout.write('x'*200000);sys.stdout.flush();sys.stdin.read()"],
            environment: ProcessInfo.processInfo.environment, logURL: root.appendingPathComponent("oversize.log"))
        var bounded = false
        do { for try await _ in oversized.stream {} } catch { bounded = true }
        oversized.terminate()
        check(bounded, "oversized protocol output is rejected with bounded memory")
        print("\(checks) speech backend checks passed; no microphone and no model inference")
    }
}
