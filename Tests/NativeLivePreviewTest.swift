import Foundation
import Translation

@main struct NativeLivePreviewTest {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("report path required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-native-preview-\(UUID())")
        let suite = "ClassScribe.NativePreview.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(storageRoot: root, preferences: preferences)
        model.newLecture()
        let id = model.current!.id
        model.prepareTranscription(for: model.current!)
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans"))
        let worker = Task { await model.runTranslation(using: session) }
        defer { worker.cancel() }
        for _ in 0..<200 {
            if model.translationReady || model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard model.translationReady else { throw ClassScribeError.message(model.errorMessage ?? "Translation assets not ready") }
        let a = "A critical section accesses a shared resource."
        let b = a + " A lock makes sure only one thread enters at a time."
        let c = b + " Other threads wait until the lock is released."
        func feed(_ text: String, end: Double) {
            model.consumeRecognition(.init(start: 0, end: end, text: text, isFinal: false, confidence: 0.9),
                lectureID: id, at: Date.timeIntervalSinceReferenceDate)
        }
        func waitForPreview(_ text: String) async throws -> TranscriptSegment {
            for _ in 0..<300 {
                if let item = model.current?.segments.last, item.isCollectingParagraph,
                   item.hasPreviewTranslation, item.translatedSource == text { return item }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ClassScribeError.message("A live preview did not appear before paragraph closure")
        }
        let firstStarted = Date()
        feed(a, end: 4)
        let first = try await waitForPreview(a)
        let firstSeconds = Date().timeIntervalSince(firstStarted)
        let updateStarted = Date()
        feed(b, end: 8)
        guard model.current?.segments.last?.chinese == first.chinese else {
            throw ClassScribeError.message("English growth erased visible Chinese")
        }
        let second = try await waitForPreview(b)
        let updateSeconds = Date().timeIntervalSince(updateStarted)
        feed(c, end: 12)
        model.finishTranscription(for: id)
        for _ in 0..<300 {
            if let item = model.current?.segments.last, !item.hasPreviewTranslation && item.translationState == .complete { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let final = model.current?.segments.last, !final.isCollectingParagraph, !final.hasPreviewTranslation,
              final.translationState == .complete, final.translatedSource == c,
              final.chinese.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else {
            throw ClassScribeError.message("Full paragraph did not replace the previews on stop")
        }
        model.persist()
        guard try model.store!.load().first?.segments.last == final else {
            throw ClassScribeError.message("Final translation did not survive saving")
        }
        let report: [String: Any] = ["status": "pass", "input": "scripted English ASR-text updates; no microphone",
            "actual_app_scheduler_and_translation_queue_used": true, "on_device_apple_translation_used": true,
            "first_preview_seconds": firstSeconds, "updated_preview_seconds": updateSeconds,
            "latency_scope": "ASR text arrival to visible Chinese model state; excludes microphone and ASR latency",
            "first_chinese": first.chinese, "updated_chinese": second.chinese, "final_english": c,
            "final_chinese": final.chinese, "visible_preview_preserved_during_growth": true,
            "final_translation_is_not_a_preview": true, "realtime_microphone_tested": false,
            "real_classroom_tested": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        worker.cancel(); await worker.value
        print(String(format: "PASS: real local preview, first %.2fs, updated %.2fs; ASR latency excluded", firstSeconds, updateSeconds))
        print("PREVIEW: \(first.chinese)")
        print("UPDATED: \(second.chinese)")
        print("FINAL: \(final.chinese)")
    }
}
