import Foundation

enum ContextModel: String, CaseIterable, Codable, Sendable {
    case light = "qwen3:0.6b"
    case larger = "qwen3:1.7b"
    var title: String { self == .light ? "轻量 · 约 523MB" : "较大 · 约 1.4GB" }
}

enum CourseDomain: String, CaseIterable, Sendable {
    case computerScience, operatingSystems, networks, softwareEngineering, general
    var title: String {
        switch self {
        case .computerScience: return "计算机课程"
        case .operatingSystems: return "操作系统"
        case .networks: return "计算机网络"
        case .softwareEngineering: return "软件工程"
        case .general: return "通用 / 自定义"
        }
    }
}

struct CourseTerm: Equatable, Sendable {
    var english: String
    var chinese: String
}

enum CourseGlossary {
    static func terms(domain: CourseDomain, custom: String) -> [CourseTerm] {
        let os = ["mutex=互斥锁", "mutual exclusion=互斥", "critical section=临界区", "semaphore=信号量",
                  "deadlock=死锁", "thread=线程", "process=进程", "scheduler=调度器", "context switch=上下文切换",
                  "virtual memory=虚拟内存", "page fault=缺页异常", "cache=缓存", "race condition=竞态条件"]
        let network = ["TCP=传输控制协议", "UDP=用户数据报协议", "IP=网际协议", "packet=数据包",
                       "subnet=子网", "router=路由器", "port=端口", "socket=套接字", "congestion control=拥塞控制",
                       "flow control=流量控制", "routing table=路由表", "throughput=吞吐量"]
        let software = ["data flow diagram=数据流图", "DFD=数据流图", "pseudocode=伪代码", "coupling=耦合",
                        "cohesion=内聚", "encapsulation=封装", "inheritance=继承", "polymorphism=多态"]
        let presets: [String]
        switch domain {
        case .computerScience: presets = os + network + software
        case .operatingSystems: presets = os
        case .networks: presets = network
        case .softwareEngineering: presets = software
        case .general: presets = []
        }
        var result: [CourseTerm] = []
        for line in presets + custom.components(separatedBy: CharacterSet(charactersIn: ",，\n")) {
            let pieces = line.components(separatedBy: "=")
            let english = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !english.isEmpty, english.count <= 80 else { continue }
            let chinese = pieces.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespacesAndNewlines)
            let term = CourseTerm(english: english, chinese: String(chinese.prefix(80)))
            if let index = result.firstIndex(where: { $0.english.caseInsensitiveCompare(english) == .orderedSame }) {
                if !chinese.isEmpty { result[index] = term }
            } else { result.append(term) }
        }
        return Array(result.prefix(100))
    }
}

struct ContextReplacement: Codable, Equatable, Sendable {
    var from: String
    var to: String
}

struct ContextRevision: Codable, Equatable, Sendable {
    var sourceEnglish: String
    var sourceChinese: String
    var english: String
    var chinese: String
    var reason: String
    var evidence: String
    var model: String
    var created = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
}

struct ContextReviewEntry: Sendable {
    var id: UUID
    var english: String
    var chinese: String
    var isComplete: Bool
    var revision: ContextRevision?
}

struct ContextReviewWindow: Sendable {
    var lectureID: UUID
    var entries: [ContextReviewEntry]
    var terms: [CourseTerm]
    var subject: String
    var model: ContextModel

    static func make(lecture: Lecture, domain: CourseDomain, custom: String,
                     subject: String, model: ContextModel) -> Self? {
        let latestEnd = lecture.segments.last?.end ?? 0
        let rows = Array(lecture.segments.filter {
            $0.end >= latestEnd - 90 && !$0.english.isEmpty && $0.english.count <= 1500
        }.suffix(4))
        guard rows.count >= 2,
              rows.dropLast().contains(where: { !$0.isCollectingParagraph && !$0.edited }) else { return nil }
        return Self(lectureID: lecture.id, entries: rows.map {
            ContextReviewEntry(id: $0.id, english: $0.english, chinese: $0.chinese,
                isComplete: !$0.isCollectingParagraph && !$0.edited && $0.translationState != .edited,
                revision: $0.activeContextRevision)
        }, terms: CourseGlossary.terms(domain: domain, custom: custom),
            subject: String((subject.isEmpty ? domain.title : subject).prefix(250)), model: model)
    }

    var fingerprint: String {
        entries.map { "\($0.id):\($0.english):\($0.chinese):\($0.isComplete)" }.joined(separator: "\n") +
            subject + model.rawValue + terms.map { $0.english + "=" + $0.chinese }.joined(separator: ",")
    }
}

struct ContextReviewPatch: Sendable {
    var index: Int
    var replacements: [ContextReplacement]
    var chineseReplacements: [ContextReplacement]
    var evidence: String
    var reason: String
}

struct ContextReviewCandidate: Sendable {
    var index: Int
    var from: String
    var term: CourseTerm
    var evidence: String
    var distance: Double
}

enum ContextReviewPolicy {
    // Model-approved suggestions still need source and evidence validation.
    // The app never accepts a free-form rewritten transcript.
    static func revision(_ patch: ContextReviewPatch, window: ContextReviewWindow) -> ContextRevision? {
        guard window.entries.indices.contains(patch.index), patch.index < window.entries.count - 1 else { return nil }
        let target = window.entries[patch.index]
        guard target.isComplete, !target.chinese.isEmpty,
              patch.replacements.count <= 4, patch.chineseReplacements.count <= 4 else { return nil }
        let evidence = patch.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let later = window.entries.dropFirst(patch.index + 1).map(\.english).joined(separator: " ")
        guard evidence.count >= 8, evidence.count <= 300,
              normalized(later).contains(normalized(evidence)) else { return nil }
        var english = target.english
        for replacement in patch.replacements {
            let from = replacement.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = replacement.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, !to.isEmpty, from.count <= 60, to.count <= 60,
                  from.split(separator: " ").count <= 4, to.split(separator: " ").count <= 4,
                  numbers(from).isEmpty, numbers(to).isEmpty,
                  !hasNegation(from), !hasNegation(to), !containsPhrase(from, to),
                  containsPhrase(evidence, to), containsPhrase(english, from),
                  window.terms.contains(where: { $0.english.caseInsensitiveCompare(to) == .orderedSame }),
                  similarSpelling(from, to) else { return nil }
            let regex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])" +
                NSRegularExpression.escapedPattern(for: from) + "(?![A-Za-z0-9])", options: .caseInsensitive)
            english = regex.stringByReplacingMatches(in: english, range: NSRange(english.startIndex..., in: english),
                withTemplate: NSRegularExpression.escapedTemplate(for: to))
        }
        // Build Chinese from exact, short substitutions as well. A model cannot
        // replace the sentence with a translation of the later evidence.
        var chinese = target.chinese
        for replacement in patch.chineseReplacements {
            let from = replacement.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = replacement.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, from.count <= 12, from != to, chinese.contains(from),
                  numbers(from).isEmpty, !hasNegation(from),
                  !["不", "没有", "未", "无", "不能", "并非", "不是", "禁止", "至少", "至多"].contains(where: from.contains),
                  window.terms.contains(where: {
                      !$0.chinese.isEmpty && $0.chinese == to &&
                      containsPhrase(english, $0.english) && containsPhrase(evidence, $0.english)
                  }) else { return nil }
            chinese = chinese.replacingOccurrences(of: from, with: to)
        }
        let reason = patch.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if english == target.english {
            // Do not turn an already-correct translation into a stylistic rewrite.
            let gainsTermMeaning = window.terms.contains {
                !$0.chinese.isEmpty && containsPhrase(target.english, $0.english) && containsPhrase(evidence, $0.english) &&
                    !target.chinese.contains($0.chinese) && chinese.contains($0.chinese)
            }
            guard gainsTermMeaning else { return nil }
        }
        guard !chinese.isEmpty, chinese.count <= max(300, target.english.count * 4),
              chinese.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
              !reason.isEmpty, reason.count <= 200,
              numbers(chinese).isSubset(of: numbers(target.english).union(numbers(target.chinese))),
              english != target.english || chinese != target.chinese else { return nil }
        for replacement in patch.replacements {
            if let term = window.terms.first(where: { $0.english.caseInsensitiveCompare(replacement.to) == .orderedSame }),
               !term.chinese.isEmpty, !chinese.contains(term.chinese) { return nil }
        }
        return ContextRevision(sourceEnglish: target.english, sourceChinese: target.chinese,
            english: english, chinese: chinese, reason: reason, evidence: evidence, model: window.model.rawValue)
    }

    static func candidates(in window: ContextReviewWindow) -> [ContextReviewCandidate] {
        var result: [ContextReviewCandidate] = []
        let wordPattern = try! NSRegularExpression(pattern: "[A-Za-z]+(?:['-][A-Za-z]+)?")
        for (index, entry) in window.entries.dropLast().enumerated() where entry.isComplete && !entry.chinese.isEmpty {
            let later = window.entries.dropFirst(index + 1).map(\.english)
            let words = wordPattern.matches(in: entry.english, range: NSRange(entry.english.startIndex..., in: entry.english))
            for term in window.terms where !term.chinese.isEmpty {
                guard let quoted = later.first(where: { containsPhrase($0, term.english) }),
                      let match = quoted.range(of: "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: term.english) + "(?![A-Za-z0-9])",
                        options: [.regularExpression, .caseInsensitive]) else { continue }
                if let previous = entry.revision, containsPhrase(previous.english, term.english), previous.chinese.contains(term.chinese) { continue }
                // A bounded literal quote around the actual later occurrence.
                let start = quoted.index(match.lowerBound, offsetBy: -100, limitedBy: quoted.startIndex) ?? quoted.startIndex
                let end = quoted.index(match.upperBound, offsetBy: 100, limitedBy: quoted.endIndex) ?? quoted.endIndex
                let evidence = String(quoted[start..<end])
                if containsPhrase(entry.english, term.english) {
                    if !entry.chinese.contains(term.chinese) {
                        result.append(.init(index: index, from: term.english, term: term, evidence: evidence, distance: 0))
                    }
                    continue
                }
                var best: (String, Double)?
                let maximumWords = min(4, term.english.split(separator: " ").count + 1)
                for first in words.indices {
                    for count in 1...maximumWords where first + count <= words.count {
                        let span = NSRange(location: words[first].range.location,
                            length: NSMaxRange(words[first + count - 1].range) - words[first].range.location)
                        let from = String(entry.english[Range(span, in: entry.english)!])
                        guard from.count <= 60, from.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?;:\n")) == nil,
                              !containsPhrase(from, term.english), !hasNegation(from), numbers(from).isEmpty else { continue }
                        let distance = spellingDistance(from, term.english)
                        guard distance <= 0.5 else { continue }
                        if best == nil || distance < best!.1 { best = (from, distance) }
                    }
                }
                if let best { result.append(.init(index: index, from: best.0, term: term, evidence: evidence, distance: best.1)) }
            }
        }
        return Array(result.sorted { $0.distance == $1.distance ? $0.index < $1.index : $0.distance < $1.distance }.prefix(8))
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![A-Za-z0-9])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func numbers(_ text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: "[0-9]+(?:[.,][0-9]+)*")
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        })
    }

    private static func hasNegation(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        return words.contains { ["not", "no", "never", "without", "cannot", "can't", "don't", "doesn't", "isn't"].contains($0) }
    }

    private static func similarSpelling(_ a: String, _ b: String) -> Bool {
        spellingDistance(a, b) <= 0.5
    }

    private static func spellingDistance(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter(\.isLetter)), y = Array(b.lowercased().filter(\.isLetter))
        guard !x.isEmpty, !y.isEmpty else { return 1 }
        var previous = Array(0...y.count)
        for (i, left) in x.enumerated() {
            var row = [i + 1]
            for (j, right) in y.enumerated() {
                row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = row
        }
        return Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}
