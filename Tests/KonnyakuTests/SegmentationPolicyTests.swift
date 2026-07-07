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

    @Test
    func clauseAwareIsFalseBelowThreshold() {
        let text = String(repeating: "あ", count: 38) + "。"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }

    // 末尾そのものが句読点なら文末として即確定する
    @Test
    func clauseAwareTrueWhenTextEndsWithPunctuation() {
        let text = String(repeating: "あ", count: 39) + "。"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }

    // current が語中 (「…ので、表示を」の「を」の後) で発火する境界を clauseAware は保留する。
    // baseline eval で観測された「hardLimit 到達前の語中分断」の regression 防止
    @Test
    func clauseAwareHoldsOffWhenPunctuationIsNotAtEnd() {
        let text = "リアルタイムで音声を認識して翻訳するときにこの字幕の区切りがうまくいかない問題があったので、表示を"
        #expect(SegmentationPolicy.current.shouldForceFinalize(text: text, threshold: 40))
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }

    // 接続助詞 (「あったので」) で終わる節境界は確定する
    @Test
    func clauseAwareTrueAtClauseFinalParticleAfterVerb() {
        let text = "リアルタイムで音声を認識して翻訳するときにこの字幕の区切りがうまくいかない問題があったので"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }

    // 動詞のて形 (「作り直して」) は節境界として確定する
    @Test
    func clauseAwareTrueAtVerbTeForm() {
        let text = "字幕の区切りがうまくいかない問題があったので設定の画面をわかりやすい形に作り直して"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }

    // 体言 + 格助詞 (「画面が」) は主語の途中であって節境界ではないため保留する
    @Test
    func clauseAwareHoldsOffAtNounCaseParticle() {
        let text = "リアルタイムで音声を認識して翻訳するときに使うつもりで昨日から作っている設定の画面が"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }

    // 「〜ですが」の接続用法は体言主格の「が」と区別して確定する
    @Test
    func clauseAwareTrueAtDesugaClauseEnding() {
        let text = "リアルタイムで音声を認識して字幕を出す仕組みを昨日からずっと試しているところなんですが"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }

    // 「〜について」等の複合格助詞は「て」で終わるが名詞句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtCompoundParticle() {
        let text = "リアルタイムで音声を認識して翻訳する仕組みの中でも字幕の区切りを決める部分について"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }

    // 区切りが見つからなくても閾値の 1.5 倍で強制確定する (current と共通の上限)
    @Test
    func clauseAwareTrueAtGraceLimitRegardlessOfBoundary() {
        let text = String(repeating: "あ", count: 60)
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }
}
