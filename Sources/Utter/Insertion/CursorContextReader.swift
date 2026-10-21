import ApplicationServices

/// What sits around the insertion point when recording starts.
struct CursorContext: Sendable, Equatable {
    /// Up to a few hundred characters before the cursor; nil when the app does not expose it.
    var precedingText: String?
    /// Used only to tell which web app a browser is showing; never sent anywhere.
    var windowTitle: String?
}

/// Reads the focused text field through Accessibility. Each call is capped by a short
/// messaging timeout so a slow app cannot stall dictation. Never reads secure fields.
enum CursorContextReader {
    static func read(processID: pid_t, limit: Int = 300) -> CursorContext {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var context = CursorContext()
        if let window = element(app, kAXFocusedWindowAttribute) {
            AXUIElementSetMessagingTimeout(window, 0.15)
            context.windowTitle = string(window, kAXTitleAttribute)
        }
        guard let field = element(app, kAXFocusedUIElementAttribute) else { return context }
        AXUIElementSetMessagingTimeout(field, 0.15)
        if string(field, kAXRoleAttribute) == "AXSecureTextField"
            || string(field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String { return context }
        guard let selection = range(field, kAXSelectedTextRangeAttribute), selection.location >= 0 else { return context }
        let start = max(0, selection.location - limit)
        let length = selection.location - start
        guard length > 0 else { context.precedingText = ""; return context }
        var wanted = CFRange(location: start, length: length)
        if let axRange = AXValueCreate(.cfRange, &wanted) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
                                                          axRange, &value) == .success,
               let text = value as? String {
                context.precedingText = text
                return context
            }
        }
        // Fallback for fields without range queries; skip very large documents.
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let number = count as? Int, number > 200_000 { return context }
        if let full = string(field, kAXValueAttribute) {
            let text = full as NSString
            guard start + length <= text.length else { return context }
            context.precedingText = text.substring(with: NSRange(location: start, length: length))
        }
        return context
    }

    private static func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func string(_ source: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private static func range(_ source: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var result = CFRange()
        return AXValueGetValue(axValue, .cfRange, &result) ? result : nil
    }
}
