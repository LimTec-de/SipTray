import AppKit
import Sparkle

final class SipTrayAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: SipTrayAppDelegate?

    private var updaterController: SPUStandardUpdaterController?
    var updater: SPUUpdater? { updaterController?.updater }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
