import Foundation
@preconcurrency import WhisperKit

/// Bridges the public file-only tokenizer factory to WhisperKit's public protocol.
/// The SDK's concrete wrapper initializer is internal, so we cannot inject it directly.
final class OfflineWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ tokenizer: TokenizerWrapper) throws {
        self.tokenizer = tokenizer
        func id(_ spelling: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(spelling) else { throw LocalModelError.invalidFiles }
            return value
        }
        guard let space = tokenizer.encode(text: " ", addSpecialTokens: false).first else {
            throw LocalModelError.invalidFiles
        }
        specialTokens = try SpecialTokens(
            endToken: id("<|endoftext|>"), englishToken: id("<|en|>"),
            noSpeechToken: id("<|nospeech|>"), noTimestampsToken: id("<|notimestamps|>"),
            specialTokenBegin: id("<|endoftext|>"), startOfPreviousToken: id("<|startofprev|>"),
            startOfTranscriptToken: id("<|startoftranscript|>"), timeTokenBegin: id("<|0.00|>"),
            transcribeToken: id("<|transcribe|>"), translateToken: id("<|translate|>"),
            whitespaceToken: space
        )
        allLanguageTokens = Set(Constants.languages.values.compactMap { tokenizer.convertTokenToId("<|\($0)|>") })
    }
    func encode(text: String) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: false) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    // Utter requests plain text, not word timestamps. Still preserve token groups
    // at Unicode boundaries to fulfill the tokenizer protocol without losing bytes.
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = []
        var groups: [[Int]] = []
        var pending: [Int] = []
        for token in tokenIds {
            pending.append(token)
            let text = decode(tokens: pending)
            guard !text.contains("\u{fffd}") else { continue }
            words.append(text)
            groups.append(pending)
            pending.removeAll(keepingCapacity: true)
        }
        if !pending.isEmpty { words.append(decode(tokens: pending)); groups.append(pending) }
        return (words, groups)
    }
}
