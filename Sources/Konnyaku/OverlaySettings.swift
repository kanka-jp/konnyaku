import Foundation
import Observation

@MainActor
@Observable
final class OverlaySettings {
    static let fontScales: [Double] = [
        0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0,
    ]

    var fontScale: Double {
        didSet {
            ConfigStore.set(String(fontScale), forKey: ConfigStore.fontScaleKey)
        }
    }

    var isMovable = false

    init(config: [String: String]) {
        let saved = config[ConfigStore.fontScaleKey].flatMap(Double.init) ?? 1.0
        fontScale = Self.fontScales.contains(saved) ? saved : 1.0
    }

    private var fontScaleIndex: Int {
        Self.fontScales.firstIndex(of: fontScale) ?? Self.fontScales.firstIndex(of: 1.0) ?? 0
    }

    var canDecreaseFontScale: Bool {
        fontScaleIndex > 0
    }

    var canIncreaseFontScale: Bool {
        fontScaleIndex < Self.fontScales.count - 1
    }

    func decreaseFontScale() {
        guard canDecreaseFontScale else { return }
        fontScale = Self.fontScales[fontScaleIndex - 1]
    }

    func increaseFontScale() {
        guard canIncreaseFontScale else { return }
        fontScale = Self.fontScales[fontScaleIndex + 1]
    }
}
