import Foundation
import Observation

@MainActor
@Observable
final class CaptionState {
    static let maxSourceLines = 3
    static let maxTranslatedLines = 3
    // 発表の聞き手が読み終える猶予
    static let lineLifetime: TimeInterval = 10

    struct Line {
        var text: String
        var addedAt: Date
        // 確定時点の volatileGeneration。同一テキストの重複行を FIFO 順序ではなく
        // 世代で一意に識別するために使う (replaceFinalSource 参照)
        var generation: Int
    }

    struct DisplayLine: Identifiable, Equatable {
        enum Kind: Equatable {
            case final
            case volatile
        }

        let id: Int
        let text: String
        let kind: Kind
    }

    private(set) var volatileSource = ""
    private(set) var volatileTranslation = ""
    private(set) var sourceLines: [Line] = []
    private(set) var translatedLines: [Line] = []
    var isRunning = false
    var statusMessage: String?

    private var volatileUpdatedAt = Date.distantPast
    private var volatileTranslationUpdatedAt = Date.distantPast
    // 文の切り替わり (確定) を跨いで届いた追従訳を破棄するための世代番号
    private(set) var volatileGeneration = 0
    // 表示中の追従訳がどの世代の文のものか (-1 は不在)。確定訳の遅延到着が
    // 次の文の追従訳を巻き添えクリアしないための判定に使う
    private var volatileTranslationGeneration = -1

    var sourceDisplayLines: [DisplayLine] {
        var lines = sourceLines.enumerated().map { offset, line in
            DisplayLine(id: offset, text: line.text, kind: .final)
        }
        if !volatileSource.isEmpty {
            lines.append(DisplayLine(id: lines.count, text: volatileSource, kind: .volatile))
        }
        return lines
    }

    var translationDisplayLines: [DisplayLine] {
        var lines = translatedLines.enumerated().map { offset, line in
            DisplayLine(id: offset, text: line.text, kind: .final)
        }
        if !volatileTranslation.isEmpty {
            lines.append(DisplayLine(id: lines.count, text: volatileTranslation, kind: .volatile))
        }
        return lines
    }

    func setVolatileSource(_ text: String, at now: Date = Date()) {
        volatileSource = text
        volatileUpdatedAt = now
    }

    // 話し中テキストの追従訳。generation が現在と異なる (訳している間に文が確定した)
    // 場合は stale として捨て、確定訳の後に古い追従訳が再表示されるのを防ぐ
    func setVolatileTranslation(_ text: String, generation: Int, at now: Date = Date()) {
        guard generation == volatileGeneration else { return }
        volatileTranslation = text
        volatileTranslationGeneration = generation
        volatileTranslationUpdatedAt = now
    }

    func appendFinalSource(_ text: String, at now: Date = Date()) {
        // increment 前の値を記録する。呼び出し元 (CaptionPipeline) が既に持つ
        // generation と同じ考え方で、replaceFinalSource の対象特定に使う
        let generation = volatileGeneration
        volatileSource = ""
        volatileGeneration += 1
        sourceLines.append(Line(text: text, addedAt: now, generation: generation))
        if sourceLines.count > Self.maxSourceLines {
            sourceLines.removeFirst(sourceLines.count - Self.maxSourceLines)
        }
    }

    // 表示に値する確定文が無いままセグメントが終わった (句読点のみの final を捨てた)
    // 場合の後始末。世代を進めて in-flight の追従訳を無効化する。旧世代の placeholder
    // (確定訳待ち) は消さない — 確定訳が届いて置き換わるため、消すと到着まで下段が空く
    func discardVolatileSegment() {
        volatileSource = ""
        if volatileTranslationGeneration == volatileGeneration {
            volatileTranslation = ""
            volatileTranslationGeneration = -1
        }
        volatileGeneration += 1
    }

    // 停止時の後始末。worker が全て止まり確定訳・追従訳とも今後届かないため、
    // 旧世代の placeholder も含め volatile 表示を全て消す
    func clearVolatile() {
        volatileSource = ""
        volatileTranslation = ""
        volatileGeneration += 1
        volatileTranslationGeneration = -1
    }

    // 停止後は pruneTask が止まり確定行が時間失効しない。調整モードでは停止後も
    // overlay が可視のため、残すと前回の字幕がプレビューを塞いだまま固定表示される
    func clearFinalLines() {
        sourceLines = []
        translatedLines = []
    }

    // 文字列一致だけでは補正完了順序の入れ替わりで誤った行を差し替えるため generation で
    // 一意特定する (text は既に流れた行を上書きしない guard、addedAt は差し替え直後の失効防止)
    func replaceFinalSource(_ old: String, with new: String, generation: Int, at now: Date = Date()) {
        guard let index = sourceLines.firstIndex(where: { $0.generation == generation && $0.text == old })
        else { return }
        sourceLines[index].text = new
        sourceLines[index].addedAt = now
    }

    // generation は「この確定訳の文の volatile が刻まれていた世代」(appendFinalSource が
    // 進める前の値)。自分の文以前の追従訳のみ置き換え、後の文 (現在話し中) の追従訳の
    // 巻き添えクリア (flicker) を防ぐ。自分より古い placeholder も消す — 確定訳は文順に
    // 届くため、それは対応する確定訳が buffer 溢れで欠落した孤児で、残すと表示され続ける
    func appendTranslation(_ text: String, generation: Int, at now: Date = Date()) {
        if volatileTranslationGeneration <= generation {
            volatileTranslation = ""
            volatileTranslationGeneration = -1
        }
        translatedLines.append(Line(text: text, addedAt: now, generation: generation))
        if translatedLines.count > Self.maxTranslatedLines {
            translatedLines.removeFirst(translatedLines.count - Self.maxTranslatedLines)
        }
    }

    func pruneExpired(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.lineLifetime)
        sourceLines.removeAll { $0.addedAt < cutoff }
        translatedLines.removeAll { $0.addedAt < cutoff }
        if !volatileSource.isEmpty && volatileUpdatedAt < cutoff {
            volatileSource = ""
        }
        if !volatileTranslation.isEmpty && volatileTranslationUpdatedAt < cutoff {
            volatileTranslation = ""
        }
    }

    func setStatusMessage(_ message: String) {
        statusMessage = message
    }

    func reset() {
        volatileSource = ""
        volatileUpdatedAt = .distantPast
        volatileTranslation = ""
        volatileTranslationUpdatedAt = .distantPast
        volatileGeneration = 0
        volatileTranslationGeneration = -1
        sourceLines = []
        translatedLines = []
    }
}
