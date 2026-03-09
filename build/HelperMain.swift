import Cocoa
import AppKit

class HelperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let helperPath = Bundle.main.bundlePath as NSString
        // .../DockClick.app/Contents/Library/LoginItems/DockClickHelper.app
        let loginItemsDir = helperPath.deletingLastPathComponent
        let contentsDir = (loginItemsDir as NSString).deletingLastPathComponent
        let appRoot = (contentsDir as NSString).deletingLastPathComponent
        let mainAppURL = URL(fileURLWithPath: appRoot)
        let mainBundleID = "com.yourname.dockclick"
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID).isEmpty
        if !isRunning {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: mainAppURL, configuration: config, completionHandler: nil)
        }
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = HelperAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
