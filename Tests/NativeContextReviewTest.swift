import Foundation

@main struct NativeContextReviewTest {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("report path required") }
        let service = LocalContextService()
        guard try await service.availability(for: .larger) == .ready else {
            throw ClassScribeError.message("Prepare qwen3:1.7b before running the optional context test.")
        }
        struct Example {
            var name: String
            var original: String
            var chinese: String
            var later: String
            var domain: CourseDomain
            var expectedEnglish: String
            var expectedChinese: String?
        }
        let examples = [
            Example(name: "misheard mutex", original: "This mute X protects the shared resource.",
                chinese: "这个静音 X 保护共享资源。", later: "A mutex provides mutual exclusion. Only one thread can hold a mutex.",
                domain: .operatingSystems, expectedEnglish: "This mutex protects the shared resource.", expectedChinese: "这个互斥锁 保护共享资源。"),
            Example(name: "misheard cache", original: "The cash stores frequently used data.",
                chinese: "现金存储常用数据。", later: "The cache sits between the CPU and main memory.",
                domain: .computerScience, expectedEnglish: "The cache stores frequently used data.", expectedChinese: "缓存存储常用数据。"),
            Example(name: "network port sense", original: "Open the port.", chinese: "打开港口。",
                later: "The TCP port is used by the server.", domain: .networks,
                expectedEnglish: "Open the port.", expectedChinese: "打开端口。"),
            Example(name: "literal cash preserved", original: "I brought cash to buy the textbook.",
                chinese: "我带了现金来买课本。", later: "We use this money to buy books.", domain: .computerScience,
                expectedEnglish: "I brought cash to buy the textbook.", expectedChinese: nil),
            Example(name: "literal cash before a cache topic", original: "I brought cash to buy the textbook.",
                chinese: "我带了现金来买课本。", later: "Now turn to the cache between the CPU and main memory.",
                domain: .computerScience, expectedEnglish: "I brought cash to buy the textbook.", expectedChinese: nil),
            Example(name: "harbour before a networking topic", original: "The ship arrived at the port.",
                chinese: "船抵达港口。", later: "Now configure a TCP port on the server.",
                domain: .networks, expectedEnglish: "The ship arrived at the port.", expectedChinese: nil),
            Example(name: "critical section sense", original: "A critical section accesses shared data.",
                chinese: "关键部分访问共享数据。", later: "Only one thread may enter the critical section at a time.",
                domain: .operatingSystems, expectedEnglish: "A critical section accesses shared data.", expectedChinese: "临界区访问共享数据。"),
            Example(name: "correct terminology preserved", original: "A mutex protects the shared resource.",
                chinese: "互斥锁保护共享资源。", later: "A mutex provides mutual exclusion.", domain: .operatingSystems,
                expectedEnglish: "A mutex protects the shared resource.", expectedChinese: nil)
        ]
        var reports: [[String: Any]] = []
        for example in examples {
            var lecture = Lecture(title: "Synthetic context example")
            lecture.segments = [
                TranscriptSegment(start: 0, end: 5, english: example.original, chinese: example.chinese,
                    isFinal: true, confidence: 0.6, translationState: .complete, paragraphComplete: true),
                TranscriptSegment(start: 5, end: 12, english: example.later, isFinal: false,
                    confidence: nil, paragraphComplete: false)
            ]
            let window = ContextReviewWindow.make(lecture: lecture, domain: example.domain,
                custom: "", subject: "", model: .larger)!
            let began = Date()
            let patches = try await service.review(window)
            let seconds = Date().timeIntervalSince(began)
            var accepted = 0
            for patch in patches {
                if let revision = ContextReviewPolicy.revision(patch, window: window), patch.index == 0,
                   lecture.segments[0].applyContextRevision(revision, expectedPrevious: nil) { accepted += 1 }
            }
            let row = lecture.segments[0]
            let passed: Bool
            if let chinese = example.expectedChinese {
                passed = row.presentedEnglish.caseInsensitiveCompare(example.expectedEnglish) == .orderedSame && row.presentedChinese == chinese
            } else { passed = accepted == 0 && row.presentedEnglish == example.original && row.presentedChinese == example.chinese }
            let entry: [String: Any] = ["name": example.name, "passed": passed, "source_english": example.original,
                "initial_chinese": example.chinese, "later_english": example.later,
                "displayed_english": row.presentedEnglish, "displayed_chinese": row.presentedChinese,
                "service_proposals": patches.count, "accepted_revisions": accepted, "seconds": seconds,
                "reasons": patches.map(\.reason), "replacements": patches.flatMap(\.replacements).map { ["from": $0.from, "to": $0.to] }]
            reports.append(entry)
            print("\(passed ? "PASS" : "FAIL"): \(example.name), \(String(format: "%.2f", seconds))s")
            print("EN: \(row.presentedEnglish)")
            print("ZH: \(row.presentedChinese)")
        }
        // Exercise the actual application scheduler and persistent record layer
        // with the real local model, without opening an audio input.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-native-context-\(UUID())")
        let suite = "ClassScribe.NativeContext.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        preferences.set(ContextModel.larger.rawValue, forKey: "contextModel")
        let model = AppModel(storageRoot: root, preferences: preferences, contextService: service, contextInterval: 0.1)
        var lecture = Lecture(title: "Synthetic end-to-end context check")
        lecture.segments = [
            TranscriptSegment(start: 0, end: 4, english: "The cash stores frequently used data.",
                chinese: "现金存储常用数据。", isFinal: true, confidence: 0.6,
                translationState: .complete, paragraphComplete: true),
            TranscriptSegment(start: 4, end: 10, english: "The cache sits between the CPU and main memory.",
                isFinal: false, confidence: nil, paragraphComplete: false)
        ]
        model.lectures = [lecture]; model.selectedID = lecture.id; model.contextReady = true
        let began = Date()
        model.scheduleContextReview(for: lecture.id)
        for _ in 0..<900 {
            if model.current?.segments[0].activeContextRevision != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let row = model.current!.segments[0]
        let reloaded = try model.store!.load().first?.segments.first
        let schedulerPassed = row.presentedEnglish == "The cache stores frequently used data." &&
            row.presentedChinese == "缓存存储常用数据。" && row.english == lecture.segments[0].english &&
            row.chinese == lecture.segments[0].chinese && reloaded == row
        reports.append(["name": "actual application scheduler and save reload", "passed": schedulerPassed,
            "seconds": Date().timeIntervalSince(began), "displayed_english": row.presentedEnglish,
            "displayed_chinese": row.presentedChinese, "original_preserved": row.english == lecture.segments[0].english,
            "persistent_round_trip": reloaded == row])
        print("\(schedulerPassed ? "PASS" : "FAIL"): real model + app scheduler + persistence")
        await model.finishBeforeQuit()
        let report: [String: Any] = ["model": ContextModel.larger.rawValue,
            "input": "synthetic English ASR-text snapshots; not classroom audio", "microphone_used": false,
            "actual_local_model_and_policy_used": true,
            "on_device_apple_translation_used_for_term_alignment": true, "thinking_enabled": true, "num_ctx": 4096,
            "fixtures_used_during_development": true, "independent_accuracy_benchmark": false,
            "latency_scope": "local context request to validated revision; excludes microphone, ASR and UI rendering",
            "all_passed": reports.allSatisfy { $0["passed"] as? Bool == true }, "examples": reports]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        await service.shutdown()
        guard reports.allSatisfy({ $0["passed"] as? Bool == true }) else {
            throw ClassScribeError.message("One or more real-model examples did not meet the declared expectations; inspect the report.")
        }
    }
}
