import Combine
import Foundation

@MainActor
final class IOSSettingsStore: ObservableObject {
    @Published var fetchOnlineMetadata: Bool {
        didSet { defaults.set(fetchOnlineMetadata, forKey: Keys.fetchOnlineMetadata) }
    }
    @Published var downloadCover: Bool {
        didSet { defaults.set(downloadCover, forKey: Keys.downloadCover) }
    }
    @Published var downloadLyrics: Bool {
        didSet { defaults.set(downloadLyrics, forKey: Keys.downloadLyrics) }
    }
    @Published var useNetEase: Bool {
        didSet { defaults.set(useNetEase, forKey: Keys.useNetEase) }
    }
    @Published var useQQMusic: Bool {
        didSet { defaults.set(useQQMusic, forKey: Keys.useQQMusic) }
    }
    @Published var domesticSourcePriority: DomesticSourcePriority {
        didSet { defaults.set(domesticSourcePriority.rawValue, forKey: Keys.domesticSourcePriority) }
    }
    @Published var translationMode: LyricsTranslationMode {
        didSet { defaults.set(translationMode.rawValue, forKey: Keys.translationMode) }
    }
    @Published var aiProvider: AITranslationProvider {
        didSet { defaults.set(aiProvider.rawValue, forKey: Keys.aiProvider) }
    }

    @Published var openAIBaseURL: String {
        didSet { defaults.set(openAIBaseURL, forKey: Keys.openAIBaseURL) }
    }
    @Published var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: Keys.openAIModel) }
    }
    @Published var openAIOrganization: String {
        didSet { defaults.set(openAIOrganization, forKey: Keys.openAIOrganization) }
    }
    @Published var openAIProject: String {
        didSet { defaults.set(openAIProject, forKey: Keys.openAIProject) }
    }
    @Published var anthropicBaseURL: String {
        didSet { defaults.set(anthropicBaseURL, forKey: Keys.anthropicBaseURL) }
    }
    @Published var anthropicModel: String {
        didSet { defaults.set(anthropicModel, forKey: Keys.anthropicModel) }
    }
    @Published var anthropicVersion: String {
        didSet { defaults.set(anthropicVersion, forKey: Keys.anthropicVersion) }
    }
    @Published var microsoftTranslatorEndpoint: String {
        didSet { defaults.set(microsoftTranslatorEndpoint, forKey: Keys.microsoftTranslatorEndpoint) }
    }
    @Published var microsoftTranslatorRegion: String {
        didSet { defaults.set(microsoftTranslatorRegion, forKey: Keys.microsoftTranslatorRegion) }
    }
    @Published var customSystemPrompt: String {
        didSet { defaults.set(customSystemPrompt, forKey: Keys.customSystemPrompt) }
    }

    @Published var openAIAPIKey: String {
        didSet { persistSecret(openAIAPIKey, account: SecretAccount.openAI) }
    }
    @Published var anthropicAPIKey: String {
        didSet { persistSecret(anthropicAPIKey, account: SecretAccount.anthropic) }
    }
    @Published var googleCloudAPIKey: String {
        didSet { persistSecret(googleCloudAPIKey, account: SecretAccount.googleCloud) }
    }
    @Published var microsoftTranslatorAPIKey: String {
        didSet { persistSecret(microsoftTranslatorAPIKey, account: SecretAccount.microsoft) }
    }
    @Published private(set) var secretPersistenceErrorMessage: String?

    private let defaults: UserDefaults
    private let keychain: any IOSSecretStoring

    init(
        defaults: UserDefaults = .standard,
        keychain: any IOSSecretStoring = IOSKeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain

        fetchOnlineMetadata = Self.bool(defaults, Keys.fetchOnlineMetadata, fallback: true)
        downloadCover = Self.bool(defaults, Keys.downloadCover, fallback: true)
        downloadLyrics = Self.bool(defaults, Keys.downloadLyrics, fallback: true)
        useNetEase = Self.bool(defaults, Keys.useNetEase, fallback: true)
        useQQMusic = Self.bool(defaults, Keys.useQQMusic, fallback: true)
        domesticSourcePriority = Self.enumValue(
            defaults,
            Keys.domesticSourcePriority,
            fallback: .netEaseFirst
        )
        translationMode = Self.enumValue(defaults, Keys.translationMode, fallback: .auto)
        aiProvider = Self.enumValue(defaults, Keys.aiProvider, fallback: .auto)

        openAIBaseURL = Self.string(defaults, Keys.openAIBaseURL, fallback: "https://api.openai.com/v1")
        openAIModel = Self.string(defaults, Keys.openAIModel, fallback: "gpt-5-mini")
        openAIOrganization = Self.string(defaults, Keys.openAIOrganization)
        openAIProject = Self.string(defaults, Keys.openAIProject)
        anthropicBaseURL = Self.string(defaults, Keys.anthropicBaseURL, fallback: "https://api.anthropic.com/v1")
        anthropicModel = Self.string(defaults, Keys.anthropicModel, fallback: "claude-sonnet-4-6")
        anthropicVersion = Self.string(defaults, Keys.anthropicVersion, fallback: "2023-06-01")
        microsoftTranslatorEndpoint = Self.string(
            defaults,
            Keys.microsoftTranslatorEndpoint,
            fallback: "https://api.cognitive.microsofttranslator.com"
        )
        microsoftTranslatorRegion = Self.string(defaults, Keys.microsoftTranslatorRegion)
        customSystemPrompt = Self.string(defaults, Keys.customSystemPrompt)

        openAIAPIKey = Self.loadSecret(keychain, SecretAccount.openAI)
        anthropicAPIKey = Self.loadSecret(keychain, SecretAccount.anthropic)
        googleCloudAPIKey = Self.loadSecret(keychain, SecretAccount.googleCloud)
        microsoftTranslatorAPIKey = Self.loadSecret(keychain, SecretAccount.microsoft)
        secretPersistenceErrorMessage = nil
    }

    func translationConfiguration() -> TranslationServiceConfiguration {
        var configuration = TranslationServiceConfiguration()
        configuration.mode = translationMode
        configuration.aiProvider = aiProvider
        configuration.openAIAPIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.openAIBaseURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.openAIModel = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.openAIOrganization = openAIOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.openAIProject = openAIProject.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.anthropicAPIKey = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.anthropicBaseURL = anthropicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.anthropicModel = anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.anthropicVersion = anthropicVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.googleCloudAPIKey = googleCloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.microsoftTranslatorAPIKey = microsoftTranslatorAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.microsoftTranslatorEndpoint = microsoftTranslatorEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.microsoftTranslatorRegion = microsoftTranslatorRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.customSystemPrompt = customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return configuration
    }

    func lyricsPipelineOptions() -> LyricsPipelineOptions {
        LyricsPipelineOptions(
            useNetEase: useNetEase,
            useQQMusic: useQQMusic,
            useLRCLIB: true,
            translateMissingChinese: translationMode != .none,
            translation: translationConfiguration()
        )
    }

    func clearSecretError() {
        secretPersistenceErrorMessage = nil
    }

    func clearAllAPIKeys() {
        openAIAPIKey = ""
        anthropicAPIKey = ""
        googleCloudAPIKey = ""
        microsoftTranslatorAPIKey = ""
    }

    func restoreBuiltInPrompt() {
        customSystemPrompt = ""
    }

    var hasAnyDomesticSource: Bool {
        useNetEase || useQQMusic
    }

    var hasAnyConfiguredAIKey: Bool {
        !openAIAPIKey.trimmedSettings.isEmpty || !anthropicAPIKey.trimmedSettings.isEmpty
    }

    var hasAnyConfiguredOfficialTranslationKey: Bool {
        !googleCloudAPIKey.trimmedSettings.isEmpty || !microsoftTranslatorAPIKey.trimmedSettings.isEmpty
    }

    private func persistSecret(_ value: String, account: String) {
        do {
            if value.trimmedSettings.isEmpty {
                try keychain.removeValue(for: account)
            } else {
                try keychain.setValue(value, for: account)
            }
            secretPersistenceErrorMessage = nil
        } catch {
            secretPersistenceErrorMessage = error.localizedDescription
        }
    }

    private static func loadSecret(_ keychain: any IOSSecretStoring, _ account: String) -> String {
        (try? keychain.value(for: account)) ?? ""
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private static func string(_ defaults: UserDefaults, _ key: String, fallback: String = "") -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private static func enumValue<Value: RawRepresentable>(
        _ defaults: UserDefaults,
        _ key: String,
        fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let rawValue = defaults.string(forKey: key),
              let value = Value(rawValue: rawValue) else { return fallback }
        return value
    }

    private enum Keys {
        static let prefix = "ios.settings.v1."
        static let fetchOnlineMetadata = prefix + "fetchOnlineMetadata"
        static let downloadCover = prefix + "downloadCover"
        static let downloadLyrics = prefix + "downloadLyrics"
        static let useNetEase = prefix + "useNetEase"
        static let useQQMusic = prefix + "useQQMusic"
        static let domesticSourcePriority = prefix + "domesticSourcePriority"
        static let translationMode = prefix + "translationMode"
        static let aiProvider = prefix + "aiProvider"
        static let openAIBaseURL = prefix + "openAIBaseURL"
        static let openAIModel = prefix + "openAIModel"
        static let openAIOrganization = prefix + "openAIOrganization"
        static let openAIProject = prefix + "openAIProject"
        static let anthropicBaseURL = prefix + "anthropicBaseURL"
        static let anthropicModel = prefix + "anthropicModel"
        static let anthropicVersion = prefix + "anthropicVersion"
        static let microsoftTranslatorEndpoint = prefix + "microsoftTranslatorEndpoint"
        static let microsoftTranslatorRegion = prefix + "microsoftTranslatorRegion"
        static let customSystemPrompt = prefix + "customSystemPrompt"
    }

    private enum SecretAccount {
        static let openAI = "openai-api-key"
        static let anthropic = "anthropic-api-key"
        static let googleCloud = "google-cloud-translation-api-key"
        static let microsoft = "microsoft-translator-api-key"
    }
}

private extension String {
    var trimmedSettings: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
