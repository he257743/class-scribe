import SwiftUI
import Translation

private let ink = Color(red: 0.10, green: 0.15, blue: 0.18)
private let accent = Color(red: 0.08, green: 0.46, blue: 0.41)
private let surface = Color(red: 0.965, green: 0.972, blue: 0.973)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showPreferences = false
    @State private var editing: TranscriptSegment?
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if model.demoMode {
                    HStack {
                        Image(systemName: "play.rectangle")
                        Text("演示模式 · 以下是示例文字，没有开启麦克风")
                        Spacer()
                        Button("返回课堂记录") { model.leaveDemo() }.buttonStyle(.borderless)
                    }
                    .font(.callout).padding(.horizontal, 26).padding(.vertical, 10)
                    .background(Color.orange.opacity(0.10))
                }
                if !model.ready && !model.demoMode { preparation }
                transcript
                Divider()
                controls
            }
            .background(Color.white)
        }
        .foregroundStyle(ink)
        .tint(accent)
        .frame(minWidth: 980, minHeight: 680)
        .task { await model.refreshAvailability() }
        .translationTask(model.translationConfiguration) { session in
            await model.runTranslation(using: session)
        }
        .alert("需要留意", isPresented: Binding(get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
                Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("删除课堂记录？", isPresented: Binding(
            get: { model.deletionCandidate != nil },
            set: { if !$0 { model.cancelDeletion() } }), titleVisibility: .visible,
            presenting: model.deletionCandidate) { lecture in
                Button("移到废纸篓", role: .destructive) { model.deleteLecture(lecture.id) }
                Button("取消", role: .cancel) { model.cancelDeletion() }
        } message: { lecture in
            Text("“\(lecture.title.isEmpty ? "未命名课堂" : lecture.title)”的课堂文字和关联录音将一起移到废纸篓，可从废纸篓找回。已导出的文件会保留。")
        }
        .sheet(item: $editing) { segment in
            EditSegmentView(segment: segment) { en, zh in model.edit(segment.id, english: en, chinese: zh) }
        }
        .sheet(isPresented: $showHelp) { help }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 23, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 38, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("听课译记").font(.system(size: 19, weight: .bold))
                    Text("CLASS SCRIBE").font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 28)

            Button { model.newLecture() } label: {
                Label("新建课堂", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent).disabled(model.busy || model.demoMode)
            .padding(.horizontal, 18)

            HStack {
                Text("课堂记录").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.lectures.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.top, 29).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.lectures) { lecture in
                        Button { model.selectedID = lecture.id } label: {
                            HStack(alignment: .top, spacing: 9) {
                                RoundedRectangle(cornerRadius: 2).fill(model.selectedID == lecture.id ? accent : .clear)
                                    .frame(width: 3, height: 29)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(lecture.title.isEmpty ? "未命名课堂" : lecture.title)
                                        .font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    HStack(spacing: 7) {
                                        Text(lecture.created, format: .dateTime.month().day())
                                        Text("·")
                                        Text(TranscriptSegment.time(lecture.duration))
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                            .background(model.selectedID == lecture.id ? Color.white : .clear,
                                in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain).disabled(model.busy)
                        .contextMenu {
                            Button("删除课堂…", role: .destructive) { model.requestDeletion(lecture.id) }
                                .disabled(model.busy || model.demoMode || model.store == nil)
                        }
                    }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 10) {
                Label("音频与文字在本机处理", systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(accent)
                Button { model.openRecords() } label: { Label("打开保存文件夹", systemImage: "folder") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { showHelp = true } label: { Label("使用说明", systemImage: "questionmark.circle") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(20)
        }
        .frame(width: 220).background(surface)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(model.current == nil ? "新建一堂课" : "课堂名称", text: Binding(get: { model.current?.title ?? "" }, set: model.rename))
                    .textFieldStyle(.plain).font(.system(size: 22, weight: .semibold))
                    .accessibilityLabel("课堂名称")
                    .disabled(model.current == nil)
                HStack(spacing: 7) {
                    Text("English").fontWeight(.medium)
                    Image(systemName: "arrow.right").font(.system(size: 10))
                    Text("简体中文").fontWeight(.medium)
                    Text("·  麦克风收音").foregroundStyle(.secondary)
                    Text("·  \(model.translationStyle.title)").foregroundStyle(.secondary)
                }.font(.system(size: 12)).foregroundStyle(accent)
            }
            Spacer(minLength: 6)
            Button { showPreferences.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 16)) }
                .buttonStyle(.borderless).help("收音与术语设置")
                .popover(isPresented: $showPreferences) { preferences }
            Menu {
                Button("Word 文档（.docx）") { model.export("docx") }
                Button("中英对照文本（.txt）") { model.export("txt") }
                Button("双语字幕（.srt）") { model.export("srt") }
                Divider()
                Button("复制全部文字") { model.copyTranscript() }
                Button("打开原音文件夹") { model.revealAudio() }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderedButton).disabled(!model.canExportTranscript)
            Button(role: .destructive) { model.requestDeletion() } label: {
                Image(systemName: "trash").font(.system(size: 15))
            }
            .buttonStyle(.borderless).help("删除当前课堂").accessibilityLabel("删除当前课堂")
            .disabled(!model.canDeleteLecture)
        }
        .padding(.horizontal, 27).padding(.vertical, 23)
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("先准备本机语言包").font(.system(size: 15, weight: .semibold))
                    Text("首次需要联网下载。准备完成后，可断网收音、识别和翻译。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.preparing ? "正在准备…" : "准备语言包") { model.prepareLanguages() }
                    .buttonStyle(.borderedProminent).disabled(model.preparing || model.busy || model.store == nil)
            }
            HStack(spacing: 20) {
                statusItem(model.speechStatus, ready: model.speechReady, working: model.speechPreparing)
                statusItem(model.translationStatus, ready: model.translationReady, working: model.translationPreparing)
            }
            if model.speechPreparing && model.speechProgress > 0 {
                ProgressView(value: model.speechProgress).tint(accent)
            }
        }
        .padding(18).background(surface, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 26).padding(.top, 20)
    }

    private func statusItem(_ title: String, ready: Bool, working: Bool) -> some View {
        HStack(spacing: 6) {
            if working { ProgressView().controlSize(.mini) }
            else { Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(ready ? accent : .secondary) }
            Text(title).lineLimit(2)
        }.font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            if let warning = model.storageWarning {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning).textSelection(.enabled)
                    Spacer()
                    Button("导出文本") { model.export("txt") }.disabled(!model.hasContent)
                }
                .font(.callout).foregroundStyle(.red).padding(14).background(Color.red.opacity(0.05))
            }
            if !model.hasContent { emptyState }
            else {
                HStack(spacing: 24) {
                    Text("英语原文").frame(maxWidth: .infinity, alignment: .leading)
                    Text("中文翻译").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 42).padding(.top, 23).padding(.bottom, 11)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(model.current?.segments ?? []) { segment in
                                TranscriptRow(item: segment, recordingActive: model.busy && model.phase != .paused,
                                    livePreviewEnabled: model.liveChinesePreview,
                                    editingEnabled: !model.busy && !model.demoMode) { editing = segment }
                                    .id(segment.id)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(.horizontal, 26).padding(.bottom, 22)
                    }
                    .onChange(of: model.current?.segments.last?.english) { _, _ in
                        if model.autoScroll { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("end", anchor: .bottom) } }
                    }
                    .onChange(of: model.current?.segments.last?.chinese) { _, _ in
                        if model.autoScroll { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("end", anchor: .bottom) } }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: model.phase == .paused ? "pause.circle" : (model.phase == .listening ? "waveform" : "text.bubble"))
                .font(.system(size: 38, weight: .light)).foregroundStyle(accent.opacity(0.75))
                .padding(.bottom, 9)
            Text(emptyTitle)
                .font(.system(size: 22, weight: .medium))
            Text(emptyMessage)
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
            if model.current == nil {
                Button("新建课堂") { model.newLecture() }.buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.demoMode)
            }
            if model.current?.interrupted == true {
                Text("上次记录中断，已保存的内容仍在本机。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    private var emptyTitle: String {
        if model.current == nil { return "还没有课堂记录" }
        if model.phase == .paused { return "已暂停听课" }
        return model.phase == .listening ? "正在听，请开始说话" : "开始一堂课"
    }

    private var emptyMessage: String {
        if model.current == nil { return "点击“新建课堂”，开始记录下一堂课。" }
        if model.phase == .paused { return "麦克风已停止，点击“继续听课”接着记录。\n暂停时间不会计入课堂时长。" }
        if model.translationStyle == .paragraphs {
            return model.liveChinesePreview ? "英文和中文预览随讲述更新。\n段落结束后，再用完整上下文统一定稿。" :
                "英文实时出现，连续几句话合成一段翻译。\n明显停顿或达到段落长度后，显示整段中文。"
        }
        return "老师讲英语，这里显示原文和中文译文。\n文字会随识别结果更新，停顿后逐段定稿。"
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 15) {
                HStack(spacing: 3) {
                    ForEach(0..<12) { index in
                        Capsule().fill(model.phase == .listening && model.level > Double(index) / 13 ? accent : Color.gray.opacity(0.19))
                            .frame(width: 3, height: CGFloat([8, 13, 19, 25, 17, 30, 22, 14, 26, 20, 12, 7][index]))
                    }
                }.frame(width: 72, height: 32).accessibilityLabel("麦克风音量")
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.statusLabel).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(TranscriptSegment.time(model.current?.duration ?? 0))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.pendingCount > 0 && model.translationReady {
                    Text("\(model.pendingCount) 段待译").font(.caption).foregroundStyle(.secondary)
                }
                if model.failedCount > 0 {
                    Button("重试 \(model.failedCount) 段翻译") { model.retryTranslations() }
                        .font(.caption).disabled(!model.translationReady)
                }
                if model.phase == .listening || model.phase == .paused {
                    Button {
                        Task {
                            if model.phase == .paused { await model.stop() }
                            else { await model.pause() }
                        }
                    } label: {
                        Label(model.phase == .paused ? "结束听课" : "暂停",
                            systemImage: model.phase == .paused ? "stop.fill" : "pause.fill")
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .help(model.phase == .paused ? "结束这堂课，之后可新建或切换记录" : "暂停收音（⌘⇧P）")
                }
                Button {
                    Task {
                        if model.phase == .listening { await model.stop() }
                        else if model.phase == .paused { await model.resume() }
                        else if model.phase == .idle { await model.start() }
                    }
                } label: {
                    Label(buttonTitle, systemImage: model.phase == .listening ? "stop.fill" :
                        (model.phase == .paused ? "play.fill" : "mic.fill"))
                        .font(.system(size: 14, weight: .semibold)).frame(width: 123).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.phase == .listening ? Color(red: 0.72, green: 0.22, blue: 0.24) : accent)
                .disabled(model.phase.isTransitioning || model.preparing || model.current == nil ||
                    model.deletionCandidate != nil || (!model.ready && (model.phase == .idle || model.phase == .paused)))
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            HStack(spacing: 7) {
                Image(systemName: model.storageWarning == nil ? "checkmark.circle" : "exclamationmark.triangle")
                Text(model.storageWarning == nil ? "自动保存到本机" : "自动保存异常")
                Text("·")
                Text(model.phase == .paused ? "暂停期间不收音" : (model.keepAudio ? "保留原音" : "仅保存文字"))
                Spacer()
                Toggle("跟随最新", isOn: $model.autoScroll).toggleStyle(.checkbox)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 27).padding(.vertical, 18)
    }

    private var buttonTitle: String {
        switch model.phase {
        case .starting: return "正在开启…"
        case .listening: return "停止听课"
        case .pausing: return "正在暂停…"
        case .paused: return "继续听课"
        case .stopping: return "正在收尾…"
        case .idle: return model.hasContent ? "继续听课" : "开始听课"
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("翻译与收音").font(.headline)
            Picker("翻译方式", selection: $model.translationStyle) {
                ForEach(TranslationStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }.pickerStyle(.segmented).disabled(model.busy)
            if model.translationStyle == .paragraphs {
                Picker("段落长度", selection: $model.paragraphLength) {
                    ForEach(ParagraphLength.allCases, id: \.self) { length in
                        Text(length.title).tag(length)
                    }
                }.disabled(model.busy)
                Toggle("实时中文预览", isOn: $model.liveChinesePreview).disabled(model.busy)
                Text(model.liveChinesePreview ? "讲述中先更新中文预览，段落结束后整段定稿。预览可能随上下文修订；更新速度取决于本机识别和翻译耗时。" :
                    "英文先实时显示，段落结束后整段翻译。识别停顿约 3 秒或接近所选长度时自动分段。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("分段设置在下次开始或继续听课时生效。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("保留原音，方便课后回听", isOn: $model.keepAudio).disabled(model.busy)
            Text("使用系统当前选择的麦克风。可在系统设置 → 声音 → 输入中切换。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("课堂术语提示").font(.subheadline.weight(.medium))
            Text("用逗号或换行分隔，帮助识别人名和专业词。下次开始收音时生效。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.contextualWords).font(.system(size: 12)).frame(height: 95)
                .padding(6).background(surface, in: RoundedRectangle(cornerRadius: 7)).disabled(model.busy)
            Text("原音和记录保存在本机“应用程序支持 / ClassScribe”目录。")
                .font(.caption).foregroundStyle(.secondary)
            Button("打开保存文件夹") { model.openRecords() }
        }.padding(23).frame(width: 340)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 19) {
            Text("开始使用听课译记").font(.title2.bold())
            Text("1  首次点击“准备语言包”，联网下载系统的英语语音包和中英翻译包。")
            Text("2  新建课堂，点击“开始听课”，允许麦克风访问。尽量靠近老师或使用外接麦克风。")
            Text("3  中途可点击“暂停”，继续时点击“继续听课”，快捷键为 ⌘⇧P。暂停会停止收音和计时，已有内容的翻译仍可完成。下课时点击“停止听课”或“结束听课”。")
            Text("4  右键左侧课堂，选择“删除课堂”；也可点击右上角废纸篓按钮。确认后，课堂文字和关联录音一起移到废纸篓。录音期间无法删除。")
            Text("5  默认按段翻译并实时预览中文，段落结束后整段定稿。右上角设置可调整段落长度、关闭实时预览，或切回逐句翻译。停止时会补译末段。")
            Divider()
            Text("英语原文与中文机器翻译均可能有误。正在识别的段落会更新；人名、数字和专业术语建议结合原音核对。默认保留原音，可在收音设置中关闭。")
                .font(.callout).foregroundStyle(.secondary)
            Text("语言包准备完成后，语音识别和翻译均在设备端进行，不需要 API 密钥。软件不会自动开启麦克风。")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Button("打开保存文件夹") { model.openRecords() }; Spacer(); Button("知道了") { showHelp = false }.buttonStyle(.borderedProminent) }
        }.padding(30).frame(width: 510)
    }
}

private struct TranscriptRow: View {
    var item: TranscriptSegment
    var recordingActive: Bool
    var livePreviewEnabled: Bool
    var editingEnabled: Bool
    var edit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Text(item.timeLabel).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                if item.isCollectingParagraph { tag("段落进行中", color: accent) }
                else if !item.isFinal { tag(recordingActive ? "识别中 · 会更新" : "未定稿 · 建议回听", color: accent) }
                else if item.needsReview { tag("建议回听", color: .orange) }
                if item.edited { tag("已编辑", color: .secondary) }
                Spacer()
                Button(action: edit) { Image(systemName: "pencil").font(.system(size: 11)) }
                    .buttonStyle(.borderless).disabled(!editingEnabled).help("核对并编辑本段")
            }
            HStack(alignment: .top, spacing: 24) {
                Text(item.english).font(.system(size: 17)).lineSpacing(5)
                    .foregroundStyle(item.isFinal ? ink : ink.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                VStack(alignment: .leading, spacing: 7) {
                    if !item.chinese.isEmpty {
                        Text(item.chinese).font(.system(size: 17)).lineSpacing(5).textSelection(.enabled)
                    } else {
                        Text(item.isCollectingParagraph ? (livePreviewEnabled ? "正在生成实时中文预览…" : "正在收集这一段，停顿后显示整段中文…") :
                            (item.translationState == .failed ? "翻译未完成，可点击下方重试" : "等待本机翻译…"))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if item.hasPreviewTranslation {
                        Text(item.isCollectingParagraph ? "中文预览 · 随上下文更新" : "中文预览 · 等待整段定稿")
                            .font(.caption2).foregroundStyle(accent)
                    } else if item.translationState == .translating && !item.chinese.isEmpty {
                        Text("译文更新中").font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(item.isFinal && !item.isCollectingParagraph ? Color.white : accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
    }
    private func tag(_ title: String, color: Color) -> some View {
        Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 3).background(color.opacity(0.08), in: Capsule())
    }
}

private struct EditSegmentView: View {
    @Environment(\.dismiss) private var dismiss
    let segment: TranscriptSegment
    let save: (String, String) -> Void
    @State private var english = ""
    @State private var chinese = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("核对这一段").font(.title2.bold())
            Text(segment.timeLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("英语原文").font(.subheadline.weight(.medium))
            TextEditor(text: $english).font(.system(size: 15)).frame(height: 115).border(Color.gray.opacity(0.25))
            Text("中文译文").font(.subheadline.weight(.medium))
            TextEditor(text: $chinese).font(.system(size: 15)).frame(height: 115).border(Color.gray.opacity(0.25))
            Text("清空中文译文后保存，会按修改后的英文重新翻译。保留中文则视为人工核对结果。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存修改") { save(english, chinese); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(27).frame(width: 560)
        .onAppear { english = segment.english; chinese = segment.chinese }
    }
}
