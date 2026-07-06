import Foundation
import Testing

@testable import Konnyaku

// EvalMetrics は以降の segmentation 改善 PR が効果測定の根拠にする物差しのため、
// 定義 (sacrebleu 互換 chrF / 編集パス射影 / 境界マッチング) を数値で固定する
struct EvalMetricsTests {
    @Test
    func chrFIsHundredForIdenticalStrings() {
        #expect(abs(EvalMetrics.chrF(hypothesis: "kitten", reference: "kitten") - 100) < 0.001)
    }

    @Test
    func chrFIsZeroForDisjointStrings() {
        #expect(EvalMetrics.chrF(hypothesis: "abc", reference: "def") == 0)
    }

    // 手計算による固定値 (空白除去後 "catsat" vs "catsit"):
    // order 1-6 の P=R = 5/6, 3/5, 1/2, 1/3, 0, 0 → 平均 0.377778 → P=R のため F も同値
    @Test
    func chrFMatchesHandComputedSymmetricCase() {
        let score = EvalMetrics.chrF(hypothesis: "cat sat", reference: "cat sit")
        #expect(abs(score - 37.7778) < 0.01)
    }

    // 手計算による固定値 ("ab" vs "abcd"): hyp 側に n-gram が無い order 3+ は
    // effective-order smoothing で除外され、P=1.0, R=(1/2+1/3)/2=5/12、β=2 で
    // F = 5PR/(4P+R) = 47.1698。β 重み (recall 優先) と order 除外の両方を固定する
    @Test
    func chrFMatchesHandComputedAsymmetricCase() {
        let score = EvalMetrics.chrF(hypothesis: "ab", reference: "abcd")
        #expect(abs(score - 47.1698) < 0.01)
    }

    @Test
    func alignmentProjectionIsIdentityForEqualStrings() {
        let projection = EvalMetrics.alignmentProjection(
            hypothesis: Array("abc"), reference: Array("abc"))
        #expect(projection == [0, 1, 2, 3])
    }

    // 参照側に挿入がある場合 (hyp "abc" vs ref "abxc")、"ab" 直後の仮説境界 (2) は
    // 参照側でも "ab" 直後 (2) に射影される (挿入分を跨いだ 4 ではなく)
    @Test
    func alignmentProjectionMapsAcrossReferenceInsertion() {
        let projection = EvalMetrics.alignmentProjection(
            hypothesis: Array("abc"), reference: Array("abxc"))
        #expect(projection == [0, 1, 2, 4])
    }

    // 仮説側の湧き出し (hyp "abxc" vs ref "abc") は同一参照位置に潰れる
    @Test
    func alignmentProjectionCollapsesHypothesisInsertion() {
        let projection = EvalMetrics.alignmentProjection(
            hypothesis: Array("abxc"), reference: Array("abc"))
        #expect(projection == [0, 1, 2, 2, 3])
    }

    @Test
    func boundaryScoreMatchesWithinTolerance() {
        let score = EvalMetrics.boundaryScore(
            hypothesis: [10, 25, 40], reference: [12, 30, 41], tolerance: 3)
        #expect(score.matched == 2)
        #expect(abs(score.precision - 2.0 / 3.0) < 0.001)
        #expect(abs(score.recall - 2.0 / 3.0) < 0.001)
    }

    // 1 対 1 マッチング: 近接する複数の仮説境界が同一参照境界を重複してクレームしない
    @Test
    func boundaryScoreDoesNotDoubleCountReferences()  {
        let score = EvalMetrics.boundaryScore(
            hypothesis: [10, 11], reference: [10], tolerance: 3)
        #expect(score.matched == 1)
        #expect(abs(score.precision - 0.5) < 0.001)
        #expect(abs(score.recall - 1.0) < 0.001)
    }

    // 追記のみの更新列は erasure 0 (伸びる volatile は flicker ではない)
    @Test
    func erasedCharactersIsZeroForAppendOnlyUpdates() {
        #expect(EvalMetrics.erasedCharacters(updates: ["a", "ab", "abc"]) == 0)
    }

    // 末尾の書き換え・縮みは「一度見せた文字の取り消し」として数える
    @Test
    func erasedCharactersCountsTailRewrites() {
        // "abX" → "abcd": X の 1 文字が取り消し。"abcd" → "ab": 2 文字が取り消し
        #expect(EvalMetrics.erasedCharacters(updates: ["abX", "abcd", "ab"]) == 3)
    }
}
