import Foundation
import Combine
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?
    let configured: Bool
    init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        configured = URL(string: feed)?.scheme == "https" && Data(base64Encoded: key)?.count == 32
        if configured {
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            self.controller = controller
            controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
            controller.startUpdater()
        } else { controller = nil }
    }
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    func check() { controller?.checkForUpdates(nil) }
}
