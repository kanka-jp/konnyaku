import Foundation
import Observation

@MainActor
@Observable
final class OverlaySettings {
    static let fontScaleKey = "overlay.fontScale"

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
            UserDefaults.standard.set(fontScale, forKey: Self.fontScaleKey)
        }
    }

    var isMovable = false

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.fontScaleKey)
        fontScale = Self.fontScales.contains { $0.id == saved } ? saved : 1.0
    }
}
