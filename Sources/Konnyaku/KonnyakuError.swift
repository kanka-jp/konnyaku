import Foundation

enum KonnyakuError: LocalizedError {
    case speechUnsupported
    case audioFormatUnavailable
    case audioConverterUnavailable
    case transcriberNotPrepared

    var errorDescription: String? {
        switch self {
        case .speechUnsupported:
            return t("error.speech_unsupported")
        case .audioFormatUnavailable:
            return t("error.audio_format")
        case .audioConverterUnavailable:
            return t("error.audio_converter")
        case .transcriberNotPrepared:
            return t("error.transcriber_not_prepared")
        }
    }
}
