import SwiftUI

@MainActor
struct IOSSettingsSheet: View {
    @ObservedObject var settings: IOSSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            IOSSettingsView(settings: settings)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

@MainActor
struct IOSSettingsView: View {
    @ObservedObject var settings: IOSSettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("获取并写入在线元数据", isOn: $settings.fetchOnlineMetadata)
                Toggle("下载并嵌入专辑封面", isOn: $settings.downloadCover)
                Toggle("下载歌词并生成字幕", isOn: $settings.downloadLyrics)
            } header: {
                Text("在线内容")
            } footer: {
                Text("MusicBrainz 仍负责光盘识别；这里控制识别完成后的国内元数据、封面和歌词增强。网络失败不会改变原始 BIN/TOC。")
            }

            Section {
                Toggle("网易云音乐", isOn: $settings.useNetEase)
                Toggle("QQ 音乐", isOn: $settings.useQQMusic)
                Picker("标签优先级", selection: $settings.domesticSourcePriority) {
                    ForEach(DomesticSourcePriority.allCases) { priority in
                        Text(priority.displayName).tag(priority)
                    }
                }
                .disabled(!settings.hasAnyDomesticSource)

                if !settings.hasAnyDomesticSource {
                    Label("已关闭全部国内源，将回退 MusicBrainz 等其他来源。", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("国内音乐源")
            } footer: {
                Text("整专匹配必须同时通过专辑、艺人、轨数与逐轨时长门槛；整专失败时仅允许标题、艺人、专辑、版本标记及 3 秒时长均独立通过的单曲覆盖。MusicBrainz 发行版身份始终保留。")
            }

            Section {
                Picker("翻译回退", selection: $settings.translationMode) {
                    ForEach(LyricsTranslationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(!settings.downloadLyrics)

                NavigationLink {
                    IOSAITranslationSettingsView(settings: settings)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("翻译服务与 API")
                        Text(translationSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.downloadLyrics || settings.translationMode == .none)
            } header: {
                Text("歌词与中文翻译")
            } footer: {
                Text("歌词顺序：网易云 → QQ 音乐 → LRCLIB；缺少中文时再按所选模式翻译。免费回退固定为 Google GTX → Bing 无 Key。")
            }

            PrivacyNoticeSection()

            if let error = settings.secretPersistenceErrorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.lock.fill")
                        .foregroundStyle(.red)
                    Button("关闭提示", action: settings.clearSecretError)
                } header: {
                    Text("Keychain")
                }
            }
        }
        .navigationTitle("在线内容与歌词")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var translationSummary: String {
        if settings.translationMode == .none { return "已关闭自动翻译" }
        var values: [String] = []
        if settings.hasAnyConfiguredAIKey { values.append("AI 已配置") }
        if settings.hasAnyConfiguredOfficialTranslationKey { values.append("官方翻译已配置") }
        if values.isEmpty { values.append("可使用 Google GTX / Bing 无 Key 回退") }
        return values.joined(separator: " · ")
    }
}

@MainActor
private struct IOSAITranslationSettingsView: View {
    @ObservedObject var settings: IOSSettingsStore
    @State private var confirmingClearKeys = false

    var body: some View {
        Form {
            Section {
                Picker("AI 提供商", selection: $settings.aiProvider) {
                    ForEach(AITranslationProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } header: {
                Text("AI 选择")
            }

            Section {
                SecretField(
                    title: "API Key",
                    placeholder: "sk-…",
                    text: $settings.openAIAPIKey
                )
                PlainConfigurationField(title: "Base URL", text: $settings.openAIBaseURL)
                PlainConfigurationField(title: "模型", text: $settings.openAIModel)
                PlainConfigurationField(
                    title: "Organization（可选）",
                    text: $settings.openAIOrganization
                )
                PlainConfigurationField(title: "Project（可选）", text: $settings.openAIProject)
            } header: {
                Text("OpenAI 兼容接口")
            } footer: {
                Text("Base URL 可填写 OpenAI 或兼容 Chat Completions 服务的 /v1 根地址；密钥只保存在本机 Keychain。")
            }

            Section {
                SecretField(
                    title: "API Key",
                    placeholder: "sk-ant-…",
                    text: $settings.anthropicAPIKey
                )
                PlainConfigurationField(title: "Base URL", text: $settings.anthropicBaseURL)
                PlainConfigurationField(title: "模型", text: $settings.anthropicModel)
                PlainConfigurationField(title: "anthropic-version", text: $settings.anthropicVersion)
            } header: {
                Text("Anthropic 兼容接口")
            } footer: {
                Text("使用 Messages 格式；API Key 只保存在本机 Keychain。")
            }

            Section {
                SecretField(
                    title: "Google Cloud API Key",
                    placeholder: "可选",
                    text: $settings.googleCloudAPIKey
                )
                SecretField(
                    title: "Microsoft API Key",
                    placeholder: "可选",
                    text: $settings.microsoftTranslatorAPIKey
                )
                PlainConfigurationField(
                    title: "Microsoft Endpoint",
                    text: $settings.microsoftTranslatorEndpoint
                )
                PlainConfigurationField(
                    title: "Microsoft Region（可选）",
                    text: $settings.microsoftTranslatorRegion
                )
            } header: {
                Text("传统翻译服务")
            } footer: {
                Text("有 Key 时优先使用官方接口；含 Google 的回退模式最后还会尝试 Google GTX，再尝试 Bing 无 Key。")
            }

            Section {
                ZStack(alignment: .topLeading) {
                    if settings.customSystemPrompt.isEmpty {
                        Text("留空即使用内置“信、达、雅”结构化歌词翻译 Prompt")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $settings.customSystemPrompt)
                        .frame(minHeight: 210)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button("恢复内置 Prompt", action: settings.restoreBuiltInPrompt)
                    .disabled(settings.customSystemPrompt.isEmpty)
            } header: {
                Text("AI 歌词翻译 Prompt")
            } footer: {
                Text("自定义 Prompt 必须要求模型保持输入 JSON 的行数、顺序和 id，并只输出 lyrics-zh-hans-v1 JSON。")
            }

            Section {
                Button("清除全部 API Key", role: .destructive) {
                    confirmingClearKeys = true
                }
                .disabled(
                    !settings.hasAnyConfiguredAIKey
                        && !settings.hasAnyConfiguredOfficialTranslationKey
                )
            }

            PrivacyNoticeSection()
        }
        .navigationTitle("翻译服务与 API")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清除 Keychain 中的全部翻译 API Key？", isPresented: $confirmingClearKeys) {
            Button("清除全部 API Key", role: .destructive, action: settings.clearAllAPIKeys)
            Button("取消", role: .cancel) {}
        } message: {
            Text("Base URL、模型和其他非密钥设置会保留。")
        }
    }
}

private struct SecretField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                SecureField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("清除\(title)")
                }
            }
        }
    }
}

private struct PlainConfigurationField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private struct PrivacyNoticeSection: View {
    var body: some View {
        Section("隐私") {
            Label {
                Text("只会把歌词文本发送到所选翻译服务；不会上传 BIN、TOC 或音频。歌曲名、艺术家和专辑名只会作为 AI 消歧上下文。")
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.green)
            }
            Label {
                Text("API Key 使用 ThisDeviceOnly Keychain，并设为首次解锁后可用；不会写入 UserDefaults、日志或输出目录，也不会随 iCloud Keychain 同步。")
            } icon: {
                Image(systemName: "key.fill")
                    .foregroundStyle(.blue)
            }
            Label {
                Text("Google GTX 与 Bing 无 Key 是非官方网页接口，可能随时失效；只在含 Google 的翻译模式中作为最后回退。")
            } icon: {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
    }
}
