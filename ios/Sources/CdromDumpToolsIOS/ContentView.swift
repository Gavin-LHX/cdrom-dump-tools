import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let cdromBIN = UTType(importedAs: "com.gavinlhx.cdrom-dump-tools.bin")
    static let cdromTOC = UTType(importedAs: "com.gavinlhx.cdrom-dump-tools.toc")
}

@MainActor
struct ContentView: View {
    @ObservedObject var model: IOSAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var importingBIN = false
    @State private var importingTOC = false

    var body: some View {
        NavigationStack {
            ZStack {
                CdromGlassBackground()
                ScrollView {
                    LazyVStack(spacing: 14) {
                        StatusCard(model: model)
                        IOSLimitationsCard()
                        InputCard(
                            model: model,
                            importingBIN: $importingBIN,
                            importingTOC: $importingTOC
                        )
                        OptionsCard(model: model, settings: model.settings)
                        if let output = model.outputDirectoryURL {
                            OutputCard(outputURL: output)
                        }
                        ActionCard(model: model)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("CD 光盘镜像转换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        IOSSettingsView(settings: model.settings)
                    } label: {
                        Label("在线内容与歌词", systemImage: "gearshape")
                    }
                    .disabled(model.isRunning)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        LogView(model: model)
                    } label: {
                        Label("运行日志", systemImage: "text.alignleft")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $importingBIN,
            allowedContentTypes: [.cdromBIN],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result, as: .bin)
        }
        .fileImporter(
            isPresented: $importingTOC,
            allowedContentTypes: [.cdromTOC, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result, as: .toc)
        }
        .sheet(isPresented: Binding(
            get: { model.isAwaitingReleaseSelection },
            set: { presented in
                if !presented, model.isAwaitingReleaseSelection {
                    model.cancelReleaseSelection()
                }
            }
        )) {
            ReleaseSelectionSheet(model: model)
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "未知错误")
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>, as part: ImportedImagePart) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            model.acceptImportedFile(url, as: part)
        case .failure(let error):
            model.handleImportFailure(error)
        }
    }
}

@MainActor
private struct StatusCard: View {
    @ObservedObject var model: IOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.isRunning ? "opticaldisc.fill" : "opticaldisc")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: model.isRunning && !model.isAwaitingReleaseSelection)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusText)
                        .font(.title3.weight(.semibold))
                    Text(model.phaseText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if model.isRunning {
                    Text(model.elapsedText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = model.progress {
                ProgressView(value: progress)
                    .accessibilityLabel("转换进度")
                    .accessibilityValue("\(Int(progress * 100))%")
            } else if model.isRunning, !model.isAwaitingReleaseSelection {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在处理")
            }
        }
        .padding(18)
        .cdromGlassSurface()
    }
}

private struct IOSLimitationsCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("iPhone 只能转换现成镜像")
                    .font(.headline)
                Text("请先在电脑或服务器读取光盘，再从“文件”App 选择 BIN 与 TOC。iOS 不允许应用直接访问光驱；长时间转换请保持本应用在前台。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cdromGlassSurface(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct InputCard: View {
    @ObservedObject var model: IOSAppModel
    @Binding var importingBIN: Bool
    @Binding var importingTOC: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("输入文件", systemImage: "doc.on.doc")
                .font(.headline)

            ImportedFileRow(
                title: "BIN 镜像",
                fileName: model.binDisplayName,
                isSelected: model.binURL != nil,
                browse: { importingBIN = true },
                clear: { model.clearImportedFile(.bin) }
            )
            Divider()
            ImportedFileRow(
                title: "TOC 文件",
                fileName: model.tocDisplayName,
                isSelected: model.tocURL != nil,
                browse: { importingTOC = true },
                clear: { model.clearImportedFile(.toc) }
            )

            Text("必须分别授权两个文件；iOS 不会静默读取同目录中的另一个文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .cdromGlassSurface()
        .disabled(model.isRunning)
    }
}

private struct ImportedFileRow: View {
    let title: String
    let fileName: String
    let isSelected: Bool
    let browse: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isSelected ? Color.green : Color.secondary)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if isSelected {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("清除\(title)")
            }
            Button(isSelected ? "更换" : "选择", action: browse)
                .cdromGlassButton()
        }
    }
}

@MainActor
private struct OptionsCard: View {
    @ObservedObject var model: IOSAppModel
    @ObservedObject var settings: IOSSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("转换设置", systemImage: "slider.horizontal.3")
                .font(.headline)

            VStack(alignment: .leading, spacing: 7) {
                Text("输出格式")
                    .font(.subheadline.weight(.medium))
                Picker("输出格式", selection: $model.format) {
                    ForEach(AudioOutputFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle(isOn: $model.verifyAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("逐轨无损 PCM 校验")
                    Text("转换后解码并与原 BIN 字节段比较 SHA-256")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $model.lookupMusicBrainz) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("使用 MusicBrainz 识别专辑")
                    Text("多个发行版本时必须由你明确选择，不会自动采用第一个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            NavigationLink {
                IOSSettingsView(settings: settings)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("网易云、QQ、歌词与 AI 翻译")
                            .foregroundStyle(.primary)
                        Text(enrichmentSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .cdromGlassSurface()
        .disabled(model.isRunning)
    }

    private var enrichmentSummary: String {
        var parts: [String] = []
        if settings.fetchOnlineMetadata { parts.append(settings.domesticSourcePriority.displayName) }
        if settings.downloadCover { parts.append("封面") }
        if settings.downloadLyrics {
            parts.append("歌词")
            if settings.translationMode != .none { parts.append(settings.translationMode.displayName) }
        }
        return parts.isEmpty ? "在线增强已关闭" : parts.joined(separator: " · ")
    }
}

private struct OutputCard: View {
    let outputURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("输出已就绪", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(outputURL.lastPathComponent)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Text("目录同时位于“文件”App → 在我的 iPhone 上 → CD 光盘镜像转换 → CD-ROM Dump Tools。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ShareLink(item: outputURL) {
                Label("分享输出目录", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .cdromGlassButton(prominent: true)
        }
        .padding(16)
        .cdromGlassSurface()
    }
}

@MainActor
private struct ActionCard: View {
    @ObservedObject var model: IOSAppModel

    var body: some View {
        CdromGlassEffectGroup(spacing: 10) {
            VStack(spacing: 10) {
                if model.isRunning {
                    Button(role: .destructive, action: model.cancelConversion) {
                        Label(model.cancellationRequested ? "正在取消…" : "取消转换", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.cancellationRequested)
                } else {
                    Button(action: model.startConversion) {
                        Label("开始转换", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .cdromGlassButton(prominent: true)
                    .disabled(!model.canStart)
                }

                NavigationLink {
                    LogView(model: model)
                } label: {
                    Label(model.hasLogs ? "查看运行日志" : "运行日志", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
            .cdromGlassSurface(cornerRadius: 18)
        }
    }
}

@MainActor
private struct LogView: View {
    @ObservedObject var model: IOSAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CdromGlassBackground()
            VStack(spacing: 8) {
                HStack {
                    Text("最多保留最近 5000 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空", action: model.clearLog)
                        .disabled(model.isRunning || !model.hasLogs)
                }
                .padding(.horizontal, 16)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(model.logs) { entry in
                                HStack(alignment: .top, spacing: 7) {
                                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                        .foregroundStyle(Color.white.opacity(0.55))
                                    Text(entry.text.isEmpty ? " " : entry.text)
                                        .foregroundStyle(entry.isWarning ? Color.orange : Color.white)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("log-bottom")
                        }
                        .padding(12)
                    }
                    .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12))
                    }
                    .padding(.horizontal, 12)
                    .onChange(of: model.logs.count) { _, _ in
                        if reduceMotion {
                            proxy.scrollTo("log-bottom", anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo("log-bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct ReleaseSelectionSheet: View {
    @ObservedObject var model: IOSAppModel
    @State private var selectedID: AlbumCandidate.ID?

    private var selectedCandidate: AlbumCandidate? {
        model.releaseCandidates.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CdromGlassBackground()
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("同一 Disc ID 可能对应不同地区、日期或版本。请核对后选择；这里不会预选第一项。")
                            .font(.callout)
                        Text("不确定时可取消，原始 BIN/TOC 不会被修改。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .cdromGlassSurface(cornerRadius: 18)
                    .padding(.horizontal, 12)

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.releaseCandidates) { candidate in
                                Button {
                                    selectedID = candidate.id
                                } label: {
                                    CandidateRow(candidate: candidate, isSelected: candidate.id == selectedID)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("选择此 MusicBrainz 发行版本")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }

                    CdromGlassEffectGroup(spacing: 10) {
                        HStack(spacing: 10) {
                            Button("取消转换", role: .cancel, action: model.cancelReleaseSelection)
                                .frame(maxWidth: .infinity)
                                .buttonStyle(.bordered)
                            Button("使用所选版本") {
                                if let selectedCandidate { model.chooseRelease(selectedCandidate) }
                            }
                            .frame(maxWidth: .infinity)
                            .cdromGlassButton(prominent: true)
                            .disabled(selectedCandidate == nil)
                        }
                        .padding(14)
                        .cdromGlassSurface(cornerRadius: 18)
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("选择发行版本")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}

private struct CandidateRow: View {
    let candidate: AlbumCandidate
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                    Text(candidate.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }

            HStack(spacing: 12) {
                CandidateBadge(icon: "calendar", text: candidate.date ?? "日期未知")
                CandidateBadge(icon: "globe.asia.australia", text: candidate.country ?? "地区未知")
                CandidateBadge(icon: "opticaldisc", text: "Disc \(candidate.mediumPosition)")
            }
            Text("\(candidate.tracks.count) 轨 · MBID \(candidate.releaseID)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .cdromGlassSurface(cornerRadius: 18)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }
}

private struct CandidateBadge: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
