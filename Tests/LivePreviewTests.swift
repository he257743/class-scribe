import Foundation

@main struct LivePreviewTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            count += 1; print("PASS: \(label)")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ClassScribe-preview-tests-\(UUID())")
        var models: [AppModel] = []
        var suites: [String] = []
        defer {
            for model in models { if let id = model.current?.id { model.finishTranscription(for: id) } }
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            try? manager.removeItem(at: root)
        }
        func makeModel(live: Bool = true, automatic: Bool = false) -> AppModel {
            let suite = "ClassScribe.LivePreviewTests.\(UUID())"; suites.append(suite)
            let preferences = UserDefaults(suiteName: suite)!
            preferences.set(live, forKey: "liveChinesePreview")
            let model = AppModel(storageRoot: root.appendingPathComponent(UUID().uuidString), preferences: preferences,
                previewInterval: automatic ? 0.04 : 1000, previewInitialDelay: automatic ? 0.01 : 1000,
                trashAction: { url in
                    let trash = root.appendingPathComponent("TestTrash")
                    try manager.createDirectory(at: trash, withIntermediateDirectories: true)
                    try manager.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
                })
            models.append(model)
            model.newLecture(); model.prepareTranscription(for: model.current!)
            return model
        }
        func feed(_ model: AppModel, _ text: String, end: Double = 4, final: Bool = false) {
            model.consumeRecognition(.init(start: 0, end: end, text: text, isFinal: final, confidence: 0.9),
                lectureID: model.current!.id, at: end)
        }
        let a = "A critical section accesses a shared resource."
        let b = a + " A lock protects that resource."

        var segment = TranscriptSegment(start: 0, end: 5, english: b, isFinal: false,
            confidence: 0.9, paragraphComplete: false)
        check(segment.applyPreviewTranslation("共享资源。", forSource: a) && segment.hasPreviewTranslation,
            "a translated prefix can appear while newer English is still arriving")
        check(segment.applyPreviewTranslation("完整的新预览。", forSource: b), "newer preview replaces an earlier snapshot")
        check(!segment.applyPreviewTranslation("过期的短预览。", forSource: a) && segment.chinese == "完整的新预览。",
            "a shorter late snapshot cannot replace a newer Chinese preview")
        segment.paragraphComplete = true
        check(!segment.applyPreviewTranslation("晚到的预览。", forSource: b), "closed paragraph rejects late preview replies")
        check(segment.applyTranslation("整段定稿。", forSource: b) && !segment.hasPreviewTranslation &&
              segment.translatedSource == b, "full paragraph translation clears preview status")
        segment.translationState = .edited; segment.paragraphComplete = false
        check(!segment.applyPreviewTranslation("覆盖人工修改。", forSource: b), "human translation is protected from preview replies")

        var buffer = ParagraphBuffer()
        buffer.ingest(.init(start: 0, end: 4, text: a, isFinal: false, confidence: 0.9), at: 1)
        var rows = buffer.render()
        let rowID = rows[0].id
        _ = rows[0].applyPreviewTranslation("原先的中文预览。", forSource: a)
        buffer.ingest(.init(start: 0, end: 7, text: b, isFinal: false, confidence: 0.9), at: 2)
        rows = buffer.render(reusing: rows)
        check(rows[0].id == rowID && rows[0].chinese == "原先的中文预览。" && rows[0].hasPreviewTranslation,
            "changing volatile ASR ranges keeps the same paragraph row and visible Chinese")
        buffer.ingest(.init(start: 0, end: 8, text: "A corrected explanation.", isFinal: false, confidence: 0.9), at: 3)
        rows = buffer.render(reusing: rows)
        check(rows[0].chinese.isEmpty && !rows[0].hasPreviewTranslation,
            "a revision of earlier English clears an incompatible Chinese snapshot")

        let model = makeModel()
        let id = model.current!.id
        feed(model, a)
        model.requestParagraphPreview(for: id)
        var requestedSource = ""
        await model.processNextTranslation { text in requestedSource = text; return "实时中文一。" }
        check(requestedSource == a && model.current?.segments.last?.isCollectingParagraph == true &&
              model.current?.segments.last?.chinese == "实时中文一。", "Chinese appears before any pause or paragraph closure")
        feed(model, b, end: 7)
        check(model.current?.segments.last?.chinese == "实时中文一。", "English growth does not blank the visible Chinese preview")
        model.requestParagraphPreview(for: id)
        await model.processNextTranslation { text in requestedSource = text; return "实时中文二。" }
        check(requestedSource == b && model.current?.segments.last?.chinese == "实时中文二。",
            "each preview translates the growing paragraph with its accumulated context")
        for index in 0..<15 {
            feed(model, b + String(repeating: " more", count: index + 1), end: 7 + Double(index) / 100)
            model.requestParagraphPreview(for: id)
        }
        check(model.pendingJobs.count == 1 && model.pendingJobs[0].isPreview &&
              model.pendingJobs[0].text == model.current?.segments.last?.english,
            "many ASR updates coalesce to one latest pending preview instead of building a backlog")

        let priority = makeModel()
        feed(priority, a); priority.requestParagraphPreview(for: priority.current!.id)
        var stable = Lecture(title: "Final waiting")
        stable.segments = [.init(start: 0, end: 5, english: "A completed paragraph.", isFinal: true, confidence: 0.9)]
        priority.lectures.append(stable); priority.retryTranslations(allRecords: true)
        var firstJob = ""
        await priority.processNextTranslation { firstJob = $0; return "定稿优先。" }
        check(firstJob == "A completed paragraph.", "completed paragraph translations take priority over live previews")

        let stopped = makeModel()
        let stoppedID = stopped.current!.id
        feed(stopped, a); stopped.requestParagraphPreview(for: stoppedID)
        await stopped.processNextTranslation { _ in
            feed(stopped, b, end: 7)
            stopped.finishTranscription(for: stoppedID)
            return "停止后晚到的预览。"
        }
        check(stopped.current?.segments.last?.chinese.isEmpty == true && stopped.pendingJobs.count == 1 &&
              !stopped.pendingJobs[0].isPreview && stopped.pendingJobs[0].text == b,
            "stop discards an in-flight preview and queues the full remaining paragraph")
        await stopped.processNextTranslation { _ in "整段最终中文。" }
        check(stopped.current?.segments.last?.chinese == "整段最终中文。" &&
              stopped.current?.segments.last?.hasPreviewTranslation == false,
            "final translation remains intact after a delayed preview returns")

        let revised = makeModel()
        let revisedID = revised.current!.id
        feed(revised, a); revised.requestParagraphPreview(for: revisedID)
        await revised.processNextTranslation { _ in
            feed(revised, "The corrected source is different.", end: 6)
            return "旧原文的译文。"
        }
        check(revised.current?.segments.last?.chinese.isEmpty == true,
            "an in-flight reply cannot translate words that ASR has corrected away")
        revised.requestParagraphPreview(for: revisedID)
        await revised.processNextTranslation { _ in
            revised.edit(revised.current!.segments.last!.id, english: revised.current!.segments.last!.english, chinese: "人工核对。")
            return "自动覆盖。"
        }
        check(revised.current?.segments.last?.chinese == "人工核对。", "manual edits survive an in-flight preview callback")

        let deleted = makeModel()
        let deletedID = deleted.current!.id
        feed(deleted, a); deleted.requestParagraphPreview(for: deletedID)
        await deleted.processNextTranslation { _ in deleted.deleteLecture(deletedID); return "删除后回复。" }
        let deletedRecords = try deleted.store!.load()
        check(deleted.lectures.isEmpty && deletedRecords.isEmpty, "late preview reply cannot recreate a deleted classroom")

        let failure = makeModel()
        let failureID = failure.current!.id
        feed(failure, a); failure.requestParagraphPreview(for: failureID)
        await failure.processNextTranslation { _ in throw NSError(domain: "TemporaryPreviewFailure", code: 1) }
        failure.finishTranscription(for: failureID)
        await failure.processNextTranslation { _ in "停止后仍然补译。" }
        check(failure.current?.segments.last?.chinese == "停止后仍然补译。" && failure.errorMessage == nil,
            "temporary preview failure does not prevent final paragraph translation")

        var saved = Lecture(title: "Preview recovery")
        saved.segments = [.init(start: 0, end: 5, english: b, chinese: "尚未定稿的中文。", isFinal: true,
            confidence: 0.9, translationState: .complete, paragraphComplete: false, translatedSource: a, translationIsPreview: true)]
        let store = try LectureStore(root: root.appendingPathComponent("Recovery"))
        try store.save(saved)
        let recovered = try store.load().first!
        check(recovered.segments[0].hasPreviewTranslation && !recovered.segments[0].isCollectingParagraph &&
              recovered.segments[0].translationState == .pending,
            "restart retains visible preview but requires a full paragraph translation")
        check(TranscriptExport.text(saved).contains("中文预览，待整段定稿") &&
              TranscriptExport.srt(saved).contains("中文预览，待整段定稿"),
            "exports explicitly label a preview if full translation has not finished")

        let disabled = makeModel(live: false)
        let disabledID = disabled.current!.id
        feed(disabled, a); disabled.requestParagraphPreview(for: disabledID)
        check(disabled.pendingJobs.isEmpty && !disabled.liveChinesePreview, "preview toggle preserves end-of-paragraph-only mode")
        disabled.finishTranscription(for: disabledID)
        check(disabled.pendingJobs.count == 1 && !disabled.pendingJobs[0].isPreview,
            "disabling preview still translates the completed paragraph")

        let serial = makeModel()
        let serialID = serial.current!.id
        feed(serial, a); serial.requestParagraphPreview(for: serialID)
        let (entered, notification) = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        let running = Task { @MainActor in
            await serial.processNextTranslation { _ in
                await withCheckedContinuation { continuation in release = continuation; notification.yield(()) }
                return "第一份预览。"
            }
        }
        for await _ in entered { break }
        feed(serial, b, end: 7); serial.requestParagraphPreview(for: serialID)
        let concurrent = await serial.processNextTranslation { _ in fatalError("Concurrent translator invocation") }
        check(!concurrent && serial.pendingJobs.count == 1, "only one translation runs while one latest preview waits")
        release?.resume(); notification.finish(); _ = await running.value
        check(serial.current?.segments.last?.chinese == "第一份预览。",
            "valid prefix preview is displayed even if English grew during translation")
        await serial.processNextTranslation { _ in "第二份预览。" }
        check(serial.current?.segments.last?.chinese == "第二份预览。", "newer queued preview follows the in-flight result")

        let cancelled = makeModel()
        feed(cancelled, a)
        cancelled.finishTranscription(for: cancelled.current!.id)
        let (cancelEntered, cancelNotification) = AsyncStream<Void>.makeStream()
        var finishCancelled: CheckedContinuation<Void, Never>?
        let cancelledWork = Task { @MainActor in
            await cancelled.processNextTranslation { _ in
                await withCheckedContinuation { continuation in finishCancelled = continuation; cancelNotification.yield(()) }
                return "取消的回复。"
            }
        }
        for await _ in cancelEntered { break }
        cancelledWork.cancel(); finishCancelled?.resume(); cancelNotification.finish(); _ = await cancelledWork.value
        check(cancelled.pendingJobs.count == 1 && cancelled.current?.segments.last?.translationState == .pending,
            "cancelling an in-flight worker leaves the final paragraph queued for retry")
        await cancelled.processNextTranslation { _ in "恢复后的定稿。" }
        check(cancelled.current?.segments.last?.chinese == "恢复后的定稿。",
            "a replacement worker can finish a previously cancelled paragraph")

        let automatic = makeModel(automatic: true)
        var sawWhileSpeaking = false
        for index in 0..<30 {
            feed(automatic, a + String(repeating: " additional", count: index + 1), end: 4 + Double(index) / 100)
            if index < 25 && automatic.pendingJobs.contains(where: \.isPreview) { sawWhileSpeaking = true }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(sawWhileSpeaking && automatic.pendingJobs.count == 1,
            "continuous speech triggers throttled previews without waiting for a debounce pause")
        automatic.finishTranscription(for: automatic.current!.id)
        try await Task.sleep(for: .milliseconds(70))
        check(automatic.pendingJobs.count == 1 && !automatic.pendingJobs[0].isPreview,
            "scheduled preview is cancelled on stop and cannot requeue behind the final translation")
        print("\(count) live preview checks passed; temporary data and isolated preferences only")
    }
}
