import Foundation

/// Builds one transcript out of SpeechTranscriber's stream of results.
///
/// The transcriber emits *volatile* guesses for the segment it is still hearing, then a *final*
/// result that replaces them. Finals are appended in order; the latest volatile text is shown
/// after them until its own final arrives.
struct TranscriptAssembler: Equatable {
    private(set) var finalizedText = ""
    private(set) var volatileText = ""

    mutating func accept(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !trimmed.isEmpty {
                finalizedText = finalizedText.isEmpty ? trimmed : finalizedText + " " + trimmed
            }
            volatileText = ""
        } else {
            volatileText = trimmed
        }
    }

    /// Finalized segments followed by the current guess, or an empty string when nothing was heard.
    var text: String {
        [finalizedText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
