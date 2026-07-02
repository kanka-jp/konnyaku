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

    var sourceDisplayLines: [String] {
        var lines = sourceLines.map(\.text)
        if !volatileSource.isEmpty {
            lines.append(volatileSource)
        }
        return lines
    }

    var translationDisplayLines: [String] {
        var lines = translatedLines.map(\.text)
        if !volatileTranslation.isEmpty {
            lines.append(volatileTranslation)
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
        volatileTranslationUpdatedAt = now
    }

    func appendFinalSource(_ text: String, at now: Date = Date()) {
        volatileSource = ""
        volatileGeneration += 1
        sourceLines.append(Line(text: text, addedAt: now))
        if sourceLines.count > Self.maxSourceLines {
            sourceLines.removeFirst(sourceLines.count - Self.maxSourceLines)
        }
    }

    // 対象行が既に流れた場合に無関係な行を上書きしない guard。補正は FIFO 処理のため
    // 重複テキストは最古の一致行が対象。addedAt 更新は差し替え直後の失効を防ぐ
    func replaceFinalSource(_ old: String, with new: String, at now: Date = Date()) {
        guard let index = sourceLines.firstIndex(where: { $0.text == old }) else { return }
        sourceLines[index].text = new
        sourceLines[index].addedAt = now
    }

    func appendTranslation(_ text: String, at now: Date = Date()) {
        // 確定訳が追従訳を置き換える
        volatileTranslation = ""
        translatedLines.append(Line(text: text, addedAt: now))
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
        sourceLines = []
        translatedLines = []
    }
}
