import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: AIConfiguration
    @State private var rememberKeys: Bool
    @State private var errorMessage: String?

    let onSave: (AIConfiguration, Bool) throws -> Void

    init(
        initialConfiguration: AIConfiguration,
        initialRememberKeys: Bool,
        onSave: @escaping (AIConfiguration, Bool) throws -> Void
    ) {
        _configuration = State(initialValue: initialConfiguration)
        _rememberKeys = State(initialValue: initialRememberKeys)
        self.onSave = onSave
    }

    var body: some View {
        ZStack {
            CdromGlassWindowBackground()
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("歌词翻译服务").font(.title2.weight(.semibold))
                        Text("只在没有可靠中文歌词且启用相应回退时调用；音频不会上传。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(18)
                .cdromGlassSurface(cornerRadius: 18)
                .accessibilityElement(children: .combine)

                Form {
                    Section("OpenAI / Chat Completions 兼容接口") {
                        SecureField("API Key", text: $configuration.openAIAPIKey)
                        TextField("Base URL", text: $configuration.openAIBaseURL)
                        TextField("模型（例如 gpt-4.1-mini）", text: $configuration.openAIModel)
                        TextField("Organization ID（可选）", text: $configuration.openAIOrganizationID)
                        TextField("Project ID（可选）", text: $configuration.openAIProjectID)
                    }

                    Section("Anthropic / Messages 兼容接口") {
                    SecureField("API Key", text: $configuration.anthropicAPIKey)
                    TextField("Base URL", text: $configuration.anthropicBaseURL)
                    TextField("模型", text: $configuration.anthropicModel)
                    TextField("API Version", text: $configuration.anthropicVersion)
                    HStack {
                        Text("Max Tokens")
                        TextField("4096", value: $configuration.anthropicMaxTokens, format: .number)
                            .frame(width: 110)
                        Stepper("", value: $configuration.anthropicMaxTokens, in: 256...32768, step: 256)
                            .labelsHidden()
                    }
                    }

                    Section("Google Cloud Translation Basic v2") {
                    SecureField("API Key", text: $configuration.googleAPIKey)
                    TextField("Base URL", text: $configuration.googleBaseURL)
                    }

                    Section("Microsoft Azure Translator v3") {
                    SecureField("API Key", text: $configuration.microsoftAPIKey)
                    TextField("Base URL", text: $configuration.microsoftBaseURL)
                    TextField("Region（可选）", text: $configuration.microsoftRegion)
                    }

                    Section("自定义 Prompt 与密钥保存") {
                    HStack {
                        TextField("UTF-8 Prompt 文件（留空使用内置 Prompt）", text: $configuration.promptFile)
                        Button("浏览…", action: choosePrompt)
                        if !configuration.promptFile.isEmpty {
                            Button {
                                configuration.promptFile = ""
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Toggle("将 API Key 保存到当前用户的 macOS 钥匙串", isOn: $rememberKeys)
                    Text("关闭时，Key 只保留在本次应用会话内；非密钥设置仍保存到 UserDefaults。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

                CdromGlassEffectGroup(spacing: 10) {
                    HStack {
                        Spacer()
                        Button("取消") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("保存") { save() }
                            .cdromGlassButton(prominent: true)
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(16)
                    .cdromGlassSurface(cornerRadius: 18)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 720, minHeight: 720)
        .interactiveDismissDisabled()
        .alert("无法保存 AI 设置", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func choosePrompt() {
        let panel = NSOpenPanel()
        panel.title = "选择 UTF-8 AI Prompt"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            configuration.promptFile = url.standardizedFileURL.path
        }
    }

    private func save() {
        do {
            try onSave(configuration, rememberKeys)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
