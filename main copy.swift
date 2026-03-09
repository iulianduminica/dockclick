/*
 * DockClick - macOS Dock Click-to-Minimize Utility
 * 
 * Created by: mac
 * Date: September 2025
 * Version: 1.0
 * 
 * Description: A menu bar application that enables click-to-minimize functionality
 * for dock items. Clicking a dock icon for an already-active app will minimize it.
 * Uses precise dock item detection without guessing.
 * 
 * Features:
 * - Precise dock item rectangle detection via AppleScript
 * - Dynamic dock change monitoring
 * - Click interception with exact position matching
 * - No guessing - updates dock positions on every change
 * - Handles app minimization and restoration
 * 
 * License: Personal use - Created for learning and productivity
 */

import Cocoa
import Carbon
import ApplicationServices
import UserNotifications

// MARK: - Accessibility Constants
let kAXMinimizableAttribute = "AXMinimizable"
let kAXMinimizedAttribute = "AXMinimized"

// MARK: - Dock Item Structure
struct DockItem {
    let rect: NSRect
    let appName: String
    let isSystemItem: Bool // Trash, Downloads, etc.
    
    init(rect: NSRect, appName: String) {
        self.rect = rect
        self.appName = appName
        self.isSystemItem = ["Trash", "Downloads", "Launchpad", "Finder"].contains(appName)
    }
    
    func contains(point: CGPoint) -> Bool {
        return rect.contains(point)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    // UI Elements
    var statusItem: NSStatusItem!
    
    // Event Monitoring
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var isMonitoring = false
    
    // Dock State Management
    var dockItems: [DockItem] = []
    var dockUpdateTimer: Timer?
    
    // Debug Mode
    let debugMode = true
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("🚀 DockClick starting up...")
        
        setupNotifications()
        setupStatusBar()
        setupDockMonitoring()
        startEventMonitoring()
        
        // Initial dock scan
        updateDockItems()
        
        print("✅ DockClick ready - dock monitoring active!")
    }
    
    func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("❌ Notification permission error: \(error)")
            } else {
                print("📢 Notification permission granted: \(granted)")
            }
        }
    }
    
    // MARK: - Status Bar Setup
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockClick")
            button.toolTip = "DockClick - Click dock icons to minimize"
        }
        
        updateMenu()
    }
    
    func updateMenu() {
        let menu = NSMenu()
        
        // Status
        let statusText = isMonitoring ? "🟢 Monitoring Active" : "🔴 Monitoring Disabled"
        menu.addItem(NSMenuItem(title: statusText, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Dock items count
        menu.addItem(NSMenuItem(title: "Dock Items: \(dockItems.count)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Toggle monitoring
        let toggleTitle = isMonitoring ? "Disable Monitoring" : "Enable Monitoring"
        menu.addItem(NSMenuItem(title: toggleTitle, action: #selector(toggleMonitoring), keyEquivalent: ""))
        
        // Refresh dock
        menu.addItem(NSMenuItem(title: "Refresh Dock Items", action: #selector(refreshDock), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        
        // Debug mode toggle
        menu.addItem(NSMenuItem(title: "Show Dock Info", action: #selector(showDockInfo), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // About
        menu.addItem(NSMenuItem(title: "About DockClick", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    // MARK: - Dock Monitoring
    func setupDockMonitoring() {
        // Monitor workspace changes that might affect the dock
        let center = NSWorkspace.shared.notificationCenter
        
        // App launch/termination
        center.addObserver(self, selector: #selector(dockChanged),
                          name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged),
                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        
        // App activation
        center.addObserver(self, selector: #selector(appActivated),
                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        
        // Space changes
        center.addObserver(self, selector: #selector(dockChanged),
                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        
        print("📡 Dock change monitoring configured")
    }
    
    @objc func dockChanged(_ notification: Notification) {
        if debugMode {
            print("🔄 Dock change detected: \(notification.name.rawValue)")
        }
        
        // Debounce dock updates to avoid excessive refreshing
        dockUpdateTimer?.invalidate()
        dockUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.updateDockItems()
        }
    }
    
    @objc func appActivated(_ notification: Notification) {
        // No longer need complex activation tracking with simplified logic
        if debugMode {
            if let userInfo = notification.userInfo,
               let app = userInfo[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                print("📱 App activated: \(app.localizedName ?? "Unknown")")
            }
        }
    }
    
    @objc func refreshDock() {
        updateDockItems()
    }
    
    // MARK: - Dock Item Detection (Core Functionality)
    func updateDockItems() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let script = """
            tell application "System Events"
                tell process "Dock"
                    set dockItemList to {}
                    set dockElements to every UI element of list 1
                    
                    repeat with dockItem in dockElements
                        try
                            set itemPosition to position of dockItem
                            set itemSize to size of dockItem
                            set itemName to name of dockItem
                            
                            -- Create a record with all the info
                            set itemInfo to {itemPosition, itemSize, itemName}
                            set end of dockItemList to itemInfo
                        on error errMsg
                            -- Skip items that can't be accessed
                        end try
                    end repeat
                    
                    return dockItemList
                end tell
            end tell
            """
            
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            let result = appleScript?.executeAndReturnError(&error)
            
            if let error = error {
                print("❌ AppleScript error: \(error)")
                return
            }
            
            var newDockItems: [DockItem] = []
            
            // Parse the AppleScript result
            if let result = result, result.descriptorType == typeAEList {
                for i in 1...result.numberOfItems {
                    if let itemDescriptor = result.atIndex(i) {
                        // Each item contains: position, size, name
                        if itemDescriptor.numberOfItems >= 3,
                           let posDesc = itemDescriptor.atIndex(1),
                           let sizeDesc = itemDescriptor.atIndex(2),
                           let nameDesc = itemDescriptor.atIndex(3) {
                            
                            // Extract position (x, y)
                            let x = posDesc.atIndex(1)?.doubleValue ?? 0
                            let y = posDesc.atIndex(2)?.doubleValue ?? 0
                            
                            // Extract size (width, height)
                            let width = sizeDesc.atIndex(1)?.doubleValue ?? 0
                            let height = sizeDesc.atIndex(2)?.doubleValue ?? 0
                            
                            // Extract name
                            let name = nameDesc.stringValue ?? "Unknown"
                            
                            // Create dock item
                            let rect = NSRect(x: x, y: y, width: width, height: height)
                            let dockItem = DockItem(rect: rect, appName: name)
                            newDockItems.append(dockItem)
                            
                            if self?.debugMode == true {
                                print("🔍 Dock item: \(name) at (\(Int(x)), \(Int(y))) size: \(Int(width))x\(Int(height))")
                            }
                        }
                    }
                }
            }
            
            DispatchQueue.main.async {
                self?.dockItems = newDockItems
                self?.updateMenu()
                print("✅ Updated \(newDockItems.count) dock items")
            }
        }
    }
    
    // MARK: - Event Monitoring
    func startEventMonitoring() {
        // Check accessibility permissions
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("⚠️ Requesting accessibility permissions...")
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
            
            showNotification(title: "Permission Required",
                           message: "Please grant accessibility permissions in System Settings")
            return
        }
        
        // Create event tap for mouse clicks
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return appDelegate.handleMouseClick(event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            print("❌ Failed to create event tap")
            return
        }
        
        // Add to run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        isMonitoring = true
        updateMenu()
        
        // Monitor for tap being disabled
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                print("⚠️ Re-enabling event tap...")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        
        print("✅ Event monitoring started")
    }
    
    func stopEventMonitoring() {
        guard isMonitoring else { return }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
        isMonitoring = false
        updateMenu()
        
        print("🛑 Event monitoring stopped")
    }
    
    // MARK: - Click Handling (Fixed Core Logic)
    func handleMouseClick(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isMonitoring else { return Unmanaged.passUnretained(event) }
        
        let clickLocation = event.location
        
        // Find which dock item was clicked (if any)
        let clickedItem = dockItems.first { $0.contains(point: clickLocation) }
        
        guard let item = clickedItem else {
            // Not a dock click
            return Unmanaged.passUnretained(event)
        }
        
        if debugMode {
            print("🖱️ Clicked dock item: \(item.appName) at (\(Int(clickLocation.x)), \(Int(clickLocation.y)))")
        }
        
        // Skip system items
        if item.isSystemItem {
            if debugMode {
                print("⭐ Skipping system item: \(item.appName)")
            }
            return Unmanaged.passUnretained(event)
        }
        
        // Find the corresponding running app
        guard let app = findRunningApp(named: item.appName) else {
            if debugMode {
                print("❌ No running app found for: \(item.appName)")
            }
            return Unmanaged.passUnretained(event)
        }
        
        // Check if this app is currently frontmost
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isCurrentlyFrontmost = frontmostApp?.bundleIdentifier == app.bundleIdentifier
        
        if debugMode {
            print("🎯 App '\(app.localizedName ?? "Unknown")' is frontmost: \(isCurrentlyFrontmost)")
            if let frontmost = frontmostApp {
                print("   Current frontmost: \(frontmost.localizedName ?? "Unknown")")
            }
        }
        
        if isCurrentlyFrontmost {
            // App is already frontmost - minimize it and block the click
            if debugMode {
                print("🔽 Minimizing frontmost app: \(app.localizedName ?? "Unknown")")
            }
            
            minimizeApp(app)
            
            // Block the click to prevent re-activation
            return nil
        } else {
            // App is not frontmost - let the click through to activate it
            if debugMode {
                print("▶️ Letting click through to activate: \(app.localizedName ?? "Unknown")")
            }
            return Unmanaged.passUnretained(event)
        }
    }
    
    // MARK: - App Management
    func findRunningApp(named appName: String) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications
        
        // Direct name match first
        if let app = runningApps.first(where: { $0.localizedName == appName }) {
            return app
        }
        
        // Try bundle display name
        if let app = runningApps.first(where: { 
            ($0.bundleIdentifier?.contains(appName.lowercased()) == true) ||
            ($0.bundleURL?.lastPathComponent.lowercased().contains(appName.lowercased()) == true)
        }) {
            return app
        }
        
        // Handle common dock name variations
        let nameMap: [String: String] = [
            "Code": "Visual Studio Code",
            "Rosetta Stone": "Rosetta Stone Learn Languages",
            "Terminal": "Terminal",
            "Activity Monitor": "Activity Monitor",
            "System Preferences": "System Preferences",
            "System Settings": "System Settings"
        ]
        
        if let realName = nameMap[appName],
           let app = runningApps.first(where: { $0.localizedName == realName }) {
            return app
        }
        
        // Last resort: partial name matching
        return runningApps.first { app in
            guard let localizedName = app.localizedName?.lowercased() else { return false }
            return localizedName.contains(appName.lowercased()) || 
                   appName.lowercased().contains(localizedName)
        }
    }
    
    func minimizeApp(_ app: NSRunningApplication) {
        if debugMode {
            print("🔽 Minimizing \(app.localizedName ?? "Unknown")")
        }
        
        // Use accessibility API to minimize all windows
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowList: CFTypeRef?
        
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
        
        if result == .success, let windows = windowList as? [AXUIElement] {
            var minimizedCount = 0
            var totalWindows = 0
            var alreadyMinimized = 0
            
            for window in windows {
                // Check if this is a real window by checking for basic window attributes
                var role: CFTypeRef?
                let hasRole = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success
                
                // Only process windows with the "AXWindow" role
                guard hasRole, 
                      let roleString = role as? String, 
                      roleString == "AXWindow" else { continue }
                
                totalWindows += 1
                
                // Check if window is minimizable
                var minimizable: CFTypeRef?
                let isMinimizable = AXUIElementCopyAttributeValue(window, kAXMinimizableAttribute as CFString, &minimizable) == .success &&
                                  (minimizable as? Bool) == true
                
                if isMinimizable {
                    // Check current minimized state
                    var isMinimized: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &isMinimized) == .success,
                       let minimized = isMinimized as? Bool {
                        
                        if minimized {
                            alreadyMinimized += 1
                            if debugMode {
                                var title: CFTypeRef?
                                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                                print("   ⏹️ Already minimized: \(title as? String ?? "Untitled")")
                            }
                        } else {
                            // Try to minimize the window
                            let minimizeResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                            if minimizeResult == .success {
                                minimizedCount += 1
                                if debugMode {
                                    var title: CFTypeRef?
                                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                                    print("   ✅ Minimized: \(title as? String ?? "Untitled")")
                                }
                            } else if debugMode {
                                var title: CFTypeRef?
                                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                                print("   ❌ Failed to minimize: \(title as? String ?? "Untitled")")
                            }
                        }
                    }
                } else if debugMode {
                    var title: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                    print("   🚫 Not minimizable: \(title as? String ?? "Untitled")")
                }
            }
            
            if debugMode {
                print("   📊 Windows: \(totalWindows) total, \(minimizedCount) minimized, \(alreadyMinimized) already minimized")
            }
            
            // If we couldn't minimize any windows and none were already minimized, try hiding the app
            if minimizedCount == 0 && alreadyMinimized == 0 && totalWindows > 0 {
                app.hide()
                if debugMode {
                    print("   🔄 Attempted app hide (windows not minimizable)")
                }
            } else if totalWindows == 0 {
                // No windows found, try hiding the app
                app.hide()
                if debugMode {
                    print("   🔄 No windows found, attempted app hide")
                }
            }
        } else {
            if debugMode {
                print("   ❌ Could not access windows, trying app hide")
            }
            
            // Fallback: try hiding the app
            app.hide()
            if debugMode {
                print("   🔄 Attempted app hide as fallback")
            }
        }
    }
    
    // MARK: - UI Actions
    @objc func toggleMonitoring() {
        if isMonitoring {
            stopEventMonitoring()
        } else {
            startEventMonitoring()
        }
    }
    
    @objc func showDockInfo() {
        let alert = NSAlert()
        alert.messageText = "Current Dock Items"
        
        var info = "Total items: \(dockItems.count)\n\n"
        for (index, item) in dockItems.enumerated() {
            info += "\(index + 1). \(item.appName)\n"
            info += "   Position: (\(Int(item.rect.origin.x)), \(Int(item.rect.origin.y)))\n"
            info += "   Size: \(Int(item.rect.width))x\(Int(item.rect.height))\n\n"
        }
        
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DockClick v1.0"
        alert.informativeText = """
        Created by: mac
        
        DockClick adds click-to-minimize functionality to your dock:
        
        🖱️ Click a dock icon once to activate the app
        🖱️ Click the same icon again to minimize/hide it
        🔍 Precise dock item detection - no guessing
        🔄 Automatic dock change monitoring
        
        Required Permissions:
        • Accessibility - To monitor mouse clicks
        • Automation - To detect dock items
        
        © 2025 mac. All rights reserved.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    func showNotification(title: String, message: String) {
        print("📢 \(title): \(message)")
        
        // Try modern notification first
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to show notification: \(error)")
                // Fallback to console output
                DispatchQueue.main.async {
                    print("📢 Notification: \(title) - \(message)")
                }
            }
        }
    }
    
    // MARK: - Login Items Management
    
    func isInLoginItems() -> Bool {
        // Simple approach: check if app path exists in LaunchAgents
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent("com.yourname.dockclick.plist")
        
        return FileManager.default.fileExists(atPath: plistPath.path)
    }
    
    @objc func addToLoginItems() {
        let appPath = Bundle.main.bundlePath
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent("com.yourname.dockclick.plist")
        
        // Create LaunchAgents directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            showNotification(title: "Login Items Error", message: "Could not create LaunchAgents directory")
            return
        }
        
        // Create plist content
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.yourname.dockclick</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(appPath)/Contents/MacOS/DockClick</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """
        
        do {
            try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
            showNotification(title: "Login Items Updated", message: "DockClick will start automatically at login")
        } catch {
            showNotification(title: "Login Items Error", message: "Failed to create login item: \(error.localizedDescription)")
        }
        
        updateMenu()
    }
    
    @objc func removeFromLoginItems() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent("com.yourname.dockclick.plist")
        
        do {
            try FileManager.default.removeItem(at: plistPath)
            showNotification(title: "Login Items Updated", message: "DockClick removed from auto-start")
        } catch {
            showNotification(title: "Login Items Error", message: "Failed to remove login item: \(error.localizedDescription)")
        }
        
        updateMenu()
    }
    
    @objc func quitApp() {
        stopEventMonitoring()
        NSApplication.shared.terminate(nil)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        stopEventMonitoring()
    }
}

// MARK: - Main Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()