import Foundation

struct InsertionTarget: Sendable, Equatable {
    let processID: Int32
    let appName: String
    let bundleID: String
}

struct ClipboardRepresentation: Equatable {
    let type: String
    let data: Data
}

struct ClipboardItem: Equatable {
    let representations: [ClipboardRepresentation]
}

struct ClipboardSnapshot: Equatable {
    let items: [ClipboardItem]
}

enum InsertionError: LocalizedError, Equatable {
    case accessibilityRequired, secureInput, focusChanged, clipboardUnavailable, keyboardUnavailable, emptyText, busy
    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: "Enable Accessibility for Utter before inserting text."
        case .secureInput: "Can't type into a secure field"
        case .focusChanged: "The focused app changed. Text was not inserted."
        case .clipboardUnavailable: "The clipboard could not be read or updated safely."
        case .keyboardUnavailable: "Unable to create the paste keyboard event."
        case .emptyText: "There is no text to insert."
        case .busy: "Another paste is still finishing."
        }
    }
}

@MainActor
protocol TextInserter: AnyObject {
    func insert(_ text: String, target: InsertionTarget) async throws
    func copyForRecovery(_ text: String) throws
}

@MainActor
protocol ClipboardAccess: AnyObject {
    func snapshot() throws -> ClipboardSnapshot
    func writeText(_ text: String, transient: Bool, rollback: ClipboardSnapshot?) throws -> Int
    @discardableResult func restore(_ snapshot: ClipboardSnapshot, ifUnchanged changeCount: Int) -> Bool
}

@MainActor
protocol PasteEnvironment: AnyObject {
    var accessibilityGranted: Bool { get }
    var secureInput: Bool { get }
    var focusedProcessID: Int32? { get }
    var ownProcessID: Int32 { get }
    func postPaste() throws
}
