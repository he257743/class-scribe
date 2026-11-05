import Foundation

enum TranslationState: String, Codable {
    case pending, translating, complete, failed, edited
}

enum TranslationStyle: String, CaseIterable {
    case paragraphs, sentences
    var title: String { self == .paragraphs ? "按段翻译" : "逐句翻译" }
}

enum ParagraphLength: Int, CaseIterable {
    case short = 15, balanced = 25, long = 40
    var title: String { "约 \(rawValue) 秒" }
}

struct RecognitionPart: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
    var isFinal: Bool
    var confidence: Double?
}

struct TranscriptSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var english: String
    var chinese = ""
    var isFinal: Bool
    var confidence: Double?
    var translationState: TranslationState = .pending
    var edited = false
    // Optional fields keep records from earlier releases readable without conversion.
    var paragraphComplete: Bool?
    var recognitionParts: [RecognitionPart]?
    var translatedSource: String?
    var translationIsPreview: Bool?
    var contextRevisions: [ContextRevision]?

    var activeContextRevision: ContextRevision? {
        guard !edited, translationState != .edited,
              let last = contextRevisions?.last, last.sourceEnglish == english else { return nil }
        return last
    }
    var presentedEnglish: String { activeContextRevision?.english ?? english }
    var presentedChinese: String { activeContextRevision?.chinese ?? chinese }

    @discardableResult
    mutating func applyContextRevision(_ revision: ContextRevision, expectedPrevious: ContextRevision?) -> Bool {
        guard !edited, translationState != .edited, !isCollectingParagraph,
              english == revision.sourceEnglish, activeContextRevision == expectedPrevious else { return false }
        if let last = activeContextRevision, last.english == revision.english && last.chinese == revision.chinese { return false }
        var history = contextRevisions ?? []
        history.append(revision)
        contextRevisions = Array(history.suffix(8))
        return true
    }

    var isCollectingParagraph: Bool { paragraphComplete == false }
    var hasPreviewTranslation: Bool { !chinese.isEmpty && translationIsPreview == true }

    @discardableResult
    mutating func applyTranslation(_ translated: String, forSource source: String) -> Bool {
        guard english == source, translationState != .edited else { return false }
        chinese = translated
        translationState = .complete
        translatedSource = source
        translationIsPreview = false
        return true
    }

    @discardableResult
    mutating func applyPreviewTranslation(_ translated: String, forSource source: String) -> Bool {
        guard isCollectingParagraph, translationState != .edited, !source.isEmpty,
              english.hasPrefix(source) else { return false }
        if let newer = translatedSource, hasPreviewTranslation, newer.count > source.count,
           english.hasPrefix(newer) { return false }
        chinese = translated
        translatedSource = source
        translationIsPreview = true
        translationState = .complete
        return true
    }

    var needsReview: Bool { !isFinal || (confidence.map { $0 < 0.65 } ?? false) }
    var timeLabel: String { "\(Self.time(start)) – \(Self.time(end))" }
    static func time(_ seconds: Double) -> String {
        let n = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
    }
}

struct AudioClip: Codable, Equatable {
    var filename: String
    var start: Double
    var end: Double
}

struct Lecture: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var created = Date()
    var duration: Double = 0
    var segments: [TranscriptSegment] = []
    var audio: [AudioClip] = []
    var interrupted = false
    var schemaVersion = 1

    static func fresh() -> Lecture {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return Lecture(title: "课堂记录 \(formatter.string(from: Date()))")
    }
}

struct RecognitionUpdate: Sendable {
    var start: Double
    var end: Double
    var text: String
    var isFinal: Bool
    var confidence: Double?
}

struct TranscriptTimeline {
    // Final results are immutable from the recognizer. Volatile ranges can be replaced.
    static func ingest(_ update: RecognitionUpdate, into segments: inout [TranscriptSegment]) -> UUID? {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, update.start.isFinite, update.end.isFinite,
              update.start >= 0, update.end >= update.start else { return nil }
        let matching = segments.firstIndex {
            abs($0.start - update.start) < 0.035 && abs($0.end - update.end) < 0.035
        }
        if let index = matching, segments[index].isFinal {
            return nil // Duplicate delivery must not erase a translation or a manual correction.
        }
        let preservedID = matching.map { segments[$0].id } ?? UUID()
        segments.removeAll { item in
            guard !item.isFinal else { return false }
            return item.id == preservedID ||
                (item.start < update.end - 0.001 && item.end > update.start + 0.001)
        }
        let item = TranscriptSegment(id: preservedID, start: update.start, end: update.end,
            english: text, isFinal: update.isFinal, confidence: update.confidence)
        segments.append(item)
        segments.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        return item.id
    }
}

struct ParagraphBuffer {
    let targetDuration: Double
    let pauseDuration: Double
    private var parts: [TranscriptSegment] = []
    private var closedAfter: Set<UUID> = []
    private var lastUpdateAt: Double?

    init(targetDuration: Double = 25, pauseDuration: Double = 3) {
        self.targetDuration = max(1, targetDuration)
        self.pauseDuration = max(1, pauseDuration)
    }

    @discardableResult
    mutating func ingest(_ update: RecognitionUpdate, at time: Double) -> Bool {
        guard TranscriptTimeline.ingest(update, into: &parts) != nil else { return false }
        lastUpdateAt = time
        return true
    }

    @discardableResult
    mutating func closeAfterPause(at time: Double) -> Bool {
        guard let lastUpdateAt, time - lastUpdateAt >= pauseDuration, let last = parts.last,
              !closedAfter.contains(last.id) else { return false }
        let start = parts.lastIndex(where: { closedAfter.contains($0.id) }).map { $0 + 1 } ?? 0
        guard parts[start...].allSatisfy(\.isFinal) else { return false }
        closedAfter.insert(last.id)
        return true
    }

    mutating func finish() {
        if let last = parts.last { closedAfter.insert(last.id) }
    }

    mutating func render(reusing existing: [TranscriptSegment] = []) -> [TranscriptSegment] {
        let previous = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [TranscriptSegment] = []
        var group: [TranscriptSegment] = []
        var boundaries = closedAfter
        func appendGroup(complete: Bool) {
            guard let first = group.first, let last = group.last else { return }
            let text = group.map(\.english).joined(separator: " ")
            // A volatile result can get a new ASR ID as its time range grows; the paragraph stays the same row.
            let old = previous[first.id] ?? existing.first { abs($0.start - first.start) < 0.035 }
            var row = TranscriptSegment(id: old?.id ?? first.id, start: first.start, end: last.end,
                english: text, isFinal: group.allSatisfy(\.isFinal),
                confidence: group.compactMap(\.confidence).min(), paragraphComplete: complete,
                recognitionParts: group.map { RecognitionPart(start: $0.start, end: $0.end,
                    text: $0.english, isFinal: $0.isFinal, confidence: $0.confidence) })
            row.contextRevisions = old?.contextRevisions
            if let old, old.english == text {
                row.chinese = old.chinese; row.translationState = old.translationState; row.edited = old.edited
                row.translatedSource = old.translatedSource; row.translationIsPreview = old.translationIsPreview
                if complete && old.isCollectingParagraph && old.hasPreviewTranslation && old.translationState != .edited {
                    row.translationState = .pending // A preview never substitutes for the completed paragraph translation.
                }
            } else if let old, old.hasPreviewTranslation, let source = old.translatedSource,
                      text.hasPrefix(source) {
                row.chinese = old.chinese; row.translatedSource = source; row.translationIsPreview = true
            }
            result.append(row)
            group.removeAll(keepingCapacity: true)
        }
        for part in parts {
            if let last = group.last, part.start - last.end >= pauseDuration,
               group.allSatisfy(\.isFinal) {
                boundaries.insert(last.id)
                appendGroup(complete: true)
            }
            group.append(part)
            let duration = part.end - (group.first?.start ?? part.start)
            let tail = part.english.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"'”’)]"))
            let sentenceEnded = tail.last.map { ".!?。！？".contains($0) } ?? false
            let timedBoundary = group.allSatisfy(\.isFinal) &&
                ((duration >= targetDuration && sentenceEnded) || duration >= targetDuration * 1.5)
            if boundaries.contains(part.id) || timedBoundary {
                boundaries.insert(part.id)
                appendGroup(complete: true)
            }
        }
        appendGroup(complete: false)
        closedAfter = boundaries
        return result
    }
}

struct LectureStore {
    typealias TrashAction = (URL) throws -> Void
    let root: URL
    var recordings: URL { root.appendingPathComponent("录音", isDirectory: true) }
    var records: URL { root.appendingPathComponent("记录", isDirectory: true) }

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("ClassScribe", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    }

    func save(_ lecture: Lecture) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(lecture).write(to: records.appendingPathComponent("\(lecture.id).json"), options: .atomic)
    }

    static func systemTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func moveToTrash(_ lecture: Lecture, using trash: TrashAction = LectureStore.systemTrash) throws {
        let manager = FileManager.default
        // Only include audio owned by this classroom, never arbitrary paths from a damaged JSON file.
        let names = Set(lecture.audio.map(\.filename))
        for name in names {
            guard !name.contains("/"), !name.contains("\\"),
                  name.hasPrefix("\(lecture.id)-"), name.hasSuffix(".caf") else {
                throw NSError(domain: "ClassScribe.Storage", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "关联录音的文件名异常，课堂未删除。请打开保存文件夹检查。"])
            }
        }
        let bundle = root.appendingPathComponent("待删除课堂-\(lecture.id)-\(UUID())", isDirectory: true)
        let archivedStore = try LectureStore(root: bundle)
        var moved: [(source: URL, destination: URL)] = []
        do {
            let record = records.appendingPathComponent("\(lecture.id).json")
            if manager.fileExists(atPath: record.path) {
                let destination = archivedStore.records.appendingPathComponent(record.lastPathComponent)
                try manager.moveItem(at: record, to: destination)
                moved.append((record, destination))
            } else {
                // Even a classroom not yet saved gets a recoverable snapshot in the Trash.
                try archivedStore.save(lecture)
            }
            for name in names.sorted() {
                let audio = recordings.appendingPathComponent(name)
                guard manager.fileExists(atPath: audio.path) else { continue }
                let destination = archivedStore.recordings.appendingPathComponent(name)
                try manager.moveItem(at: audio, to: destination)
                moved.append((audio, destination))
            }
            try trash(bundle)
        } catch {
            var rollbackFailed = false
            for item in moved.reversed() {
                do { try manager.moveItem(at: item.destination, to: item.source) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed {
                throw NSError(domain: "ClassScribe.Storage", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "删除未完成，部分文件保留在 \(bundle.path)。请先备份该文件夹，再检查文件权限。"])
            }
            try? manager.removeItem(at: bundle)
            throw error
        }
    }

    func load() throws -> [Lecture] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: records,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("._") }
        var result: [Lecture] = []
        for url in files {
            // Do not silently overwrite a damaged record with an empty document.
            let data = try Data(contentsOf: url)
            var lecture = try decoder.decode(Lecture.self, from: data)
            for i in lecture.segments.indices where lecture.segments[i].translationState == .translating {
                lecture.segments[i].translationState = .pending
            }
            // After a crash, translate all text that was actually saved, including an unfinished paragraph.
            for i in lecture.segments.indices where lecture.segments[i].isCollectingParagraph {
                lecture.segments[i].paragraphComplete = true
            }
            for i in lecture.segments.indices where lecture.segments[i].hasPreviewTranslation &&
                    lecture.segments[i].translationState != .edited {
                lecture.segments[i].translationState = .pending
            }
            result.append(lecture)
        }
        return result.sorted { $0.created > $1.created }
    }
}

enum TranscriptExport {
    static func text(_ lecture: Lecture) -> String {
        var lines = [lecture.title, "英文转录与中文机器翻译", "草稿及低置信度片段需回听核对；未标注处也可能有误。", ""]
        for item in lecture.segments {
            lines += ["[\(item.timeLabel)]\(item.isFinal ? "" : " 〔未定稿〕")\(item.needsReview ? " 〔建议回听〕" : "")",
                "英文：\(item.presentedEnglish)", "中文：\(translationText(item))"]
            if let revision = item.activeContextRevision {
                lines += ["原始识别：" + revision.sourceEnglish, "初始译文：" + revision.sourceChinese,
                    "校订依据：" + revision.reason, "后文原句：" + revision.evidence]
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func translationText(_ item: TranscriptSegment) -> String {
        if let revision = item.activeContextRevision { return "〔上下文校订〕" + revision.chinese }
        if !item.chinese.isEmpty {
            return (item.hasPreviewTranslation ? "〔中文预览，待整段定稿〕" : "") + item.chinese
        }
        return item.translationState == .failed ? "〔翻译失败，可在软件中重试〕" : "〔尚未翻译〕"
    }

    static func srt(_ lecture: Lecture) -> String {
        lecture.segments.enumerated().map { i, item in
            let end = max(item.start + 0.05, item.end)
            let status = item.isFinal ? "" : "〔未定稿〕"
            let source = item.presentedEnglish.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: "\n")
            let target = translationText(item).components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: "\n")
            return "\(i + 1)\n\(srtTime(item.start)) --> \(srtTime(end))\n\(status)\(source)\n\(target)\n"
        }.joined(separator: "\n")
    }

    static func srtTime(_ seconds: Double) -> String {
        let n = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", n / 3_600_000, n / 60_000 % 60, n / 1000 % 60, n % 1000)
    }

    static func xml(_ string: String) -> String {
        let clean = String(string.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) })
        return clean.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }

    static func docx(_ lecture: Lecture, to destination: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-export-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let package = temporary.appendingPathComponent("package", isDirectory: true)
        for directory in ["_rels", "word", "word/_rels"] {
            try FileManager.default.createDirectory(at: package.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        func write(_ path: String, _ value: String) throws {
            try value.write(to: package.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        func paragraph(_ value: String, style: String = "Normal") -> String {
            let runs = value.components(separatedBy: "\n").enumerated().map { index, line in
                "\(index > 0 ? "<w:br/>" : "")<w:t xml:space=\"preserve\">\(xml(line))</w:t>"
            }.joined()
            return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr><w:r>\(runs)</w:r></w:p>"
        }
        var body = paragraph(lecture.title, style: "Title")
        body += paragraph("英文转录与中文机器翻译。草稿、低置信度片段及人名、数字、术语建议回听核对；未标注处也可能有误。")
        for (i, item) in lecture.segments.enumerated() {
            body += paragraph("分段 \(i + 1)", style: "Heading1")
            body += paragraph(item.timeLabel + (item.isFinal ? "" : " 〔未定稿〕") + (item.needsReview ? " 〔建议回听〕" : ""))
            body += paragraph("英文：" + item.presentedEnglish)
            body += paragraph("中文：" + translationText(item))
            if let revision = item.activeContextRevision {
                body += paragraph("原始识别：" + revision.sourceEnglish)
                if !revision.sourceChinese.isEmpty { body += paragraph("初始译文：" + revision.sourceChinese) }
                body += paragraph("校订依据：" + revision.reason + "\n后文原句：" + revision.evidence)
            }
        }
        try write("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """)
        try write("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """)
        try write("word/_rels/document.xml.rels", """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """)
        try write("word/styles.xml", """
        <?xml version="1.0" encoding="UTF-8"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Songti SC"/><w:color w:val="000000"/><w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="100" w:line="280" w:lineRule="auto"/><w:widowControl/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="240"/><w:keepNext/></w:pPr><w:rPr><w:sz w:val="40"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="220" w:after="100"/><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style></w:styles>
        """)
        try write("word/document.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/></w:sectPr></w:body></w:document>
        """)
        let archive = temporary.appendingPathComponent("export.docx")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-q", "-r", archive.path, "[Content_Types].xml", "_rels", "word"]
        task.currentDirectoryURL = package
        let errors = Pipe(); task.standardError = errors
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "ClassScribe.Export", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Word 文件打包失败，请重试或先导出纯文本。"])
        }
        try Data(contentsOf: archive).write(to: destination, options: .atomic)
    }
}
