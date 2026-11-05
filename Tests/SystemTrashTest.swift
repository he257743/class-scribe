import Foundation

@main struct SystemTrashTest {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ClassScribe-system-trash-test-\(UUID())")
        var trashed: URL?
        defer {
            try? manager.removeItem(at: root)
            if let trashed { try? manager.removeItem(at: trashed) }
        }
        let store = try LectureStore(root: root)
        var lecture = Lecture(title: "废纸篓集成测试 · 临时假数据")
        let filename = "\(lecture.id)-\(UUID()).caf"
        lecture.audio = [.init(filename: filename, start: 0, end: 1)]
        let dummy = Data("synthetic test fixture only".utf8)
        try store.save(lecture)
        try dummy.write(to: store.recordings.appendingPathComponent(filename))
        try store.moveToTrash(lecture) { url in
            var result: NSURL?
            try manager.trashItem(at: url, resultingItemURL: &result)
            trashed = result as URL?
        }
        guard let trashed,
              manager.fileExists(atPath: trashed.path),
              !manager.fileExists(atPath: store.records.appendingPathComponent("\(lecture.id).json").path),
              !manager.fileExists(atPath: store.recordings.appendingPathComponent(filename).path),
              try Data(contentsOf: trashed.appendingPathComponent("录音/\(filename)")) == dummy,
              try LectureStore(root: trashed).load().first?.id == lecture.id else {
            fatalError("System Trash did not preserve the complete test classroom")
        }
        print("PASS: macOS moved a temporary classroom and audio bundle to the real Trash; fixture cleaned up")
    }
}
