import Foundation
import Testing

@testable import Konnyaku

struct SubtitleViewTests {
    // プレビューの段数が実表示と一致する契約 (翻訳無効なら source 1 段のみ)。
    // isTranslationEnabled ゲートが消えると調整時だけ 2 段になり位置合わせがずれる
    @Test
    @MainActor
    func previewOmitsTranslationRowWhenTranslationDisabled() {
        let settings = OverlaySettings(config: [:])
        settings.isMovable = true
        let languages = LanguageSettings(config: [
            ConfigStore.inputLanguageKey: "ja-JP",
            ConfigStore.outputLanguageKey: "ja-JP",
        ])
        let view = SubtitleView(state: CaptionState(), settings: settings, languages: languages, onFinishMoving: {})

        #expect(view.showsPreview)
        #expect(!view.sourceLines.isEmpty)
        #expect(view.translationLines.isEmpty)
    }

    @Test
    @MainActor
    func previewShowsTranslationRowWhenTranslationEnabled() {
        let settings = OverlaySettings(config: [:])
        settings.isMovable = true
        let languages = LanguageSettings(config: [
            ConfigStore.inputLanguageKey: "ja-JP",
            ConfigStore.outputLanguageKey: "en-US",
        ])
        let view = SubtitleView(state: CaptionState(), settings: settings, languages: languages, onFinishMoving: {})

        #expect(view.showsPreview)
        #expect(!view.translationLines.isEmpty)
    }
}
