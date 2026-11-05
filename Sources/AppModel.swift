import SwiftUI
import Combine
import AppKit
import AVFoundation
import Translation
import Speech
import UniformTypeIdentifiers

enum RecordingPhase {
    case idle, starting, listening, pausing, paused, stopping
    var isTransitioning: Bool { self == .starting || self == .pausing || self == .stopping }
}

struct TranslationJob {
    var lectureID: UUID
    var segmentID: UUID
    var text: String
    var isFinal: Bool
    var isPreview = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published var lectures: [Lecture] = []
    @Published var selectedID: UUID?
    @Published var phase: RecordingPhase = .idle {
        didSet {
            if !phase.isTransitioning {
                let waiting = transitionWaiters; transitionWaiters.removeAll()
                for continuation in waiting { continuation.resume() }
            }
        }
    }
    @Published var level: Double = 0
    @Published var speechBackend: SpeechBackend {
        didSet {
            preferences.set(speechBackend.rawValue, forKey: "speechBackend")
            speechReady = false
            Task { await refreshSpeechAvailability() }
        }
    }
    @Published var speechReady = false
    @Published var translationReady = false
    @Published var speechPreparing = false
    @Published var translationPreparing = false
    @Published var speechProgress: Double = 0
    @Published var speechStatus = "正在检查英语语音包"
    @Published var translationStatus = "正在检查中英翻译包"
    @Published var translationConfiguration: TranslationSession.Configuration?
    @Published var errorMessage: String?
    @Published var storageWarning: String?
    @Published var savedAt: Date?
    @Published var keepAudio: Bool {
        didSet { preferences.set(keepAudio, forKey: "keepAudio") }
    }
    @Published var contextualWords: String {
        didSet { preferences.set(contextualWords, forKey: "contextualWords") }
    }
    @Published var translationStyle: TranslationStyle {
        didSet { preferences.set(translationStyle.rawValue, forKey: "translationStyle") }
    }
    @Published var paragraphLength: ParagraphLength {
        didSet { preferences.set(paragraphLength.rawValue, forKey: "paragraphLength") }
    }
    @Published var liveChinesePreview: Bool {
        didSet { preferences.set(liveChinesePreview, forKey: "liveChinesePreview") }
    }
    @Published var autoScroll = true
    @Published var contextEnabled: Bool {
        didSet {
            preferences.set(contextEnabled, forKey: "contextEnabled")
            if !contextEnabled {
                cancelContextReview(); contextStatus = "上下文校对已关闭"
                Task { await contextService.shutdown() }
            } else { Task { await refreshContextAvailability() } }
        }
    }
    @Published var contextModel: ContextModel {
        didSet { preferences.set(contextModel.rawValue, forKey: "contextModel"); resetContextSettings() }
    }
    @Published var courseDomain: CourseDomain {
        didSet { preferences.set(courseDomain.rawValue, forKey: "courseDomain"); cancelContextReview() }
    }
    @Published var courseSubject: String {
        didSet { preferences.set(courseSubject, forKey: "courseSubject"); cancelContextReview() }
    }
    @Published var contextReady = false
    @Published var contextPreparing = false
    @Published var contextWorking = false
    @Published var contextProgress: Double = 0
    @Published var contextStatus = "上下文模型尚未准备"
    @Published var demoMode: Bool
    @Published var deletionCandidate: Lecture?
    let store: LectureStore?
    private let trashAction: LectureStore.TrashAction
    private let preferences: UserDefaults
    private let contextService: any ContextReviewing
    private var contextTimer: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var contextPreparationTask: Task<Void, Never>?
    private var contextEpoch = UUID()
    private var lastContextFingerprint: String?
    private var lastContextStarted = Date.distantPast
    private var contextLectureID: UUID?
    private let contextInterval: TimeInterval

    private var engine: SpeechRecording?
    private let engineFactory: (() -> SpeechRecording)?
    private let qwenAssets: any QwenPreparing
    private var speechPreparationTask: Task<Void, Never>?
    private let microphoneAccess: (() async -> Bool)?
    private let recordingNow: () -> Date
    private var pausedLectureID: UUID?
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeLectureID: UUID?
    private var generation = UUID()
    private var translationEpoch = UUID()
    private var timer: Timer?
    private var started: Date?
    private var offset: Double = 0
    private var activeAudioFilename: String?
    private(set) var pendingJobs: [TranslationJob] = []
    private var activeTranslationStyle: TranslationStyle = .paragraphs
    private var paragraphBuffer: ParagraphBuffer?
    private var paragraphBaseCount = 0
    private var activeLivePreview = true
    private var paragraphPreviewTask: Task<Void, Never>?
    private var paragraphPreviewToken = UUID()
    private var lastParagraphPreviewRequest: Date?
    private let previewInterval: TimeInterval
    private let previewInitialDelay: TimeInterval
    private var inFlightJob: TranslationJob?
    private var signal: AsyncStream<Void>.Continuation?
    private var previewTask: Task<Void, Never>?
    private var startupFailure: String?
    private var lastCheckpoint = Date.distantPast
    private var realLectures: [Lecture]?
    private var realSelectedID: UUID?

    var current: Lecture? { lectures.first { $0.id == selectedID } }
    var busy: Bool { phase != .idle }
    var preparing: Bool { speechPreparing || translationPreparing }
    var canDeleteLecture: Bool { !busy && !demoMode && current != nil && store != nil }
    var canTogglePause: Bool { phase == .listening || phase == .paused }
    var canExportTranscript: Bool { hasContent && (phase == .idle || phase == .paused) }
    var ready: Bool { speechReady && translationReady && store != nil && !demoMode }
    var pendingCount: Int {
        current?.segments.filter { $0.recognitionWarning == nil && !$0.isCollectingParagraph &&
            ($0.translationState == .pending || $0.translationState == .translating) }.count ?? 0
    }
    var failedCount: Int { current?.segments.filter { $0.recognitionWarning == nil && $0.translationState == .failed }.count ?? 0 }
    var hasContent: Bool { !(current?.segments.isEmpty ?? true) }
    var statusLabel: String {
        switch phase {
        case .starting: return speechBackend == .qwen ? "正在加载千问识别" : (pausedLectureID == nil ? "正在开启麦克风" : "正在继续听课")
        case .listening: return level < 0.08 ? "正在听 · 等待发言" : "正在听课"
        case .pausing: return "正在暂停 · 保存末段文字"
        case .paused: return "已暂停 · 麦克风已停止"
        case .stopping: return "正在收尾 · 保留末段文字"
        case .idle: return demoMode ? "演示模式" : (ready ? "已就绪" : "需要准备识别与翻译组件")
        }
    }

    init(demoMode: Bool = false, storageRoot: URL? = nil,
         preferences: UserDefaults = .standard,
         previewInterval: TimeInterval = 1.5, previewInitialDelay: TimeInterval = 0.6,
         engineFactory: (() -> SpeechRecording)? = nil,
         microphoneAccess: (() async -> Bool)? = nil, recordingNow: @escaping () -> Date = Date.init,
         trashAction: @escaping LectureStore.TrashAction = LectureStore.systemTrash,
         contextService: any ContextReviewing = LocalContextService(), contextInterval: TimeInterval = 8,
         qwenAssets: any QwenPreparing = QwenASRAssets()) {
        self.demoMode = demoMode
        self.trashAction = trashAction
        self.preferences = preferences
        self.contextService = contextService
        self.contextInterval = max(0.01, contextInterval)
        self.contextEnabled = preferences.object(forKey: "contextEnabled") as? Bool ?? true
        let choiceURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassScribe/ContextRuntime/selected-model.json")
        let preparedChoice = (try? Data(contentsOf: choiceURL)).flatMap { try? JSONDecoder().decode(ContextModel.self, from: $0) }
        self.contextModel = ContextModel(rawValue: preferences.string(forKey: "contextModel") ?? "") ?? preparedChoice ?? .light
        self.courseDomain = CourseDomain(rawValue: preferences.string(forKey: "courseDomain") ?? "") ?? .computerScience
        self.courseSubject = preferences.string(forKey: "courseSubject") ?? ""
        self.engineFactory = engineFactory
        self.qwenAssets = qwenAssets
        self.speechBackend = SpeechBackend(rawValue: preferences.string(forKey: "speechBackend") ?? "") ?? .apple
        self.microphoneAccess = microphoneAccess
        self.recordingNow = recordingNow
        self.previewInterval = max(0.01, previewInterval)
        self.previewInitialDelay = max(0.01, previewInitialDelay)
        self.keepAudio = preferences.object(forKey: "keepAudio") as? Bool ?? true
        self.contextualWords = preferences.string(forKey: "contextualWords") ??
            "operating system, semaphore, mutex, deadlock, thread, process, critical section, TCP, IP, synchronization"
        self.translationStyle = TranslationStyle(rawValue: preferences.string(forKey: "translationStyle") ?? "") ?? .paragraphs
        self.paragraphLength = ParagraphLength(rawValue: preferences.integer(forKey: "paragraphLength")) ?? .balanced
        self.liveChinesePreview = preferences.object(forKey: "liveChinesePreview") as? Bool ?? true
        do {
            let temporaryRoot = demoMode ? FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-Demo", isDirectory: true) : nil
            let store = try LectureStore(root: temporaryRoot ?? storageRoot)
            self.store = store
            if demoMode {
                var lecture = Lecture(title: "操作系统 · 演示文字")
                lecture.duration = 24
                lecture.segments = [
                    TranscriptSegment(start: 0, end: 8, english: "A critical section is a part of a program that accesses a shared resource.",
                        chinese: "临界区是程序中访问共享资源的一部分。", isFinal: true, confidence: 0.94, translationState: .complete),
                    TranscriptSegment(start: 8, end: 17, english: "A mutex helps ensure that only one thread enters the critical section at a time.",
                        chinese: "互斥锁帮助确保同一时间只有一个线程进入临界区。", isFinal: true, confidence: 0.92, translationState: .complete),
                    TranscriptSegment(start: 17, end: 24, english: "Now, what happens if two processes are waiting for each other?",
                        chinese: "那么，如果两个进程相互等待，会发生什么？", isFinal: false, confidence: 0.59, translationState: .complete)
                ]
                if translationStyle == .paragraphs {
                    let first = lecture.segments[0], second = lecture.segments[1]
                    var paragraph = first
                    paragraph.end = second.end
                    paragraph.english = first.english + " " + second.english
                    paragraph.chinese = first.chinese + " " + second.chinese
                    paragraph.paragraphComplete = true
                    paragraph.recognitionParts = [first, second].map { RecognitionPart(start: $0.start, end: $0.end,
                        text: $0.english, isFinal: $0.isFinal, confidence: $0.confidence) }
                    var tail = lecture.segments[2]
                    tail.paragraphComplete = false; tail.translationIsPreview = true; tail.translatedSource = tail.english
                    lecture.segments = [paragraph, tail]
                }
                lectures = [lecture]
                speechStatus = "演示界面，不使用麦克风"
                translationStatus = "示例译文，不是真实翻译结果"
            } else {
                do { lectures = try store.load() }
                catch { storageWarning = "有记录未能读取。原文件已保留，请打开记录文件夹检查。\n\(error.localizedDescription)" }
            }
        } catch {
            store = nil
            storageWarning = "无法创建本机保存目录：\(error.localizedDescription)"
        }
        selectedID = lectures.first?.id
    }

    func refreshAvailability() async {
        guard !demoMode else { return }
        await refreshSpeechAvailability()
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: "en"),
            to: Locale.Language(identifier: "zh-Hans"))
        switch status {
        case .installed:
            translationStatus = "正在连接本机翻译"
            configureTranslation()
        case .supported: translationStatus = "中英翻译包需要下载"
        case .unsupported: translationStatus = "系统暂未提供中英翻译，请联网后重试检查"
        @unknown default: translationStatus = "无法检查翻译语言包"
        }
        await refreshContextAvailability()
    }

    func refreshSpeechAvailability() async {
        guard !demoMode, !speechPreparing else { return }
        let selected = speechBackend
        do {
            let ready = selected == .apple ? try await SpeechAssets.status() == .installed : await qwenAssets.available()
            guard speechBackend == selected, !speechPreparing else { return }
            speechReady = ready
            speechStatus = selected == .apple ? (ready ? "英语语音包已就绪" : "英语语音包需要下载") :
                (ready ? "千问识别组件已就绪" : "千问识别组件需要准备")
        } catch { if speechBackend == selected { speechReady = false; speechStatus = error.localizedDescription } }
    }

    func prepareLanguages() {
        guard !demoMode, !busy, !preparing else { return }
        errorMessage = nil
        if !translationReady { translationPreparing = true; configureTranslation() }
        if !speechReady {
            let selected = speechBackend
            speechPreparing = true; speechProgress = 0
            speechStatus = selected == .apple ? "正在准备英语语音包" : "正在准备千问识别组件"
            speechPreparationTask = Task {
                do {
                    if selected == .apple {
                        try await SpeechAssets.install { [weak self] fraction in await self?.setSpeechProgress(fraction) }
                    } else {
                        try await qwenAssets.prepare { [weak self] fraction, status in
                            await self?.setSpeechProgress(fraction, status: status)
                        }
                    }
                    guard !Task.isCancelled else { throw CancellationError() }
                    if speechBackend == selected {
                        speechReady = true
                        speechStatus = selected == .apple ? "英语语音包已就绪" : "千问识别组件已就绪"
                    }
                } catch {
                    if speechBackend == selected {
                        speechReady = false
                        speechStatus = Task.isCancelled ? "识别组件准备已取消" : "识别组件准备失败"
                        if !Task.isCancelled { errorMessage = "本机识别未准备完成：\(error.localizedDescription)" }
                    }
                }
                speechPreparing = false; speechPreparationTask = nil
            }
        }
    }
    func cancelSpeechPreparation() { speechPreparationTask?.cancel() }

    private func setSpeechProgress(_ fraction: Double, status: String? = nil) {
        speechProgress = fraction
        if let status { speechStatus = status }
    }

    private func configureTranslation() {
        translationEpoch = UUID()
        translationReady = false
        if translationConfiguration == nil {
            translationConfiguration = TranslationSession.Configuration(source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans"))
        } else { translationConfiguration?.invalidate() }
    }

    func runTranslation(using session: TranslationSession) async {
        let epoch = translationEpoch
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal = continuation
        defer {
            continuation.finish()
            if translationEpoch == epoch { signal = nil; translationReady = false; translationPreparing = false }
        }
        do {
            try await session.prepareTranslation()
            let waitingSince = Date()
            let availability = LanguageAvailability()
            while await availability.status(from: Locale.Language(identifier: "en"),
                    to: Locale.Language(identifier: "zh-Hans")) != .installed {
                guard !Task.isCancelled, translationEpoch == epoch else { return }
                translationPreparing = true
                translationStatus = "中英翻译包正在下载，可在系统下载窗口查看"
                if Date().timeIntervalSince(waitingSince) > 600 {
                    throw ClassScribeError.message("翻译语言包仍未下载完成。请检查网络后重试，已下载的进度由系统保留。")
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, translationEpoch == epoch else { return }
            translationReady = true; translationPreparing = false
            translationStatus = "中英翻译包已就绪"
            retryTranslations(allRecords: true)
            continuation.yield(())
            for await _ in signals {
                while !pendingJobs.isEmpty && !Task.isCancelled && translationEpoch == epoch {
                    guard await processNextTranslation(using: { text in
                        try await session.translate(text).targetText
                    }) else { break }
                }
            }
        } catch {
            if !Task.isCancelled {
                translationStatus = "中英翻译包尚未就绪"
                errorMessage = "本机翻译未准备完成：\(error.localizedDescription)\n可点击“准备语言包”重试。"
            }
        }
    }

    private func canTranslate(_ job: TranslationJob, item: TranscriptSegment) -> Bool {
        guard item.recognitionWarning == nil, item.translationState != .edited else { return false }
        if job.isPreview {
            return item.isCollectingParagraph && item.english.hasPrefix(job.text)
        }
        return !item.isCollectingParagraph && item.english == job.text
    }

    @discardableResult
    func processNextTranslation(using translate: (String) async throws -> String) async -> Bool {
        guard inFlightJob == nil, !pendingJobs.isEmpty else { return false }
        let index = pendingJobs.firstIndex(where: { !$0.isPreview }) ?? 0
        let job = pendingJobs.remove(at: index)
        guard let item = segment(lectureID: job.lectureID, segmentID: job.segmentID),
              canTranslate(job, item: item) else { return true }
        let epoch = translationEpoch
        inFlightJob = job
        defer {
            inFlightJob = nil
            if Task.isCancelled || translationEpoch != epoch,
               let latest = segment(lectureID: job.lectureID, segmentID: job.segmentID),
               latest.translationState == .translating, canTranslate(job, item: latest) {
                changeSegment(lectureID: job.lectureID, segmentID: job.segmentID) { $0.translationState = .pending }
                if !job.isPreview || (activeLivePreview && paragraphBuffer != nil) {
                    enqueue(job.lectureID, latest, isPreview: job.isPreview)
                }
                persist(job.lectureID)
            }
            signal?.yield(())
        }
        changeSegment(lectureID: job.lectureID, segmentID: job.segmentID) { $0.translationState = .translating }
        do {
            let translated = try await translate(job.text)
            guard !Task.isCancelled, translationEpoch == epoch,
                  let latest = segment(lectureID: job.lectureID, segmentID: job.segmentID),
                  canTranslate(job, item: latest) else { return true }
            var applied = false
            changeSegment(lectureID: job.lectureID, segmentID: job.segmentID) {
                applied = job.isPreview ? $0.applyPreviewTranslation(translated, forSource: job.text) :
                    $0.applyTranslation(translated, forSource: job.text)
            }
            if applied { persist(job.lectureID); scheduleContextReview(for: job.lectureID) }
        } catch {
            guard !Task.isCancelled, translationEpoch == epoch,
                  let latest = segment(lectureID: job.lectureID, segmentID: job.segmentID),
                  canTranslate(job, item: latest) else { return true }
            changeSegment(lectureID: job.lectureID, segmentID: job.segmentID) {
                $0.translationState = job.isPreview ? .pending : .failed
            }
            persist(job.lectureID)
        }
        return true
    }

    func makeSpeechEngine() -> any SpeechRecording {
        if let engineFactory { return engineFactory() }
        if speechBackend == .qwen { return QwenSpeechEngine() }
        return LocalSpeechEngine()
    }

    func start() async {
        guard phase == .idle || phase == .paused, !demoMode, deletionCandidate == nil,
              let lecture = current, let store else { return }
        let resuming = phase == .paused
        guard !resuming || pausedLectureID == lecture.id else {
            errorMessage = "请先结束已暂停的课堂，再切换到另一条记录。"; return
        }
        guard ready else { errorMessage = "请先准备所选识别引擎和中英翻译包。"; return }
        phase = .starting; errorMessage = nil; startupFailure = nil
        let allowed: Bool
        if let microphoneAccess { allowed = await microphoneAccess() }
        else {
            let permission = AVCaptureDevice.authorizationStatus(for: .audio)
            if permission == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
            else { allowed = permission == .authorized }
        }
        guard allowed else {
            phase = resuming ? .paused : .idle
            errorMessage = "麦克风尚未获准。请在系统设置 → 隐私与安全性 → 麦克风中允许“听课译记”。"
            return
        }
        let token = UUID(); generation = token
        let lectureID = lecture.id
        activeLectureID = lectureID; offset = lecture.duration
        prepareTranscription(for: lecture)
        let filename = "\(lectureID)-\(UUID()).caf"
        activeAudioFilename = keepAudio ? filename : nil
        let audioURL = keepAudio ? store.recordings.appendingPathComponent(filename) : nil
        let engine = makeSpeechEngine(); self.engine = engine
        let words = CourseGlossary.terms(domain: courseDomain, custom: contextualWords).map(\.english)
        do {
            try await engine.start(audioURL: audioURL, contextualWords: Array(words), offset: offset,
                receive: { [weak self] update in
                    await self?.receive(update, lectureID: lectureID, token: token)
                }, meter: { [weak self] value in
                    Task { @MainActor in if self?.generation == token { self?.level = value } }
                }, failure: { [weak self] message in
                    Task { @MainActor in await self?.handleFailure(message, token: token) }
                })
            started = recordingNow(); pausedLectureID = nil; phase = .listening
            changeLecture(lectureID) {
                $0.interrupted = true
                if let audioName = activeAudioFilename { $0.audio.append(AudioClip(filename: audioName, start: offset, end: offset)) }
            }
            persist(lectureID)
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            if let startupFailure { await handleFailure(startupFailure, token: token) }
        } catch {
            _ = await engine.stop()
            self.engine = nil; activeLectureID = nil; activeAudioFilename = nil
            finishTranscription(for: lectureID)
            persist(lectureID)
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            generation = UUID(); level = 0
            phase = resuming ? .paused : .idle
            if case ClassScribeError.speechAssetsUnavailable = error {
                speechReady = false; speechStatus = "英语语音包需要重新准备"
            } else if case ClassScribeError.qwenAssetsUnavailable = error {
                speechReady = false; speechStatus = "千问识别组件需要重新准备"
            }
            errorMessage = "无法开始听课：\(error.localizedDescription)"
        }
    }

    func stop() async {
        if phase == .paused {
            if let id = pausedLectureID { persist(id) }
            pausedLectureID = nil; phase = .idle
            return
        }
        await endCapture(pausing: false)
    }

    func pause() async { await endCapture(pausing: true) }

    func resume() async {
        guard phase == .paused else { return }
        await start()
    }

    func togglePause() async {
        if phase == .listening { await pause() }
        else if phase == .paused { await resume() }
    }

    private func endCapture(pausing: Bool) async {
        guard phase == .listening, let lectureID = activeLectureID else { return }
        tick(); timer?.invalidate(); timer = nil; phase = pausing ? .pausing : .stopping
        previewTask?.cancel(); previewTask = nil
        activeLivePreview = false; cancelParagraphPreview()
        let problem = await engine?.stop()
        // Final callbacks have been consumed before the engine returns from stop().
        changeLecture(lectureID) { lecture in
            lecture.duration = max(lecture.duration, lecture.segments.map(\.end).max() ?? 0)
            lecture.interrupted = problem != nil
            if let audioName = activeAudioFilename, let i = lecture.audio.firstIndex(where: { $0.filename == audioName }) {
                lecture.audio[i].end = lecture.duration
            }
        }
        finishTranscription(for: lectureID)
        persist(lectureID)
        engine = nil; activeLectureID = nil; activeAudioFilename = nil; started = nil
        generation = UUID(); level = 0
        pausedLectureID = pausing ? lectureID : nil
        phase = pausing ? .paused : .idle
        if let problem { errorMessage = problem }
    }

    private func tick() {
        guard phase == .listening, let started, let lectureID = activeLectureID else { return }
        changeLecture(lectureID) {
            $0.duration = max($0.duration, offset + max(0, recordingNow().timeIntervalSince(started)))
            if let filename = activeAudioFilename, let index = $0.audio.firstIndex(where: { $0.filename == filename }) {
                $0.audio[index].end = $0.duration
            }
        }
        closeParagraphAfterPause(for: lectureID, at: Date.timeIntervalSinceReferenceDate)
        if Date().timeIntervalSince(lastCheckpoint) >= 5 {
            lastCheckpoint = Date(); persist(lectureID)
        }
    }

    private func receive(_ update: RecognitionUpdate, lectureID: UUID, token: UUID) {
        guard generation == token, activeLectureID == lectureID else { return }
        consumeRecognition(update, lectureID: lectureID, at: Date.timeIntervalSinceReferenceDate)
    }

    func prepareTranscription(for lecture: Lecture) {
        cancelContextReview()
        cancelParagraphPreview()
        lastParagraphPreviewRequest = nil
        activeTranslationStyle = translationStyle
        activeLivePreview = liveChinesePreview
        paragraphBaseCount = lecture.segments.count
        paragraphBuffer = translationStyle == .paragraphs ? ParagraphBuffer(targetDuration: Double(paragraphLength.rawValue)) : nil
    }

    func consumeRecognition(_ update: RecognitionUpdate, lectureID: UUID, at time: Double) {
        guard let index = lectures.firstIndex(where: { $0.id == lectureID }) else { return }
        if activeTranslationStyle == .paragraphs {
            guard paragraphBuffer?.ingest(update, at: time) == true else { return }
            renderParagraphs(for: lectureID)
            if update.isFinal { persist(lectureID) }
            scheduleContextReview(for: lectureID)
            return
        }
        guard let id = TranscriptTimeline.ingest(update, into: &lectures[index].segments),
              let item = segment(lectureID: lectureID, segmentID: id) else { return }
        if update.isFinal {
            previewTask?.cancel(); previewTask = nil
            enqueue(lectureID, item); persist(lectureID)
        } else {
            previewTask?.cancel()
            previewTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled, let self,
                      let latest = self.segment(lectureID: lectureID, segmentID: id), latest.english == item.english else { return }
                self.enqueue(lectureID, latest)
            }
        }
        scheduleContextReview(for: lectureID)
    }

    func closeParagraphAfterPause(for lectureID: UUID, at time: Double) {
        guard paragraphBuffer?.closeAfterPause(at: time) == true else { return }
        renderParagraphs(for: lectureID)
        persist(lectureID)
        scheduleContextReview(for: lectureID)
    }

    func finishTranscription(for lectureID: UUID) {
        previewTask?.cancel(); previewTask = nil
        cancelParagraphPreview()
        if activeTranslationStyle == .paragraphs {
            paragraphBuffer?.finish()
            renderParagraphs(for: lectureID)
        } else if let lecture = lectures.first(where: { $0.id == lectureID }) {
            for item in lecture.segments where !item.isFinal && item.translationState != .complete && item.translationState != .edited {
                enqueue(lectureID, item)
            }
        }
        paragraphBuffer = nil; paragraphBaseCount = 0
        activeLivePreview = false
        scheduleContextReview(for: lectureID)
    }

    private func renderParagraphs(for lectureID: UUID) {
        guard let index = lectures.firstIndex(where: { $0.id == lectureID }), paragraphBuffer != nil else { return }
        let history = Array(lectures[index].segments.prefix(paragraphBaseCount))
        let previous = Array(lectures[index].segments.dropFirst(paragraphBaseCount))
        let rows = paragraphBuffer!.render(reusing: previous)
        lectures[index].segments = history + rows
        pendingJobs.removeAll { job in
            job.lectureID == lectureID &&
                !lectures[index].segments.contains(where: { $0.id == job.segmentID && canTranslate(job, item: $0) })
        }
        for item in rows where !item.isCollectingParagraph && item.translationState == .pending {
            enqueue(lectureID, item)
        }
        scheduleParagraphPreview(for: lectureID)
    }

    private func cancelParagraphPreview() {
        paragraphPreviewTask?.cancel(); paragraphPreviewTask = nil
        paragraphPreviewToken = UUID()
    }

    private func scheduleParagraphPreview(for lectureID: UUID) {
        guard activeLivePreview, paragraphBuffer != nil, paragraphPreviewTask == nil,
              let item = lectures.first(where: { $0.id == lectureID })?.segments.last,
              item.isCollectingParagraph, !item.english.isEmpty else { return }
        let token = paragraphPreviewToken
        let delay = lastParagraphPreviewRequest.map { max(0, previewInterval - Date().timeIntervalSince($0)) } ?? previewInitialDelay
        // Updates do not reset this timer: a continuously speaking teacher must still get Chinese previews.
        paragraphPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.paragraphPreviewToken == token else { return }
            self.paragraphPreviewTask = nil
            self.requestParagraphPreview(for: lectureID)
        }
    }

    func requestParagraphPreview(for lectureID: UUID) {
        guard activeLivePreview, paragraphBuffer != nil,
              let item = lectures.first(where: { $0.id == lectureID })?.segments.last,
              item.isCollectingParagraph, !item.english.isEmpty,
              !(item.hasPreviewTranslation && item.translatedSource == item.english) else { return }
        lastParagraphPreviewRequest = Date()
        enqueue(lectureID, item, isPreview: true)
    }

    private func handleFailure(_ message: String, token: UUID) async {
        guard generation == token else { return }
        if phase == .starting { startupFailure = message; return }
        if phase == .listening { await stop(); errorMessage = message }
    }

    func newLecture() {
        guard !busy, !demoMode, deletionCandidate == nil else { return }
        cancelContextReview()
        let lecture = Lecture.fresh(); lectures.insert(lecture, at: 0); selectedID = lecture.id
        persist(lecture.id)
    }

    func requestDeletion(_ id: UUID? = nil) {
        guard !busy, !demoMode, store != nil, let id = id ?? selectedID,
              let lecture = lectures.first(where: { $0.id == id }) else { return }
        deletionCandidate = lecture
    }

    func cancelDeletion() { deletionCandidate = nil }

    func deleteLecture(_ requestedID: UUID) {
        deletionCandidate = nil
        guard !busy, !demoMode, let store,
              let index = lectures.firstIndex(where: { $0.id == requestedID }) else { return }
        let lecture = lectures[index]
        do {
            try store.moveToTrash(lecture, using: trashAction)
        } catch {
            errorMessage = "课堂未能移到废纸篓，记录仍保留在列表中。\n\(error.localizedDescription)"
            return
        }
        pendingJobs.removeAll { $0.lectureID == lecture.id }
        if contextLectureID == lecture.id { cancelContextReview() }
        previewTask?.cancel(); previewTask = nil
        cancelParagraphPreview()
        lectures.remove(at: index)
        if selectedID == lecture.id {
            selectedID = lectures.isEmpty ? nil : lectures[min(index, lectures.count - 1)].id
        }
    }

    func enterDemo() {
        guard !busy, !demoMode else { return }
        cancelContextReview()
        for lecture in lectures { persist(lecture.id) }
        realLectures = lectures; realSelectedID = selectedID
        let example = AppModel(demoMode: true, preferences: preferences)
        demoMode = true; lectures = example.lectures; selectedID = lectures.first?.id
    }

    func leaveDemo() {
        guard demoMode, let records = realLectures else { return }
        lectures = records; selectedID = realSelectedID
        realLectures = nil; realSelectedID = nil; demoMode = false
        retryTranslations(allRecords: true)
    }

    func rename(_ title: String) {
        guard let id = selectedID else { return }
        changeLecture(id) { $0.title = title }
        persist(id)
    }

    func edit(_ id: UUID, english: String, chinese: String) {
        guard let lectureID = selectedID else { return }
        let source = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        changeSegment(lectureID: lectureID, segmentID: id) {
            let sourceChanged = $0.english != source
            $0.english = source; $0.chinese = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.edited = true
            $0.translationState = $0.chinese.isEmpty ? .pending : .edited
            $0.translatedSource = $0.chinese.isEmpty ? nil : source
            $0.translationIsPreview = false
            if sourceChanged { $0.confidence = nil }
        }
        pendingJobs.removeAll { $0.lectureID == lectureID && $0.segmentID == id }
        if let item = segment(lectureID: lectureID, segmentID: id), item.chinese.isEmpty { enqueue(lectureID, item) }
        persist(lectureID)
    }

    func retryTranslations(allRecords: Bool = false) {
        let records = allRecords ? lectures : lectures.filter { $0.id == selectedID }
        for lecture in records {
            for item in lecture.segments where item.translationState == .failed || item.translationState == .pending || item.translationState == .translating {
                enqueue(lecture.id, item)
            }
        }
    }

    private func enqueue(_ lectureID: UUID, _ item: TranscriptSegment, isPreview: Bool = false) {
        guard item.translationState != .edited, !item.english.isEmpty,
              isPreview ? item.isCollectingParagraph : !item.isCollectingParagraph else { return }
        let sameJob: (TranslationJob) -> Bool = { $0.lectureID == lectureID && $0.segmentID == item.id &&
            $0.text == item.english && $0.isPreview == isPreview }
        guard !pendingJobs.contains(where: sameJob), !(inFlightJob.map(sameJob) ?? false) else { return }
        pendingJobs.removeAll { $0.lectureID == lectureID && $0.segmentID == item.id }
        pendingJobs.append(TranslationJob(lectureID: lectureID, segmentID: item.id,
            text: item.english, isFinal: item.isFinal, isPreview: isPreview))
        signal?.yield(())
    }

    private func segment(lectureID: UUID, segmentID: UUID) -> TranscriptSegment? {
        lectures.first(where: { $0.id == lectureID })?.segments.first(where: { $0.id == segmentID })
    }

    private func changeSegment(lectureID: UUID, segmentID: UUID, _ change: (inout TranscriptSegment) -> Void) {
        guard let record = lectures.firstIndex(where: { $0.id == lectureID }),
              let segment = lectures[record].segments.firstIndex(where: { $0.id == segmentID }) else { return }
        change(&lectures[record].segments[segment])
    }

    private func changeLecture(_ id: UUID, _ change: (inout Lecture) -> Void) {
        guard let index = lectures.firstIndex(where: { $0.id == id }) else { return }
        change(&lectures[index])
    }

    func persist(_ id: UUID? = nil) {
        guard !demoMode, let store, let id = id ?? selectedID,
              let lecture = lectures.first(where: { $0.id == id }) else { return }
        do { try store.save(lecture); savedAt = Date() }
        catch { storageWarning = "自动保存失败，请先导出当前文字。\n\(error.localizedDescription)" }
    }

    func openRecords() {
        if let store { NSWorkspace.shared.open(store.root) }
    }

    func revealAudio() {
        guard let store else { return }
        NSWorkspace.shared.open(store.recordings)
    }

    func export(_ format: String) {
        guard let lecture = current else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = lecture.title.replacingOccurrences(of: "/", with: "_") + "." + format
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if format == "docx" { try TranscriptExport.docx(lecture, to: url) }
                else {
                    let value = format == "srt" ? TranscriptExport.srt(lecture) : TranscriptExport.text(lecture)
                    try value.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch { self?.errorMessage = "导出失败：\(error.localizedDescription)" }
        }
    }

    func copyTranscript() {
        guard let current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptExport.text(current), forType: .string)
    }

    func finishBeforeQuit() async {
        while phase.isTransitioning {
            await withCheckedContinuation { transitionWaiters.append($0) }
        }
        if phase == .listening || phase == .paused { await stop() }
        speechPreparationTask?.cancel()
        await speechPreparationTask?.value
        contextPreparationTask?.cancel()
        await contextPreparationTask?.value
        cancelContextReview()
        await contextService.shutdown()
        for lecture in lectures { persist(lecture.id) }
    }

    func refreshContextAvailability() async {
        guard !demoMode, contextEnabled, !contextPreparing else { return }
        let selected = contextModel
        do {
            let status = try await contextService.availability(for: selected)
            guard contextModel == selected, contextEnabled else { return }
            contextReady = status == .ready
            contextStatus = contextReady ? "上下文校对已就绪 · 本机处理" : "需要准备上下文模型"
        } catch {
            contextReady = false; contextStatus = "上下文模型未就绪：\(error.localizedDescription)"
        }
    }

    func prepareContextModel() {
        guard !demoMode, !busy, !contextPreparing else { return }
        contextPreparing = true; contextReady = false; contextProgress = 0
        let selected = contextModel
        contextPreparationTask = Task {
            do {
                try await contextService.prepare(model: selected) { [weak self] progress, status in
                    await self?.setContextProgress(progress, status: status)
                }
                contextReady = contextModel == selected
                contextStatus = "上下文校对已就绪 · 本机处理"
            } catch {
                contextStatus = Task.isCancelled ? "模型准备已取消，可稍后继续" : "上下文模型准备失败：\(error.localizedDescription)"
            }
            contextPreparing = false
            contextPreparationTask = nil
        }
    }

    func cancelContextPreparation() { contextPreparationTask?.cancel() }

    func retryContextReview() {
        guard let id = selectedID else { return }
        cancelContextReview()
        Task {
            await refreshContextAvailability()
            scheduleContextReview(for: id)
        }
    }

    private func setContextProgress(_ progress: Double, status: String) {
        guard contextPreparing else { return }
        contextProgress = progress; contextStatus = status
    }

    private func resetContextSettings() {
        cancelContextReview(); contextReady = false
        Task { await refreshContextAvailability() }
    }

    private func cancelContextReview() {
        contextEpoch = UUID()
        contextTimer?.cancel(); contextTimer = nil
        contextTask?.cancel(); contextTask = nil
        contextWorking = false; lastContextFingerprint = nil; contextLectureID = nil
    }

    func scheduleContextReview(for lectureID: UUID) {
        guard contextEnabled, contextReady, !demoMode,
              let lecture = lectures.first(where: { $0.id == lectureID }),
              let window = ContextReviewWindow.make(lecture: lecture, domain: courseDomain,
                custom: contextualWords, subject: courseSubject, model: contextModel),
              window.fingerprint != lastContextFingerprint else { return }
        contextLectureID = lectureID
        guard contextTimer == nil, contextTask == nil else { return }
        let epoch = contextEpoch
        let delay = max(0.1, contextInterval - Date().timeIntervalSince(lastContextStarted))
        contextTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.contextEpoch == epoch else { return }
            self.contextTimer = nil
            self.beginContextReview(for: lectureID)
        }
    }

    func beginContextReview(for lectureID: UUID) {
        guard contextEnabled, contextReady, !demoMode, contextTask == nil,
              let lecture = lectures.first(where: { $0.id == lectureID }),
              let window = ContextReviewWindow.make(lecture: lecture, domain: courseDomain,
                custom: contextualWords, subject: courseSubject, model: contextModel),
              window.fingerprint != lastContextFingerprint else { return }
        let epoch = contextEpoch
        contextLectureID = lectureID; lastContextFingerprint = window.fingerprint
        lastContextStarted = Date(); contextWorking = true
        contextStatus = "正在结合后文校对 · 原始识别已保留"
        contextTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.contextEpoch == epoch {
                    self.contextTask = nil; self.contextWorking = false
                    self.scheduleContextReview(for: lectureID)
                }
            }
            do {
                let patches = try await self.contextService.review(window)
                guard !Task.isCancelled, self.contextEpoch == epoch, self.contextEnabled else { return }
                let applied = self.applyContextPatches(patches, window: window)
                self.contextStatus = applied > 0 ? "已结合后文更新校订 · 可查看原始识别" : "上下文校对已就绪 · 本机处理"
            } catch {
                guard !Task.isCancelled, self.contextEpoch == epoch else { return }
                self.contextStatus = "本次校对未完成，原始识别已保留"
                self.lastContextStarted = Date().addingTimeInterval(20)
            }
        }
    }

    @discardableResult
    func applyContextPatches(_ patches: [ContextReviewPatch], window: ContextReviewWindow) -> Int {
        guard let lecture = lectures.first(where: { $0.id == window.lectureID }) else { return 0 }
        var applied = 0
        for patch in patches.prefix(3) {
            guard let revision = ContextReviewPolicy.revision(patch, window: window) else { continue }
            let entry = window.entries[patch.index]
            guard let index = lecture.segments.firstIndex(where: { $0.id == entry.id }),
                  lecture.segments[index].english == entry.english, lecture.segments[index].chinese == entry.chinese,
                  lecture.segments.dropFirst(index + 1).contains(where: {
                      ContextReviewPolicy.normalized($0.english).contains(ContextReviewPolicy.normalized(revision.evidence))
                  }) else { continue }
            // Unrelated volatile text may be revised while inference runs. Only
            // the target and the actually quoted later evidence must still match.
            changeSegment(lectureID: window.lectureID, segmentID: entry.id) {
                if $0.applyContextRevision(revision, expectedPrevious: entry.revision) { applied += 1 }
            }
        }
        if applied > 0 { persist(window.lectureID) }
        return applied
    }
}
