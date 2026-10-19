import AppKit
import SwiftUI

// Keep the property-wrapper API available with Command Line Tools SDKs.
typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor enum InstallationActivity { static var busy = false }

@MainActor final class ManagerDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !InstallationActivity.busy { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Installation in progress"
        alert.informativeText = "Wait for the installation or removal to finish before quitting."
        alert.runModal()
        return .terminateCancel
    }
}

@main struct OnlineFixManagerApp: App {
    @NSApplicationDelegateAdaptor(ManagerDelegate.self) private var delegate

    var body: some Scene {
        Window("OnlineFix Manager", id: "manager") { ManagerView() }
            .defaultSize(width: 980, height: 680)
    }
}
