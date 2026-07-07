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

    // 動詞 + から (「言われたから」) は理由の接続用法として確定する
    @Test
    func clauseAwareTrueAtVerbKara() {
        let text = "来月の予定を確認したところ会議が重なっていてどれも動かせないと言われたから"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 35))
    }

    // 体言 + から (「駅から」) は起点の格助詞用法のため保留する
    @Test
    func clauseAwareHoldsOffAtNounKara() {
        let text = "会場までの移動時間を短くしたいので当日はいつも使っている自宅の最寄り駅から"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 36))
    }

    // て形 + から (「読んでから」) は時間の接続用法として確定する
    @Test
    func clauseAwareTrueAtTeKara() {
        let text = "配布した資料の最初のページにある注意書きを全員がひととおり読んでから"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 丁寧否定 + が (「ありませんが」) は接続用法として確定する
    @Test
    func clauseAwareTrueAtMasenGa() {
        let text = "この機能はまだ実験段階なので細かい調整までは手が回っておらず申し訳ありませんが"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 35))
    }

    // かな語幹の一段動詞て形 (「できて」) は節境界として確定する
    @Test
    func clauseAwareTrueAtIchidanTeForm() {
        let text = "先週から準備していた新しい仕組みがようやく手元の環境でも問題なく確認できて"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 37))
    }

    // 「〜に基づいて」は「い + て」で て形規則に一致するが複合格助詞のため保留する
    @Test
    func clauseAwareHoldsOffAtNiMotozuite() {
        let text = "今回の設計は去年のユーザー調査で集めたアンケートの自由記述の分析結果に基づいて"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 38))
    }

    // ひらがな敬称 + で (「みなさんで」) は「ん + で」に一致するが体言句のため保留する
    @Test
    func clauseAwareHoldsOffAtHonorificDe() {
        let text = "この後の時間はせっかく全員が集まっているのでここにいる参加者のみなさんで"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 36))
    }

    // 程度表現 + から (「くらいから」) は「い + から」に一致するが体言句のため保留する
    @Test
    func clauseAwareHoldsOffAtKuraiKara() {
        let text = "リリース後の様子を見ながら進めたいので本格的な移行の作業は来月の中旬くらいから"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 38))
    }

    // 濁音の条件形 (「読んだら」) は接続用法として確定する
    @Test
    func clauseAwareTrueAtNdara() {
        let text = "会議で配られた資料をまず参加者が自分のペースでひととおり読んだら"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 「だら」終端の体言 (「まだら」) は「んだら」に一致しないため保留する
    @Test
    func clauseAwareHoldsOffAtMadara() {
        let text = "実際に画面を見てみると字幕の背景の黒の濃さが場所によってまだら"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 音便形 + から (「泳いでから」) は時間接続として確定する
    @Test
    func clauseAwareTrueAtIdeKara() {
        let text = "午前中は体を慣らすためにまずプールの浅いところでひととおり泳いでから"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 体言 + 格助詞で + から の過渡状態 (「会議室でから」) は「んでから/いでから」に一致しないため保留する
    @Test
    func clauseAwareHoldsOffAtLocativeDeKara() {
        let text = "次のセッションの受付はさっき案内があった二階の奥にある会議室でから"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 体言「もの」+ 格助詞 (「もので」) は「ので」に表層一致するが句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtMonoDe() {
        let text = "動作確認に使う端末は会社の備品ではなくいつも使っている手元のもので"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 固定副詞 (「改めて」) は「め + て」に一致するが後続の述語を修飾する句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtFixedAdverbTe() {
        let text = "この件は資料の準備ができたところで来週の定例の時間をもらって改めて"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }
}
