import Foundation
import Observation

@MainActor
@Observable
final class OverlaySettings {
    struct FontScale: Identifiable, Equatable {
        let id: Double
        let labelKey: String
    }

    static let fontScales: [FontScale] = [
        FontScale(id: 0.8, labelKey: "font.small"),
        FontScale(id: 1.0, labelKey: "font.regular"),
        FontScale(id: 1.3, labelKey: "font.large"),
    ]

    var fontScale: Double {
        didSet {
            ConfigStore.set(String(fontScale), forKey: ConfigStore.fontScaleKey)
        }
    }

    var isMovable = false

    init(config: [String: String]) {
        let saved = config[ConfigStore.fontScaleKey].flatMap(Double.init) ?? 1.0
        fontScale = Self.fontScales.contains { $0.id == saved } ? saved : 1.0
    }
}
