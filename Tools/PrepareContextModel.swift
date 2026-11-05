import Foundation

actor SetupProgress {
    private var last = Date.distantPast
    func update(_ fraction: Double, _ message: String) {
        guard fraction >= 1 || Date().timeIntervalSince(last) >= 15 else { return }
        last = Date()
        try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }
}

@main struct PrepareContextModel {
    static func main() async {
        let argument = CommandLine.arguments.dropFirst().first ?? ContextModel.light.rawValue
        guard let choice = ContextModel(rawValue: argument) else {
            fputs("Choose qwen3:0.6b or qwen3:1.7b.\n", stderr); exit(2)
        }
        let service = LocalContextService()
        let reporter = SetupProgress()
        do {
            try await service.prepare(model: choice) { progress, status in await reporter.update(progress, status) }
        } catch {
            await service.shutdown()
            fputs("Model preparation failed: \(error.localizedDescription)\n", stderr); exit(1)
        }
        print("PASS: local context model ready: \(choice.rawValue)")
        await service.shutdown()
    }
}
