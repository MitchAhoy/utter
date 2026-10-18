import AppKit
import XCTest
@testable import Utter

@MainActor
private final class FakePasteEnvironment: PasteEnvironment {
    var accessibilityGranted = true
    var secureInput = false
    var focusedProcessID: Int32? = 42
    var ownProcessID: Int32 = 99
    var posts = 0
    var failure = false
    var onPaste: (() -> Void)?
    func postPaste() throws {
        if failure { throw InsertionError.keyboardUnavailable }
        posts += 1
        onPaste?()
    }
}

final class TextInsertionTests: XCTestCase {
    private let target = InsertionTarget(processID: 42, appName: "Notes", bundleID: "com.apple.Notes")

    @MainActor private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("UtterTests-\(UUID().uuidString)"))
    }

    @MainActor func testRestoresEveryTypeAndItemAfterPaste() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        first.setData(Data(#"{\rtf1\ansi original}"#.utf8), forType: .rtf)
        let second = NSPasteboardItem()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        second.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        board.writeObjects([first, second])
        let clipboard = SystemPasteboard(pasteboard: board)
        let before = try clipboard.snapshot()
        let environment = FakePasteEnvironment()
        environment.onPaste = {
            XCTAssertEqual(board.string(forType: .string), "dictated text")
            XCTAssertNotNil(board.data(forType: .init("org.nspasteboard.TransientType")))
            XCTAssertNotNil(board.data(forType: .init("org.nspasteboard.ConcealedType")))
        }
        let inserter = ClipboardTextInserter(clipboard: clipboard, environment: environment, waitForPaste: {})
        try await inserter.insert("dictated text", target: target)
        XCTAssertEqual(environment.posts, 1)
        XCTAssertEqual(try clipboard.snapshot(), before)
    }

    @MainActor func testRestoresAnEmptyClipboard() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents()
        let clipboard = SystemPasteboard(pasteboard: board)
        let inserter = ClipboardTextInserter(clipboard: clipboard, environment: FakePasteEnvironment(), waitForPaste: {})
        try await inserter.insert("text", target: target)
        XCTAssertEqual(try clipboard.snapshot().items, [])
    }

    @MainActor func testDoesNotOverwriteANewCopyDuringRestoreDelay() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("before", forType: .string)
        let clipboard = SystemPasteboard(pasteboard: board)
        let inserter = ClipboardTextInserter(clipboard: clipboard, environment: FakePasteEnvironment(), waitForPaste: {
            board.clearContents()
            board.setString("new user copy", forType: .string)
        })
        try await inserter.insert("text", target: target)
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    @MainActor private func checkBlocked(_ error: InsertionError, change: (FakePasteEnvironment) -> Void) async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let environment = FakePasteEnvironment()
        change(environment)
        let inserter = ClipboardTextInserter(clipboard: SystemPasteboard(pasteboard: board), environment: environment, waitForPaste: {})
        do {
            try await inserter.insert("text", target: target)
            XCTFail("Expected insertion to be blocked")
        } catch let actual as InsertionError { XCTAssertEqual(actual, error) }
        XCTAssertEqual(board.string(forType: .string), "keep")
        XCTAssertEqual(environment.posts, 0)
    }

    @MainActor func testSecureInputNeverPostsOrChangesClipboard() async throws {
        try await checkBlocked(.secureInput) { $0.secureInput = true }
    }
    @MainActor func testMissingAccessibilityNeverPosts() async throws {
        try await checkBlocked(.accessibilityRequired) { $0.accessibilityGranted = false }
    }
    @MainActor func testChangedFocusNeverPosts() async throws {
        try await checkBlocked(.focusChanged) { $0.focusedProcessID = 43 }
    }
    @MainActor func testOwnAppCannotReceivePaste() async throws {
        try await checkBlocked(.focusChanged) { $0.ownProcessID = 42 }
    }

    @MainActor func testKeyboardEventFailureRestoresClipboard() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let environment = FakePasteEnvironment()
        environment.failure = true
        let inserter = ClipboardTextInserter(clipboard: SystemPasteboard(pasteboard: board), environment: environment, waitForPaste: {})
        do { try await inserter.insert("text", target: target); XCTFail("Expected keyboard failure") }
        catch let error as InsertionError { XCTAssertEqual(error, .keyboardUnavailable) }
        XCTAssertEqual(board.string(forType: .string), "keep")
    }

    @MainActor func testCancellationDuringDelayRestoresClipboardAndPreventsOverlappingPaste() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let entered = AsyncStream.makeStream(of: Void.self)
        let inserter = ClipboardTextInserter(clipboard: SystemPasteboard(pasteboard: board), environment: FakePasteEnvironment(), waitForPaste: {
            entered.continuation.yield(())
            try await Task.sleep(for: .seconds(60))
        })
        let target = self.target
        let first = Task { try await inserter.insert("first", target: target) }
        for await _ in entered.stream { break }
        do { try await inserter.insert("second", target: target); XCTFail("Expected busy") }
        catch let error as InsertionError { XCTAssertEqual(error, .busy) }
        first.cancel()
        do { try await first.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        entered.continuation.finish()
        XCTAssertEqual(board.string(forType: .string), "keep")
    }

    @MainActor func testRecoveryTextRemainsOnClipboardWithoutTransientMarkers() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let inserter = ClipboardTextInserter(clipboard: SystemPasteboard(pasteboard: board), environment: FakePasteEnvironment())
        try inserter.copyForRecovery("raw transcript")
        XCTAssertEqual(board.string(forType: .string), "raw transcript")
        XCTAssertNil(board.data(forType: .init("org.nspasteboard.TransientType")))
    }

    @MainActor func testEmptyTextDoesNotTouchClipboard() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let inserter = ClipboardTextInserter(clipboard: SystemPasteboard(pasteboard: board), environment: FakePasteEnvironment())
        do { try await inserter.insert(" \n ", target: target); XCTFail("Expected empty text error") }
        catch let error as InsertionError { XCTAssertEqual(error, .emptyText) }
        XCTAssertEqual(board.string(forType: .string), "keep")
    }
}
