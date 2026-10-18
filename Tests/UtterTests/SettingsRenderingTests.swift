import AppKit
import SwiftUI
import XCTest
@testable import Utter

private struct PreviewCredentials: CredentialStore {
    func read(_ service: CloudService) -> String? { nil }
    func save(_ value: String, for service: CloudService) throws { throw CloudError.disabled }
    func delete(_ service: CloudService) throws { throw CloudError.disabled }
}
final class SettingsRenderingTests: XCTestCase {
    @MainActor func testAllSettingsPagesRenderAtSupportedSize() async throws {
        // Never start the model: no permission prompts, audio, downloads or API calls.
        let suite = "UtterPreview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: "utter-settings-\(UUID().uuidString)")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(cloud: CloudSettings(defaults: defaults, credentials: PreviewCredentials()),
                             historyStore: HistoryStore(directory: directory))
        defer { model.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 690),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for tab in SettingsTab.allCases {
            let host = NSHostingView(rootView: RecordingSettingsView(model: model, initialTab: tab))
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1_000, "\(tab.title) must render content")
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 840)
            try png.write(to: FileManager.default.temporaryDirectory.appending(path: "utter-settings-\(tab.rawValue).png"))
        }
    }
}
