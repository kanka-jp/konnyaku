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

    // 主語句直後の読点 (「…画面が、」) はそれ自体を文末とみなさず保留する
    @Test
    func clauseAwareHoldsOffAtCommaAfterSubject() {
        let text = "リアルタイムで音声を認識して翻訳するときに使うつもりで作っている設定の画面が、"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 38))
    }

    // 節境界直後の読点 (「…あったので、」) は確定する (読点の手前で節境界判定)
    @Test
    func clauseAwareTrueAtCommaAfterClauseBoundary() {
        let text = "リアルタイムで音声を認識して翻訳するときに字幕の区切りがうまくいかない問題があったので、"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 40))
    }

    // 固定副詞 (「残念ながら」) は「ながら」に一致するが後続の述語を修飾するため保留する
    @Test
    func clauseAwareHoldsOffAtZannenNagara() {
        let text = "字幕の表示位置を細かく調整できる設定も検討しましたが今回の対応では残念ながら"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 34))
    }

    // い形容詞の接続形 (「長くて」) は節境界として確定する
    @Test
    func clauseAwareTrueAtAdjectiveKute() {
        let text = "画面の下に出てくる翻訳の字幕はどうしても一行あたりの説明が長くて"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 述語直後の読点 (「…します、」) は文相当の区切りとして確定する
    @Test
    func clauseAwareTrueAtCommaAfterPredicate() {
        let text = "設定の変更はこの画面のスイッチを切り替えるとすぐに本体へ保存します、"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 32))
    }

    // 並列の接続助詞 (「増えたし」) は節境界として確定する
    @Test
    func clauseAwareTrueAtParallelShi() {
        let text = "認識の精度は前のバージョンより上がったし対応できる言語の種類も増えたし"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 32))
    }

    // 疑問副詞 (「どうして」) は「し + て」に一致するが疑問文の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtDoushite() {
        let text = "設定を切り替えても字幕の表示位置がなかなか変わらないのはどうして"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 節頭の接続詞 (「ただし」) は「だ + し」に一致するが直後に条件節が続くため保留する
    @Test
    func clauseAwareHoldsOffAtTadashi() {
        let text = "この機能は次のバージョンからすべての利用者に既定で有効になりますただし"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 32))
    }

    // 副詞 + 読点 (「まだ、」) は「だ」が述語終端に一致するが述語ではないため保留する
    @Test
    func clauseAwareHoldsOffAtAdverbMadaComma() {
        let text = "新しい認識モデルへの切り替えは検証が終わっていないのでこの時点ではまだ、"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 32))
    }

    // 否定副詞 (「けっして」) は「し + て」に一致するが後続の述語を修飾するため保留する
    // (漢字表記の 決して は 解決して 等の漢語複合動詞のて形と同形のため負条件にしない)
    @Test
    func clauseAwareHoldsOffAtKesshite() {
        let text = "この設定を変えても既存の字幕の履歴が消えてしまうことはけっして"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 28))
    }

    // 漢語複合動詞のて形 (「解決して」) は負条件に誤ブロックされず確定する
    @Test
    func clauseAwareTrueAtCompoundVerbTeForm() {
        let text = "認識が途中で止まってしまう既知の問題は先週のリリースで解決して"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 28))
    }

    // コピュラ述語 + 読点 (「このままだ、」) は副詞 まだ の負条件より先に確定する
    @Test
    func clauseAwareTrueAtMamadaComma() {
        let text = "再起動しても字幕の表示位置は前回の設定を引き継いでこのままだ、"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 28))
    }

    // 辞書形の述語 + が (「変更するが」) は接続用法として確定する
    @Test
    func clauseAwareTrueAtPlainVerbGa() {
        let text = "次のリリースで字幕の既定の表示位置は画面の下側に変更するが"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 節頭の接続詞 (「そして」) は「し + て」に一致するが直後に節が続くため保留する
    @Test
    func clauseAwareHoldsOffAtSoshite() {
        let text = "まず音声認識のモデルを読み込んで準備ができたことを確認しますそして"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 疑問詞 (「なんで」) は「ん + で」に一致するが疑問文の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtNande() {
        let text = "設定を切り替えたのに字幕の表示位置が変わらないのはいったいなんで"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 副詞 (「せめて」) は「め + て」に一致するが後続の述語を修飾するため保留する
    @Test
    func clauseAwareHoldsOffAtSemete() {
        let text = "全部の言語に対応するのは難しいとしても今回のリリースではせめて"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 28))
    }

    // 丁寧否定の並列 (「できませんし」) は節境界として確定する
    @Test
    func clauseAwareTrueAtMasenShi() {
        let text = "古い端末では新しい認識モデルがそもそも動きませんし"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // 否定のて形 (「保存しないで」) は「〜ないです」の過渡状態と表層分離不能のため保留する
    @Test
    func clauseAwareHoldsOffAtNegativeTeForm() {
        let text = "動作を試すだけのときは画面の下のボタンから設定を保存しないで"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 28))
    }

    // 「〜ないです」の過渡状態 (「問題ないで」) は保留する
    @Test
    func clauseAwareHoldsOffAtNaideTransient() {
        let text = "新しいモデルに切り替えた後の認識の精度はいまのところ特に問題ないで"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 閉じ引用符付きの句点 (「…します。」) は閉じ記号を剥がして文末として確定する
    @Test
    func clauseAwareTrueAtPunctuationBeforeClosingQuote() {
        let text = "処理が終わると画面の上の段に「認識が完了しました。」"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // 終助詞 + 読点 (「できますね、」) は終助詞を透過して述語 + 読点として確定する
    @Test
    func clauseAwareTrueAtFinalParticleComma() {
        let text = "変更した内容はこの画面の右下のボタンからいつでも保存できますね、"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 否定接続 (「保存せずに」) は節境界として確定する
    @Test
    func clauseAwareTrueAtZuni() {
        let text = "動作を試すだけのときは変更した内容をいったん本体に保存せずに"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 28))
    }

    // 「けども」は けど の表層変種として確定する
    @Test
    func clauseAwareTrueAtKedomo() {
        let text = "字幕の表示位置は既定のままでも大きな問題はないと思うんですけども"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 固定副詞 (「例えば/すべて」) は え+ば / べ+て に一致するが句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtTatoebaAndSubete() {
        let tatoeba = "音の環境によって認識の精度は変わるので静かな会議室の場合だと例えば"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: tatoeba, threshold: 30))
        let subete = "移行を始める前に設定画面に並んでいる必要な項目をまずはすべて"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: subete, threshold: 28))
    }

    // 転成名詞の主語 (「違いが」) は い 終端だが述語ではないため保留する
    @Test
    func clauseAwareHoldsOffAtDeverbalNounGa() {
        let text = "同じ音声でも認識モデルの版による細かい挙動や結果の違いが"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 逆接の接続形 (「抱えながらも」) は確定し、「たものの」は連体修飾
    // (「入れたものの一覧」) と表層分離不能のため保留する
    @Test
    func clauseAwareTrueAtNagaramoAndHoldsOffAtMonono() {
        let nagaramo = "実行速度の面ではまだいくつかの課題を抱えながらも"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: nagaramo, threshold: 22))
        let monono = "先週のリリースで認識が止まる問題には修正を入れたものの"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: monono, threshold: 24))
    }

    // 譲歩の固定接続 (「したにもかかわらず」) は節境界として確定する
    @Test
    func clauseAwareTrueAtNimokakawarazu() {
        let text = "事前に設定の内容を何度も確認したにもかかわらず"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 20))
    }

    // 数詞の助数詞 + が (「ひとつが」「四つが」) は主語の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtCounterGa() {
        let hitotsu = "今回の障害で報告が多かった原因のひとつが"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: hitotsu, threshold: 18))
        let yottsu = "設定の画面に並んでいる項目の四つが"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: yottsu, threshold: 15))
    }

    // 述語 + としても (「必要だとしても」) は確定し、体言 + としても は保留する
    @Test
    func clauseAwareShitemoDistinguishesPredicateAndNoun() {
        let predicate = "新しいモデルへの切り替えがどうしても必要だとしても"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: predicate, threshold: 22))
        let noun = "この問題への対応の方針については私たちの会社としても"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: noun, threshold: 23))
    }

    // 疑問詞・数詞 + まで (「いつまで」「二つまで」) は体言句のため保留する
    @Test
    func clauseAwareHoldsOffAtNominalMade() {
        let itsumade = "この静音の設定が有効になるのはいったいいつまで"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: itsumade, threshold: 20))
        let futatsumade = "共有ビューで同時に表示できる字幕の行は二つまで"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: futatsumade, threshold: 20))
    }

    // 副詞 + 後に (「されたすぐ後に」の すぐ後に) は述語接続ではないため保留する
    @Test
    func clauseAwareHoldsOffAtAdverbAtoni() {
        let text = "モデルの切り替えの通知が表示されたすぐ後に"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 18))
    }

    // ひらがな代名詞 + が (「あなたが」) は主語の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtHiraganaPronounGa() {
        let text = "次の定例のこの機能の説明はぜひあなたが"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 16))
    }

    // 比較の複合後置詞 (「に比べて」) は「べ + て」に一致するが句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtNiKurabete() {
        let text = "新しい認識モデルの精度は前の版のものに比べて"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 19))
    }

    // い形容詞の述語 + 読点 (「見づらい、」) は確定し、転成名詞 (「違い、」) は保留する
    @Test
    func clauseAwareAdjectivePredicateComma() {
        let adjective = "いまの配色だと字幕の文字と背景の対比が見づらい、"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: adjective, threshold: 21))
        let noun = "同じ音声でも認識モデルの版ごとの結果の違い、"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: noun, threshold: 19))
    }

    // 義務構文の過渡状態 (「確認しなければ」) は「れば」に一致するが保留する
    @Test
    func clauseAwareHoldsOffAtNakerebaTransient() {
        let text = "移行の前に設定の内容をひととおり確認しなければ"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 20))
    }

    // 連体詞 + 場合 (「どんな場合」) は名詞句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtDonnaBaai() {
        let text = "下側の帯の配置の字幕が向いているのはどんな場合"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 20))
    }

    // 副詞 + 読点 (「少しずつ、」) と過渡状態 (「もたら」) は保留する
    @Test
    func clauseAwareHoldsOffAtZutsuCommaAndMotara() {
        let zutsu = "設定の変更は再起動を待たずにこの画面の項目から少しずつ、"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: zutsu, threshold: 26))
        let motara = "今回の変更が字幕の読みやすさにどれだけの改善をもたら"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: motara, threshold: 24))
    }

    // 五段動詞の条件形 (「書けば」等の え段 + ば) は節境界として確定する
    @Test
    func clauseAwareTrueAtGodanConditional() {
        let text = "認識がうまくいかないときは設定画面から辞書に読み方を書けば"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 丁寧否定の理由節 (「できませんから」) は節境界として確定する
    @Test
    func clauseAwareTrueAtMasenKara() {
        let text = "この画面では過去の字幕の履歴までは遡って確認できませんから"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 譲歩の接続形 (「変更しても」) は節境界として確定する
    @Test
    func clauseAwareTrueAtTemoConcessive() {
        let text = "アプリを再起動して認識に使う言語の設定を何度か変更しても"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // 副詞「とても」は「ても」に一致するが程度修飾の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtTotemo() {
        let text = "新しい表示モードでの字幕の読みやすさは前と比べるととても"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // 理由・目的の接続形 (「発生したため」) は節境界として確定する
    @Test
    func clauseAwareTrueAtTameClause() {
        let text = "昨日の夜に認識サーバー側でモデルの配信に障害が発生したため"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 接続節 (「確認したうえで」) は節境界として確定する
    @Test
    func clauseAwareTrueAtUedeClause() {
        let text = "移行の前にまず設定画面の項目をひととおり確認したうえで"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // く終端の副詞 + 読点 (「しばらく、」) は述語ではないため保留する
    @Test
    func clauseAwareHoldsOffAtShibarakuComma() {
        let text = "モデルの切り替えの直後は新しい設定が反映されるまでしばらく、"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 「〜ませんでした」の過渡状態 (「ありませんで」) は保留する
    @Test
    func clauseAwareHoldsOffAtMasenDeTransient() {
        let text = "前回の版では認識が止まる問題への恒久的な対応はまだありませんで"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 28))
    }

    // 固定副詞 (「どうしても」) と過渡状態 (「とんでも」) は「(んで)も」に一致するが保留する
    @Test
    func clauseAwareHoldsOffAtDoushitemoAndTondemo() {
        let doushitemo = "古い端末との互換性の制約があって表示の仕組みの側ではどうしても"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: doushitemo, threshold: 28))
        let tondemo = "設定を全部初期化してやり直すというのはそれはさすがにとんでも"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: tondemo, threshold: 26))
    }

    // 連体の もの + の (「必要なものの」) は逆接に一致せず保留する
    @Test
    func clauseAwareHoldsOffAtGenitiveMonono() {
        let text = "移行を始める前に新しい環境の構築に必要なものの"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // 副詞 + 終助詞 + 読点 (「ただね、」) は終助詞を剥がした後も負条件で保留する
    @Test
    func clauseAwareHoldsOffAtAdverbParticleComma() {
        let text = "設定はそのままでもほとんどの場合は問題なく使えるんですがただね、"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 音便形の譲歩 (「急いでも」) と否定の理由節 (「できないため」) は確定する
    @Test
    func clauseAwareTrueAtIdemoAndNaiTame() {
        let idemo = "モデルの読み込みは端末の性能に依存するのでどれだけ急いでも"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: idemo, threshold: 26))
        let naitame = "外部のネットワークからは検証用のサーバーに接続できないため"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: naitame, threshold: 26))
    }

    // 固定副詞 (「かねてから」) は「てから」に一致するが句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtKanetekara() {
        let text = "認識モデルの差し替えに備えた仕組みの見直しはこの機能ではかねてから"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 30))
    }

    // 固定表現「にほかならない」の過渡状態 (「にほかなら」) は「なら」に一致するが保留する
    @Test
    func clauseAwareHoldsOffAtHokanaraTransient() {
        let text = "この問題の原因は設定ファイルの記述の不備にほかなら"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // 譲歩の接続形 (「進めつつも」) は節境界として確定する
    @Test
    func clauseAwareTrueAtTsutsumo() {
        let text = "利用者からの意見を集めて画面の表示の改善を進めつつも"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // 条件の接続形 (「必要ならば」) は節境界として確定する
    @Test
    func clauseAwareTrueAtNaraba() {
        let text = "認識のモデルを新しい版へ切り替える対応がもし必要ならば"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 代名詞的な「なんでも」は音便形の譲歩「んでも」に一致するが句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtNandemo() {
        let text = "設定の画面では表示に関わる項目を利用者がなんでも"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // 謙譲の「いたします」の過渡状態 (「お配りいたし」) は並列の「し」に一致するが保留する
    @Test
    func clauseAwareHoldsOffAtItashiTransient() {
        let text = "資料の準備ができましたので後ほど会場でお配りいたし"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // 談話標識「そういえば」は条件形の「えば」に一致するが句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtSouieba() {
        let text = "字幕の表示の設定について説明しようと思ったんですがそういえば"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 28))
    }

    // 節頭の接続詞「なぜならば」は「ならば」に一致するが直後に理由節が続くため保留する
    @Test
    func clauseAwareHoldsOffAtNazenaraba() {
        let text = "この機能は今回の版では既定で無効にしていますなぜならば"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 五段動詞の条件形に現れない「へ + ば」(「へばりつく」の過渡状態) は保留する
    @Test
    func clauseAwareHoldsOffAtHebaTransient() {
        let text = "結露した窓のガラスに貼ったシートが時間とともにへば"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // 必要の助動詞「なければならない」の過渡状態 (「なければなら」) は保留する
    @Test
    func clauseAwareHoldsOffAtNakerebaNaraTransient() {
        let text = "この項目は移行の前に必ず設定画面で状態を確認しなければなら"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 願望の助動詞 (「したいが」「したい、」) は述語終端として確定する
    @Test
    func clauseAwareTrueAtDesiderativeTai() {
        let taiga = "新しい表示モードは次の版でぜひ既定の設定として有効にしたいが"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: taiga, threshold: 28))
        let taiComma = "リリースの前に一度は実際の会議の音声でも動作を確認したい、"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: taiComma, threshold: 26))
    }

    // 形式名詞の理由節 (「増えたことから」) は節境界として確定する
    @Test
    func clauseAwareTrueAtKotoKara() {
        let text = "先月から利用者の数が急に増えたことから"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 18))
    }

    // 複合助詞 (「をもって」) は「っ + て」に一致するが句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtWoMotte() {
        let text = "長年続けてきた旧形式の配信は本日の更新をもって"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 20))
    }

    // 固定副詞 (「かえって」) は「っ + て」に一致するが後続の述語を修飾するため保留する
    @Test
    func clauseAwareHoldsOffAtKaette() {
        let text = "字幕を大きくしすぎると本番の共有画面ではかえって"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // 引用節直後の読点 (「保存しました」、) は閉じ記号を剥がして述語 + 読点として確定する
    @Test
    func clauseAwareTrueAtCommaAfterClosingQuote() {
        let text = "設定を変更すると画面の上の段に「保存しました」、"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // 固定の連体形 (「昔ながら」) は「ながら」に一致するが名詞句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtMukashiNagara() {
        let text = "新しい版でも設定画面の構成は利用者に馴染みのある昔ながら"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 26))
    }

    // 固定の謙譲表現 (「僭越ながら」) は「ながら」に一致するが句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtSenetsuNagara() {
        let text = "表示の改善の要望についてはこの場を借りて僭越ながら"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // 目的の接続節 (「使うために」) は確定し、節頭の「そのために」は保留する
    @Test
    func clauseAwareTrueAtTameni() {
        let tsukau = "新しい認識モデルを次の版でも続けて使うために"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: tsukau, threshold: 20))
        let sonotameni = "認識は端末の性能に依存していますそのために"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: sonotameni, threshold: 18))
    }

    // 連体の な + 場合 (「必要な場合」) と主題化 (「した場合は」) は確定する
    @Test
    func clauseAwareTrueAtNaBaaiAndBaaiwa() {
        let naBaai = "認識モデルの再取得がどうしても必要な場合"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: naBaai, threshold: 18))
        let baaiwa = "共有ビューの表示中にエラーが発生した場合は"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: baaiwa, threshold: 18))
    }

    // 固定の時間表現 (「また後で」) は「た後で」に一致するが句の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtMataAtode() {
        let text = "この設定の詳しい説明は時間が足りないのでまた後で"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // 時間副詞 + 読点 (「すぐ、」) は述語ではないため保留する
    @Test
    func clauseAwareHoldsOffAtSuguComma() {
        let text = "設定の変更は保存のボタンを押すとすぐ、"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 16))
    }

    // ひらがな代名詞 (「わたし」) は「た + し」に一致するが体言のため保留する
    @Test
    func clauseAwareHoldsOffAtWatashi() {
        let text = "次の定例で新機能の説明を担当するのはわたし"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 18))
    }

    // 起点の固定形 (「古くから」) は保留し、動詞終止形 (「行くから」) は確定する
    @Test
    func clauseAwareKaraDistinguishesFixedAndVerb() {
        let furuku = "この形式の字幕は放送の分野では古くから"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: furuku, threshold: 16))
        let iku = "資料は私が先に会場へ持って行くから"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: iku, threshold: 15))
    }

    // 様態・目的の接続節 (「なるように」) は確定し、指示の「このように」は保留する
    @Test
    func clauseAwareTrueAtYouni() {
        let naruyouni = "画面の字幕が離れた席からでも見やすくなるように"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: naruyouni, threshold: 20))
        let konoyouni = "下側の帯の配置では字幕は黒い帯の中にこのように"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: konoyouni, threshold: 20))
    }

    // 時間の接続節 (「終わるまで」) は確定し、固定副詞 (「あくまで」) は保留する
    @Test
    func clauseAwareTrueAtMadeClause() {
        let owaru = "共有ビューの録画は会議のすべての議題が終わるまで"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: owaru, threshold: 21))
        let akumade = "この数値は参考のための目安であってあくまで"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: akumade, threshold: 18))
    }

    // 時・条件の接続節 (「出たとき」「確認した後に」) は節境界として確定する
    @Test
    func clauseAwareTrueAtTokiAndAtoni() {
        let toki = "共有ビューの表示中に認識のエラーが出たとき"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: toki, threshold: 18))
        let atoni = "移行の前にまず設定画面の項目を確認した後に"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: atoni, threshold: 18))
    }

    // 形容動詞の連体形 + 読点 (「新たな、」) は な を剥がしても述語ではないため保留する
    @Test
    func clauseAwareHoldsOffAtAratanaComma() {
        let text = "次の版では字幕の表示にこれまでになかった新たな、"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // い形容詞の理由節 (「見づらいため」「低いことから」) は節境界として確定する
    @Test
    func clauseAwareTrueAtAdjectiveReasonClause() {
        let itame = "新しい表示モードは文字と背景の対比が弱くて見づらいため"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: itame, threshold: 24))
        let ikotokara = "今回の障害は再現の頻度が極端に低いことから"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: ikotokara, threshold: 18))
    }

    // 疑問の語幹 + 条件形 (「どうしたら/どうすれば」) は質問文の途中のため保留する
    @Test
    func clauseAwareHoldsOffAtQuestionConditional() {
        let doushitara = "保存した字幕の履歴が急に消えてしまったときはどうしたら"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: doushitara, threshold: 24))
        let dousureba = "認識の言語がうまく切り替わらないときはどうすれば"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: dousureba, threshold: 22))
    }

    // 比較・助言の構文 (「したほうが」) は「ほう + が」で述語ではないため保留する
    @Test
    func clauseAwareHoldsOffAtHougaConstruction() {
        let text = "本番で使う前に一度は静かな環境で動作を確認したほうが"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // 状態継続の従属節 (「開いたまま」「保存しないまま」) は節境界として確定する
    @Test
    func clauseAwareTrueAtMamaClause() {
        let tamama = "共有ビューの画面は会議が終わるまでずっと開いたまま"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: tamama, threshold: 22))
        let naimama = "変更した設定の内容を本体に保存しないまま"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: naimama, threshold: 18))
    }

    // 疑問の量化表現 + 読点 (「いくつか、」) は か を剥がしても述語ではないため保留する
    @Test
    func clauseAwareHoldsOffAtIkutsukaComma() {
        let text = "移行の前に設定の画面で確認してほしい項目がいくつか、"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // 固定副詞 (「もしかしたら」) は「たら」に一致するが後続の節を導くため保留する
    @Test
    func clauseAwareHoldsOffAtMoshikashitara() {
        let text = "認識が急に止まってしまう今回の問題の原因はもしかしたら"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }

    // 談話標識 (「もしかして」) は「し + て」に一致するが後続の節を導くため保留する
    @Test
    func clauseAwareHoldsOffAtMoshikashite() {
        let text = "認識が急に止まった今回の問題はもしかして"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 18))
    }

    // 辞書形 + ため (「使うため」) は確定し、節頭の接続詞 (「そのため」) は保留する
    @Test
    func clauseAwareTrueAtDictionaryFormTame() {
        let tsukau = "新しい認識のモデルを次の版の検証でも続けて使うため"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: tsukau, threshold: 22))
        let sonotame = "認識の処理は端末の性能に大きく依存していますそのため"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: sonotame, threshold: 24))
    }

    // 辞書形 + 上で (「使う上で」) は前提の接続節として確定する
    @Test
    func clauseAwareTrueAtDictionaryFormUede() {
        let text = "この機能を毎日の会議の記録の用途で継続して使う上で"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 22))
    }

    // 述語 + 場合 (「発生した場合」) は確定し、体言 + の場合 は保留する
    @Test
    func clauseAwareTrueAtPredicateBaai() {
        let hassei = "共有ビューの表示中に認識のエラーが発生した場合"
        #expect(SegmentationPolicy.clauseAware.shouldForceFinalize(text: hassei, threshold: 20))
        let noBaai = "字幕の表示の位置を調整できるのは下側の帯の配置の場合"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: noBaai, threshold: 24))
    }

    // 「〜しつつあります」の過渡状態 (「改善しつつ」) は保留する (つつも のみ確定)
    @Test
    func clauseAwareHoldsOffAtBareTsutsu() {
        let text = "利用者の意見を取り込んで表示の品質を少しずつ改善しつつ"
        #expect(!SegmentationPolicy.clauseAware.shouldForceFinalize(text: text, threshold: 24))
    }
}
