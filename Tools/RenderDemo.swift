import AppKit
import SwiftUI

// Render the real SwiftUI view with synthetic, visibly labeled demo content.
// This tool does not access the microphone or the user's classroom store.
@main struct RenderDemo {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: render-demo output.png")
        }
        _ = NSApplication.shared
        let suite = "ClassScribe.RenderDemo.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(demoMode: true, preferences: preferences)
        if !model.lectures.isEmpty {
            model.lectures[0].created = Date(timeIntervalSince1970: 1_767_225_600)
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
