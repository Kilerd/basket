import Foundation

extension String {
    /// The text as a complete sentence, for messages from other tools (command errors) that are
    /// followed by another sentence: unchanged when it already ends with sentence punctuation,
    /// else closed with the language's full stop ("." in English, "。" in Chinese and Japanese,
    /// where the next sentence follows without a space).
    public var asSentence: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?。！？…".contains(last) else { return trimmed }
        return String(localized: "\(trimmed).", bundle: .main,
                      comment: "Closes a sentence that came from another tool (an error message) with a full stop")
    }
}
