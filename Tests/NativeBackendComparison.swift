import Foundation
import Translation
import Darwin

@main struct NativeBackendComparison {
    @MainActor static func main() async throws {
        guard [5, 6].contains(CommandLine.arguments.count), let backend = SpeechBackend(rawValue: CommandLine.arguments[1]) else {
            throw ClassScribeError.message("backend audio.wav worker.py report.json required")
        }
        let privateInput = CommandLine.arguments.contains("--private")
        let pauseTest = CommandLine.arguments.contains("--pause-test")
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-ASR-comparison-\(UUID())")
        let suite = "ClassScribe.ASRComparison.\(UUID())"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(backend.rawValue, forKey: "speechBackend")
        prefs.set(false, forKey: "contextEnabled")
        prefs.set(false, forKey: "keepAudio")
        let capture = FileAudioCapture(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        let qwen = QwenSpeechEngine(capture: capture, workerURL: URL(fileURLWithPath: CommandLine.arguments[3]))
        let engine: any SpeechRecording = backend == .qwen ? qwen : LocalSpeechEngine(capture: capture)
        let model = AppModel(storageRoot: root, preferences: prefs, engineFactory: { engine }, microphoneAccess: { true })
        model.newLecture()
        let id = model.current!.id
        let translation = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
        let translator = Task { await model.runTranslation(using: translation) }
        defer { translator.cancel() }
        for _ in 0..<200 { if model.translationReady { break }; try await Task.sleep(for: .milliseconds(50)) }
        guard model.translationReady else { throw ClassScribeError.message("Translation assets unavailable") }
        model.speechReady = true
        var firstEnglish: Date?, firstChinese: Date?
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                if firstEnglish == nil && model.current?.segments.contains(where: { !$0.english.isEmpty }) == true { firstEnglish = Date() }
                if firstChinese == nil && model.current?.segments.contains(where: { !$0.chinese.isEmpty }) == true { firstChinese = Date() }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let started = Date()
        await model.start()
        guard model.phase == .listening else { throw ClassScribeError.message(model.errorMessage ?? "Engine did not start") }
        let firstCaptureBegin = capture.began!
        let startupSeconds = Date().timeIntervalSince(started)
        await capture.waitUntilEnded()
        let inputEnd = capture.ended!
        await model.stop()
        let recognitionDrainSeconds = Date().timeIntervalSince(inputEnd)
        var pauseResumePassed: Bool? = nil
        if pauseTest {
            // Repeat a short synthetic utterance after an actual pause/resume.
            // Both runs use the real selected engine, never a fake ASR response.
            await model.start()
            await capture.waitUntilEnded()
            await model.pause()
            let durationBefore = model.current!.duration
            let rowsBefore = model.current!.segments.count
            let paused = model.phase == .paused
            try await Task.sleep(for: .milliseconds(250))
            await model.resume()
            await capture.waitUntilEnded()
            await model.stop()
            pauseResumePassed = paused && model.phase == .idle && model.current!.segments.count > rowsBefore &&
                model.current!.duration >= durationBefore + capture.duration - 0.2 &&
                model.current!.duration < durationBefore + capture.duration + 0.8 &&
                model.current!.segments.dropFirst(rowsBefore).allSatisfy { $0.start >= durationBefore - 0.1 }
        }
        for _ in 0..<600 {
            if model.current?.segments.isEmpty == false && model.current!.segments.allSatisfy({ $0.translationState == .complete }) { break }
            if model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        observer.cancel(); await observer.value
        let rows = model.current!.segments
        let complete = !rows.isEmpty && rows.allSatisfy { !$0.isCollectingParagraph && !$0.hasPreviewTranslation && $0.translationState == .complete }
        let loaded = try model.store!.load().first { $0.id == id }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var report: [String: Any] = ["backend": backend.rawValue, "status": complete && model.errorMessage == nil ? "pass" : "fail",
            "input": privateInput ? "private lecture excerpt replayed at wall-clock pace; no human reference" : "synthetic English audio replayed at wall-clock pace through injected capture",
            "microphone_used": false, "audio_seconds": capture.duration, "replayed_runs": pauseTest ? 3 : 1, "startup_seconds": startupSeconds,
            "recognition_drain_seconds": recognitionDrainSeconds,
            "english": rows.map(\.english).joined(separator: " "), "chinese": rows.map(\.chinese).joined(separator: " "),
            "final_translation_complete": complete, "saved_and_reloaded": loaded?.segments == rows,
            "host_peak_rss_bytes": usage.ru_maxrss, "host_cpu_seconds": cpu,
            "context_review_enabled": false, "private_classroom_audio_used": privateInput,
            "memory_scope": "Host RSS excludes Apple system service processes. Qwen worker RSS and Metal allocations are separate measurements that can overlap; neither is total system RAM.",
            "error": model.errorMessage ?? ""]
        if let pauseResumePassed { report["real_engine_pause_resume_passed"] = pauseResumePassed }
        if let firstEnglish { report["first_english_seconds"] = firstEnglish.timeIntervalSince(firstCaptureBegin) }
        if let firstChinese { report["first_chinese_seconds"] = firstChinese.timeIntervalSince(firstCaptureBegin) }
        if backend == .qwen { report["qwen_peak_mlx_allocation_bytes"] = await qwen.workerPeakMLX; report["qwen_worker_peak_rss_bytes"] = await qwen.workerPeakRSS; report["qwen_worker_cpu_seconds"] = await qwen.workerCPU; report["qwen_model_load_seconds"] = await qwen.modelLoadSeconds }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .atomic)
        await model.finishBeforeQuit(); translator.cancel(); await translator.value
        guard complete && model.errorMessage == nil && loaded?.segments == rows && pauseResumePassed != false else { throw ClassScribeError.message("Comparison pipeline failed; inspect report") }
        print("PASS: \(backend.rawValue), full capture → ASR → real translation → save/reload")
        if !privateInput { print(rows.map(\.english).joined(separator: " ")) }
    }
}
