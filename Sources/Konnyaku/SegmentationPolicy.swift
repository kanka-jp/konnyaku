import Foundation

// 強制確定 (段落を待たず文を区切る) の判定ポリシー。app と eval が同一実装を共有し、
// eval (SegmentationEvaluationTests) は複数 case を同一音声で A/B 比較する
enum SegmentationPolicy: CaseIterable, CustomStringConvertible {
    // 文字数閾値 + 末尾句読点 (末尾 10 字以内) + 1.5 倍ハードリミット
    case current
    // 文字数閾値 + 末尾アンカーの節境界判定 + 1.5 倍ハードリミット。
    // 「末尾付近の句読点」は句読点の後に語が続いた位置 (「…ので、表示を」) でも発火して
    // 語中分断を招くため、末尾そのものが区切りのときだけ確定する。
    // 日→英 (SOV→SVO) では動詞前の分断が訳を壊すため節境界で切る
    case clauseAware

    var description: String {
        switch self {
        case .current: return "current"
        case .clauseAware: return "clauseAware"
        }
    }

    // 閾値超過後も区切りが見つからない場合に強制確定を保留する上限 (閾値の倍数)
    static let graceMultiplier = 1.5
    // 句読点の有無を確認する対象は末尾付近のみ (先頭寄りの句読点で誤って早期確定しないため)
    static let punctuationTailWindow = 10
    static let sentenceBreakPunctuation: Set<Character> = [
        "、", "。", "，", "．", "！", "？", ",", ".", "!", "?",
    ]
    // 読点は ASR が主題・主語句の直後にも挿入する (「…画面が、」) ため、それ自体は
    // 文末とみなさず、読点の手前が節境界または述語終端 (endsWithPredicate) の
    // ときだけ確定する (句点・疑問符等と区別)
    static let pausePunctuation: Set<Character> = ["、", "，", ","]
    // 引用・括弧の閉じ記号。句読点の後ろに続く (「…します。」) と末尾アンカー判定を
    // 隠すため、判定前に剥がす
    static let closingBrackets: Set<Character> = ["」", "』", "）", ")", "]", "】", "〉", "》", "\""]
    // 文末の終助詞。述語の後ろに付く (「できますね、」) ため読点手前の述語判定で透過する
    static let sentenceFinalParticles: Set<Character> = ["ね", "よ", "か", "な"]

    // 前後の品詞に依らず節境界とみなせる接続助詞・接続形の末尾。
    // 「ので/のに」は体言接続が「なので/なのに」になるため単独で接続用法に確定し、
    // 「けど/けれど(も)」「たら/れば/なら/ながら」も体言直結の用法が事実上ない。
    // 濁音の条件形は「んだら」に限定する (読んだら/飲んだら。「だら」だと まだら 等の
    // 体言末尾と衝突する)
    // 「つつ」単独は「〜しつつあります」の過渡状態と表層分離不能のため含めず、
    // 逆接が確定する「つつも」のみ扱う (誤確定は誤訳に直結し、保留は hardLimit で
    // 回収される)。ため / うえで / 上で / 場合 は動詞終端ガード付きで
    // endsAtClauseBoundary の switch 側が判定する
    static let unconditionalClauseSuffixes: [String] = [
        "ので", "のに", "けど", "けども", "けれど", "けれども",
        "たら", "んだら", "れば", "なら", "ならば", "ながら", "ながらも", "つつも", "ずに",
        "たものの", "だものの", "ても", "んでも", "いでも",
        "たことから", "ることから", "ないことから", "いことから",
        "たまま", "だまま", "ないまま",
        "たあとで", "だあとで", "た後で", "だ後で",
    ]

    // 表層が接続助詞規則に一致しても節境界でない末尾の負条件 (肯定規則より先に評価する)。
    // 複合格助詞 (について 等)・固定副詞 (改めて 等) は「て」終端、体言 + 格助詞
    // (もので / みなさんで / いつから / くらいから 等) は各肯定規則と表層が衝突するが
    // いずれも述語が来る前の句の途中のため切らない。なぜなら は節頭の接続詞で
    // 直後に理由節が続くため同様に切らない
    static let nonBoundarySuffixes: [String] = [
        "について", "として", "において", "にとって", "によって",
        "に関して", "に対して", "をめぐって", "に向けて", "につれて",
        "に基づいて", "に応じて", "に沿って", "にわたって", "に従って", "に加えて",
        "を通じて", "を通して", "をもって",
        "改めて", "初めて", "極めて",
        "ものに", "もので",
        "さんで", "ちゃんで", "くんで",
        "いつから", "くらいから", "ぐらいから",
        "いくつ", "いつ",
        "なぜなら", "なぜならば", "残念ながら", "しかしながら", "やたら",
        "昔ながら", "我ながら",
        "ほかなら", "他なら", "ばなら", "はなら",
        "どうして", "どうやって", "どうしたら", "どうすれば", "ただし",
        "ほうが",
        "まだ", "ただ", "また", "ずつ", "もたら",
        "しばらく", "おそらく", "ようやく", "まったく", "せっかく",
        "けっして",
        "そして", "こうして", "そうして", "かえって", "なんで",
        "新た",
        "そしたら", "そうしたら", "もしかしたら", "ひょっとしたら", "せめて", "すべて",
        "例えば", "たとえば", "そういえば", "あえて", "敢えて",
        "とても", "としても", "にしても", "どうしても", "なんとしても", "とんでも", "なんでも",
        "かねてから", "いたし",
    ]

    // 接続助詞「て」の直前に現れうる文字。五段動詞の音便形 (使って/聞いて/読んで)、
    // かな語幹の一段動詞 (食べて/できて/信じて)、い形容詞の接続形 (長くて/読みづらくて)。
    // 見て/出て/来て 等の漢字一文字語幹は直前が漢字になるため本方式では判定できない
    // (既知の保留側トレードオフ)。「に」は「〜にて」(格助詞) と衝突するため含めない。
    // 話題・引用の「って」(「この設定って」) は促音便て形 (「使って」) と表層完全同形の
    // ため分別できない (既知の確定側トレードオフ)
    static let teFormPrecedingCharacters: Set<Character> = [
        "っ", "い", "し", "え", "け", "せ", "べ", "め", "ね", "れ", "げ", "て",
        "き", "ぎ", "じ", "ち", "み", "り", "び", "ひ", "ぜ", "で", "く",
    ]

    // 「〜たから/〜するから」の接続用法を「駅から」の格助詞用法と区別するための
    // 動詞終端文字 (終止形の u 段 + た/だ/い)。送りがな終端の転成名詞 + から
    // (「違いから」等) は形容詞 + から (「広いから」) と表層同形のため分別できない
    // (既知の確定側トレードオフ)
    static let verbFinalCharacters: Set<Character> = [
        "た", "だ", "い", "う", "く", "ぐ", "す", "つ", "ぬ", "ぶ", "む", "る",
    ]

    // 述語で終わるか (「が」の接続用法と「画面が」の主格用法の区別、および読点手前の
    // 文相当判定に共用)。動詞終端文字から「い」を除いた集合 (違い/扱い 等の転成名詞が
    // 主語として頻出するため。長いが 等の形容詞対照は保留側に倒し、否定の ない と
    // 願望の たい は多文字判定で維持) に、ん 終端で文字集合に乗らない「ません」を
    // 加えた近似
    static func endsWithPredicate(_ text: some StringProtocol) -> Bool {
        if text.hasSuffix("ません") || text.hasSuffix("ない") || text.hasSuffix("たい") {
            return true
        }
        guard let last = text.last, last != "い" else { return false }
        return verbFinalCharacters.contains(last)
    }

    // 五段動詞の条件形「〜えば」の直前に現れる え段文字 (書けば/話せば/読めば)。
    // 五段の語尾 (う/く/ぐ/す/つ/ぬ/ぶ/む/る) に対応する 9 字のみで、
    // ぜ/で/へ は対応する語尾を持つ動詞が無いため含めない
    static let ebaRowCharacters: Set<Character> = [
        "え", "け", "げ", "せ", "て", "ね", "べ", "め", "れ",
    ]

    // 閾値超過後、区切りらしい位置なら確定要求する。無ければ閾値の 1.5 倍まで
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
        case .clauseAware:
            // 閉じ括弧・閉じ引用符 (「…します。」) は句読点判定を隠すため先に剥がす
            var tail = Substring(text)
            while let closer = tail.last, Self.closingBrackets.contains(closer) {
                tail = tail.dropLast()
            }
            guard let last = tail.last else { return false }
            if Self.pausePunctuation.contains(last) {
                var head = tail.dropLast()
                // 引用節直後の読点 (「保存しました」、) も閉じ記号を剥がして判定する
                while let closer = head.last, Self.closingBrackets.contains(closer) {
                    head = head.dropLast()
                }
                // 終助詞 (「できますね、」) は述語の後ろに付くため、負条件・述語の
                // 判定より先に透過する (「ただね、」を負条件が見逃さないため)
                while let particle = head.last, Self.sentenceFinalParticles.contains(particle) {
                    head = head.dropLast()
                }
                // コピュラ述語「〜ままだ、」は副詞「まだ」の負条件より先に確定する。
                // 読点なしの「ままだ」は「ままだと/ままだった」の過渡状態と分離
                // 不能のため確定せず、ポーズの証拠がある読点経路に限定する
                if head.hasSuffix("ままだ") { return true }
                // 負条件 (まだ、/ただ、等の副詞) を述語判定より先に評価する
                if Self.nonBoundarySuffixes.contains(where: { head.hasSuffix($0) }) {
                    return false
                }
                // 述語直後の読点 (「〜します、」) は文相当の区切りとして確定する
                if Self.endsWithPredicate(head) { return true }
                return Self.endsAtClauseBoundary(head)
            }
            if Self.sentenceBreakPunctuation.contains(last) {
                return true
            }
            return Self.endsAtClauseBoundary(tail)
        }
    }

    // 末尾が接続助詞で終わる節境界かを表層形の規則で判定する。
    // NLTagger の .lexicalClass は日本語では全トークンに .otherWord を返し品詞判定に
    // 使えない (実測) ため、形態素の品詞ではなく末尾サフィックス + 直前文字の
    // 語彙規則で「接続助詞」と「体言 + 格助詞」(駅から / 画面が / 会議室で) を近似分別する。
    // 判定は ASR 出力の書字文字に対して行う (漢字正規化により体言の多くは
    // 漢字終端になり、かな終端を前提とする肯定規則と自然に分離される)
    static func endsAtClauseBoundary(_ text: some StringProtocol) -> Bool {
        for suffix in nonBoundarySuffixes where text.hasSuffix(suffix) {
            return false
        }
        for suffix in unconditionalClauseSuffixes where text.hasSuffix(suffix) {
            return true
        }
        // volatile 更新ごとに呼ばれる hot path のため、全量の Array 化や String 再構築を
        // 避け、サフィックス照合と末尾数文字の参照だけで判定する
        guard let last = text.last else { return false }
        let head = text.dropLast()
        switch last {
        case "て":
            guard let previous = head.last else { return false }
            return teFormPrecedingCharacters.contains(previous)
        case "で":
            // 前提の接続節 (確認したうえで/使う上で)。体言接続 (机の上で) と
            // 区別するため直前が動詞終端のときに限定する
            if text.hasSuffix("うえで"), let before = text.dropLast(3).last,
                verbFinalCharacters.contains(before)
            {
                return true
            }
            if text.hasSuffix("上で"), let before = text.dropLast(2).last,
                verbFinalCharacters.contains(before)
            {
                return true
            }
            // 音便形「読んで/飲んで」のみ。他の「で」は格助詞が圧倒的に多い。
            // 否定て形「しないで」は「〜ないです」の発話途中の過渡状態と表層分離
            // 不能のため確定しない (誤確定は誤訳に直結し、保留は hardLimit で
            // 回収される。否定接続は ずに 側でカバーする)。「ませんで」も
            // 「ありませんでした」の過渡状態のため同様に確定しない
            if head.hasSuffix("ない") || head.hasSuffix("ません") { return false }
            return head.last == "ん"
        case "し":
            // 並列の接続助詞「〜だし/〜ますし/〜ませんし」。かな終端の体言 (むかし 等) と区別
            if head.hasSuffix("ません") { return true }
            guard let previous = head.last else { return false }
            return verbFinalCharacters.contains(previous)
        case "が":
            return endsWithPredicate(head)
        case "め":
            // 目的・理由の接続節 (使うため/発生したため/多いため)。体言接続
            // (そのため/このため) は節頭の接続詞のため直前が動詞・形容詞終端の
            // ときに限定する
            guard text.hasSuffix("ため"), let before = text.dropLast(2).last else { return false }
            return verbFinalCharacters.contains(before)
        case "合":
            // 条件の接続節 (発生した場合/変更する場合)。体言接続 (配置の場合) と
            // 区別するため直前が動詞・形容詞終端のときに限定する
            guard text.hasSuffix("場合"), let before = text.dropLast(2).last else { return false }
            return verbFinalCharacters.contains(before)
        case "ば":
            // 五段動詞の条件形 (書けば/話せば/読めば)。え段 + ば に限定する
            // (一段・する の条件形「れば」は無条件サフィックス側で確定済み)
            guard let previous = head.last else { return false }
            return ebaRowCharacters.contains(previous)
        case "ら":
            guard text.hasSuffix("から") else { return false }
            // て形 + から (確認してから) も時間接続の節境界。濁音側は音便形の
            // んでから (読んでから) / いでから (泳いでから) に限定する
            // (裸の「でから」だと体言 + 格助詞で + から の過渡状態と衝突する)
            if text.hasSuffix("てから") || text.hasSuffix("んでから") || text.hasSuffix("いでから") {
                return true
            }
            // 丁寧否定の理由節 (対応できませんから)。ん は動詞終端集合外のため個別に扱う
            if text.hasSuffix("ませんから") { return true }
            guard let beforeKara = text.dropLast(2).last else { return false }
            return verbFinalCharacters.contains(beforeKara)
        default:
            return false
        }
    }
}
