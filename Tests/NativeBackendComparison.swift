import Foundation
import Translation
import Darwin

@main struct NativeBackendComparison {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 5,
              CommandLine.arguments.dropFirst(5).allSatisfy({ ["--private", "--pause-test", "--rejection-test", "--quick-qwen"].contains($0) }),
              let backend = SpeechBackend(rawValue: CommandLine.arguments[1]) else {
            throw ClassScribeError.message("backend audio.wav worker.py report.json required")
        }
        let qwenWindow: QwenRecognitionWindow = CommandLine.arguments.contains("--quick-qwen") ? .quick : .context
        let privateInput = CommandLine.arguments.contains("--private")
        let rejectionTest = CommandLine.arguments.contains("--rejection-test")
        let pauseTest = CommandLine.arguments.contains("--pause-test")
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-ASR-comparison-\(UUID())")
        let suite = "ClassScribe.ASRComparison.\(UUID())"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(backend.rawValue, forKey: "speechBackend")
        prefs.set(qwenWindow.rawValue, forKey: "qwenRecognitionWindow")
        prefs.set(false, forKey: "contextEnabled")
        prefs.set(false, forKey: "keepAudio")
        let capture = FileAudioCapture(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        let qwen = QwenSpeechEngine(capture: capture, workerURL: URL(fileURLWithPath: CommandLine.arguments[3]), recognitionWindow: qwenWindow)
        let engine: any SpeechRecording = backend == .qwen ? qwen : LocalSpeechEngine(capture: capture)
        let model = AppModel(storageRoot: root, preferences: prefs, engineFactory: { engine }, microphoneAccess: { true })
        model.newLecture()
        let id = model.current!.id
        let translation = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
        let translator = Task { await model.runTranslation(using: translation) }
        defer { translator.cancel() }
        for _ in 0..<1200 {
            if model.translationReady || model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard model.translationReady else { throw ClassScribeError.message(model.errorMessage ?? "Translation preparation timed out: " + model.translationStatus) }
        model.speechReady = true
        var firstEnglish: Date?, firstChinese: Date?
        var observedRejection = false
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                if model.current?.segments.contains(where: { $0.recognitionWarning != nil }) == true { observedRejection = true }
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
            if model.current?.segments.isEmpty == false && model.current!.segments.allSatisfy({ $0.translationState == .complete || (rejectionTest && $0.recognitionWarning != nil) }) { break }
            if model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        observer.cancel(); await observer.value
        let rows = model.current!.segments
        let rejected = rows.filter { $0.recognitionWarning != nil }
        let good = rows.filter { $0.recognitionWarning == nil }
        let complete = !good.isEmpty && rows.allSatisfy {
            (rejectionTest && $0.recognitionWarning != nil) ||
            (!$0.isCollectingParagraph && !$0.hasPreviewTranslation && $0.translationState == .complete)
        }
        // A longer reliable result may replace a rejected draft of the same window.
        // Check that rejection was visible and later fixture speech was translated,
        // rather than requiring the transient warning to remain forever.
        let recovered = !rejectionTest || (observedRejection && good.contains {
            $0.english.lowercased().contains("mutex") && !$0.chinese.isEmpty
        } && good.map(\.english).joined(separator: " ").lowercased().contains("critical section"))
        let loaded = try model.store!.load().first { $0.id == id }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var report: [String: Any] = ["backend": backend.rawValue, "status": complete && recovered && model.errorMessage == nil ? "pass" : "fail",
            "input": privateInput ? "private lecture excerpt replayed at wall-clock pace; no human reference" : "synthetic English audio replayed at wall-clock pace through injected capture",
            "microphone_used": false, "audio_seconds": capture.duration, "replayed_runs": pauseTest ? 3 : 1, "startup_seconds": startupSeconds,
            "recognition_drain_seconds": recognitionDrainSeconds,
            "english": rows.map(\.english).joined(separator: " "), "chinese": rows.map(\.chinese).joined(separator: " "),
            "final_translation_complete": complete, "saved_and_reloaded": loaded?.segments == rows,
            "host_peak_rss_bytes": usage.ru_maxrss, "host_cpu_seconds": cpu,
            "context_review_enabled": false, "private_classroom_audio_used": privateInput,
            "memory_scope": "Host RSS excludes Apple system service processes. Qwen worker RSS and Metal allocations are separate measurements that can overlap; neither is total system RAM.",
            "error": model.errorMessage ?? ""]
        if rejectionTest { report["retained_rejected_windows"] = rejected.count; report["rejection_observed"] = observedRejection; report["normal_speech_translated_after_rejection"] = recovered; report["final_rows_saved_without_loss"] = loaded?.segments == rows }
        if backend == .qwen {
            report["recognition_window"] = qwenWindow.rawValue
            report["recognition_window_seconds"] = qwenWindow.seconds
            report["max_recognition_part_seconds"] = rows.flatMap { $0.recognitionParts ?? [] }.map { $0.end - $0.start }.max() ?? 0
        }
        if let pauseResumePassed { report["real_engine_pause_resume_passed"] = pauseResumePassed }
        if let firstEnglish { report["first_english_seconds"] = firstEnglish.timeIntervalSince(firstCaptureBegin) }
        if let firstChinese { report["first_chinese_seconds"] = firstChinese.timeIntervalSince(firstCaptureBegin) }
        if backend == .qwen { report["qwen_peak_mlx_allocation_bytes"] = await qwen.workerPeakMLX; report["qwen_worker_peak_rss_bytes"] = await qwen.workerPeakRSS; report["qwen_worker_cpu_seconds"] = await qwen.workerCPU; report["qwen_model_load_seconds"] = await qwen.modelLoadSeconds }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .atomic)
        await model.finishBeforeQuit(); translator.cancel(); await translator.value
        guard complete && recovered && model.errorMessage == nil && loaded?.segments == rows && pauseResumePassed != false else { throw ClassScribeError.message("Comparison pipeline failed; inspect report") }
        print("PASS: \(backend.rawValue), full capture → ASR → real translation → save/reload")
        if !privateInput { print(rows.map(\.english).joined(separator: " ")) }
    }
}
