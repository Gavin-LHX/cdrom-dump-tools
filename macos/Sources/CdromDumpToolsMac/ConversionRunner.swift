import Foundation
import Darwin

struct ConversionResult {
    let exitCode: Int32
    let wasCancelled: Bool
    let outputDirectory: String?
}

final class ConversionRunner {
    var onLog: ((String, Bool) -> Void)?
    var onProgress: ((ConversionProgress) -> Void)?
    var onReleaseSelectionRequested: (([ReleaseCandidate]) -> Void)?
    var onFinished: ((ConversionResult) -> Void)?

    private let stateLock = NSLock()
    private let workerQueue = DispatchQueue(label: "com.gavinlhx.cdrom-dump-tools.converter", qos: .userInitiated)
    private var process: Process?
    private var standardInput: FileHandle?
    private var stdoutReader: PipeLineReader?
    private var stderrReader: PipeLineReader?
    private var runIdentifier: UUID?
    private var cancellationRequested = false
    private var reportedOutputDirectory: String?

    var isRunning: Bool {
        stateLock.cdromLocked { process?.isRunning == true }
    }

    func start(request: ConversionRequest, tools: BundledTools) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let readersFinished = DispatchGroup()
        let identifier = UUID()

        let arguments = Self.arguments(for: request, tools: tools)
        process.executableURL = tools.powerShellURL
        process.arguments = arguments
        process.currentDirectoryURL = tools.converterScriptURL.deletingLastPathComponent()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = Self.environment(for: request, tools: tools)

        let stdoutReader = PipeLineReader(pipe: outputPipe, group: readersFinished) { [weak self] line in
            self?.handleLine(line, isError: false)
        }
        let stderrReader = PipeLineReader(pipe: errorPipe, group: readersFinished) { [weak self] line in
            self?.handleLine(line, isError: true)
        }

        stateLock.lock()
        guard self.process == nil else {
            stateLock.unlock()
            throw AppError.message("已有转换正在运行。")
        }
        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        self.stdoutReader = stdoutReader
        self.stderrReader = stderrReader
        runIdentifier = identifier
        cancellationRequested = false
        reportedOutputDirectory = nil
        stateLock.unlock()

        stdoutReader.start()
        stderrReader.start()
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            readersFinished.notify(queue: self.workerQueue) { [weak self] in
                self?.complete(terminatedProcess, identifier: identifier)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutReader.abort()
            stderrReader.abort()
            stateLock.cdromLocked {
                if runIdentifier == identifier {
                    self.process = nil
                    standardInput = nil
                    self.stdoutReader = nil
                    self.stderrReader = nil
                    runIdentifier = nil
                }
            }
            throw AppError.message("无法启动内置 PowerShell：\(error.localizedDescription)")
        }
    }

    func submitReleaseSelection(_ index: Int) throws {
        let handle: FileHandle = try stateLock.cdromLocked {
            guard process?.isRunning == true, !cancellationRequested, let standardInput else {
                throw AppError.message("转换进程已经退出，无法提交候选版本。")
            }
            return standardInput
        }
        do {
            try handle.write(contentsOf: Data("\(index)\n".utf8))
            postLog("已选择 MusicBrainz 候选 [\(index)]，继续转换。", isError: false)
        } catch {
            cancel()
            throw AppError.message("无法把候选版本发送给转换进程：\(error.localizedDescription)")
        }
    }

    func cancel() {
        let snapshot: (pid: Int32, input: FileHandle?)? = stateLock.cdromLocked {
            guard let process, process.isRunning, runIdentifier != nil else { return nil }
            cancellationRequested = true
            let input = standardInput
            standardInput = nil
            return (process.processIdentifier, input)
        }
        guard let snapshot else { return }

        // Capture descendants before closing stdin: a PowerShell process blocked on
        // the release-selection protocol can exit as soon as it observes EOF.
        let processIdentities = ProcessTreeTerminator.snapshot(root: snapshot.pid)
        try? snapshot.input?.close()
        postLog("已请求取消，正在终止 PowerShell 与 FFmpeg 进程树。", isError: true)
        ProcessTreeTerminator.send(signal: SIGTERM, to: processIdentities)
        workerQueue.asyncAfter(deadline: .now() + 2.0) {
            // Each PID is matched to the process identity captured above. This
            // still kills an orphaned child, without risking a reused PID.
            ProcessTreeTerminator.send(signal: SIGKILL, to: processIdentities)
        }
    }

    static func arguments(for request: ConversionRequest, tools: BundledTools) -> [String] {
        var arguments = [
            "-NoLogo", "-NoProfile", "-NonInteractive",
            "-File", tools.converterScriptURL.path,
            "-BinPath", request.binURL.path,
            "-Format", request.format.rawValue,
            "-TocPath", request.tocURL.path,
            "-FfmpegPath", tools.ffmpegURL.path,
        ]
        if let outputURL = request.outputURL {
            arguments += ["-OutputDirectory", outputURL.path]
        }
        if !request.includeMetadata { arguments.append("-NoMetadata") }
        if !request.includeCover { arguments.append("-NoCover") }
        if !request.includeLyrics { arguments.append("-NoLyrics") }
        if !request.useNetEase { arguments.append("-NoNetEase") }
        if !request.useQQMusic { arguments.append("-NoQQMusic") }
        if request.verifyAudio { arguments.append("-VerifyAudio") }
        arguments.append("-NoPause")
        if request.includeMetadata && request.releaseIndex == 0 {
            arguments.append("-GuiReleaseSelection")
        }
        arguments += [
            "-LyricsTranslationFallback", request.lyricsFallback.rawValue,
            "-AiTranslationProvider", request.aiProvider.rawValue,
            "-DomesticSourcePriority", request.domesticPriority.rawValue,
            "-ReleaseIndex", String(request.releaseIndex),
        ]
        if let environmentURL = request.environmentURL {
            arguments += ["-EnvPath", environmentURL.path]
        }
        let userAgent = request.musicBrainzUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userAgent.isEmpty {
            arguments += ["-MusicBrainzUserAgent", userAgent]
        }
        return arguments
    }

    static func safeCommandPreview(for request: ConversionRequest, tools: BundledTools) -> String {
        ([tools.powerShellURL.path] + arguments(for: request, tools: tools))
            .map(shellQuote)
            .joined(separator: " ")
    }

    private static func environment(for request: ConversionRequest, tools: BundledTools) -> [String: String] {
        let parentEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for name in safeInheritedEnvironmentVariableNames {
            if let value = parentEnvironment[name], !value.isEmpty {
                environment[name] = value
            }
        }
        if environment["HOME"] == nil {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        if environment["TMPDIR"] == nil {
            environment["TMPDIR"] = FileManager.default.temporaryDirectory.path
        }
        let executableDirectories = [
            tools.ffmpegURL.deletingLastPathComponent().path,
            tools.powerShellURL.deletingLastPathComponent().path,
        ]
        environment["PATH"] = executableDirectories.joined(separator: ":") + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PWD"] = tools.converterScriptURL.deletingLastPathComponent().path
        environment["DOTNET_NOLOGO"] = "1"
        environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1"

        guard request.includeLyrics, request.lyricsFallback != .none else { return environment }
        let configuration = request.aiConfiguration
        let useMachineTranslation = request.lyricsFallback == .auto
            || request.lyricsFallback == .google
            || request.lyricsFallback == .googleThenAI
            || request.lyricsFallback == .aiThenGoogle
        let useAITranslation = request.lyricsFallback == .auto
            || request.lyricsFallback == .ai
            || request.lyricsFallback == .googleThenAI
            || request.lyricsFallback == .aiThenGoogle

        let googleConfigured = useMachineTranslation && (hasText(configuration.googleAPIKey)
            || !sameURL(configuration.googleBaseURL, AIConfiguration.defaultGoogleBaseURL)
        )
        if googleConfigured {
            add(&environment, "GOOGLE_TRANSLATE_API_KEY", configuration.googleAPIKey)
            add(&environment, "GOOGLE_TRANSLATE_BASE_URL", configuration.googleBaseURL)
        }

        let microsoftConfigured = useMachineTranslation && (hasText(configuration.microsoftAPIKey)
            || hasText(configuration.microsoftRegion)
            || !sameURL(configuration.microsoftBaseURL, AIConfiguration.defaultMicrosoftBaseURL)
        )
        if microsoftConfigured {
            add(&environment, "MICROSOFT_TRANSLATOR_API_KEY", configuration.microsoftAPIKey)
            add(&environment, "MICROSOFT_TRANSLATOR_BASE_URL", configuration.microsoftBaseURL)
            add(&environment, "MICROSOFT_TRANSLATOR_REGION", configuration.microsoftRegion)
        }

        let injectOpenAI = useAITranslation && (request.aiProvider == .auto || request.aiProvider == .openAI)
        let openAIConfigured = injectOpenAI && (hasText(configuration.openAIAPIKey)
            || hasText(configuration.openAIModel)
            || hasText(configuration.openAIOrganizationID)
            || hasText(configuration.openAIProjectID)
            || !sameURL(configuration.openAIBaseURL, AIConfiguration.defaultOpenAIBaseURL))
        if openAIConfigured {
            add(&environment, "OPENAI_API_KEY", configuration.openAIAPIKey)
            add(&environment, "OPENAI_BASE_URL", configuration.openAIBaseURL)
            add(&environment, "OPENAI_MODEL", configuration.openAIModel)
            add(&environment, "OPENAI_ORG_ID", configuration.openAIOrganizationID)
            add(&environment, "OPENAI_PROJECT_ID", configuration.openAIProjectID)
        }

        let injectAnthropic = useAITranslation && (request.aiProvider == .auto || request.aiProvider == .anthropic)
        let anthropicConfigured = injectAnthropic && (hasText(configuration.anthropicAPIKey)
            || hasText(configuration.anthropicModel)
            || !sameURL(configuration.anthropicBaseURL, AIConfiguration.defaultAnthropicBaseURL)
            || configuration.anthropicVersion.trimmingCharacters(in: .whitespacesAndNewlines) != AIConfiguration.defaultAnthropicVersion
            || configuration.anthropicMaxTokens != 4096)
        if anthropicConfigured {
            add(&environment, "ANTHROPIC_API_KEY", configuration.anthropicAPIKey)
            add(&environment, "ANTHROPIC_BASE_URL", configuration.anthropicBaseURL)
            add(&environment, "ANTHROPIC_MODEL", configuration.anthropicModel)
            add(&environment, "ANTHROPIC_VERSION", configuration.anthropicVersion)
            environment["ANTHROPIC_MAX_TOKENS"] = String(configuration.anthropicMaxTokens)
        }
        if useAITranslation {
            let expandedPrompt = (configuration.promptFile.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .expandingTildeInPath
            add(&environment, "AI_TRANSLATION_PROMPT_FILE", expandedPrompt)
        }
        return environment
    }

    private func handleLine(_ line: String, isError: Bool) {
        if line.hasPrefix(ReleaseSelectionProtocol.prefix) {
            do {
                let candidates = try ReleaseSelectionProtocol.parse(line)
                DispatchQueue.main.async { [weak self] in
                    self?.onReleaseSelectionRequested?(candidates)
                }
            } catch {
                postLog("错误：\(error.localizedDescription)", isError: true)
                cancel()
            }
            return
        }

        let completionMarker = "Done. Converted tracks are in:"
        if !isError, line.hasPrefix(completionMarker + " ") {
            let value = String(line.dropFirst(completionMarker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                stateLock.cdromLocked { reportedOutputDirectory = value }
            }
        }
        if let progress = ProgressLineParser.parse(line) {
            DispatchQueue.main.async { [weak self] in self?.onProgress?(progress) }
        }
        postLog(line, isError: isError)
    }

    private func complete(_ terminatedProcess: Process, identifier: UUID) {
        let result: ConversionResult? = stateLock.cdromLocked {
            guard runIdentifier == identifier, process === terminatedProcess else { return nil }
            let result = ConversionResult(
                exitCode: terminatedProcess.terminationStatus,
                wasCancelled: cancellationRequested,
                outputDirectory: reportedOutputDirectory
            )
            try? standardInput?.close()
            process = nil
            standardInput = nil
            stdoutReader = nil
            stderrReader = nil
            runIdentifier = nil
            return result
        }
        guard let result else { return }
        DispatchQueue.main.async { [weak self] in self?.onFinished?(result) }
    }

    private func postLog(_ line: String, isError: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(line, isError) }
    }

    private static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func sameURL(_ value: String, _ defaultValue: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .caseInsensitiveCompare(defaultValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) == .orderedSame
    }

    private static func add(_ environment: inout [String: String], _ name: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { environment[name] = trimmed }
    }

    private static let safeInheritedEnvironmentVariableNames: Set<String> = [
        "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL",
        "LANG", "LC_ALL", "LC_CTYPE", "TZ", "__CF_USER_TEXT_ENCODING",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE",
    ]
}

private final class PipeLineReader {
    private let pipe: Pipe
    private let group: DispatchGroup
    private let onLine: (String) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false

    init(pipe: Pipe, group: DispatchGroup, onLine: @escaping (String) -> Void) {
        self.pipe = pipe
        self.group = group
        self.onLine = onLine
        group.enter()
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                finish()
            } else {
                consume(data)
            }
        }
    }

    func abort() {
        finish()
    }

    private func consume(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineData.last == 0x0D { lineData.removeLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    private func finish() {
        var finalLine: String?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        pipe.fileHandleForReading.readabilityHandler = nil
        if !buffer.isEmpty {
            if buffer.last == 0x0D { buffer.removeLast() }
            finalLine = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        if let finalLine, !finalLine.isEmpty { onLine(finalLine) }
        group.leave()
    }
}

private enum ProgressLineParser {
    static func parse(_ line: String) -> ConversionProgress? {
        if line.hasPrefix("MusicBrainz Disc ID:") || line.hasPrefix("Matched release:") {
            return .indeterminate("正在识别光盘与匹配专辑…")
        }
        if line.hasPrefix("Trying cover source: ") {
            return .indeterminate("正在获取封面：" + String(line.dropFirst("Trying cover source: ".count)))
        }
        if let values = captures(#"^Lyrics ([0-9]{2,3}):\s*(.*)$"#, in: line),
           let current = Int(values[0]) {
            return .indeterminate("正在处理第 \(current) 轨歌词…")
        }
        if let values = captures(#"^Tracks:\s*([0-9]+)$"#, in: line),
           let total = Int(values[0]), total > 0 {
            return .indeterminate("准备转换 \(total) 轨音频…")
        }
        if let values = captures(#"^Converting track ([0-9]+)/([0-9]+) -> (.+)$"#, in: line),
           let current = Int(values[0]), let total = Int(values[1]), current > 0, current <= total {
            return .determinate(current: current, total: total, text: "正在转换第 \(current)/\(total) 轨")
        }
        if let values = captures(#"^Verifying track ([0-9]+)/([0-9]+) -> (.+)$"#, in: line),
           let current = Int(values[0]), let total = Int(values[1]), current > 0, current <= total {
            return .determinate(current: current, total: total, text: "正在校验第 \(current)/\(total) 轨")
        }
        if let values = captures(#"^Verified track ([0-9]+)/([0-9]+): lossless PCM SHA-256 match$"#, in: line),
           let current = Int(values[0]), let total = Int(values[1]), current > 0, current <= total {
            return .determinate(current: current, total: total, text: "第 \(current)/\(total) 轨校验通过")
        }
        return nil
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
}

private enum ProcessTreeTerminator {
    struct Identity: Equatable {
        let pid: Int32
        let signature: String
    }

    static func snapshot(root: Int32) -> [Identity] {
        (descendantPIDs(of: root) + [root]).compactMap(identity)
    }

    static func send(signal: Int32, to identities: [Identity]) {
        for captured in identities where identity(of: captured.pid) == captured {
            _ = Darwin.kill(captured.pid, signal)
        }
    }

    private static func identity(of pid: Int32) -> Identity? {
        let psURL = URL(fileURLWithPath: "/bin/ps")
        guard FileManager.default.isExecutableFile(atPath: psURL.path) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = psURL
        process.arguments = ["-p", String(pid), "-o", "lstart=", "-o", "comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let signature = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return signature.isEmpty ? nil : Identity(pid: pid, signature: signature)
    }

    private static func descendantPIDs(of parent: Int32) -> [Int32] {
        var result: [Int32] = []
        for child in directChildren(of: parent) {
            result.append(contentsOf: descendantPIDs(of: child))
            result.append(child)
        }
        return result
    }

    private static func directChildren(of parent: Int32) -> [Int32] {
        let pgrepURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        guard FileManager.default.isExecutableFile(atPath: pgrepURL.path) else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = pgrepURL
        process.arguments = ["-P", String(parent)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
    }
}

private extension NSLock {
    func cdromLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
