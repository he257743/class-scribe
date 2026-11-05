import AppKit
import SwiftUI

// Render the real SwiftUI view with synthetic, visibly labeled demo content.
// This tool does not access the microphone or the user's classroom store.
@main struct RenderDemo {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fatalError("Usage: render-demo output.png")
        }
        _ = NSApplication.shared
        let suite = "ClassScribe.RenderDemo.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(demoMode: true, preferences: preferences)
        if CommandLine.arguments.contains("--qwen") { model.speechBackend = .qwen }
        if !model.lectures.isEmpty {
            model.lectures[0].title = "操作系统 · 合成校订演示"
            let corrected = model.lectures[0].segments[0]
            model.lectures[0].segments[0].english = corrected.english.replacingOccurrences(of: "A mutex", with: "A mute X")
            model.lectures[0].segments[0].chinese = corrected.chinese.replacingOccurrences(of: "互斥锁", with: "静音 X")
            let raw = model.lectures[0].segments[0]
            model.lectures[0].segments[0].contextRevisions = [ContextRevision(sourceEnglish: raw.english,
                sourceChinese: raw.chinese, english: corrected.english, chinese: corrected.chinese,
                reason: "合成示例：后文明确说明 mutex 指互斥锁。", evidence: "A mutex provides mutual exclusion.",
                model: ContextModel.larger.rawValue)]
            model.lectures[0].segments[1].english = "A mutex provides mutual exclusion. Other threads wait until the lock is released."
            model.lectures[0].segments[1].chinese = "互斥锁提供互斥。其他线程会等待锁释放。"
            model.lectures[0].created = Date(timeIntervalSince1970: 1_767_225_600)
        }
        if CommandLine.arguments.contains("--prompt-echo") {
            model.speechBackend = .qwen
            model.lectures[0].title = "异常识别保护 · 合成演示"
            model.lectures[0].segments[0].english = "Transcribe the English lecture faithfully. Technical vocabulary: mutex, thread, process."
            model.lectures[0].segments[0].chinese = "这是一段异常提示的机器译文。"
        }
        let view = ContentView(model: model)
            .frame(width: 1280, height: 820)
            .environment(\.colorScheme, .light)
        // ImageRenderer omits native controls and lazy scroll content. Host the
        // full view hierarchy in a window that is never ordered onto the screen.
        let host = NSHostingView(rootView: view)
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("Failed to allocate demo bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Failed to render demo view")
        }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print("Rendered synthetic demo; no microphone or personal classroom data used.")
    }
}
