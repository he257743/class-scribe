import Foundation

@main struct TranscriptTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        var segments: [TranscriptSegment] = []
        let draft = RecognitionUpdate(start: 0, end: 1, text: "A shared", isFinal: false, confidence: nil)
        _ = TranscriptTimeline.ingest(draft, into: &segments)
        _ = TranscriptTimeline.ingest(.init(start: 0, end: 2, text: "A shared resource.", isFinal: false, confidence: nil), into: &segments)
        check(segments.count == 1 && segments[0].english == "A shared resource.", "volatile ranges replace earlier drafts")
        let stable = RecognitionUpdate(start: 0, end: 2, text: "A shared resource.", isFinal: true, confidence: 0.91)
        let stableID = TranscriptTimeline.ingest(stable, into: &segments)
        check(stableID != nil && segments.count == 1 && segments[0].isFinal, "final replaces matching volatile range")
        segments[0].chinese = "共享资源。"; segments[0].translationState = .complete
        let duplicate = TranscriptTimeline.ingest(stable, into: &segments)
        check(duplicate == nil && segments[0].chinese == "共享资源。", "duplicate final preserves translation")
        _ = TranscriptTimeline.ingest(.init(start: 2, end: 4, text: "Use a mutex.", isFinal: true, confidence: 0.6), into: &segments)
        check(segments.count == 2 && segments[1].start == 2 && segments[1].needsReview, "adjacent final remains separate and low confidence is flagged")
        _ = TranscriptTimeline.ingest(.init(start: -1, end: 5, text: "bad", isFinal: true, confidence: nil), into: &segments)
        _ = TranscriptTimeline.ingest(.init(start: 5, end: 4, text: "bad", isFinal: true, confidence: nil), into: &segments)
        _ = TranscriptTimeline.ingest(.init(start: 4, end: 5, text: "  ", isFinal: true, confidence: nil), into: &segments)
        check(segments.count == 2, "invalid ranges and empty results are ignored")
        var edited = segments[0]
        edited.english = "A corrected sentence."
        check(!edited.applyTranslation("旧译文", forSource: "A shared resource.") && edited.chinese == "共享资源。", "stale translation cannot overwrite revised source")
        edited.translationState = .edited; edited.chinese = "人工核对。"
        check(!edited.applyTranslation("机器覆盖", forSource: edited.english) && edited.chinese == "人工核对。", "manual translation survives a late machine response")
        edited.translationState = .pending
        check(edited.applyTranslation("新的译文。", forSource: edited.english) && edited.translationState == .complete, "matching source accepts a fresh translation")
        check(TranscriptSegment.time(3661.9) == "01:01:01", "long lecture timestamps")
        check(TranscriptExport.srtTime(59.9996) == "00:01:00,000", "subtitle milliseconds roll over correctly")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root)
        var lecture = Lecture(title: "测试课堂 A & B <C>")
        lecture.segments = segments
        lecture.segments[1].translationState = .translating
        lecture.interrupted = true
        lecture.duration = 4
        try store.save(lecture)
        try store.save(lecture)
        let loaded = try store.load()
        check(loaded.count == 1 && loaded[0].id == lecture.id && loaded[0].interrupted, "atomic overwrite and interrupted-session recovery")
        check(loaded[0].segments[1].translationState == .pending, "unfinished translation is retryable after restart")
        let exported = TranscriptExport.text(lecture)
        check(exported.contains("共享资源。") && exported.contains("Use a mutex.") && exported.contains("建议回听"), "bilingual text retains source, translation and review notice")
        let srt = TranscriptExport.srt(lecture)
        check(srt.contains("00:00:02,000 --> 00:00:04,000") && srt.contains("〔尚未翻译〕"), "SRT includes time ranges and honest pending-translation label")
        check(TranscriptExport.xml("A & B <C> \"D\"\u{0001}") == "A &amp; B &lt;C&gt; &quot;D&quot;", "DOCX XML escaping and control-character filtering")
        if let output = ProcessInfo.processInfo.environment["CLASSSCRIBE_TEST_DOCX"] {
            try TranscriptExport.docx(lecture, to: URL(fileURLWithPath: output))
            check(FileManager.default.fileExists(atPath: output), "DOCX export writes a standalone file")
        }
        print("\(count) checks passed")
    }
}
