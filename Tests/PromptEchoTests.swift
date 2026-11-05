import Foundation
@main struct PromptEchoTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); count += 1; print("PASS: " + label)
        }
        let echo = "Transcribe the English lecture faithfully. Technical vocabulary: mutex, thread, process."
        var row = TranscriptSegment(start: 0, end: 4, english: echo, chinese: "内部提示的错误机器译文。",
            isFinal: true, confidence: nil, translationState: .complete, paragraphComplete: true)
        check(row.recognitionWarning != nil && row.needsReview, "saved prompt echoes are explicitly flagged for review")
        check(row.english == echo && row.chinese == "内部提示的错误机器译文。", "flagging never deletes original recognition or translation")
        check(!row.presentedEnglish.contains("Technical vocabulary") && row.presentedChinese.isEmpty,
            "the normal classroom view does not present internal hints as lecture content")
        check(!row.applyTranslation("错误的新译文。", forSource: echo), "flagged hints cannot receive an ordinary final translation")
        var lecture = Lecture(title: "Synthetic regression fixture");lecture.segments=[row]
        let txt=TranscriptExport.text(lecture)
        check(txt.contains("异常识别原文（仅供核查）") && txt.contains(echo), "text export preserves anomalous raw text under a clear audit label")
        check(!TranscriptExport.srt(lecture).contains("Technical vocabulary"), "subtitles do not publish prompt echoes as subtitles")
        check(TranscriptExport.srt(lecture).contains("识别异常"), "subtitles mark the affected time range for audio review")
        lecture.segments.append(TranscriptSegment(start:4,end:8,english:"A mutex protects a resource.",isFinal:true,confidence:nil))
        check(ContextReviewWindow.make(lecture:lecture,domain:.operatingSystems,custom:"",subject:"",model:.larger)==nil,
            "the text context model cannot build a correction from known contaminated recognition")
        let valid = TranscriptSegment(start: 8, end: 12, english: "A mutex protects a resource.",
            chinese: "互斥锁保护资源。", isFinal: true, confidence: nil, translationState: .complete, paragraphComplete: true)
        var mixed = Lecture(title: "Synthetic mixed fixture")
        mixed.segments = [valid, row, valid]
        let mixedWindow = ContextReviewWindow.make(lecture: mixed, domain: .operatingSystems,
            custom: "", subject: "", model: .larger)
        check(mixedWindow != nil && mixedWindow!.entries.allSatisfy { $0.id != row.id },
            "contaminated rows cannot serve as context evidence for otherwise valid paragraphs")
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-prompt-tests-\(UUID())")
        let suite="ClassScribe.PromptTests.\(UUID())";let prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"contextEnabled")
        defer { prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:directory) }
        let model=AppModel(storageRoot:directory,preferences:prefs)
        lecture.segments=[row];model.lectures=[lecture];model.selectedID=lecture.id
        model.retryTranslations(allRecords:true)
        var calls=0
        while await model.processNextTranslation(using:{ _ in calls += 1; return "不得调用。" }) {}
        check(calls==0, "retrying translations never sends contaminated rows to the translator")
        model.edit(row.id,english:"A mutex protects a resource.",chinese:"互斥锁保护资源。")
        check(model.current!.segments[0].recognitionWarning==nil && model.current!.segments[0].edited,
            "human correction clears the warning and remains protected")
        await model.finishBeforeQuit()
        row.edited=true
        check(row.recognitionWarning==nil, "a human-confirmed quotation is not automatically hidden")
        check(!RecognitionSanity.isPromptEcho("Our technical vocabulary includes mutex and thread."),
            "ordinary discussion of technical vocabulary is not flagged")
        print("\(count) prompt echo checks passed; synthetic fixtures, no microphone")
    }
}
