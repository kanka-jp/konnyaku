import Foundation
import Testing

@testable import Konnyaku

struct TranslationSupportTests {
    private let supported = [
        Locale.Language(identifier: "zh-Hans-CN"),
        Locale.Language(identifier: "zh-Hant-TW"),
        Locale.Language(identifier: "zh-Hant-HK"),
        Locale.Language(identifier: "ja-Jpan-JP"),
        Locale.Language(identifier: "en-Latn-US"),
        Locale.Language(identifier: "en-Latn-GB"),
    ]

    @Test
    func scriptWinsOverRegionForScriptBearingLanguage() {
        let resolved = TranslationSupport.resolveVariant(
            of: Locale.Language(identifier: "zh-Hant-TW"),
            in: supported
        )
        #expect(resolved.script?.identifier == "Hant")
        #expect(resolved.region?.identifier == "TW")

        // region 不一致でも script は保持される (zh-Hans-CN に落ちない)
        let scriptOnly = TranslationSupport.resolveVariant(
            of: Locale.Language(identifier: "zh-Hant-US"),
            in: supported
        )
        #expect(scriptOnly.script?.identifier == "Hant")
    }

    @Test
    func regionMatchUsedWhenScriptAbsent() {
        let resolved = TranslationSupport.resolveVariant(
            of: Locale.Language(identifier: "en-GB"),
            in: supported
        )
        #expect(resolved.region?.identifier == "GB")

        let fallback = TranslationSupport.resolveVariant(
            of: Locale.Language(identifier: "ja"),
            in: supported
        )
        #expect(fallback.languageCode?.identifier == "ja")
        #expect(fallback.region?.identifier == "JP")
    }

    @Test
    func unsupportedLanguageFallsBackToInput() {
        let input = Locale.Language(identifier: "ko-KR")
        let resolved = TranslationSupport.resolveVariant(of: input, in: supported)
        #expect(resolved == input)
    }

    // resolvePlan の loop 回避決定: highFidelity が installed なら lowLatency が
    // .supported でも DL を予約しない (zh→en で実測した無限 DL ループの regression guard)
    @Test
    func resolvePlanPrefersInstalledFallbackOverDownloadableLowLatency() {
        let plan = TranslationSupport.resolvePlan(lowLatency: .supported, fallback: .installed)
        #expect(plan.status == .installed)
        #expect(plan.usesLowLatency == false)
    }

    @Test
    func resolvePlanUsesInstalledLowLatencyFirst() {
        let plan = TranslationSupport.resolvePlan(lowLatency: .installed, fallback: .installed)
        #expect(plan.status == .installed)
        #expect(plan.usesLowLatency == true)
    }

    @Test
    func resolvePlanDownloadsLowLatencyWhenNothingInstalled() {
        let plan = TranslationSupport.resolvePlan(lowLatency: .supported, fallback: .supported)
        #expect(plan.status == .supported)
        #expect(plan.usesLowLatency == true)
    }

    @Test
    func resolvePlanFallsBackToHighFidelityWhenLowLatencyUnsupported() {
        let plan = TranslationSupport.resolvePlan(lowLatency: .unsupported, fallback: .supported)
        #expect(plan.status == .supported)
        #expect(plan.usesLowLatency == false)
    }
}
