import Foundation
@main struct RepetitionTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); count += 1; print("PASS: " + label)
        }
        let loop = String(repeating: "An example packet crossed the network, ", count: 64)
        check(RecognitionSanity.issue(loop, seconds: 9) == .repetition, "historical phrase loops are flagged")
        check(RecognitionSanity.issue("A good prefix. " + String(repeating: "from, ", count: 180), seconds: 28) == .repetition,
            "a runaway tail is flagged without deleting its prefix")
        check(RecognitionSanity.issue("No, no, no. Do not unlock the mutex.", seconds: 3) == nil,
            "ordinary repeated emphasis remains unchanged")
        check(RecognitionSanity.issue(String(repeating: "An example packet crossed the network. ", count: 10), seconds: 60) == nil,
            "plausible slow phrase practice is not silently removed")
        let historical = TranscriptSegment(start: 0, end: 9, english: loop, chinese: "异常重复的旧译文。", isFinal: false, confidence: nil)
        check(historical.recognitionWarning != nil && historical.presentedChinese.isEmpty && historical.english == loop,
            "existing records retain raw loops but hide them from the normal bilingual view")
        var buffer = ParagraphBuffer(targetDuration: 25)
        _ = buffer.ingest(.init(start: 0,end: 3,text: "A mutex protects a resource.",isFinal: true,confidence: nil),at: 0)
        _ = buffer.ingest(.init(start: 3,end: 6,text: "Unreliable draft.",isFinal: false,confidence: nil),at: 1)
        let prior = buffer.render()
        _ = buffer.ingest(.init(start: 3,end: 9,text: String(repeating: "from ",count: 32),isFinal: true,
            confidence: nil,recognitionIssue: .repetition),at: 2)
        _ = buffer.ingest(.init(start: 9,end: 13,text: "The next lecture paragraph is clear.",isFinal: true,confidence: nil),at: 3)
        buffer.finish()
        let rows = buffer.render(reusing: prior)
        check(rows.count == 3 && rows[0].recognitionWarning == nil && rows[1].recognitionWarning != nil && rows[2].recognitionWarning == nil,
            "rejected windows are isolated from valid adjacent paragraphs")
        check(!rows.map(\.english).joined().contains("Unreliable draft."), "rejection replaces the stale overlapping draft")
        var lecture = Lecture(title: "Synthetic runaway regression");lecture.segments=rows
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-loop-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LectureStore(root:dir)
        try store.save(lecture)
        let loaded = try store.load().first!
        check(loaded.segments[1].recognitionParts?.first?.recognitionIssue == .repetition,
            "rejection metadata and raw recognition survive save/reload")
        let txt = TranscriptExport.text(loaded)
        check(txt.contains("异常识别原文（仅供核查）") && txt.contains(rows[1].english), "text export retains rejected output under an audit label")
        check(!TranscriptExport.srt(loaded).contains("from from"), "subtitles do not repeat rejected content")
        let suite="ClassScribe.RepetitionTests.\(UUID())";let prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"contextEnabled")
        defer { prefs.removePersistentDomain(forName:suite) }
        let model=AppModel(storageRoot:dir.appendingPathComponent("app"),preferences:prefs)
        model.lectures=[lecture];model.selectedID=lecture.id
        model.retryTranslations(allRecords:true)
        var translated:[String]=[]
        while await model.processNextTranslation(using: { source in translated.append(source);return "合成译文。" }) {}
        check(translated.count==2 && !translated.contains(where:{$0.contains("from from")}),
            "translations continue for good neighbors and never translate the rejected loop")
        model.edit(rows[1].id,english:"Confirmed repetition.",chinese:"人工确认。")
        check(model.current!.segments[1].recognitionWarning==nil, "human correction overrides the review flag")
        await model.finishBeforeQuit()
        let legacy = Data("{\"start\":0,\"end\":3,\"english\":\"Legacy record.\",\"isFinal\":true,\"translationState\":\"pending\",\"chinese\":\"\",\"edited\":false,\"id\":\"00000000-0000-0000-0000-000000000001\"}".utf8)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self,from:legacy)
        check(decoded.recognitionIssue==nil, "older record schemas remain readable")
        print("\(count) repetition checks passed; synthetic data, no microphone")
    }
}
