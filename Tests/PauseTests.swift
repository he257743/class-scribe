import Foundation

private final class FakeRecorder: SpeechRecording, @unchecked Sendable {
    var starts = 0
    var stops = 0
    var recording = false
    var offset: Double = 0
    var audioURL: URL?
    var failStart = false
    var stopProblem: String?
    var finalOnStop: RecognitionUpdate?
    var startGate: (() async -> Void)?
    var stopGate: (() async -> Void)?
    private var receiver: (@Sendable (RecognitionUpdate) async -> Void)?
    private var meter: (@Sendable (Double) -> Void)?

    func start(audioURL: URL?, contextualWords: [String], offset: Double,
               receive: @escaping @Sendable (RecognitionUpdate) async -> Void,
               meter: @escaping @Sendable (Double) -> Void,
               failure: @escaping @Sendable (String) -> Void) async throws {
        starts += 1; self.offset = offset; self.audioURL = audioURL
        receiver = receive; self.meter = meter
        if let audioURL { try Data("synthetic recorder fixture".utf8).write(to: audioURL) }
        if let startGate { await startGate() }
        if failStart { throw NSError(domain: "FakeRecorder.Start", code: 1) }
        recording = true
    }

    func stop() async -> String? {
        stops += 1; recording = false
        if let stopGate { await stopGate() }
        if let finalOnStop { await deliver(finalOnStop) }
        return stopProblem
    }

    func deliver(_ update: RecognitionUpdate) async {
        var update = update; update.start += offset; update.end += offset
        await receiver?(update)
    }
    func deliverLateMeter() { meter?(1) }
}

@main struct PauseTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            checks += 1; print("PASS: \(label)")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ClassScribe-pause-tests-\(UUID())")
        var suites: [String] = []
        var models: [AppModel] = []
        defer {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            try? manager.removeItem(at: root)
        }
        var clock = Date(timeIntervalSinceReferenceDate: 10000)
        func makeModel(_ recorders: [FakeRecorder], keepAudio: Bool = true,
                       permissions: @escaping () async -> Bool = { true }) -> AppModel {
            let suite = "ClassScribe.PauseTests.\(UUID())"; suites.append(suite)
            let preferences = UserDefaults(suiteName: suite)!
            preferences.set(false, forKey: "liveChinesePreview")
            preferences.set(keepAudio, forKey: "keepAudio")
            var next = 0
            let model = AppModel(storageRoot: root.appendingPathComponent(UUID().uuidString), preferences: preferences,
                engineFactory: {
                    guard next < recorders.count else { fatalError("Unexpected recorder creation") }
                    defer { next += 1 }; return recorders[next]
                }, microphoneAccess: permissions, recordingNow: { clock })
            models.append(model)
            model.speechReady = true; model.translationReady = true
            model.newLecture()
            return model
        }
        let first = FakeRecorder(), second = FakeRecorder()
        first.finalOnStop = .init(start: 0, end: 4.8, text: "A shared resource.", isFinal: true, confidence: 0.9)
        second.finalOnStop = .init(start: 0, end: 6.4, text: "Only one thread enters.", isFinal: true, confidence: 0.9)
        let model = makeModel([first, second])
        let lectureID = model.current!.id
        await model.pause(); await model.resume(); await model.togglePause()
        check(model.phase == .idle && first.starts == 0, "pause and resume shortcuts while idle cannot start recording")
        await model.start()
        check(model.phase == .listening && first.recording && first.starts == 1,
            "start uses the recording backend only after the permission check")
        await first.deliver(.init(start: 0, end: 4, text: "A shared", isFinal: false, confidence: 0.9))
        clock = clock.addingTimeInterval(5)
        await model.pause()
        check(model.phase == .paused && first.stops == 1 && !first.recording && model.level == 0,
            "pause stops and releases capture before publishing the paused state")
        check(model.current?.segments.first?.english == "A shared resource." &&
              model.current?.segments.first?.isFinal == true && model.pendingJobs.contains(where: { !$0.isPreview }),
            "pause drains final recognition and queues the last paragraph for translation")
        check(model.current?.duration == 5 && model.current?.audio.first?.start == 0 && model.current?.audio.first?.end == 5,
            "pause freezes elapsed time and closes the active audio range")
        let firstFile = first.audioURL!
        let originalAudio = try Data(contentsOf: firstFile)
        clock = clock.addingTimeInterval(600)
        await Task.yield()
        check(model.current?.duration == 5, "ten simulated minutes of pause do not advance class time")
        await model.processNextTranslation { _ in "共享资源。" }
        check(model.phase == .paused && model.current?.segments.first?.chinese == "共享资源。" && model.canExportTranscript,
            "saved text can finish translating and be exported during pause")
        let lectureCount = model.lectures.count
        model.newLecture(); model.requestDeletion(); model.deleteLecture(lectureID); model.enterDemo()
        check(model.lectures.count == lectureCount && model.current?.id == lectureID &&
              model.deletionCandidate == nil && !model.canDeleteLecture && !model.demoMode,
            "paused classroom stays protected from new-class, deletion and demo actions")
        await model.resume()
        check(model.phase == .listening && model.current?.id == lectureID && second.recording && second.offset == 5,
            "resume keeps the same classroom and continues from the accumulated recording time")
        clock = clock.addingTimeInterval(7)
        await model.togglePause()
        check(model.phase == .paused && model.current?.duration == 12 && model.current?.segments.count == 2 &&
              model.current?.segments[1].start == 5 && model.current?.segments.first?.chinese == "共享资源。",
            "a second pause preserves earlier translation and excludes the pause gap from new timestamps")
        let clips = model.current!.audio
        check(clips.count == 2 && clips[0].end == 5 && clips[1].start == 5 && clips[1].end == 12 &&
              firstFile != second.audioURL && (try? Data(contentsOf: firstFile)) == originalAudio,
            "resumed audio uses a separate file without overwriting the first recording")
        let beforeLate = model.current!.segments
        await first.deliver(.init(start: 4, end: 50, text: "Late obsolete words", isFinal: true, confidence: 0.9))
        second.deliverLateMeter(); await Task.yield()
        check(model.current?.segments == beforeLate && model.level == 0,
            "late callbacks from stopped capture cannot add words or change the paused meter")
        await model.stop()
        check(model.phase == .idle && second.stops == 1 && model.current?.duration == 12 && model.canDeleteLecture,
            "ending a paused class unlocks history without stopping the backend twice")
        let loaded = try model.store!.load()
        check(loaded.first?.id == lectureID && loaded.first?.duration == 12 && loaded.first?.audio == clips &&
              loaded.first?.segments == model.current?.segments, "pause and resume data survive saving and reloading")

        var permissionCalls = 0
        let allowed = FakeRecorder(), afterPermission = FakeRecorder()
        let permissionModel = makeModel([allowed, afterPermission], permissions: {
            permissionCalls += 1; return permissionCalls != 2
        })
        await permissionModel.start(); clock = clock.addingTimeInterval(2); await permissionModel.pause()
        await permissionModel.resume()
        check(permissionModel.phase == .paused && permissionModel.errorMessage != nil && afterPermission.starts == 0 &&
              permissionModel.current?.duration == 2, "denied microphone permission on resume leaves the existing class paused")
        await permissionModel.resume()
        check(permissionModel.phase == .listening && afterPermission.offset == 2 && afterPermission.starts == 1,
            "resume can be retried after microphone permission is restored")
        await permissionModel.stop()

        let working = FakeRecorder(), failed = FakeRecorder(), restored = FakeRecorder()
        failed.failStart = true
        let failureModel = makeModel([working, failed, restored])
        await failureModel.start(); clock = clock.addingTimeInterval(3); await failureModel.pause()
        await failureModel.resume()
        check(failureModel.phase == .paused && failed.stops == 1 && failureModel.current?.audio.count == 1 &&
              failureModel.current?.duration == 3 && failed.audioURL.map { !manager.fileExists(atPath: $0.path) } == true,
            "resume failure keeps prior data paused and removes only its unsuccessful new audio file")
        await failureModel.resume()
        check(failureModel.phase == .listening && restored.offset == 3 && failureModel.current?.audio.count == 2,
            "a failed resume does not lose the ability to continue the same class")
        await failureModel.stop()

        let textOnly = FakeRecorder(), textOnlyNext = FakeRecorder()
        let textModel = makeModel([textOnly, textOnlyNext], keepAudio: false)
        await textModel.start(); clock = clock.addingTimeInterval(2); await textModel.togglePause()
        await textModel.togglePause(); clock = clock.addingTimeInterval(3); await textModel.stop()
        let textAudioFiles = try manager.contentsOfDirectory(atPath: textModel.store!.recordings.path)
        check(textOnly.audioURL == nil && textOnlyNext.audioURL == nil && textModel.current?.audio.isEmpty == true &&
              textModel.current?.duration == 5 && textAudioFiles.isEmpty,
            "pause and resume also work in text-only mode without creating phantom audio files")

        let problemRecorder = FakeRecorder()
        problemRecorder.stopProblem = "Final ASR could not finalize"
        let problemModel = makeModel([problemRecorder])
        await problemModel.start()
        await problemRecorder.deliver(.init(start: 0, end: 1, text: "Unfinished words", isFinal: false, confidence: 0.6))
        clock = clock.addingTimeInterval(2); await problemModel.pause()
        check(problemModel.phase == .paused && !problemRecorder.recording && problemModel.errorMessage != nil &&
              problemModel.current?.interrupted == true && problemModel.current?.segments.first?.english == "Unfinished words" &&
              problemModel.current?.segments.first?.isFinal == false,
            "pause with finalization error retains the draft, stops capture and reports the problem")
        await problemModel.finishBeforeQuit()
        check(problemModel.phase == .idle && problemRecorder.stops == 1, "quitting while paused saves without reopening or stopping capture again")

        let gated = FakeRecorder()
        gated.finalOnStop = .init(start: 0, end: 3, text: "The final captured words.", isFinal: true, confidence: 0.9)
        let (stopEntered, stopNotification) = AsyncStream<Void>.makeStream()
        var releaseStop: CheckedContinuation<Void, Never>?
        gated.stopGate = {
            await withCheckedContinuation { continuation in releaseStop = continuation; stopNotification.yield(()) }
        }
        let gatedModel = makeModel([gated])
        await gatedModel.start(); clock = clock.addingTimeInterval(4)
        let pausing = Task { @MainActor in await gatedModel.pause() }
        for await _ in stopEntered { break }
        check(gatedModel.phase == .pausing && !gatedModel.canTogglePause && !gatedModel.canExportTranscript,
            "pause transition is visible and locks commands until final callbacks are drained")
        await gatedModel.pause(); await gatedModel.resume(); await gatedModel.start(); await gatedModel.stop()
        check(gated.stops == 1 && gated.starts == 1 && gatedModel.phase == .pausing,
            "rapid repeated pause, resume and stop clicks cannot overlap capture operations")
        var quitFinished = false
        let (quitEntered, quitNotification) = AsyncStream<Void>.makeStream()
        let quitting = Task { @MainActor in
            quitNotification.yield(())
            await gatedModel.finishBeforeQuit(); quitFinished = true
        }
        for await _ in quitEntered { break }
        check(!quitFinished && gatedModel.phase == .pausing, "quit waits for a pending pause to finish draining recognition")
        releaseStop?.resume(); stopNotification.finish(); quitNotification.finish()
        await pausing.value; await quitting.value
        let finalRecord = try gatedModel.store!.load().first!
        check(quitFinished && gatedModel.phase == .idle && gated.stops == 1 &&
              finalRecord.segments.last?.english == "The final captured words." && finalRecord.duration == 4,
            "quit after a pause transition saves the last captured words exactly once")

        let preparing = FakeRecorder()
        let (startEntered, startNotification) = AsyncStream<Void>.makeStream()
        var releaseStart: CheckedContinuation<Void, Never>?
        preparing.startGate = {
            await withCheckedContinuation { continuation in releaseStart = continuation; startNotification.yield(()) }
        }
        let preparingModel = makeModel([preparing])
        let starting = Task { @MainActor in await preparingModel.start() }
        for await _ in startEntered { break }
        var startupQuitDone = false
        let (startupQuitEntered, startupQuitNotification) = AsyncStream<Void>.makeStream()
        let startupQuitting = Task { @MainActor in
            startupQuitNotification.yield(())
            await preparingModel.finishBeforeQuit(); startupQuitDone = true
        }
        for await _ in startupQuitEntered { break }
        check(!startupQuitDone && preparingModel.phase == .starting, "quit during startup waits for the capture transition safely")
        releaseStart?.resume(); startNotification.finish(); startupQuitNotification.finish()
        await starting.value; await startupQuitting.value
        check(startupQuitDone && preparingModel.phase == .idle && preparing.stops == 1 && !preparing.recording,
            "quit following startup closes capture and leaves no running recorder")
        for model in models where model.phase == .paused { await model.stop() }
        print("\(checks) pause checks passed; injected recorders only, no microphone access")
    }
}
