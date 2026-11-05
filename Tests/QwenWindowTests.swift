import Foundation
@main struct QwenWindowTests {
    @MainActor static func main() async throws {
        var count=0
        func check(_ value:@autoclosure()->Bool,_ label:String) {
            precondition(value(),label);count += 1;print("PASS: "+label)
        }
        check(QwenRecognitionWindow.context.accepts(duration:31.5),"context mode accepts the complete EOF lookahead range")
        check(!QwenRecognitionWindow.context.accepts(duration:31.7),"context mode still rejects an unbounded result range")
        check(QwenRecognitionWindow.quick.accepts(duration:12) && !QwenRecognitionWindow.quick.accepts(duration:30),"quick mode enforces its shorter protocol range")
        check(!QwenRecognitionWindow.context.accepts(duration:.nan) && !QwenRecognitionWindow.context.accepts(duration:0),"invalid time ranges remain rejected")
        let suite="ClassScribe.WindowTests.\(UUID())";let prefs=UserDefaults(suiteName:suite)!
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-window-\(UUID())")
        prefs.set(false,forKey:"contextEnabled")
        defer {prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        let model=AppModel(storageRoot:root,preferences:prefs)
        check(model.qwenRecognitionWindow == .context,"existing and new installations default to longer ASR context")
        model.speechBackend = .qwen;model.qwenRecognitionWindow = .quick
        check((model.makeSpeechEngine() as? QwenSpeechEngine)?.recognitionWindow == .quick,"selected recognition window is passed to the actual Qwen engine")
        let reopened=AppModel(storageRoot:root,preferences:prefs)
        check(reopened.qwenRecognitionWindow == .quick,"recognition pace survives reopening")
        model.newLecture();let lecture=model.current!;model.prepareTranscription(for:lecture)
        model.consumeRecognition(.init(start:0,end:3,text:"A temporary short draft.",isFinal:false,confidence:nil),lectureID:lecture.id,at:0)
        let priorID=model.current!.segments[0].id
        model.consumeRecognition(.init(start:0,end:30,text:"A longer context corrects the draft.",isFinal:true,confidence:nil),lectureID:lecture.id,at:1)
        check(model.current!.segments.count==1 && model.current!.segments[0].id==priorID && model.current!.segments[0].end==30,
            "long final recognition revises the existing draft row without duplicate paragraphs")
        model.finishTranscription(for:lecture.id)
        while await model.processNextTranslation(using:{ _ in "更长的上下文修订草稿。" }) {}
        check(model.current!.segments[0].chinese=="更长的上下文修订草稿。","revised long-context content continues through the translation queue")
        check(RecognitionSanity.issue("Broken \u{FFFD} character",seconds:5) == .invalidEncoding,"historical damaged characters are explicitly marked for audio review")
        await model.finishBeforeQuit();await reopened.finishBeforeQuit()
        print("\(count) recognition window checks passed; isolated data, no microphone")
    }
}
