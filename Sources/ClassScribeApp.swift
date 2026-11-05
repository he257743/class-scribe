import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { await model.finishBeforeQuit(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct ClassScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel(demoMode: ProcessInfo.processInfo.arguments.contains("--demo"))
    var body: some Scene {
        Window("听课译记", id: "main") {
            ContentView(model: model).preferredColorScheme(.light)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1140, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建课堂") { model.newLecture() }.keyboardShortcut("n").disabled(model.busy || model.demoMode)
                Divider()
                Button(model.phase == .paused ? "继续听课" : "暂停听课") {
                    Task { await model.togglePause() }
                }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!model.canTogglePause)
            }
            CommandGroup(after: .saveItem) {
                Button("导出 Word") { model.export("docx") }.keyboardShortcut("e").disabled(!model.canExportTranscript)
                Button("打开保存文件夹") { model.openRecords() }
            }
            CommandGroup(after: .help) {
                Button("查看演示文字") { model.enterDemo() }.disabled(model.busy || model.demoMode)
                if model.demoMode { Button("返回课堂记录") { model.leaveDemo() } }
            }
        }
    }
}
