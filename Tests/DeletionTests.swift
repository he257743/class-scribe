import Foundation

@main struct DeletionTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("ClassScribe-deletion-tests-\(UUID())")
        defer { try? manager.removeItem(at: fixture) }
        let trash = fixture.appendingPathComponent("TestTrash", isDirectory: true)
        try manager.createDirectory(at: trash, withIntermediateDirectories: true)
        let archive: LectureStore.TrashAction = { url in
            try manager.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let store = try LectureStore(root: fixture.appendingPathComponent("Data"))
        var first = Lecture(title: "要删除的课堂")
        first.segments = [.init(start: 0, end: 2, english: "Keep the original.", chinese: "保留原文。",
            isFinal: true, confidence: 0.9, translationState: .complete)]
        let firstAudio = "\(first.id)-\(UUID()).caf"
        // A duplicated link must not move the same recording twice.
        first.audio = [.init(filename: firstAudio, start: 0, end: 2), .init(filename: firstAudio, start: 0, end: 2)]
        var second = Lecture(title: "另一堂课")
        second.created = first.created.addingTimeInterval(1)
        let secondAudio = "\(second.id)-\(UUID()).caf"
        second.audio = [.init(filename: secondAudio, start: 0, end: 3)]
        try store.save(first); try store.save(second)
        let audioBytes = Data("fixture audio, not a real recording".utf8)
        try audioBytes.write(to: store.recordings.appendingPathComponent(firstAudio))
        try audioBytes.write(to: store.recordings.appendingPathComponent(secondAudio))
        let firstRecord = store.records.appendingPathComponent("\(first.id).json")
        let firstBytes = try Data(contentsOf: firstRecord)
        let exported = fixture.appendingPathComponent("用户已导出的文件.txt")
        try Data("export must survive".utf8).write(to: exported)
        let model = AppModel(storageRoot: store.root, trashAction: archive)
        model.selectedID = first.id
        model.requestDeletion()
        check(model.deletionCandidate?.id == first.id && manager.fileExists(atPath: firstRecord.path),
            "request only shows confirmation without changing files")
        model.cancelDeletion()
        check(model.deletionCandidate == nil && model.lectures.count == 2 && (try? Data(contentsOf: firstRecord)) == firstBytes,
            "cancel preserves the original classroom and bytes")
        model.selectedID = second.id
        model.requestDeletion(first.id)
        let confirmedID = model.deletionCandidate!.id
        // SwiftUI may clear presentation state before invoking the captured button action.
        model.cancelDeletion()
        model.deleteLecture(confirmedID)
        check(model.lectures.count == 1 && model.current?.id == second.id && model.errorMessage == nil,
            "confirmed row is removed even when another row is selected or dialog has dismissed")
        check(!manager.fileExists(atPath: firstRecord.path) && !manager.fileExists(atPath: store.recordings.appendingPathComponent(firstAudio).path),
            "classroom and its associated recording leave the live store together")
        let bundles = try manager.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        let recovered = try LectureStore(root: bundles[0])
        check((try? Data(contentsOf: recovered.records.appendingPathComponent(firstRecord.lastPathComponent))) == firstBytes &&
              (try? Data(contentsOf: recovered.recordings.appendingPathComponent(firstAudio))) == audioBytes,
            "recoverable bundle retains exact JSON and audio, including duplicated audio links")
        check(manager.fileExists(atPath: store.records.appendingPathComponent("\(second.id).json").path) &&
              manager.fileExists(atPath: store.recordings.appendingPathComponent(secondAudio).path) &&
              manager.fileExists(atPath: exported.path), "other classrooms, recordings and exports survive")
        model.persist(first.id)
        check(!manager.fileExists(atPath: firstRecord.path), "late save cannot recreate a deleted classroom")
        model.requestDeletion(second.id); model.deleteLecture(second.id)
        check(model.lectures.isEmpty && model.current == nil && model.selectedID == nil && !model.canDeleteLecture,
            "deleting the last classroom leaves a real empty state")
        let reopened = AppModel(storageRoot: store.root, trashAction: archive)
        check(reopened.lectures.isEmpty && reopened.selectedID == nil,
            "relaunch does not resurrect deleted records or create a phantom empty classroom")
        reopened.newLecture()
        let newRecords = try store.load()
        check(reopened.lectures.count == 1 && reopened.current != nil && newRecords.count == 1,
            "new classroom is selectable and saved after deleting all history")

        let failingStore = try LectureStore(root: fixture.appendingPathComponent("FailureData"))
        try failingStore.save(first)
        try audioBytes.write(to: failingStore.recordings.appendingPathComponent(firstAudio))
        let failureRecord = failingStore.records.appendingPathComponent(firstRecord.lastPathComponent)
        let failureBytes = try Data(contentsOf: failureRecord)
        let failing = AppModel(storageRoot: failingStore.root, trashAction: { _ in
            throw NSError(domain: "TestTrash", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated trash failure"])
        })
        failing.requestDeletion(); failing.deleteLecture(first.id)
        check(failing.lectures.count == 1 && failing.current?.id == first.id && failing.errorMessage != nil,
            "trash failure keeps classroom selected and reports an error")
        check((try? Data(contentsOf: failureRecord)) == failureBytes &&
              (try? Data(contentsOf: failingStore.recordings.appendingPathComponent(firstAudio))) == audioBytes,
            "trash failure rolls back both original record and audio without altering bytes")
        let rolledBackFiles = try manager.contentsOfDirectory(atPath: failingStore.root.path)
        check(rolledBackFiles.sorted() == ["记录", "录音"].sorted(),
            "successful rollback leaves no partial archive")
        for phase in [RecordingPhase.starting, .listening, .pausing, .paused, .stopping] {
            failing.phase = phase
            failing.requestDeletion()
            let didNotPresent = failing.deletionCandidate == nil
            failing.deletionCandidate = first
            failing.deleteLecture(first.id)
            check(didNotPresent && !failing.canDeleteLecture && failing.lectures.count == 1 &&
                  manager.fileExists(atPath: failureRecord.path),
                "\(phase) prevents deletion, including a previously opened confirmation")
        }
        failing.phase = .idle; failing.demoMode = true
        failing.requestDeletion(); failing.newLecture(); failing.deleteLecture(first.id)
        check(failing.deletionCandidate == nil && failing.lectures.count == 1 && manager.fileExists(atPath: failureRecord.path),
            "demo mode cannot delete real data or create classrooms")

        var unsafe = Lecture(title: "异常路径")
        unsafe.audio = [.init(filename: "../outside.caf", start: 0, end: 1)]
        try store.save(unsafe)
        let outside = store.root.appendingPathComponent("outside.caf")
        try audioBytes.write(to: outside)
        var refused = false
        do { try store.moveToTrash(unsafe, using: archive) } catch { refused = true }
        check(refused && manager.fileExists(atPath: store.records.appendingPathComponent("\(unsafe.id).json").path) &&
              (try? Data(contentsOf: outside)) == audioBytes,
            "malformed recording paths cannot remove unrelated files")
        var missing = Lecture(title: "原音已被手动移走")
        missing.audio = [.init(filename: "\(missing.id)-\(UUID()).caf", start: 0, end: 1)]
        try store.save(missing)
        try store.moveToTrash(missing, using: archive)
        check(!manager.fileExists(atPath: store.records.appendingPathComponent("\(missing.id).json").path),
            "missing audio does not prevent removal of its recoverable classroom record")
        print("\(count) deletion checks passed; only temporary fixtures were used")
    }
}
