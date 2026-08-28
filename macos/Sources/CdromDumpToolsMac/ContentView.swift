import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            Divider()
            TabView(selection: $selectedTab) {
                ConversionOptionsView(model: model)
                    .tabItem { Label("转换设置", systemImage: "opticaldisc") }
                    .tag(0)
                LogView(model: model)
                    .tabItem { Label("运行日志", systemImage: "text.alignleft") }
                    .tag(1)
                CommandPreviewView(model: model)
                    .tabItem { Label("命令预览", systemImage: "terminal") }
                    .tag(2)
            }
            .padding(.horizontal, 14)
            Divider()
            ActionBar(model: model, selectedTab: $selectedTab)
        }
        .frame(minWidth: 900, minHeight: 700)
        .dropDestination(for: URL.self) { urls, _ in
            model.acceptDroppedFiles(urls)
        }
        .sheet(isPresented: $model.showingAISettings) {
            AISettingsView(
                initialConfiguration: model.aiConfiguration,
                initialRememberKeys: model.rememberAPIKeys
            ) { configuration, rememberKeys in
                try model.applyAISettings(configuration, rememberKeys: rememberKeys)
            }
        }
        .sheet(isPresented: $model.showingReleaseSelection) {
            ReleaseSelectionView(candidates: model.releaseCandidates) { candidate in
                model.chooseRelease(candidate)
            } onCancel: {
                model.cancelReleaseSelection()
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "未知错误")
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "opticaldisc.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("CD-ROM Dump Tools")
                    .font(.title2.weight(.semibold))
                Text(model.phaseText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.statusText).fontWeight(.medium)
                    Text(model.elapsedText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Group {
                    if let progress = model.progressValue {
                        ProgressView(value: progress)
                    } else if model.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        ProgressView(value: model.statusText == "转换完成" ? 1 : 0)
                    }
                }
                .frame(width: 230)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

private struct ConversionOptionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("输入与输出") {
                    VStack(spacing: 9) {
                        PathRow(
                            label: "BIN 镜像",
                            placeholder: "必选；可从 Finder 拖入",
                            text: $model.binPath,
                            browse: model.chooseBIN
                        )
                        PathRow(
                            label: "TOC 文件",
                            placeholder: "默认使用同名 .toc",
                            text: $model.tocPath,
                            browse: model.chooseTOC,
                            clear: { model.tocPath = "" }
                        )
                        PathRow(
                            label: "最终输出目录",
                            placeholder: "留空时按专辑信息自动命名",
                            text: $model.outputPath,
                            browse: model.chooseOutputParent,
                            clear: { model.outputPath = "" }
                        )
                    }
                    .padding(.top, 5)
                }

                GroupBox("转换与标签") {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Text("输出格式").frame(width: 115, alignment: .trailing)
                            Picker("输出格式", selection: $model.format) {
                                ForEach(AudioFormat.allCases) { format in
                                    Text(format.label).tag(format)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 260)
                            Spacer()
                            Toggle("逐轨无损 PCM 校验（推荐）", isOn: $model.verifyAudio)
                        }
                        Divider()
                        HStack(spacing: 22) {
                            Toggle("在线元数据", isOn: $model.includeMetadata)
                            Toggle("专辑封面", isOn: $model.includeCover)
                            Toggle("歌词与旁挂字幕", isOn: $model.includeLyrics)
                        }
                        HStack(spacing: 22) {
                            Toggle("网易云音乐", isOn: $model.useNetEase)
                            Toggle("QQ 音乐", isOn: $model.useQQMusic)
                            Picker("国内标签优先", selection: $model.domesticPriority) {
                                ForEach(DomesticSourcePriority.allCases) { value in
                                    Text(value.label).tag(value)
                                }
                            }
                            .frame(maxWidth: 260)
                        }
                        Text("光盘身份优先使用 MusicBrainz；国内来源必须通过专辑、轨数和时长校验后才覆盖展示标签。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 5)
                }

                GroupBox("歌词与 AI 翻译") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("翻译回退", selection: $model.lyricsFallback) {
                                ForEach(LyricsTranslationFallback.allCases) { value in
                                    Text(value.label).tag(value)
                                }
                            }
                            .frame(maxWidth: 410)
                            Picker("AI Provider", selection: $model.aiProvider) {
                                ForEach(AIProvider.allCases) { value in
                                    Text(value.label).tag(value)
                                }
                            }
                            .frame(maxWidth: 270)
                            Spacer()
                            Button("配置模型与 API Key…") { model.showingAISettings = true }
                        }
                        Text(model.aiConfigurationSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 5)
                }

                GroupBox("高级设置") {
                    VStack(spacing: 9) {
                        PathRow(
                            label: ".env 文件",
                            placeholder: "可选；GUI 配置优先于同名环境变量",
                            text: $model.environmentPath,
                            browse: model.chooseEnvironmentFile,
                            clear: { model.environmentPath = "" }
                        )
                        HStack {
                            Text("候选序号").frame(width: 115, alignment: .trailing)
                            TextField("0", value: $model.releaseIndex, format: .number)
                                .frame(width: 90)
                            Stepper("", value: $model.releaseIndex, in: 0...1000)
                                .labelsHidden()
                            Text("0 = MusicBrainz 多版本时弹窗选择")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        HStack {
                            Text("MusicBrainz UA").frame(width: 115, alignment: .trailing)
                            TextField("User-Agent", text: $model.musicBrainzUserAgent)
                                .textFieldStyle(.roundedBorder)
                        }
                        Toggle("转换成功后自动打开输出目录", isOn: $model.openOutputOnSuccess)
                            .padding(.leading, 121)
                    }
                    .padding(.top, 5)
                }
            }
            .padding(.vertical, 12)
        }
        .disabled(model.isRunning)
    }
}

private struct PathRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let browse: () -> Void
    var clear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 115, alignment: .trailing)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
            Button("浏览…", action: browse)
            if let clear {
                Button(action: clear) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("清空")
            }
        }
    }
}

private struct LogView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("自动跟随最新日志", isOn: $model.followLatestLog)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("复制全部", action: model.copyLog)
                Button("清空", action: model.clearLog)
            }
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.logs) { entry in
                            Text(entry.text.isEmpty ? " " : entry.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(entry.isError ? Color.orange : Color.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .onChange(of: model.logs.count) { _, _ in
                    if model.followLatestLog {
                        withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo("log-bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }
}

private struct CommandPreviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("API Key 仅通过子进程环境变量传递，不会出现在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制命令", action: model.copyCommandPreview)
            }
            ScrollView(.vertical) {
                Text(model.commandPreview)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        }
        .padding(.vertical, 10)
    }
}

private struct ActionBar: View {
    @ObservedObject var model: AppModel
    @Binding var selectedTab: Int

    var body: some View {
        HStack(spacing: 10) {
            if model.isRunning {
                Button("查看运行日志") { selectedTab = 1 }
            }
            Spacer()
            Button("打开输出目录", action: model.openLastOutput)
                .disabled(model.lastOutputDirectory == nil || model.isRunning)
            Button("取消", action: model.cancelConversion)
                .disabled(!model.isRunning || model.cancellationRequested)
            Button("开始转换") {
                selectedTab = 1
                model.startConversion()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isRunning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
