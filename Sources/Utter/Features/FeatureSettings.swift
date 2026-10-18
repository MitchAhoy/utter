import Foundation
import Combine

struct Snippet: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var trigger: String
    var expansion: String
}
enum AppStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard, casual, formal, code, verbatim
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var instruction: String {
        switch self {
        case .standard: "Preserve the speaker's wording, tone, and language."
        case .casual: "Use light punctuation while preserving the speaker's casual tone and wording."
        case .formal: "Use professional punctuation and capitalization without adding or summarizing content."
        case .code: "Preserve code identifiers, casing, URLs, symbols, and technical spelling exactly."
        case .verbatim: "Return the transcript unchanged."
        }
    }
}
struct AppStyleRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var bundleID: String
    var style: AppStyle
}
struct TextTransformOptions: Sendable {
    var snippets: [Snippet] = []
    func apply(to text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return snippets.first {
            !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }?.expansion ?? text
    }
}
@MainActor
final class FeatureSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var dictionaryEnabled: Bool { didSet { save() } }
    @Published var dictionary: String { didSet { save() } }
    @Published var snippetsEnabled: Bool { didSet { save() } }
    @Published var snippets: [Snippet] { didSet { save() } }
    @Published var stylesEnabled: Bool { didSet { save() } }
    @Published var styles: [AppStyleRule] { didSet { save() } }
    @Published var historyEnabled: Bool { didSet { save() } }
    @Published var retentionDays: Int { didSet { save() } }
    @Published var commandEnabled: Bool { didSet { save() } }
    var terms: [String] {
        guard dictionaryEnabled else { return [] }
        var seen = Set<String>()
        return dictionary.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(200).map { String($0.prefix(100)) }
    }
    func style(for bundle: String) -> AppStyle {
        guard stylesEnabled else { return .standard }
        return styles.first { $0.bundleID.trimmingCharacters(in: .whitespacesAndNewlines) == bundle }?.style ?? .standard
    }
    var transforms: TextTransformOptions { TextTransformOptions(snippets: snippetsEnabled ? snippets : []) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dictionaryEnabled = defaults.bool(forKey: "dictionaryEnabled")
        dictionary = defaults.string(forKey: "dictionary") ?? ""
        snippetsEnabled = defaults.bool(forKey: "snippetsEnabled")
        snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        stylesEnabled = defaults.bool(forKey: "stylesEnabled")
        styles = defaults.data(forKey: "styles").flatMap { try? JSONDecoder().decode([AppStyleRule].self, from: $0) } ?? []
        historyEnabled = defaults.bool(forKey: "historyEnabled")
        retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 7
        commandEnabled = defaults.bool(forKey: "commandEnabled")
    }
    private func save() {
        defaults.set(dictionaryEnabled, forKey: "dictionaryEnabled"); defaults.set(dictionary, forKey: "dictionary")
        defaults.set(snippetsEnabled, forKey: "snippetsEnabled"); defaults.set(try? JSONEncoder().encode(snippets), forKey: "snippets")
        defaults.set(stylesEnabled, forKey: "stylesEnabled"); defaults.set(try? JSONEncoder().encode(styles), forKey: "styles")
        defaults.set(historyEnabled, forKey: "historyEnabled"); defaults.set(retentionDays, forKey: "retentionDays")
        defaults.set(commandEnabled, forKey: "commandEnabled")
    }
}
