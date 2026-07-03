import Testing

@testable import Konnyaku

@MainActor
struct CorrectionEngineTests {
    @Test func restoresPlainEndingWhenModelDriftsToPolite() {
        #expect(
            CorrectionEngine.restoringSentenceEnding(
                of: "会議で課題を共有しました。", toMatch: "会議で課題を共有した")
                == "会議で課題を共有した。")
        #expect(
            CorrectionEngine.restoringSentenceEnding(
                of: "精度を定量的に評価します。", toMatch: "精度を定量的に評価する。")
                == "精度を定量的に評価する。")
        #expect(
            CorrectionEngine.restoringSentenceEnding(
                of: "このアプリは字幕を使っています。", toMatch: "このアプリは字幕を使っている")
                == "このアプリは字幕を使っている。")
        #expect(
            CorrectionEngine.restoringSentenceEnding(
                of: "翻訳コンニャク由来のアプリです。", toMatch: "翻訳コンニャク由来のアプリだ。")
                == "翻訳コンニャク由来のアプリだ。")
        #expect(
            CorrectionEngine.restoringSentenceEnding(
                of: "昨日のデモは順調でした。", toMatch: "昨日のデモは順調だった")
                == "昨日のデモは順調だった。")
    }

    @Test func keepsCorrectedTextWhenRawIsAlreadyPolite() {
        // 原文が丁寧形なら復元しない (「見ました」は「した」suffix に誤マッチしない)
        #expect(
            CorrectionEngine.restoringSentenceEnding(
                of: "デモをお見せします。", toMatch: "デモをお見せします")
                == "デモをお見せします。")
        #expect(
            CorrectionEngine.restoringSentenceEnding(
                of: "特集を見ました。", toMatch: "特集を見ました。")
                == "特集を見ました。")
    }

    @Test func keepsCorrectedTextWhenEndingsAreUnrelated() {
        #expect(
            CorrectionEngine.restoringSentenceEnding(
                of: "質問してください。", toMatch: "質問してください")
                == "質問してください。")
        #expect(CorrectionEngine.restoringSentenceEnding(of: "", toMatch: "評価する") == "")
    }

    // 履歴 echo (別入力に過去の回答を返す) で同文が二重表示された実害の regression 防止
    @Test func detectsEchoOfSessionHistoryOnlyForDifferentInput() {
        let history = [
            (raw: "こんにちは今日はいい天気ですね", result: "こんにちは。今日はいい天気ですね。"),
            (raw: "ありがとうございます。", result: "ありがとうございます。"),
        ]

        // 別の入力なのに履歴中の出力と同一 → 汚染
        #expect(
            CorrectionEngine.isEchoOfSessionHistory(
                "こんにちは。今日はいい天気ですね。", raw: "ハローエブリデイ", history: history))

        // 正当に clean だった (no-op) 過去応答も echo 源として検出する
        #expect(
            CorrectionEngine.isEchoOfSessionHistory(
                "ありがとうございます。", raw: "ハローエブリデイ", history: history))

        // 同じ文の言い直し (raw も一致) は echo 扱いしない
        #expect(
            !CorrectionEngine.isEchoOfSessionHistory(
                "こんにちは。今日はいい天気ですね。", raw: "こんにちは今日はいい天気ですね", history: history))

        // 出力が履歴のどれとも異なるなら通常の補正
        #expect(
            !CorrectionEngine.isEchoOfSessionHistory(
                "ハローエブリデイ。", raw: "ハローエブリデイ", history: history))

        // 初回 (履歴なし) は比較対象なし
        #expect(
            !CorrectionEngine.isEchoOfSessionHistory(
                "こんにちは。", raw: "こんにちは", history: []))
    }

    // 捏造長文 (9 文字入力 → 379 文字出力の実害) が字幕に採用される regression 防止。
    // echo 検出は履歴との完全一致のみで新規捏造を素通しするため、長さ比ガードが唯一の防壁
    @Test func detectsImplausiblyLongOutputAsFabrication() {
        let raw = String(repeating: "あ", count: 9)
        #expect(
            CorrectionEngine.isImplausiblyLong(
                String(repeating: "い", count: 379), comparedTo: raw))
        // 実測 2 件目 (24 文字 → 61 文字) も閾値 (2x + 12 = 60) でブロックされる
        #expect(
            CorrectionEngine.isImplausiblyLong(
                String(repeating: "い", count: 61),
                comparedTo: String(repeating: "あ", count: 24)))
    }

    @Test func allowsLegitimateCorrectionExpansion() {
        // 句読点付与程度の伸長は正当な補正として通す
        #expect(
            !CorrectionEngine.isImplausiblyLong(
                "昨日の会議で決まった内容を共有します。", comparedTo: "機能の会議で決まった内容を共有します"))
        // ごく短い入力への句読点付与は定数項で許容される
        #expect(!CorrectionEngine.isImplausiblyLong("はい、そうです。", comparedTo: "はい"))
        // 同長・短縮 (filler 除去) は常に通す
        #expect(
            !CorrectionEngine.isImplausiblyLong(
                "内容を共有します。", comparedTo: "えっと、内容を、あの、共有します"))
    }

    // 直近 1 件だけでなく古い履歴の echo も検出する (session 履歴は全交換を保持するため)
    @Test func detectsEchoFromOlderHistoryEntries() {
        let history = [
            (raw: "一文目です", result: "一文目です。"),
            (raw: "二文目です", result: "二文目です。"),
        ]
        #expect(
            CorrectionEngine.isEchoOfSessionHistory(
                "一文目です。", raw: "三文目です", history: history))
    }
}
