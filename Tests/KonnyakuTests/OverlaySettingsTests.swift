import Testing

@testable import Konnyaku

@MainActor
struct OverlaySettingsTests {
    @Test
    func increaseFontScaleStepsThroughAllLevelsThenDisallowsFurtherIncrease() {
        let settings = OverlaySettings(config: ["font-scale": "0.7"])
        for expected in [0.8, 0.9, 1.0, 1.1, 1.2, 1.3] {
            #expect(settings.canIncreaseFontScale)
            settings.increaseFontScale()
            #expect(settings.fontScale == expected)
        }
        #expect(!settings.canIncreaseFontScale)
        settings.increaseFontScale()
        #expect(settings.fontScale == 1.3)
    }

    @Test
    func decreaseFontScaleStepsThroughAllLevelsThenDisallowsFurtherDecrease() {
        let settings = OverlaySettings(config: ["font-scale": "1.3"])
        for expected in [1.2, 1.1, 1.0, 0.9, 0.8, 0.7] {
            #expect(settings.canDecreaseFontScale)
            settings.decreaseFontScale()
            #expect(settings.fontScale == expected)
        }
        #expect(!settings.canDecreaseFontScale)
        settings.decreaseFontScale()
        #expect(settings.fontScale == 0.7)
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
        for legacy in [0.8, 1.0, 1.3] {
            let settings = OverlaySettings(config: ["font-scale": String(legacy)])
            #expect(settings.fontScale == legacy)
        }
    }
}
