import Foundation

@main struct ParagraphTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            count += 1; print("PASS: \(label)")
        }
        func update(_ start: Double, _ end: Double, _ text: String, final: Bool = true,
                    confidence: Double = 0.9) -> RecognitionUpdate {
            .init(start: start, end: end, text: text, isFinal: final, confidence: confidence)
        }
        let a = "A critical section accesses a shared resource."
        let b = "A mutex allows only one thread to enter."
        let c = "Other threads wait until the lock is released."
        var buffer = ParagraphBuffer()
        buffer.ingest(update(0, 5, a), at: 1)
        buffer.ingest(update(5.2, 11, b, confidence: 0.6), at: 2)
        var rows = buffer.render()
        check(rows.count == 1 && rows[0].english == a + " " + b && rows[0].isCollectingParagraph,
            "multiple final sentences form one open paragraph in original order")
        check(rows[0].recognitionParts?.map(\.text) == [a, b] && rows[0].start == 0 && rows[0].end == 11,
            "original recognition text and individual time ranges are retained")
        check(rows[0].isFinal && rows[0].needsReview && rows[0].confidence == 0.6,
            "recognition finality and low confidence survive paragraph aggregation")
        check(!buffer.closeAfterPause(at: 4.9), "brief pauses do not prematurely split a paragraph")
        check(buffer.closeAfterPause(at: 5), "three-second recognition pause closes a complete paragraph")
        rows = buffer.render(reusing: rows)
        check(!rows[0].isCollectingParagraph, "pause makes paragraph ready for whole-text translation")
        rows[0].chinese = "临界区访问共享资源。互斥锁只允许一个线程进入。"
        rows[0].translationState = .complete
        let sealedID = rows[0].id
        buffer.ingest(update(11.2, 16, c), at: 6)
        rows = buffer.render(reusing: rows)
        check(rows.count == 2 && rows[0].id == sealedID && !rows[0].chinese.isEmpty && rows[1].isCollectingParagraph,
            "new speech cannot merge into or erase a completed paragraph translation")
        check(!buffer.ingest(update(11.2, 16, c), at: 7), "duplicate final delivery is ignored")

        var corrected = ParagraphBuffer()
        corrected.ingest(update(0, 3, "A mute", final: false), at: 1)
        corrected.ingest(update(0, 5, a), at: 2)
        corrected.ingest(update(5, 10, b), at: 3)
        let correctionRows = corrected.render()
        check(correctionRows.count == 1 && correctionRows[0].english == a + " " + b &&
              !(correctionRows[0].recognitionParts?.contains { $0.text == "A mute" } ?? true),
            "ASR draft revision replaces old words without duplicated or fabricated text")

        var timed = ParagraphBuffer()
        for (index, text) in [a, b, c].enumerated() {
            timed.ingest(update(Double(index * 9), Double((index + 1) * 9), text), at: Double(index))
        }
        let timedRows = timed.render()
        check(timedRows.count == 1 && !timedRows[0].isCollectingParagraph && timedRows[0].english == [a,b,c].joined(separator: " "),
            "continuous speech closes near target duration at a finalized sentence boundary")
        timed.ingest(update(27, 30, "The next topic."), at: 3)
        let nextRows = timed.render(reusing: timedRows)
        check(nextRows.count == 2 && nextRows[0].id == timedRows[0].id && nextRows[1].start == 27,
            "continuous speech starts a fresh paragraph after the duration boundary")
        var unpunctuated = ParagraphBuffer()
        unpunctuated.ingest(update(0, 26, "words without punctuation"), at: 1)
        check(unpunctuated.render().last?.isCollectingParagraph == true,
            "target length can wait for sentence completion")
        unpunctuated.ingest(update(26, 39, "and the remaining words"), at: 2)
        check(unpunctuated.render().last?.isCollectingParagraph == false,
            "long finalized speech without punctuation still has a bounded paragraph length")

        var gap = ParagraphBuffer()
        gap.ingest(update(0, 5, a), at: 1)
        gap.ingest(update(9, 14, b), at: 2)
        let gapRows = gap.render()
        check(gapRows.count == 2 && !gapRows[0].isCollectingParagraph && gapRows[1].isCollectingParagraph,
            "audio timestamp gap splits naturally even when a timer did not run")
        var draft = ParagraphBuffer()
        draft.ingest(update(0, 4, "An unfinished explanation", final: false), at: 1)
        check(!draft.closeAfterPause(at: 10), "a pause does not falsely mark volatile recognition as final")
        draft.finish()
        let stoppedRows = draft.render()
        check(stoppedRows.count == 1 && !stoppedRows[0].isCollectingParagraph && !stoppedRows[0].isFinal &&
              stoppedRows[0].english == "An unfinished explanation", "stop retains and translates the unfinished tail honestly")
        var invalid = ParagraphBuffer()
        invalid.ingest(update(-1, 5, a), at: 1)
        invalid.ingest(update(0, 5, "   "), at: 2)
        check(invalid.render().isEmpty, "invalid or empty ASR updates cannot create phantom paragraphs")

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ClassScribe-paragraph-tests-\(UUID())")
        let suite = "ClassScribe.ParagraphTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: root)
        }
        let model = AppModel(storageRoot: root, preferences: preferences)
        check(model.translationStyle == .paragraphs && model.paragraphLength == .balanced,
            "paragraph mode and 25-second length are the new default")
        model.newLecture()
        var lecture = model.current!
        let history = TranscriptSegment(start: 0, end: 4, english: "Human-corrected source.",
            chinese: "人工核对的译文。", isFinal: true, confidence: nil, translationState: .edited, edited: true)
        lecture.segments = [history]; lecture.duration = 4
        model.lectures = [lecture]
        model.prepareTranscription(for: lecture)
        model.consumeRecognition(update(4, 9, a), lectureID: lecture.id, at: 1)
        model.consumeRecognition(update(9, 15, b), lectureID: lecture.id, at: 2)
        check(model.current?.segments.count == 2 && model.current?.segments.first == history,
            "continuing a class preserves earlier paragraphs and manual corrections")
        check(model.pendingJobs.isEmpty && model.pendingCount == 0,
            "recognition callbacks coalesce sentences instead of immediately translating every update")
        model.retryTranslations(allRecords: true)
        check(model.pendingJobs.isEmpty, "retry and language preparation cannot bypass paragraph buffering")
        model.closeParagraphAfterPause(for: lecture.id, at: 5)
        check(model.pendingJobs.count == 1 && model.pendingJobs[0].text == a + " " + b,
            "translator receives the complete paragraph as one input instead of separate sentences")
        model.closeParagraphAfterPause(for: lecture.id, at: 6)
        model.consumeRecognition(update(9, 15, b), lectureID: lecture.id, at: 6)
        check(model.pendingJobs.count == 1, "repeated pause checks and duplicate finals do not queue repeated translation")
        model.consumeRecognition(update(15, 18, "A final draft", final: false), lectureID: lecture.id, at: 7)
        model.finishTranscription(for: lecture.id)
        check(model.pendingJobs.count == 2 && model.pendingJobs.last?.text == "A final draft" &&
              model.current?.segments.last?.isFinal == false && model.current?.segments.last?.isCollectingParagraph == false,
            "stop flushes a second incomplete paragraph once without losing its draft flag")
        model.persist()
        let reloaded = try LectureStore(root: root).load()
        check(reloaded.first?.segments.count == 3 && reloaded.first?.segments[1].recognitionParts?.count == 2 &&
              reloaded.first?.segments.first == history, "paragraph source parts and prior corrections survive save and reload")

        var crash = Lecture(title: "Interrupted paragraph")
        crash.segments = stoppedRows
        crash.segments[0].paragraphComplete = false
        crash.segments[0].translationState = .translating
        let store = try LectureStore(root: root)
        try store.save(crash)
        let recovered = try store.load().first { $0.id == crash.id }!
        check(!recovered.segments[0].isCollectingParagraph && !recovered.segments[0].isFinal &&
              recovered.segments[0].translationState == .pending,
            "restart makes a saved open paragraph retryable without pretending ASR was finalized")
        var legacy = Lecture(title: "Old record")
        legacy.segments = [history]
        try store.save(legacy)
        let legacyBytes = try Data(contentsOf: store.records.appendingPathComponent("\(legacy.id).json"))
        let legacyReloaded = try store.load().first { $0.id == legacy.id }!
        check(!String(decoding: legacyBytes, as: UTF8.self).contains("paragraphComplete") &&
              legacyReloaded.segments == legacy.segments, "legacy JSON lacking paragraph fields remains fully compatible")
        model.translationStyle = .sentences
        model.paragraphLength = .long
        let settingsReloaded = AppModel(storageRoot: root, preferences: preferences)
        check(settingsReloaded.translationStyle == .sentences && settingsReloaded.paragraphLength == .long,
            "translation mode and paragraph length persist using isolated preferences")
        model.newLecture()
        let sentenceLecture = model.current!
        model.prepareTranscription(for: sentenceLecture)
        let priorJobs = model.pendingJobs.count
        model.consumeRecognition(update(0, 5, a), lectureID: sentenceLecture.id, at: 1)
        model.consumeRecognition(update(5, 10, b), lectureID: sentenceLecture.id, at: 2)
        check(model.current?.segments.count == 2 && model.pendingJobs.count == priorJobs + 2 &&
              model.current?.segments.allSatisfy { $0.paragraphComplete == nil } == true,
            "switching back to sentence mode preserves immediate per-result translation")
        model.finishTranscription(for: sentenceLecture.id)
        var exported = Lecture(title: "Paragraph export")
        exported.segments = [rows[0]]
        check(TranscriptExport.text(exported).contains(a + " " + b) &&
              TranscriptExport.srt(exported).contains("00:00:00,000 --> 00:00:11,000") &&
              TranscriptExport.srt(exported).contains(rows[0].chinese),
            "bilingual text and subtitle exports preserve paragraph text, translation and full time range")
        print("\(count) paragraph checks passed; only temporary records and isolated preferences were used")
    }
}
