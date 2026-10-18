import AppKit

@MainActor
final class SystemPasteboard: ClipboardAccess {
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func snapshot() throws -> ClipboardSnapshot {
        let before = pasteboard.changeCount
        let items = try (pasteboard.pasteboardItems ?? []).map { item in
            ClipboardItem(representations: try item.types.map { type in
                guard let data = item.data(forType: type) else { throw InsertionError.clipboardUnavailable }
                return ClipboardRepresentation(type: type.rawValue, data: data)
            })
        }
        guard before == pasteboard.changeCount else { throw InsertionError.clipboardUnavailable }
        return ClipboardSnapshot(items: items)
    }

    func writeText(_ text: String, transient: Bool, rollback: ClipboardSnapshot?) throws -> Int {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { throw InsertionError.clipboardUnavailable }
        if transient {
            guard item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
                  item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) else {
                throw InsertionError.clipboardUnavailable
            }
        }
        let cleared = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            if let rollback { restore(rollback, ifUnchanged: cleared) }
            throw InsertionError.clipboardUnavailable
        }
        return pasteboard.changeCount
    }

    @discardableResult
    func restore(_ snapshot: ClipboardSnapshot, ifUnchanged changeCount: Int) -> Bool {
        // Materialize every representation before taking ownership again.
        var items: [NSPasteboardItem] = []
        for saved in snapshot.items {
            let item = NSPasteboardItem()
            for representation in saved.representations {
                guard item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type)) else {
                    return false
                }
            }
            items.append(item)
        }
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        return items.isEmpty || pasteboard.writeObjects(items)
    }
}
