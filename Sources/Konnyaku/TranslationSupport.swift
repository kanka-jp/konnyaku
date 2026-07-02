import Foundation
import Translation

// 遅延診断でイベント間隔を読めるようミリ秒精度の時刻を付ける (stderr のみ、UI 影響なし)。
// value 型の FormatStyle は Sendable で、actor を跨ぐ debugLog 呼び出しに中立。
// Verbatim は locale 非依存の固定 24 時間表記 (FormatStyle の hour は locale の
// 12/24 時間慣習に従うため、amPM: .omitted だけでは午前/午後が曖昧になる)
private let logTimestampStyle = Date.VerbatimFormatStyle(
    format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
    timeZone: .current,
    calendar: Calendar(identifier: .gregorian)
)

// live マイクの発話内容が wrapper 経由の stderr 捕捉で残らないよう、
// 生テキストのログは診断時の opt-in に限定する
private let contentLoggingEnabled =
    ProcessInfo.processInfo.environment["KONNYAKU_LOG_CONTENT"] == "1"

func logContentSuffix(_ text: String) -> String {
    contentLoggingEnabled ? ": \(text)" : ""
}

func debugLog(_ message: String) {
    let timestamp = Date().formatted(logTimestampStyle)
    FileHandle.standardError.write(Data("[konnyaku \(timestamp)] \(message)\n".utf8))
}

enum TranslationSupport {
    static var isLowLatencyStrategyAvailable: Bool {
        if #available(macOS 26.4, *) { return true }
        return false
    }

    // lowLatency 戦略 (macOS 26.4+) は速度優先の別モデル。ユーザー選択を尊重しつつ、
    // ペア未対応・旧 OS では従来の highFidelity へ自動 fallback する
    struct Plan {
        let status: LanguageAvailability.Status
        let usesLowLatency: Bool
    }

    static func plan(
        from source: Locale.Language,
        to target: Locale.Language,
        preferLowLatency: Bool
    ) async -> Plan {
        if preferLowLatency, #available(macOS 26.4, *) {
            let status = await LanguageAvailability(preferredStrategy: .lowLatency)
                .status(from: source, to: target)
            debugLog("lowLatency availability: \(String(describing: status))")
            if status != .unsupported {
                return Plan(status: status, usesLowLatency: true)
            }
        }
        return Plan(
            status: await LanguageAvailability().status(from: source, to: target),
            usesLowLatency: false
        )
    }

    static func supportedTargetLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    // 翻訳アセットは地域付き識別子 (ja-JP / en-US 等) 単位で管理されるため、
    // supportedLanguages から実在の変異形へ解決してから session を作る
    static func resolvePair(
        input: Locale.Language,
        output: Locale.Language
    ) async -> (source: Locale.Language, target: Locale.Language) {
        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages
        let source = resolveVariant(of: input, in: supported)
        let target = resolveVariant(of: output, in: supported)
        let status = await availability.status(from: source, to: target)
        debugLog("status \(source.maximalIdentifier) -> \(target.maximalIdentifier): \(String(describing: status))")
        return (source, target)
    }

    static func makeSession(
        source: Locale.Language,
        target: Locale.Language,
        lowLatency: Bool
    ) -> TranslationSession {
        if lowLatency, #available(macOS 26.4, *) {
            return TranslationSession(
                installedSource: source, target: target, preferredStrategy: .lowLatency)
        }
        return TranslationSession(installedSource: source, target: target)
    }

    // モデル DL 用の translationTask に渡す。実セッションと同じ strategy の Configuration に
    // しないと prepareTranslation が別戦略のアセットを DL してしまう
    static func makeSetupConfiguration(
        source: Locale.Language,
        target: Locale.Language,
        lowLatency: Bool
    ) -> TranslationSession.Configuration {
        if lowLatency, #available(macOS 26.4, *) {
            return TranslationSession.Configuration(
                source: source, target: target, preferredStrategy: .lowLatency)
        }
        return TranslationSession.Configuration(source: source, target: target)
    }

    // zh-Hans / zh-Hant のように script で分かれる変異形を region より先に区別する
    static func resolveVariant(of language: Locale.Language, in supported: [Locale.Language]) -> Locale.Language {
        let sameCode = supported.filter { $0.languageCode == language.languageCode }
        if language.script != nil {
            if let match = sameCode.first(where: { $0.script == language.script && $0.region == language.region }) {
                return match
            }
            if let match = sameCode.first(where: { $0.script == language.script }) {
                return match
            }
        }
        return sameCode.first { $0.region == language.region }
            ?? sameCode.first
            ?? language
    }
}
