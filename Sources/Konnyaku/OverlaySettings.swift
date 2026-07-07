import Foundation
import Observation

@MainActor
@Observable
final class OverlaySettings {
    static let fontScales: [Double] = [
        0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0,
    ]

    // 共有ビューでの字幕の置き方 (画面全体オーバーレイには影響しない)
    enum SubtitlePlacement: String, CaseIterable {
        case overlay
        case band
    }

    // 字幕の表示位置 (枠内でテキストを上寄せ/下寄せどちらにするか。共有ビューの黒帯では
    // 帯自体の画面上の位置に使われ、帯内のテキスト自体は常に下寄せなので対象外)
    enum SubtitlePosition: String, CaseIterable {
        case bottom
        case top
    }

    var fontScale: Double {
        didSet {
            ConfigStore.set(String(fontScale), forKey: ConfigStore.fontScaleKey)
        }
    }

    var subtitlePlacement: SubtitlePlacement {
        didSet {
            ConfigStore.set(subtitlePlacement.rawValue, forKey: ConfigStore.subtitlePlacementKey)
        }
    }

    var subtitlePosition: SubtitlePosition {
        didSet {
            ConfigStore.set(subtitlePosition.rawValue, forKey: ConfigStore.subtitlePositionKey)
        }
    }

    // 視聴者に届く字幕は共有ビュー側に合成されるため、host 側のオーバーレイは二重表示になる
    var hideOverlayDuringShare: Bool {
        didSet {
            ConfigStore.set(
                String(hideOverlayDuringShare), forKey: ConfigStore.hideOverlayDuringShareKey)
        }
    }

    var isMovable = false

    init(config: [String: String]) {
        let saved = config[ConfigStore.fontScaleKey].flatMap(Double.init) ?? 1.0
        fontScale = Self.fontScales.contains(saved) ? saved : 1.0
        subtitlePlacement = config[ConfigStore.subtitlePlacementKey]
            .flatMap(SubtitlePlacement.init(rawValue:)) ?? .overlay
        subtitlePosition = config[ConfigStore.subtitlePositionKey]
            .flatMap(SubtitlePosition.init(rawValue:)) ?? .bottom
        // 未設定 (既存ユーザー含む) は false = 現行挙動 (両方表示) を維持する
        hideOverlayDuringShare = config[ConfigStore.hideOverlayDuringShareKey] == "true"
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
