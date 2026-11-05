import Foundation
import CryptoKit

protocol QwenPreparing: Sendable {
    func available() async -> Bool
    func prepare(progress: @escaping @Sendable (Double, String) async -> Void) async throws
}

actor QwenASRAssets: QwenPreparing {
    static let pythonURL = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.12.16%2B20261026-aarch64-apple-darwin-install_only.tar.gz")!
    static let pythonSHA256 = "fbf4afef53c2a6b72bb741bc06d5671a9dfaf87bd84e5aa73ac9b3d0d589f14e"
    let installation: QwenInstallation
    init(installation: QwenInstallation = .init()) { self.installation = installation }
    func available() -> Bool { installation.ready }
    func prepare(progress: @escaping @Sendable (Double, String) async -> Void) async throws {
        if installation.ready { await progress(1, "千问识别已就绪 · 本机处理"); return }
        let manager = FileManager.default
        try manager.createDirectory(at: installation.root, withIntermediateDirectories: true)
        if !manager.isExecutableFile(atPath: installation.python.path) {
            await progress(0, "正在下载识别运行环境（约 25MB）")
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 1200
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let (archive, response) = try await session.download(from: Self.pythonURL)
            defer { try? manager.removeItem(at: archive) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe)).map({ String(format: "%02x", $0) }).joined() == Self.pythonSHA256 else {
                throw ClassScribeError.message("识别运行环境下载或校验失败，请重试。")
            }
            let stage = installation.root.appendingPathComponent("setup-" + UUID().uuidString)
            try manager.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: stage) }
            try unpack(archive, to: stage)
            try Task.checkCancellation()
            let destination = installation.root.appendingPathComponent("runtime")
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: stage.appendingPathComponent("python"), to: destination)
        }
        guard let setup = Bundle.main.url(forResource: "PrepareQwenASR", withExtension: "py") else {
            throw ClassScribeError.message("应用缺少千问识别安装组件，请重新安装软件。")
        }
        let process = JSONLineProcess()
        var env = installation.environment
        env["HF_HUB_OFFLINE"] = nil; env["TRANSFORMERS_OFFLINE"] = nil
        try process.launch(executable: installation.python, arguments: ["-I", setup.path, "--root", installation.root.path],
            environment: env, logURL: installation.root.appendingPathComponent("setup.log"))
        process.closeInput()
        try await withTaskCancellationHandler {
            let decoder = JSONDecoder()
            for try await line in process.stream {
                try Task.checkCancellation()
                let event = try decoder.decode(QwenWorkerEvent.self, from: line)
                if event.kind == "error" { throw ClassScribeError.message(event.message ?? "识别组件准备失败。") }
                await progress(event.progress ?? 0, event.message ?? "正在准备千问识别组件")
            }
            guard installation.ready else { throw ClassScribeError.message("千问识别组件尚未准备完成，可再次准备。") }
        } onCancel: { process.terminate() }
    }
    private func unpack(_ archive: URL, to stage: URL) throws {
        let list = Process(); list.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); list.arguments = ["-tzf", archive.path]
        let pipe = Pipe(); list.standardOutput = pipe; list.standardError = FileHandle.nullDevice
        try list.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); list.waitUntilExit()
        guard list.terminationStatus == 0, let text = String(data: data, encoding: .utf8),
              text.split(separator: "\n").allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            throw ClassScribeError.message("识别运行环境包含异常路径，未安装。")
        }
        let tool = Process(); tool.executableURL = list.executableURL; tool.arguments = ["-xzf", archive.path, "-C", stage.path]
        tool.standardError = FileHandle.nullDevice
        try tool.run(); tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { throw ClassScribeError.message("识别运行环境解压失败。") }
    }
}
