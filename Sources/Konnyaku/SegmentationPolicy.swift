import Foundation

// 強制確定 (段落を待たず文を区切る) の判定ポリシー。app と eval が同一実装を共有し、
// eval (SegmentationEvaluationTests) は複数 case を同一音声で A/B 比較する
enum SegmentationPolicy: CaseIterable, CustomStringConvertible {
    // 文字数閾値 + 末尾句読点 + 1.5 倍ハードリミット
    case current

    var description: String {
        switch self {
        case .current: return "current"
        }
    }

    // 閾値超過後も句読点が見つからない場合に強制確定を保留する上限 (閾値の倍数)
    static let graceMultiplier = 1.5
    // 句読点の有無を確認する対象は末尾付近のみ (先頭寄りの句読点で誤って早期確定しないため)
    static let punctuationTailWindow = 10
    static let sentenceBreakPunctuation: Set<Character> = [
        "、", "。", "，", "．", "！", "？", ",", ".", "!", "?",
    ]

    // 閾値超過後、末尾付近に区切りらしさがあれば確定要求する。無ければ閾値の 1.5 倍まで
    // 保留し Speech 側の自然な final 発火を待つ (純関数・テスト対象)
    func shouldForceFinalize(text: String, threshold: Int) -> Bool {
        let count = text.count
        guard count >= threshold else { return false }
        let hardLimit = Int(Double(threshold) * Self.graceMultiplier)
        if count >= hardLimit { return true }
        switch self {
        case .current:
            return text.suffix(Self.punctuationTailWindow)
                .contains { Self.sentenceBreakPunctuation.contains($0) }
        }
    }
}
