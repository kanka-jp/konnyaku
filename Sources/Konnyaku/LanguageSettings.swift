import Foundation
import Observation
import Speech
import Translation

@MainActor
@Observable
final class LanguageSettings {
    static let inputKey = "language.input"
    static let outputKey = "language.output"

    var inputLocaleIdentifier: String {
        didSet {
            UserDefaults.standard.set(inputLocaleIdentifier, forKey: Self.inputKey)
        }
    }

    var outputLanguageIdentifier: String {
        didSet {
            UserDefaults.standard.set(outputLanguageIdentifier, forKey: Self.outputKey)
        }
    }

    private(set) var availableInputs: [(identifier: String, displayName: String)] = []
    private(set) var availableOutputs: [(identifier: String, displayName: String)] = []

    var inputLocale: Locale {
        Locale(identifier: inputLocaleIdentifier)
    }

    var outputLanguage: Locale.Language {
        Locale.Language(identifier: outputLanguageIdentifier)
    }

    // 入力 == 出力言語のときは翻訳を行わず書き起こしのみ表示する
    var isTranslationEnabled: Bool {
        inputLocale.language.languageCode != outputLanguage.languageCode
    }

    init() {
        inputLocaleIdentifier = UserDefaults.standard.string(forKey: Self.inputKey) ?? "ja-JP"
        outputLanguageIdentifier = UserDefaults.standard.string(forKey: Self.outputKey) ?? "en-US"
    }

    func loadAvailable() async {
        let inputs = await SpeechTranscriber.supportedLocales
        availableInputs = inputs
            .map { locale in
                (
                    identifier: locale.identifier(.bcp47),
                    displayName: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                )
            }
            .sorted { $0.displayName < $1.displayName }

        let outputs = await TranslationSupport.supportedTargetLanguages()
        availableOutputs = outputs
            .map { language in
                let identifier = Self.compactIdentifier(of: language)
                return (
                    identifier: identifier,
                    displayName: Locale.current.localizedString(forIdentifier: identifier) ?? identifier
                )
            }
            .sorted { $0.displayName < $1.displayName }
    }

    // script を落とすと zh-Hans-CN / zh-Hant-TW 系の変異形が region 頼みの区別になるため、
    // code-script-region を保持した識別子で保存・表示する
    private static func compactIdentifier(of language: Locale.Language) -> String {
        var parts: [String] = []
        if let code = language.languageCode?.identifier {
            parts.append(code)
        }
        if let script = language.script?.identifier {
            parts.append(script)
        }
        if let region = language.region?.identifier {
            parts.append(region)
        }
        return parts.isEmpty ? language.maximalIdentifier : parts.joined(separator: "-")
    }
}
