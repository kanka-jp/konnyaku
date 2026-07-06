import Foundation
import Testing

@testable import Konnyaku

@MainActor
@Suite(.serialized)
struct OverlaySettingsTests {
    init() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("XDG_CONFIG_HOME", tempDir.path, 1)
    }

    @Test
    func increaseFontScaleStepsThroughAllLevelsThenDisallowsFurtherIncrease() {
        let settings = OverlaySettings(config: ["font-scale": "0.5"])
        for expected in [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0] {
            #expect(settings.canIncreaseFontScale)
            settings.increaseFontScale()
            #expect(settings.fontScale == expected)
        }
        #expect(!settings.canIncreaseFontScale)
        settings.increaseFontScale()
        #expect(settings.fontScale == 2.0)
    }

    @Test
    func decreaseFontScaleStepsThroughAllLevelsThenDisallowsFurtherDecrease() {
        let settings = OverlaySettings(config: ["font-scale": "2.0"])
        for expected in [1.9, 1.8, 1.7, 1.6, 1.5, 1.4, 1.3, 1.2, 1.1, 1.0, 0.9, 0.8, 0.7, 0.6, 0.5] {
            #expect(settings.canDecreaseFontScale)
            settings.decreaseFontScale()
            #expect(settings.fontScale == expected)
        }
        #expect(!settings.canDecreaseFontScale)
        settings.decreaseFontScale()
        #expect(settings.fontScale == 0.5)
    }

    @Test
    func initFallsBackToDefaultForInvalidSavedValue() {
        let settings = OverlaySettings(config: ["font-scale": "2.5"])
        #expect(settings.fontScale == 1.0)
    }

    @Test
    func initFallsBackToDefaultWhenSavedValueMissing() {
        let settings = OverlaySettings(config: [:])
        #expect(settings.fontScale == 1.0)
    }

    @Test
    func initAcceptsExistingLegacyValues() {
        for legacy in [0.7, 0.8, 1.0, 1.3] {
            let settings = OverlaySettings(config: ["font-scale": String(legacy)])
            #expect(settings.fontScale == legacy)
        }
    }

    @Test
    func initParsesSubtitlePlacementAndFallsBackToOverlayForInvalidValue() {
        #expect(OverlaySettings(config: ["subtitle-placement": "band"]).subtitlePlacement == .band)
        #expect(OverlaySettings(config: ["subtitle-placement": "overlay"]).subtitlePlacement == .overlay)
        // 手編集の不正値・未設定は overlay に倒す (config は手編集を許容する仕様)
        #expect(OverlaySettings(config: ["subtitle-placement": "invalid"]).subtitlePlacement == .overlay)
        #expect(OverlaySettings(config: [:]).subtitlePlacement == .overlay)
    }

    @Test
    func initParsesSubtitlePositionAndFallsBackToBottomForInvalidValue() {
        #expect(OverlaySettings(config: ["subtitle-position": "top"]).subtitlePosition == .top)
        #expect(OverlaySettings(config: ["subtitle-position": "bottom"]).subtitlePosition == .bottom)
        // 手編集の不正値・未設定は bottom に倒す (config は手編集を許容する仕様)
        #expect(OverlaySettings(config: ["subtitle-position": "middle"]).subtitlePosition == .bottom)
        #expect(OverlaySettings(config: [:]).subtitlePosition == .bottom)
    }
}
