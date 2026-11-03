import Foundation
import NaturalLanguage

/// Which language a transcript is in, for the summary flow (port of `language_detection.rs`, NaturalLanguage for whatlang).
public struct LanguageDetection: Sendable, Equatable {
    public enum Reason: String, Sendable {
        case detected, tie, unsupported, empty
        case lowConfidence = "low_confidence"
    }

    public var language: String?
    public var reason: Reason
}

/// Each text of at least 20 letters votes for its language with its letter count; the heaviest supported language wins.
public func detectSummaryLanguage(_ texts: [String]) -> LanguageDetection {
    var weights: [String: Int] = [:]
    var sawText = false, sawLowConfidence = false, sawUnsupported = false
    let recognizer = NLLanguageRecognizer()
    for text in texts {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = cleaned.unicodeScalars.filter(\.properties.isAlphabetic).count
        guard letters >= 20 else { continue }
        sawText = true
        recognizer.reset()
        recognizer.processString(cleaned)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.25 else {
            sawLowConfidence = true
            continue
        }
        let code = switch language.rawValue {
        case "zh-Hant": "zh-tw"
        case let tag where tag.hasPrefix("zh"): "zh"
        case "nb", "nn": "no"
        case let tag: tag
        }
        guard languageName(code: code) != nil else {
            sawUnsupported = true
            continue
        }
        weights[code, default: 0] += letters
    }
    guard !weights.isEmpty else {
        let reason: LanguageDetection.Reason = !sawText ? .empty : sawLowConfidence ? .lowConfidence : sawUnsupported ? .unsupported : .lowConfidence
        return LanguageDetection(language: nil, reason: reason)
    }
    return dominantLanguage(weights)
}

func dominantLanguage(_ weights: [String: Int]) -> LanguageDetection {
    let best = weights.values.max() ?? 0
    let leaders = weights.filter { $0.value == best }
    return leaders.count == 1 ? LanguageDetection(language: leaders.first!.key, reason: .detected) : LanguageDetection(language: nil, reason: .tie)
}
