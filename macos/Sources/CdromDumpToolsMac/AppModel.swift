import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

@MainActor
final class AppModel: ObservableObject {
    @Published var binPath: String
    @Published var tocPath: String
    @Published var outputPath = ""
    @Published var environmentPath: String
    @Published var format: AudioFormat
    @Published var includeMetadata: Bool
    @Published var includeCover: Bool
    @Published var includeLyrics: Bool
    @Published var useNetEase: Bool
    @Published var useQQMusic: Bool
    @Published var verifyAudio: Bool
    @Published var domesticPriority: DomesticSourcePriority
    @Published var lyricsFallback: LyricsTranslationFallback
    @Published var aiProvider: AIProvider
    @Published var releaseIndex: Int
    @Published var musicBrainzUserAgent: String
    @Published var openOutputOnSuccess: Bool
    @Published var rememberAPIKeys: Bool
    @Published var aiConfiguration: AIConfiguration

    @Published private(set) var isRunning = false
    @Published private(set) var cancellationRequested = false
    @Published private(set) var statusText = "就绪"
    @Published private(set) var phaseText = "请选择 BIN/TOC 镜像"
    @Published private(set) var progressValue: Double?
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var lastOutputDirectory: String?
    @Published var followLatestLog = true
    @Published var showingAISettings = false
    @Published var showingReleaseSelection = false
    @Published private(set) var releaseCandidates: [ReleaseCandidate] = []
    @Published var alertMessage: String?

    private let runner = ConversionRunner()
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var terminateApplicationWhenFinished = false

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = .shared) {
        self.defaults = defaults
        self.keychain = keychain

        var stored = Self.loadSettings(from: defaults)
        if stored.musicBrainzUserAgent.hasPrefix("CdromDumpToolsMac/"),
           stored.musicBrainzUserAgent.hasSuffix("(https://github.com/Gavin-LHX/cdrom-dump-tools)"),
           stored.musicBrainzUserAgent != AppIdentity.defaultMusicBrainzUserAgent {
            stored.musicBrainzUserAgent = AppIdentity.defaultMusicBrainzUserAgent
        }
        binPath = stored.binPath
        tocPath = stored.tocPath
        environmentPath = stored.environmentPath
        format = stored.format
        includeMetadata = stored.includeMetadata
        includeCover = stored.includeCover
        includeLyrics = stored.includeLyrics
        useNetEase = stored.useNetEase
        useQQMusic = stored.useQQMusic
        verifyAudio = stored.verifyAudio
        domesticPriority = stored.domesticPriority
        lyricsFallback = stored.lyricsFallback
        aiProvider = stored.aiProvider
        releaseIndex = stored.releaseIndex
        musicBrainzUserAgent = stored.musicBrainzUserAgent
        openOutputOnSuccess = stored.openOutputOnSuccess
        rememberAPIKeys = stored.rememberAPIKeys
        aiConfiguration = stored.aiConfiguration

        if rememberAPIKeys {
            do {
                aiConfiguration.googleAPIKey = try keychain.read(account: KeychainAccount.google) ?? ""
                aiConfiguration.microsoftAPIKey = try keychain.read(account: KeychainAccount.microsoft) ?? ""
                aiConfiguration.openAIAPIKey = try keychain.read(account: KeychainAccount.openAI) ?? ""
                aiConfiguration.anthropicAPIKey = try keychain.read(account: KeychainAccount.anthropic) ?? ""
            } catch {
                alertMessage = error.localizedDescription
            }
        }
        wireRunnerCallbacks()
    }

    deinit {
        elapsedTimer?.invalidate()
    }

    var commandPreview: String {
        do {
            let tools = try BundledTools.locate()
            let request = try makeRequest(requireExistingFiles: false)
            return ConversionRunner.safeCommandPreview(for: request, tools: tools)
        } catch {
            return "命令预览暂不可用：\(error.localizedDescription)"
        }
    }

    var aiConfigurationSummary: String {
        var providers: [String] = []
        if !aiConfiguration.openAIAPIKey.isEmpty, !aiConfiguration.openAIModel.isEmpty {
            providers.append("OpenAI (\(aiConfiguration.openAIModel))")
        }
        if !aiConfiguration.anthropicAPIKey.isEmpty, !aiConfiguration.anthropicModel.isEmpty {
            providers.append("Anthropic (\(aiConfiguration.anthropicModel))")
        }
        if !aiConfiguration.googleAPIKey.isEmpty { providers.append("Google Cloud") }
        if !aiConfiguration.microsoftAPIKey.isEmpty { providers.append("Microsoft Azure") }
        return providers.isEmpty ? "GUI 未配置完整服务；仍可使用 .env 或免 Key 回退" : providers.joined(separator: " → ")
    }

    func startConversion() {
        guard !isRunning else { return }
        do {
            guard geteuid() != 0 else {
                throw AppError.message("为避免高权限进程误用用户文件或 API Key，请以普通用户运行本程序。")
            }
            let tools = try BundledTools.locate()
            let request = try makeRequest(requireExistingFiles: true)
            try validateAIConfiguration(request.aiConfiguration)
            persistSettings()

            logs.removeAll(keepingCapacity: true)
            releaseCandidates = []
            showingReleaseSelection = false
            lastOutputDirectory = nil
            cancellationRequested = false
            isRunning = true
            statusText = "正在转换…"
            phaseText = "正在准备转换与查询在线信息…"
            progressValue = nil
            startElapsedTimer()

            appendLog("PowerShell: \(tools.powerShellURL.path)")
            appendLog("FFmpeg: \(tools.ffmpegURL.path)")
            appendLog("命令: \(ConversionRunner.safeCommandPreview(for: request, tools: tools))")
            appendLog("AI 配置: \(aiConfigurationSummary)")
            appendLog("")
            try runner.start(request: request, tools: tools)
        } catch {
            stopElapsedTimer()
            isRunning = false
            statusText = "无法开始转换"
            phaseText = statusText
            progressValue = nil
            present(error)
        }
    }

    func cancelConversion() {
        guard isRunning, !cancellationRequested else { return }
        cancellationRequested = true
        statusText = "正在取消…"
        phaseText = "正在停止 PowerShell 与 FFmpeg…"
        showingReleaseSelection = false
        releaseCandidates = []
        runner.cancel()
    }

    func cancelConversionAndTerminateApplication() {
        terminateApplicationWhenFinished = true
        if cancellationRequested { return }
        cancelConversion()
    }

    func chooseRelease(_ candidate: ReleaseCandidate) {
        guard showingReleaseSelection, releaseCandidates.contains(candidate) else { return }
        do {
            try runner.submitReleaseSelection(candidate.index)
            showingReleaseSelection = false
            releaseCandidates = []
            phaseText = "正在使用所选版本补全专辑信息…"
        } catch {
            showingReleaseSelection = false
            releaseCandidates = []
            present(error)
        }
    }

    func cancelReleaseSelection() {
        appendLog("已取消候选专辑选择，正在停止转换。", isError: true)
        showingReleaseSelection = false
        releaseCandidates = []
        cancelConversion()
    }

    func clearLog() {
        logs.removeAll(keepingCapacity: true)
    }

    func copyLog() {
        copyToPasteboard(logs.map(\.text).joined(separator: "\n"))
    }

    func copyCommandPreview() {
        copyToPasteboard(commandPreview)
    }

    func openLastOutput() {
        guard let lastOutputDirectory else { return }
        let url = URL(fileURLWithPath: lastOutputDirectory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            present(AppError.message("输出目录不存在：\n\(url.path)"))
            return
        }
        NSWorkspace.shared.open(url)
    }

    func chooseBIN() {
        guard let url = chooseFile(title: "选择 BIN 光盘镜像", extensions: ["bin"]) else { return }
        applyInputURL(url)
    }

    func chooseTOC() {
        guard let url = chooseFile(title: "选择 cdrdao TOC 文件", extensions: ["toc"]) else { return }
        tocPath = url.path
    }

    func chooseEnvironmentFile() {
        guard let url = chooseFile(title: "选择 .env 文件", extensions: ["env", "txt"]) else { return }
        environmentPath = url.path
    }

    func chooseOutputParent() {
        let panel = NSOpenPanel()
        panel.title = "选择最终专辑目录的父目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let expandedBIN = expandedPath(binPath)
        let base = expandedBIN.isEmpty
            ? "cdrom"
            : URL(fileURLWithPath: expandedBIN).deletingPathExtension().lastPathComponent
        let stem = (base.isEmpty ? "cdrom" : base) + "-" + format.rawValue
        var candidate = parent.appendingPathComponent(stem, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stem)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        outputPath = candidate.path
    }

    func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        guard !isRunning else { return false }
        var accepted = false
        for url in urls where url.isFileURL {
            let ext = url.pathExtension.lowercased()
            if ext == "bin" || ext == "toc" {
                applyInputURL(url)
                accepted = true
            }
        }
        return accepted
    }

    func applyAISettings(_ configuration: AIConfiguration, rememberKeys: Bool) throws {
        try validateAIConfiguration(configuration)
        if rememberKeys {
            try keychain.write(configuration.googleAPIKey, account: KeychainAccount.google)
            try keychain.write(configuration.microsoftAPIKey, account: KeychainAccount.microsoft)
            try keychain.write(configuration.openAIAPIKey, account: KeychainAccount.openAI)
            try keychain.write(configuration.anthropicAPIKey, account: KeychainAccount.anthropic)
        } else {
            for account in KeychainAccount.all { try keychain.delete(account: account) }
        }
        aiConfiguration = configuration
        rememberAPIKeys = rememberKeys
        persistSettings()
    }

    func persistSettings() {
        let settings = MacAppSettings(
            binPath: binPath,
            tocPath: tocPath,
            environmentPath: environmentPath,
            format: format,
            includeMetadata: includeMetadata,
            includeCover: includeCover,
            includeLyrics: includeLyrics,
            useNetEase: useNetEase,
            useQQMusic: useQQMusic,
            verifyAudio: verifyAudio,
            domesticPriority: domesticPriority,
            lyricsFallback: lyricsFallback,
            aiProvider: aiProvider,
            releaseIndex: releaseIndex,
            musicBrainzUserAgent: musicBrainzUserAgent,
            openOutputOnSuccess: openOutputOnSuccess,
            rememberAPIKeys: rememberAPIKeys,
            aiConfiguration: aiConfiguration
        )
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
        } catch {
            present(AppError.message("无法保存设置：\(error.localizedDescription)"))
        }
    }

    private func wireRunnerCallbacks() {
        runner.onLog = { [weak self] line, isError in
            Task { @MainActor in self?.appendLog(line, isError: isError) }
        }
        runner.onProgress = { [weak self] progress in
            Task { @MainActor in self?.apply(progress) }
        }
        runner.onReleaseSelectionRequested = { [weak self] candidates in
            Task { @MainActor in
                guard let self, self.isRunning, !self.cancellationRequested else { return }
                if self.showingReleaseSelection {
                    self.appendLog("错误：转换器在上一次候选选择完成前发送了第二个候选请求。", isError: true)
                    self.cancelConversion()
                    return
                }
                self.releaseCandidates = candidates
                self.showingReleaseSelection = true
                self.phaseText = "等待选择匹配的专辑版本…"
                self.progressValue = nil
            }
        }
        runner.onFinished = { [weak self] result in
            Task { @MainActor in self?.finish(result) }
        }
    }

    private func finish(_ result: ConversionResult) {
        let shouldTerminateApplication = terminateApplicationWhenFinished
        terminateApplicationWhenFinished = false
        defer {
            if shouldTerminateApplication {
                persistSettings()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        isRunning = false
        showingReleaseSelection = false
        releaseCandidates = []
        stopElapsedTimer()

        if result.wasCancelled {
            cancellationRequested = false
            statusText = "已取消"
            phaseText = statusText
            progressValue = nil
            appendLog("转换已取消。", isError: true)
            return
        }
        cancellationRequested = false
        if result.exitCode == 0, let output = result.outputDirectory, !output.isEmpty {
            let fullPath = URL(fileURLWithPath: output).standardizedFileURL.path
            lastOutputDirectory = fullPath
            statusText = "转换完成"
            phaseText = statusText
            progressValue = 1
            appendLog("")
            appendLog("转换完成。")
            if !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outputPath = ""
            }
            if openOutputOnSuccess { openLastOutput() }
        } else if result.exitCode == 0 {
            statusText = "转换结果未确认"
            phaseText = statusText
            progressValue = nil
            appendLog("错误：进程退出码为 0，但未收到精确完成标记。", isError: true)
        } else {
            statusText = "转换失败（退出码 \(result.exitCode)）"
            phaseText = statusText
            progressValue = nil
            appendLog("转换失败，PowerShell 退出码：\(result.exitCode)", isError: true)
        }
    }

    private func apply(_ progress: ConversionProgress) {
        switch progress {
        case .indeterminate(let text):
            phaseText = text
            progressValue = nil
        case .determinate(let current, let total, let text):
            phaseText = text
            progressValue = total > 0 ? Double(current) / Double(total) : nil
        }
    }

    private func makeRequest(requireExistingFiles: Bool) throws -> ConversionRequest {
        var rawBIN = expandedPath(binPath)
        if !requireExistingFiles, rawBIN.isEmpty { rawBIN = "/path/to/disc.bin" }
        let binURL = URL(fileURLWithPath: rawBIN).standardizedFileURL
        var rawTOC = expandedPath(tocPath)
        if rawTOC.isEmpty, !rawBIN.isEmpty {
            rawTOC = binURL.deletingPathExtension().appendingPathExtension("toc").path
        }
        let tocURL = URL(fileURLWithPath: rawTOC).standardizedFileURL

        if requireExistingFiles {
            guard !rawBIN.isEmpty, isReadableRegularFile(binURL) else {
                throw AppError.message("请选择一个可读取的 BIN 光盘镜像。")
            }
            guard binURL.pathExtension.caseInsensitiveCompare("bin") == .orderedSame else {
                throw AppError.message("BIN 镜像必须使用 .bin 扩展名。")
            }
            guard !rawTOC.isEmpty, isReadableRegularFile(tocURL) else {
                throw AppError.message("请选择与 BIN 匹配且可读取的 TOC 文件。")
            }
        }

        let trimmedOutput = expandedPath(outputPath)
        let outputURL = trimmedOutput.isEmpty ? nil : URL(fileURLWithPath: trimmedOutput, isDirectory: true).standardizedFileURL
        if requireExistingFiles, let outputURL, FileManager.default.fileExists(atPath: outputURL.path) {
            throw AppError.message("最终输出目录必须尚不存在：\n\(outputURL.path)")
        }

        let trimmedEnvironment = expandedPath(environmentPath)
        let environmentURL = trimmedEnvironment.isEmpty ? nil : URL(fileURLWithPath: trimmedEnvironment).standardizedFileURL
        if requireExistingFiles, let environmentURL, !isReadableRegularFile(environmentURL) {
            throw AppError.message(".env 文件不存在或不可读取：\n\(environmentURL.path)")
        }
        guard (0...1000).contains(releaseIndex) else {
            throw AppError.message("MusicBrainz 候选序号必须在 0 到 1000 之间。")
        }

        return ConversionRequest(
            binURL: binURL,
            tocURL: tocURL,
            outputURL: outputURL,
            environmentURL: environmentURL,
            format: format,
            includeMetadata: includeMetadata,
            includeCover: includeCover,
            includeLyrics: includeLyrics,
            useNetEase: useNetEase,
            useQQMusic: useQQMusic,
            verifyAudio: verifyAudio,
            domesticPriority: domesticPriority,
            lyricsFallback: lyricsFallback,
            aiProvider: aiProvider,
            releaseIndex: releaseIndex,
            musicBrainzUserAgent: musicBrainzUserAgent,
            aiConfiguration: aiConfiguration
        )
    }

    private func validateAIConfiguration(_ configuration: AIConfiguration) throws {
        try validateServiceURL(configuration.googleBaseURL, field: "Google Base URL")
        try validateServiceURL(configuration.microsoftBaseURL, field: "Microsoft Base URL")
        try validateServiceURL(configuration.openAIBaseURL, field: "OpenAI Base URL")
        try validateServiceURL(configuration.anthropicBaseURL, field: "Anthropic Base URL")

        let region = configuration.microsoftRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if region.count > 64 || region.range(of: #"^[A-Za-z0-9-]*$"#, options: .regularExpression) == nil {
            throw AppError.message("Microsoft Region 只能包含字母、数字和连字符，且不能超过 64 个字符。")
        }
        guard (256...32768).contains(configuration.anthropicMaxTokens) else {
            throw AppError.message("Anthropic Max Tokens 必须在 256 到 32768 之间。")
        }
        let prompt = expandedPath(configuration.promptFile)
        if !prompt.isEmpty, !isReadableRegularFile(URL(fileURLWithPath: prompt)) {
            throw AppError.message("自定义 Prompt 文件不存在或不可读取。")
        }
    }

    private func validateServiceURL(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AppError.message("\(field) 必须是无凭据、查询参数和片段的绝对地址。")
        }
        let loopback = host == "localhost" || host == "::1" || host.hasPrefix("127.")
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw AppError.message("\(field) 必须使用 HTTPS；仅本机回环地址允许 HTTP。")
        }
    }

    private func applyInputURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "bin" {
            binPath = url.standardizedFileURL.path
            let sibling = url.deletingPathExtension().appendingPathExtension("toc")
            if FileManager.default.fileExists(atPath: sibling.path) { tocPath = sibling.standardizedFileURL.path }
        } else if ext == "toc" {
            tocPath = url.standardizedFileURL.path
            let sibling = url.deletingPathExtension().appendingPathExtension("bin")
            if binPath.isEmpty, FileManager.default.fileExists(atPath: sibling.path) {
                binPath = sibling.standardizedFileURL.path
            }
        }
    }

    private func chooseFile(title: String, extensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func appendLog(_ text: String, isError: Bool = false) {
        logs.append(LogEntry(text: text, isError: isError))
        if logs.count > 20_000 { logs.removeFirst(logs.count - 20_000) }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func present(_ error: Error) {
        alertMessage = error.localizedDescription
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        startedAt = Date()
        elapsedText = "00:00"
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        refreshElapsed()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func refreshElapsed() {
        guard let startedAt else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        if seconds >= 3600 {
            elapsedText = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        } else {
            elapsedText = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
    }

    private func isReadableRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private func expandedPath(_ value: String) -> String {
        (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    private static let settingsKey = "CdromDumpToolsMac.Settings.v1"

    private static func loadSettings(from defaults: UserDefaults) -> MacAppSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(MacAppSettings.self, from: data) else {
            return MacAppSettings()
        }
        return settings
    }
}
