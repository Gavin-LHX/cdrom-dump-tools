import Combine
import Foundation
import SwiftUI
import UIKit

enum ImportedImagePart {
    case bin
    case toc
}

struct IOSLogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let isWarning: Bool

    init(_ text: String, isWarning: Bool = false) {
        timestamp = Date()
        self.text = text
        self.isWarning = isWarning
    }
}

@MainActor
final class IOSAppModel: ObservableObject {
    @Published private(set) var binURL: URL?
    @Published private(set) var tocURL: URL?
    @Published var format: AudioOutputFormat = .flac
    @Published var verifyAudio = true
    @Published var lookupMusicBrainz = true

    @Published private(set) var isRunning = false
    @Published private(set) var cancellationRequested = false
    @Published private(set) var isAwaitingReleaseSelection = false
    @Published private(set) var releaseCandidates: [AlbumCandidate] = []
    @Published private(set) var statusText = "就绪"
    @Published private(set) var phaseText = "请选择同一张光盘的 BIN 与 TOC 文件"
    @Published private(set) var progress: Double?
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var logs: [IOSLogEntry] = []
    @Published private(set) var outputDirectoryURL: URL?
    @Published var alertMessage: String?

    private var operationTask: Task<Void, Never>?
    private var conversionWorker: Task<ConversionSummary, Error>?
    private var elapsedTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pendingContext: PendingConversionContext?
    private var didWarnAboutBackground = false

    var canStart: Bool {
        binURL != nil && tocURL != nil && !isRunning
    }

    var binDisplayName: String {
        binURL?.lastPathComponent ?? "尚未选择 BIN 镜像"
    }

    var tocDisplayName: String {
        tocURL?.lastPathComponent ?? "尚未选择 TOC 文件"
    }

    var hasLogs: Bool { !logs.isEmpty }

    func acceptImportedFile(_ url: URL, as part: ImportedImagePart) {
        guard !isRunning else { return }
        guard url.isFileURL else {
            present("只能导入“文件”App 中的本地或云端文件。")
            return
        }

        let expectedExtension = part == .bin ? "bin" : "toc"
        guard url.pathExtension.caseInsensitiveCompare(expectedExtension) == .orderedSame else {
            present("请选择 .\(expectedExtension) 文件。")
            return
        }

        switch part {
        case .bin:
            binURL = url
            appendLog("已选择 BIN：\(url.lastPathComponent)")
        case .toc:
            tocURL = url
            appendLog("已选择 TOC：\(url.lastPathComponent)")
        }
        outputDirectoryURL = nil
        refreshReadyState()
    }

    func clearImportedFile(_ part: ImportedImagePart) {
        guard !isRunning else { return }
        switch part {
        case .bin: binURL = nil
        case .toc: tocURL = nil
        }
        outputDirectoryURL = nil
        refreshReadyState()
    }

    func handleImportFailure(_ error: Error) {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain, value.code == NSUserCancelledError {
            return
        }
        present("无法导入文件：\(error.localizedDescription)")
    }

    func startConversion() {
        guard !isRunning else { return }
        guard let binURL, let tocURL else {
            present("请分别选择同一张光盘的 BIN 镜像和 TOC 文件。")
            return
        }

        isRunning = true
        cancellationRequested = false
        isAwaitingReleaseSelection = false
        releaseCandidates = []
        outputDirectoryURL = nil
        progress = nil
        statusText = "正在检查镜像"
        phaseText = "解析 TOC 与计算光盘轨道…"
        pendingContext = nil
        didWarnAboutBackground = false
        setIdleTimerDisabled(true)
        startElapsedTimer()
        appendLog("")
        appendLog("开始处理：\(binURL.lastPathComponent) + \(tocURL.lastPathComponent)")

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let binSize = try Self.fileSize(of: binURL)
                let tracks = try Self.withSecurityScopedAccess(to: tocURL) {
                    try TOCParser.parse(url: tocURL, binSize: binSize)
                }
                try Task.checkCancellation()
                appendLog("TOC 校验通过：\(tracks.count) 轨，BIN 大小 \(Self.byteCount(binSize))。")
                if tracks.contains(where: \.hasPreEmphasis) {
                    appendLog("TOC 标记了 PRE_EMPHASIS；本版保留原始 PCM，不执行数字去加重。", isWarning: true)
                }

                let context = PendingConversionContext(
                    binURL: binURL,
                    tocURL: tocURL,
                    binSize: binSize,
                    tracks: tracks
                )
                pendingContext = context

                guard lookupMusicBrainz else {
                    appendLog("已关闭 MusicBrainz 查询，将使用基础轨号命名。", isWarning: true)
                    await beginNativeConversion(context: context, album: nil)
                    return
                }

                statusText = "正在识别光盘"
                phaseText = "查询 MusicBrainz Disc ID/TOC…"
                do {
                    let candidates = try await MusicBrainzClient().lookup(tracks: tracks, binSize: binSize)
                    try Task.checkCancellation()
                    if candidates.count > 1 {
                        releaseCandidates = candidates
                        isAwaitingReleaseSelection = true
                        statusText = "等待选择发行版本"
                        phaseText = "找到 \(candidates.count) 个匹配版本，请核对后选择"
                        progress = nil
                        appendLog("MusicBrainz 返回 \(candidates.count) 个候选；不会静默选择第一个。")
                    } else if let candidate = candidates.first {
                        appendLog("MusicBrainz 唯一匹配：\(candidate.artist) — \(candidate.title)")
                        await beginNativeConversion(context: context, album: candidate)
                    } else {
                        appendLog("MusicBrainz 没有找到匹配版本，继续基础无损转换。", isWarning: true)
                        await beginNativeConversion(context: context, album: nil)
                    }
                } catch is CancellationError {
                    finishCancelled()
                } catch {
                    appendLog("MusicBrainz 查询不可用：\(error.localizedDescription)", isWarning: true)
                    appendLog("元数据失败不会中断音频转换。", isWarning: true)
                    await beginNativeConversion(context: context, album: nil)
                }
            } catch is CancellationError {
                finishCancelled()
            } catch {
                finishFailed(error)
            }
        }
    }

    func chooseRelease(_ candidate: AlbumCandidate) {
        guard isRunning, isAwaitingReleaseSelection, let context = pendingContext else { return }
        isAwaitingReleaseSelection = false
        releaseCandidates = []
        appendLog("已选择：\(candidate.artist) — \(candidate.title)\(candidate.date.map { " (\($0))" } ?? "")")
        operationTask = Task { [weak self] in
            guard let self else { return }
            await beginNativeConversion(context: context, album: candidate)
        }
    }

    func cancelReleaseSelection() {
        cancelConversion()
    }

    func cancelConversion() {
        guard isRunning, !cancellationRequested else { return }
        cancellationRequested = true
        statusText = "正在取消"
        phaseText = "等待当前文件块安全停止并清理临时目录…"
        appendLog("已请求取消。", isWarning: true)
        operationTask?.cancel()
        conversionWorker?.cancel()

        if isAwaitingReleaseSelection {
            finishCancelled()
        }
    }

    func clearLog() {
        guard !isRunning else { return }
        logs.removeAll(keepingCapacity: true)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard isRunning, phase != .active, !didWarnAboutBackground else { return }
        didWarnAboutBackground = true
        appendLog("iOS 可能暂停后台转换；请返回应用并保持前台。", isWarning: true)
    }

    private func beginNativeConversion(context: PendingConversionContext, album: AlbumCandidate?) async {
        guard isRunning, !cancellationRequested else {
            finishCancelled()
            return
        }

        do {
            let outputParent = try Self.outputParentDirectory()
            var coverData: Data?
            if let album {
                statusText = "正在获取封面"
                phaseText = "从 Cover Art Archive 下载所选发行版封面…"
                do {
                    coverData = try await MusicBrainzClient().fetchFrontCover(releaseID: album.releaseID)
                    if coverData != nil {
                        appendLog("已获取所选 MusicBrainz 发行版的封面；FLAC 会嵌入封面。")
                    } else {
                        appendLog("所选发行版没有可用封面，继续转换。", isWarning: true)
                    }
                } catch {
                    appendLog("封面下载失败：\(error.localizedDescription)；继续转换。", isWarning: true)
                }
                try Task.checkCancellation()
            }
            let request = NativeConversionRequest(
                binURL: context.binURL,
                tocURL: context.tocURL,
                outputParentURL: outputParent,
                format: format,
                verifyAudio: verifyAudio,
                album: album,
                coverData: coverData,
                appVersion: IOSAppVersion.current
            )

            statusText = "正在转换"
            phaseText = "准备输出 \(format.displayName)…"
            progress = 0
            appendLog("输出格式：\(format.displayName)；逐轨校验：\(verifyAudio ? "开启" : "关闭")。")

            let progressTarget = self
            let worker = Task.detached(priority: .userInitiated) {
                try Self.withSecurityScopedAccess(to: [context.binURL, context.tocURL]) {
                    try NativeAudioConverter.convert(request) { event in
                        Task { @MainActor in
                            progressTarget.apply(event)
                        }
                    }
                }
            }
            conversionWorker = worker
            let summary = try await worker.value
            conversionWorker = nil
            try Task.checkCancellation()
            finishSucceeded(summary)
        } catch is CancellationError {
            conversionWorker = nil
            finishCancelled()
        } catch {
            conversionWorker = nil
            finishFailed(error)
        }
    }

    private func apply(_ event: ConversionProgressEvent) {
        guard isRunning else { return }
        progress = min(1, max(0, event.fraction))
        statusText = "正在转换第 \(event.currentTrack)/\(event.totalTracks) 轨"
        phaseText = event.message
        if !event.message.isEmpty,
           logs.last?.text != event.message {
            appendLog(event.message)
        }
    }

    private func finishSucceeded(_ summary: ConversionSummary) {
        guard isRunning else { return }
        completeOperation()
        outputDirectoryURL = summary.outputDirectory
        statusText = "转换完成"
        phaseText = "输出已保存到“文件”App，可分享整个专辑目录"
        progress = 1
        appendLog("转换完成：\(summary.outputDirectory.lastPathComponent)")
    }

    private func finishCancelled() {
        guard isRunning else { return }
        completeOperation()
        statusText = "已取消"
        phaseText = "临时输出已清理；原始 BIN/TOC 未被修改"
        progress = nil
        appendLog("转换已取消。", isWarning: true)
    }

    private func finishFailed(_ error: Error) {
        guard isRunning else { return }
        completeOperation()
        statusText = "转换失败"
        phaseText = "没有发布不完整的专辑目录"
        progress = nil
        appendLog("错误：\(error.localizedDescription)", isWarning: true)
        alertMessage = error.localizedDescription
    }

    private func completeOperation() {
        isRunning = false
        cancellationRequested = false
        isAwaitingReleaseSelection = false
        releaseCandidates = []
        pendingContext = nil
        operationTask = nil
        conversionWorker = nil
        stopElapsedTimer()
        setIdleTimerDisabled(false)
    }

    private func refreshReadyState() {
        if binURL != nil, tocURL != nil {
            statusText = "可以开始"
            phaseText = "将从现成镜像拆分无损音轨；转换期间请保持应用在前台"
        } else {
            statusText = "就绪"
            phaseText = "请选择同一张光盘的 BIN 与 TOC 文件"
        }
    }

    private func appendLog(_ text: String, isWarning: Bool = false) {
        logs.append(IOSLogEntry(text, isWarning: isWarning))
        if logs.count > 5_000 {
            logs.removeFirst(logs.count - 5_000)
        }
    }

    private func present(_ message: String) {
        alertMessage = message
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        startedAt = Date()
        elapsedText = "00:00"
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let startedAt = self.startedAt else { return }
                let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
                if seconds >= 3_600 {
                    self.elapsedText = String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
                } else {
                    self.elapsedText = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    private static func outputParentDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("CD-ROM Dump Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private nonisolated static func fileSize(of url: URL) throws -> Int64 {
        try withSecurityScopedAccess(to: url) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let value = attributes[.size] as? NSNumber, value.int64Value > 0 else {
                throw NativeConversionError.message("BIN 文件为空或无法读取大小。")
            }
            return value.int64Value
        }
    }

    private nonisolated static func withSecurityScopedAccess<T>(
        to url: URL,
        _ body: () throws -> T
    ) rethrows -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private nonisolated static func withSecurityScopedAccess<T>(
        to urls: [URL],
        _ body: () throws -> T
    ) rethrows -> T {
        let accessed = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, didAccess) in accessed where didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }

    private nonisolated static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct PendingConversionContext: Sendable {
    let binURL: URL
    let tocURL: URL
    let binSize: Int64
    let tracks: [CDTrack]
}
