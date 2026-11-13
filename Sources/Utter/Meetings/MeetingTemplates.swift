import Combine
import Foundation

/// How enhanced notes are laid out for one kind of meeting.
struct MeetingTemplate: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var name: String
    /// Sections and emphasis, in plain words; added to the note-writing prompt.
    var instructions: String

    static let general = MeetingTemplate(id: "general", name: "General", instructions: """
    Sections: "Summary" (2-3 sentences), "Key points" (grouped by topic), "Decisions", "Action items" (who does what, by when if stated).
    """)
    static let builtIn: [MeetingTemplate] = [
        general,
        MeetingTemplate(id: "one-on-one", name: "1:1", instructions: """
        Sections: "Updates", "Feedback and concerns", "Decisions", "Action items" (split into mine and theirs).
        Keep the other person's own wording for feedback and concerns.
        """),
        MeetingTemplate(id: "stand-up", name: "Stand-up", instructions: """
        Sections: "Done", "In progress", "Blockers", "Action items". One short bullet per item, grouped by person where clear.
        """),
        MeetingTemplate(id: "sales-call", name: "Sales call", instructions: """
        Sections: "Their situation and goals", "Pain points", "Objections and questions", "Budget, timeline and decision makers",
        "Next steps". Quote the prospect's exact words for pain points and objections.
        """),
        MeetingTemplate(id: "interview", name: "Interview", instructions: """
        Sections: "Background", "Strengths", "Concerns", "Notable answers" (question, then a summary of the answer), "Follow-ups".
        Report what was said; do not give a hire recommendation.
        """),
    ]
}

/// A saved question that runs in one click.
struct MeetingRecipe: Identifiable, Codable, Sendable, Equatable {
    enum Scope: String, Codable, Sendable { case single, all }
    var id: String
    var name: String
    var prompt: String
    var scope: Scope

    static let builtIn: [MeetingRecipe] = [
        MeetingRecipe(id: "actions", name: "Action items", scope: .single,
                      prompt: "List every action item from this meeting as a checklist: who owns it, what it is, and the deadline if one was given."),
        MeetingRecipe(id: "follow-up", name: "Follow-up email", scope: .single,
                      prompt: "Write a short, friendly follow-up email to the other attendees: thank them, recap what was agreed, and list next steps with owners."),
        MeetingRecipe(id: "decisions", name: "Decisions", scope: .single,
                      prompt: "List the decisions made in this meeting, each with the reasoning given for it."),
        MeetingRecipe(id: "missed-it", name: "Summary for someone who missed it", scope: .single,
                      prompt: "Summarise this meeting in under 150 words for a colleague who could not attend."),
        MeetingRecipe(id: "promises", name: "What did I promise?", scope: .all,
                      prompt: "List everything I (Me) committed to doing across these meetings, grouped by meeting, with deadlines where stated."),
        MeetingRecipe(id: "open-questions", name: "Open questions", scope: .all,
                      prompt: "List questions and issues that were raised across these meetings and not resolved."),
    ]

    init(id: String = UUID().uuidString, name: String, scope: Scope, prompt: String) {
        self.id = id; self.name = name; self.prompt = prompt; self.scope = scope
    }

    /// The recipe a chat message like "/action items" refers to, ignoring case.
    static func match(_ input: String, in recipes: [MeetingRecipe], scope: Scope) -> MeetingRecipe? {
        guard input.hasPrefix("/") else { return nil }
        let name = input.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        let candidates = recipes.filter { $0.scope == scope }
        return candidates.first { $0.name.lowercased() == name } ?? candidates.first { $0.name.lowercased().hasPrefix(name) }
    }
}

/// Meeting preferences and the user's own templates and recipes.
@MainActor
final class MeetingSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var customTemplates: [MeetingTemplate] { didSet { store(customTemplates, "meetingTemplates") } }
    @Published var customRecipes: [MeetingRecipe] { didSet { store(customRecipes, "meetingRecipes") } }
    @Published var defaultTemplate: String { didSet { defaults.set(defaultTemplate, forKey: "meetingDefaultTemplate") } }
    /// Offer to take notes when a call app starts using the microphone.
    @Published var detectMeetings: Bool { didSet { defaults.set(detectMeetings, forKey: "meetingDetection") } }
    /// The one-time reminder to tell people they are being transcribed has been shown.
    @Published var consentAcknowledged: Bool { didSet { defaults.set(consentAcknowledged, forKey: "meetingConsentAcknowledged") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customTemplates = Self.load("meetingTemplates", defaults)
        customRecipes = Self.load("meetingRecipes", defaults)
        defaultTemplate = defaults.string(forKey: "meetingDefaultTemplate") ?? MeetingTemplate.general.id
        detectMeetings = defaults.object(forKey: "meetingDetection") as? Bool ?? true
        consentAcknowledged = defaults.bool(forKey: "meetingConsentAcknowledged")
    }

    var templates: [MeetingTemplate] { MeetingTemplate.builtIn + customTemplates }
    var recipes: [MeetingRecipe] { MeetingRecipe.builtIn + customRecipes }
    func template(id: String) -> MeetingTemplate { templates.first { $0.id == id } ?? .general }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    private static func load<T: Decodable>(_ key: String, _ defaults: UserDefaults) -> [T] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([T].self, from: $0) } ?? []
    }
}
