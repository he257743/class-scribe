import Foundation
import AVFoundation
import Speech
import Translation

@main struct NativeEngineTest {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("audio path and report path required") }
        let module = try await SpeechAssets.englishModule()
        print("Selected locales: \(module.selectedLocales.map(\.identifier))")
        print("Installed locales: \(await SpeechTranscriber.installedLocales.map(\.identifier))")
        if let locale = module.selectedLocales.first { try await AssetInventory.reserve(locale: locale) }
        let status = await AssetInventory.status(forModules: [module])
        print("Module status: \(status)")
        guard status == .installed else {
            throw ClassScribeError.message("English speech assets not installed")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let analyzer = SpeechAnalyzer(modules: [module])
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["operating system", "semaphore", "mutex", "deadlock", "thread", "process", "critical section", "TCP", "IP", "synchronization"]
        try await analyzer.setContext(context)
        let reader = Task { () throws -> [[String: Any]] in
            var values: [[String: Any]] = []
            for try await result in module.results {
                if result.isFinal {
                    let text = String(result.text.characters)
                    print("FINAL: \(text)")
                    values.append(["english": text, "start": result.range.start.seconds,
                        "end": CMTimeRangeGetEnd(result.range).seconds])
                }
            }
            return values
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let results = try await reader.value
        let recognized = results.compactMap { $0["english"] as? String }.joined(separator: " ")
        guard recognized.lowercased().contains("shared"), recognized.lowercased().contains("resource") else {
            throw ClassScribeError.message("The synthesized fixture was not recognized as expected: \(recognized)")
        }
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans"))
        let response = try await session.translate(recognized)
        guard !response.targetText.isEmpty,
              response.targetText.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else {
            throw ClassScribeError.message("Chinese translation did not produce Chinese text")
        }
        print("CHINESE: \(response.targetText)")
        let report: [String: Any] = ["fixture": "local synthesized English; no user microphone recording",
            "speech": results, "translation": response.targetText, "status": "pass"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    }
}
