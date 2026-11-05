import Foundation

actor ReviewFixture: ContextReviewing {
    private var calls = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var response: [ContextReviewPatch] = []
    func availability(for model: ContextModel) async throws -> ContextAvailability { .ready }
    func prepare(model: ContextModel, progress: @escaping @Sendable (Double, String) async -> Void) async throws {}
    func configure(_ patches: [ContextReviewPatch]) { response = patches }
    func count() -> Int { calls }
    func review(_ window: ContextReviewWindow) async throws -> [ContextReviewPatch] {
        calls += 1
        await withCheckedContinuation { waiter = $0 }
        return response
    }
    func release() { waiter?.resume(); waiter = nil }
    func shutdown() async { release() }
}

final class MissingSpeechFixture: SpeechRecording, @unchecked Sendable {
    func start(audioURL: URL?, contextualWords: [String], offset: Double,
               receive: @escaping @Sendable (RecognitionUpdate) async -> Void,
               meter: @escaping @Sendable (Double) -> Void,
               failure: @escaping @Sendable (String) -> Void) async throws {
        throw ClassScribeError.speechAssetsUnavailable
    }
    func stop() async -> String? { nil }
}

@main struct ContextReviewTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1; print("PASS: " + message)
        }
        func fixture() -> Lecture {
            var lecture = Lecture(title: "Synthetic terminology fixture")
            lecture.duration = 15
            lecture.segments = [
                TranscriptSegment(start: 0, end: 5, english: "This mute X protects the shared resource.",
                    chinese: "这个静音 X 保护共享资源。", isFinal: true, confidence: 0.5, translationState: .complete,
                    paragraphComplete: true),
                TranscriptSegment(start: 5, end: 15, english: "A mutex provides mutual exclusion. Only one thread can hold a mutex.",
                    chinese: "互斥锁提供互斥。", isFinal: false, confidence: nil, paragraphComplete: false)
            ]
            return lecture
        }
        let lecture = fixture()
        let window = ContextReviewWindow.make(lecture: lecture, domain: .operatingSystems,
            custom: "", subject: "", model: .larger)!
        let patch = ContextReviewPatch(index: 0, replacements: [.init(from: "mute X", to: "mutex")],
            chineseReplacements: [.init(from: "静音 X", to: "互斥锁")], evidence: "A mutex provides mutual exclusion.", reason: "后文明确提到 mutex 和互斥。")
        let candidates = ContextReviewPolicy.candidates(in: window)
        check(candidates.contains { $0.from == "mute X" && $0.term.english == "mutex" },
            "candidate generation keeps the whole misheard term and a later literal quote")
        var unrelated = window; unrelated.entries[1].english = "We will discuss the textbook today."
        check(ContextReviewPolicy.candidates(in: unrelated).isEmpty,
            "no terminology candidate is created without the term in later speech")
        let revision = ContextReviewPolicy.revision(patch, window: window)!
        var partial = lecture
        partial.segments[0].translationIsPreview = true
        check(ContextReviewWindow.make(lecture: partial, domain: .operatingSystems, custom: "", subject: "", model: .larger) == nil,
            "a closed paragraph with only a partial Chinese preview waits for full translation")
        check(!partial.segments[0].applyContextRevision(revision, expectedPrevious: nil),
            "a context reply cannot freeze an incomplete Chinese preview")
        partial.segments[0].translationIsPreview = false
        partial.segments[0].translatedSource = "An older, shorter English snapshot."
        check(ContextReviewWindow.make(lecture: partial, domain: .operatingSystems, custom: "", subject: "", model: .larger) == nil,
            "a translation of an older English snapshot cannot become the corrected final view")
        check(revision.english == "This mutex protects the shared resource.", "later explicit terminology permits a localized correction")
        var row = lecture.segments[0]
        check(row.applyContextRevision(revision, expectedPrevious: nil), "verified revision is accepted")
        check(row.english == lecture.segments[0].english && row.chinese == lecture.segments[0].chinese,
            "context correction preserves original ASR and initial machine translation")
        check(row.presentedEnglish.contains("mutex") && row.presentedChinese.contains("互斥锁"), "display exposes the corrected English and Chinese")
        check(row.needsReview && row.confidence == 0.5, "context correction does not erase raw ASR confidence or review warnings")
        check(!row.applyContextRevision(revision, expectedPrevious: nil), "late results cannot overwrite an intervening revision")
        check(row.applyTranslation("系统随后完成的原始译文。", forSource: row.english) && row.presentedChinese == revision.chinese,
            "late base translation cannot erase the contextual view")
        let encoded = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: encoded)
        check(decoded == row, "raw text and revision history survive JSON round trip")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "contextRevisions")
        let old = try JSONDecoder().decode(TranscriptSegment.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(old.activeContextRevision == nil && old.presentedEnglish == old.english, "legacy records remain readable without a revision field")
        var exported = lecture; exported.segments[0] = row
        let text = TranscriptExport.text(exported)
        check(text.contains("原始识别：This mute X") && text.contains("英文：This mutex") && text.contains("校订依据"),
            "text export includes both contextual correction and original source")
        check(TranscriptExport.srt(exported).contains("〔上下文校订〕"), "subtitle export labels machine context corrections")
        var human = row; human.edited = true
        check(human.activeContextRevision == nil && !human.applyContextRevision(revision, expectedPrevious: nil),
            "human-confirmed text suppresses and rejects automatic revisions")

        func rejected(_ change: (inout ContextReviewPatch) -> Void) -> Bool {
            var candidate = patch; change(&candidate)
            return ContextReviewPolicy.revision(candidate, window: window) == nil
        }
        check(rejected { $0.evidence = "invented evidence about mutex" }, "fabricated later evidence is rejected")
        check(rejected { $0.evidence = lecture.segments[0].english }, "earlier source text cannot substitute for later evidence")
        check(rejected { $0.index = 1 }, "the newest segment cannot be revised without later context")
        check(rejected { $0.index = -1 }, "invalid model indices are rejected")
        check(rejected { $0.replacements = [.init(from: "mute X", to: "semaphore")] }, "a glossary word absent from later evidence cannot replace speech")
        check(rejected { $0.replacements = [.init(from: "This mute X protects the shared resource", to: "mutex")] }, "whole-sentence rewrites are rejected")
        check(rejected { $0.replacements = [.init(from: "not", to: "mutex")] }, "negation cannot be removed as a terminology correction")
        check(rejected { $0.replacements = [.init(from: "2", to: "mutex")] }, "numbers cannot be replaced by terminology")
        check(rejected { $0.chineseReplacements = [.init(from: "静音 X", to: "8080 个互斥锁")] }, "facts and numbers borrowed from nowhere are rejected")
        check(rejected { $0.chineseReplacements = [.init(from: "静音 X", to: "mutex")] }, "non-Chinese response cannot replace the Chinese translation")
        var wrongEvidence = window
        wrongEvidence.entries[1].english = "Bring cash to buy the textbook."
        let cash = ContextReviewPatch(index: 0, replacements: [.init(from: "mute X", to: "cache")],
            chineseReplacements: [.init(from: "静音 X", to: "缓存")], evidence: wrongEvidence.entries[1].english, reason: "猜测术语。")
        check(ContextReviewPolicy.revision(cash, window: wrongEvidence) == nil, "a course glossary alone cannot justify a contextually unsupported correction")
        var portWindow = window
        portWindow.terms = CourseGlossary.terms(domain: .networks, custom: "")
        portWindow.entries[0].english = "Open the port."; portWindow.entries[0].chinese = "打开港口。"
        portWindow.entries[1].english = "The TCP port is on the server."
        let sense = ContextReviewPatch(index: 0, replacements: [], chineseReplacements: [.init(from: "港口", to: "端口")],
            evidence: portWindow.entries[1].english, reason: "后文说明是网络端口。")
        let disambiguated = ContextReviewPolicy.revision(sense, window: portWindow)
        check(disambiguated?.english == "Open the port." && disambiguated?.chinese == "打开端口。",
            "later context can disambiguate Chinese while keeping English unchanged")
        var accurate = window
        accurate.entries[0].english = "A mutex protects the shared resource."
        accurate.entries[0].chinese = "互斥锁保护共享资源。"
        let paraphrase = ContextReviewPatch(index: 0, replacements: [], chineseReplacements: [.init(from: "互斥锁", to: "互斥锁")],
            evidence: patch.evidence, reason: "调整表述。")
        check(ContextReviewPolicy.revision(paraphrase, window: accurate) == nil, "already-correct terminology is not replaced by stylistic paraphrasing")
        var money = window
        money.entries[0].english = "I brought cash to buy the textbook."
        money.entries[0].chinese = "我带了现金来买课本。"
        money.entries[1].english = "We use this money to buy books."
        let moneyRewrite = ContextReviewPatch(index: 0, replacements: [], chineseReplacements: [.init(from: "现金", to: "缓存")],
            evidence: money.entries[1].english, reason: "重新翻译。")
        check(ContextReviewPolicy.revision(moneyRewrite, window: money) == nil, "later context does not license gratuitous rewriting of unrelated speech")
        check(rejected { $0.chineseReplacements = [.init(from: "这个静音 X 保护共享资源。", to: "互斥锁")] },
            "a whole-sentence Chinese rewrite is rejected")
        check(rejected { $0.chineseReplacements = [.init(from: "不存在的短语", to: "互斥锁")] },
            "a Chinese replacement must quote the actual source translation")
        var unsupportedSense = portWindow; unsupportedSense.entries[1].english = "We discuss the textbook today."
        var unsupportedPatch = sense; unsupportedPatch.evidence = unsupportedSense.entries[1].english
        check(ContextReviewPolicy.revision(unsupportedPatch, window: unsupportedSense) == nil,
            "Chinese sense correction requires the actual term in quoted later evidence")
        var collecting = window; collecting.entries[0].isComplete = false
        check(ContextReviewPolicy.revision(patch, window: collecting) == nil, "collecting or human-edited paragraphs cannot be automatically revised")
        let glossary = CourseGlossary.terms(domain: .operatingSystems, custom: "mutex=自定义译名, new term=新术语")
        check(glossary.first { $0.english == "mutex" }?.chinese == "自定义译名" && glossary.contains { $0.english == "new term" },
            "custom glossary translations override presets and retain additional terminology")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-context-tests-\(UUID())")
        let suite = "ClassScribe.ContextTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let service = ReviewFixture(); await service.configure([patch])
        let model = AppModel(storageRoot: root, preferences: preferences, contextService: service, contextInterval: 0.02)
        model.lectures = [lecture]; model.selectedID = lecture.id; model.contextReady = true
        model.beginContextReview(for: lecture.id)
        model.beginContextReview(for: lecture.id)
        for _ in 0..<100 { if await service.count() > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let calls = await service.count()
        check(calls == 1, "only one context request runs at a time")
        model.lectures[0].segments[1].english += " This is additional context."
        await service.release()
        for _ in 0..<100 { if model.lectures[0].segments[0].activeContextRevision != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        check(model.lectures[0].segments[0].presentedEnglish.contains("mutex"), "append-only growth in later speech does not starve a valid revision")
        let loaded = try model.store!.load()
        check(loaded[0].segments[0].contextRevisions?.count == 1 && loaded[0].segments[0].english.contains("mute X"),
            "applied corrections are saved with original recognition intact")
        check(loaded[0].segments[0] == model.lectures[0].segments[0], "revision timestamps and complete paragraph state survive persistent storage")
        model.contextEnabled = false
        await service.release()
        var changed = lecture; changed.segments[1].english = "A completely different topic."
        model.lectures = [changed]
        check(model.applyContextPatches([patch], window: window) == 0, "ASR revision of the quoted evidence invalidates an old result")
        var baseChanged = lecture; baseChanged.segments[0].chinese = "随后更新的基础译文。"
        model.lectures = [baseChanged]
        check(model.applyContextPatches([patch], window: window) == 0,
            "a changed base translation invalidates Chinese substitutions from an older snapshot")
        var evolving = lecture
        evolving.segments.append(TranscriptSegment(start: 15, end: 18, english: "An unrelated first draft.",
            isFinal: false, confidence: nil, paragraphComplete: false))
        let evolvingWindow = ContextReviewWindow.make(lecture: evolving, domain: .operatingSystems,
            custom: "", subject: "", model: .larger)!
        evolving.segments[2].english = "A revised unrelated continuation."
        model.lectures = [evolving]
        check(model.applyContextPatches([patch], window: evolvingWindow) == 1,
            "revision of unrelated volatile speech does not discard a correction with surviving evidence")
        model.lectures = [lecture]
        model.edit(lecture.segments[0].id, english: "My confirmed original.", chinese: "人工核对。")
        check(model.applyContextPatches([patch], window: window) == 0, "manual edits made during inference remain protected")
        model.lectures = []
        check(model.applyContextPatches([patch], window: window) == 0, "a deleted classroom cannot be recreated by a late correction")
        await model.finishBeforeQuit()

        let failedRoot = root.appendingPathComponent("missing-speech")
        let failed = AppModel(storageRoot: failedRoot, preferences: preferences,
            engineFactory: { MissingSpeechFixture() }, microphoneAccess: { true }, contextService: service)
        failed.newLecture(); failed.speechReady = true; failed.translationReady = true
        await failed.start()
        check(!failed.speechReady && !failed.ready && failed.phase == .idle,
            "missing speech assets reset readiness so the prepare-language button reappears")
        check(failed.current != nil && failed.errorMessage?.contains("准备语言包") == true,
            "speech-asset startup failure retains the classroom and actionable instructions")
        await failed.finishBeforeQuit()
        print("\(checks) context checks passed; synthetic data, injected model service, no microphone")
    }
}
