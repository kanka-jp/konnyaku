import Foundation
import Testing

@testable import Konnyaku

struct SegmentationPolicyTests {
    @Test
    func currentIsFalseBelowThreshold() {
        let text = String(repeating: "あ", count: 39)
        #expect(!SegmentationPolicy.current.shouldForceFinalize(text: text, threshold: 40))
    }

    // 閾値超過かつ末尾付近に句読点があれば自然な区切りとして即座に確定要求する
    @Test
    func currentTrueWhenTailHasPunctuation() {
        let text = String(repeating: "あ", count: 38) + "です。"
        #expect(SegmentationPolicy.current.shouldForceFinalize(text: text, threshold: 40))
    }

    // 句読点が無ければ閾値の 1.5 倍未満は保留し、Speech 側の自然な final 発火を待つ
    // (不自然な位置での寸断を減らすための regression 防止)
    @Test
    func currentHoldsOffWithoutPunctuationBelowGraceLimit() {
        let text = String(repeating: "あ", count: 40)
        #expect(!SegmentationPolicy.current.shouldForceFinalize(text: text, threshold: 40))
    }

    // 句読点が無くても閾値の 1.5 倍に達したら強制確定する (無限に待たない上限)
    @Test
    func currentTrueAtGraceLimitRegardlessOfPunctuation() {
        let text = String(repeating: "あ", count: 60)
        #expect(SegmentationPolicy.current.shouldForceFinalize(text: text, threshold: 40))
    }

    // 末尾付近から外れた句読点は対象外 (先頭寄りの句読点で誤って早期確定しない)
    @Test
    func currentIgnoresPunctuationOutsideTailWindow() {
        let text = "です。" + String(repeating: "あ", count: 40)
        #expect(!SegmentationPolicy.current.shouldForceFinalize(text: text, threshold: 40))
    }
}
