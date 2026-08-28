import SwiftUI
import Foundation
import AppKit
import Darwin

@MainActor
final class CdromDumpToolsAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.isRunning else {
            model.persistSettings()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "转换仍在进行"
        alert.informativeText = "是否终止 PowerShell 与 FFmpeg 进程树并退出？"
        alert.addButton(withTitle: "终止并退出")
        alert.addButton(withTitle: "继续转换")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        model.cancelConversionAndTerminateApplication()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.persistSettings()
    }
}

@main
@MainActor
struct CdromDumpToolsMacApp: App {
    @NSApplicationDelegateAdaptor(CdromDumpToolsAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if CommandLine.arguments.dropFirst().contains("--self-test") {
            let result = SelfTest.run()
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(result)
        }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { appDelegate.model = model }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { model.persistSettings() }
                }
        }
        .defaultSize(width: 1080, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("开始转换") { model.startConversion() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.isRunning)
                Button("取消转换") { model.cancelConversion() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!model.isRunning || model.cancellationRequested)
            }
        }
    }
}

private enum SelfTest {
    static func run() -> Int32 {
        do {
            let tools = try BundledTools.locate()
            try requireSuccessfulProcess(tools.powerShellURL, arguments: ["--version"], label: "PowerShell")
            try requireSuccessfulProcess(tools.ffmpegURL, arguments: ["-version"], label: "FFmpeg")

            let script = try String(contentsOf: tools.converterScriptURL, encoding: .utf8)
            guard script.contains("[CmdletBinding()]"),
                  script.contains("$GuiReleaseSelection"),
                  script.contains(ReleaseSelectionProtocol.prefix) else {
                throw AppError.message("内置转换脚本缺少必要的参数或候选协议。")
            }

            let payload = """
            [
              {"index":1,"artist":"A","title":"One","date":"2026","country":"JP","disc":"1","release_id":"a","barcode":"1"},
              {"index":2,"artist":"B","title":"Two","date":"2025","country":"US","disc":"1","release_id":"b","barcode":"2"}
            ]
            """
            let line = ReleaseSelectionProtocol.prefix + Data(payload.utf8).base64EncodedString()
            let candidates = try ReleaseSelectionProtocol.parse(line)
            guard candidates.map(\.index) == [1, 2] else {
                throw AppError.message("候选协议自检结果不一致。")
            }

            print("SELF-TEST PASS: bundled PowerShell, FFmpeg, converter script, and release protocol")
            return 0
        } catch {
            FileHandle.standardError.write(Data("SELF-TEST FAIL: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func requireSuccessfulProcess(_ executable: URL, arguments: [String], label: String) throws {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw AppError.message("\(label) 无法启动：\(error.localizedDescription)")
        }
        if finished.wait(timeout: .now() + 15) == .timedOut {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            throw AppError.message("\(label) 自检超时。")
        }
        let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
        let stderrData = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderrData + stdoutData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message("\(label) 自检失败（退出码 \(process.terminationStatus)）：\(detail)")
        }
    }
}
