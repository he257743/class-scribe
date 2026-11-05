import Foundation
import AVFoundation
import Speech
import Translation

@main struct NativeParagraphTest {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("audio path and report path required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-native-paragraph-\(UUID())")
        let suite = "ClassScribe.NativeParagraph.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(storageRoot: root, preferences: preferences)
        model.newLecture()
        let lecture = model.current!
        model.prepareTranscription(for: lecture)
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans"))
        let worker = Task { await model.runTranslation(using: session) }
        defer { worker.cancel() }
        for _ in 0..<200 {
            if model.translationReady || model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard model.translationReady else {
            throw ClassScribeError.message(model.errorMessage ?? "Local translation worker did not become ready")
        }
        let module = try await SpeechAssets.englishModule()
        if let locale = module.selectedLocales.first { try await AssetInventory.reserve(locale: locale) }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw ClassScribeError.message("English speech assets are not installed")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let reader = Task { @MainActor () throws -> Int in
            var finalCount = 0
            for try await result in module.results {
                if result.isFinal { finalCount += 1 }
                let update = RecognitionUpdate(start: max(0, result.range.start.seconds),
                    end: max(0, CMTimeRangeGetEnd(result.range).seconds), text: String(result.text.characters),
                    isFinal: result.isFinal, confidence: nil)
                model.consumeRecognition(update, lectureID: lecture.id, at: update.end)
            }
            return finalCount
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let finalCount = try await reader.value
        model.finishTranscription(for: lecture.id)
        for _ in 0..<400 {
            let segments = model.current?.segments ?? []
            if !segments.isEmpty && segments.allSatisfy({ $0.translationState == .complete }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let rows = model.current?.segments ?? []
        let english = rows.map(\.english).joined(separator: " ")
        guard rows.count == 1, english.lowercased().contains("shared resource"), english.split(separator: " ").count >= 30,
              rows.allSatisfy({ !$0.isCollectingParagraph && !$0.hasPreviewTranslation && $0.translationState == .complete &&
                  $0.chinese.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) }) else {
            throw ClassScribeError.message("Native paragraph pipeline did not produce a complete bilingual paragraph: \(english)")
        }
        model.persist()
        let reopened = try LectureStore(root: root).load()
        guard reopened.first?.segments == rows else { throw ClassScribeError.message("Native paragraph changed after saving") }
        let report: [String: Any] = ["status": "pass", "input": "locally synthesized English audio file",
            "microphone_used": false, "realtime_microphone_tested": false, "asr_final_results": finalCount,
            "paragraphs": rows.map { ["english": $0.english, "chinese": $0.chinese,
                "start": $0.start, "end": $0.end, "source_parts": $0.recognitionParts?.count ?? 0] },
            "actual_app_translation_queue_used": true, "round_trip_preserves_transcript": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        worker.cancel(); await worker.value
        print("PASS: real on-device speech recognition → app paragraph queue → local Chinese translation → save/reload")
        print("ENGLISH: \(english)")
        print("CHINESE: \(rows.map(\.chinese).joined(separator: " "))")
    }
}
