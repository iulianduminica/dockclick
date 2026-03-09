/*
 * DockClick (Restored Clean Implementation)
 * Click Dock apps to minimize / hide; clicking again restores.
 */

import Cocoa
import ApplicationServices
import UserNotifications
import ServiceManagement
import os

// MARK: - Simple Models / Logging
private extension NSRect { var area: CGFloat { width * height } }
struct DockItem { let rect: NSRect; let appName: String }
enum DockOrientation: String { case left, bottom, right, unknown }
enum LogCat { static let subsystem = Bundle.main.bundleIdentifier ?? "DockClick"; static let app = Logger(subsystem: subsystem, category: "app"); static let dock = Logger(subsystem: subsystem, category: "dock"); static let ev = Logger(subsystem: subsystem, category: "events"); static let ax = Logger(subsystem: subsystem, category: "ax"); static let notif = Logger(subsystem: subsystem, category: "notify"); static let ui = Logger(subsystem: subsystem, category: "ui") }

// Simple perf timer utility
struct PerfTimer {
    private let start = DispatchTime.now()
    func ms() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0 }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // UI
    var statusItem: NSStatusItem!

    // Event tap
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var isMonitoring = false

    // Dock items & refresh
    var dockItems: [DockItem] = []
    var dockUpdateTimer: Timer?
    private var lastDockChangeAt: Date = .distantPast
    private var pendingRescanAttempts = 0
    private let maxRescanAttempts = 3

    // Geometry
    private var dockBounds: NSRect?
    private var dockScreen: NSScreen?
    private var dockBoundsOnScreen: NSRect?
    private var detectedDockOrientation: DockOrientation = .unknown

    // Click state
    private var lastDockClickBundleID: String?
    private var lastDockClickAt: Date = .distantPast
    private enum DockClickAction { case passedForActivation, minimized, hid }
    private var lastActionByBundleID: [String: DockClickAction] = [:]

    // Preferences
    enum MinBehavior: String { case minimizeAll, hideApp }
    var minimizeBehavior: MinBehavior = {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "MinimizeBehavior"), let b = MinBehavior(rawValue: raw) { return b }
        d.set(MinBehavior.minimizeAll.rawValue, forKey: "MinimizeBehavior")
        return .minimizeAll
    }()
    var debugMode: Bool = UserDefaults.standard.object(forKey: "DebugMode") as? Bool ?? true
    // Feature flag: batch multi-window minimize/restore via AppleScript (perceived simultaneous animation)
    let appleScriptBatch: Bool = {
        if let v = UserDefaults.standard.object(forKey: "AppleScriptBatch") as? Bool { return v }
        UserDefaults.standard.set(true, forKey: "AppleScriptBatch")
        return true
    }()

    // Env debug
    private let mirrorLogsToStdout = ProcessInfo.processInfo.environment["DOCKCLICK_STDOUT_LOG"] == "1"
    private let forceDebugEnv = ProcessInfo.processInfo.environment["DOCKCLICK_FORCE_DEBUG"] == "1"
    private lazy var hasTTY: Bool = {
        // Detect if launched from an interactive terminal (stderr isatty)
        return isatty(fileno(stderr)) != 0 || isatty(fileno(stdout)) != 0
    }()
    private func debugStdout(_ s: String) {
        // If we have a TTY, always mirror when debugMode/forced; if not, only when explicit env variable set
        if (debugMode || forceDebugEnv) && (mirrorLogsToStdout || hasTTY) {
            fputs("[DockClick] \(s)\n", stderr)
        }
    }
    // Structured mirroring wrappers
    private func mirror(_ category: String, _ message: String) {
        if (debugMode || forceDebugEnv) && (mirrorLogsToStdout || hasTTY) {
            fputs("[DockClick][\(category)] \(message)\n", stderr)
        }
    }
    private func logEv(_ msg: String) { if debugMode { LogCat.ev.debug("\(msg)"); mirror("events", msg) } }
    private func logAX(_ msg: String) { if debugMode { LogCat.ax.debug("\(msg)"); mirror("ax", msg) } }
    private func logDock(_ msg: String) { if debugMode { LogCat.dock.debug("\(msg)"); mirror("dock", msg) } }

    // Login helper id
    private let helperBundleIdentifier = "com.yourname.dockclick.helper"

    // MARK: Launch
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
    LogCat.app.info("🚀 starting")
    debugStdout("startup mirrorLogsToStdout=\(mirrorLogsToStdout) forceDebugEnv=\(forceDebugEnv) hasTTY=\(hasTTY) debugMode=\(debugMode)")
        logEv("startup flags AppleScriptBatch=\(appleScriptBatch)")
        setupNotifications()
        setupStatusBar()
        setupDockMonitoring()
        startEventMonitoring()
        updateDockItems()
        LogCat.app.info("✅ ready")
    }
    @MainActor func applicationWillTerminate(_ n: Notification) { stopEventMonitoring() }

    // MARK: Notifications
    func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err = err { LogCat.notif.error("perm \(String(describing: err))") }
            else { LogCat.notif.info("granted=\(granted)") }
        }
    }
    func showNotification(title: String, message: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = message
        c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { LogCat.notif.error("notify err: \(String(describing: err))") }
        }
    }

    // MARK: Menu
    @MainActor func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockClick")
        statusItem.button?.toolTip = "DockClick – Click dock icons to minimize"
        updateMenu()
    }
    @MainActor func updateMenu() {
        let m = NSMenu()
        m.addItem(withTitle: isMonitoring ? "🟢 Monitoring Active" : "🔴 Monitoring Disabled", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        let orient = detectedDockOrientation == .unknown ? currentDockOrientation() : detectedDockOrientation
        m.addItem(withTitle: "Dock Items: \(dockItems.count)", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "Dock Orientation: \(orient.rawValue)", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: isMonitoring ? "Disable Monitoring" : "Enable Monitoring", action: #selector(toggleMonitoring), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Refresh Dock Items", action: #selector(refreshDock), keyEquivalent: "r"))
        m.addItem(.separator())
        let login = NSMenuItem()
        if isInLoginItems() { login.title = "Remove from Login Items"; login.action = #selector(removeFromLoginItems) }
        else { login.title = "Add to Login Items"; login.action = #selector(addToLoginItems) }
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open Notifications Settings…", action: #selector(openNotificationSettings), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Enable Notifications…", action: #selector(enableNotifications), keyEquivalent: ""))
        m.addItem(.separator())
        let dbg = NSMenuItem(title: debugMode ? "Disable Debug Logging" : "Enable Debug Logging", action: #selector(toggleDebugLogging), keyEquivalent: "")
        m.addItem(dbg)
        let behaviorMenu = NSMenu()
        let minAll = NSMenuItem(title: "Minimize All Windows", action: #selector(selectMinimizeAllBehavior), keyEquivalent: "")
        minAll.state = (minimizeBehavior == .minimizeAll ? .on : .off)
        behaviorMenu.addItem(minAll)
        let hideApp = NSMenuItem(title: "Hide App", action: #selector(selectHideAppBehavior), keyEquivalent: "")
        hideApp.state = (minimizeBehavior == .hideApp ? .on : .off)
        behaviorMenu.addItem(hideApp)
        let root = NSMenuItem(title: "Minimize Behavior", action: nil, keyEquivalent: "")
        root.submenu = behaviorMenu
        m.addItem(root)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Show Dock Info", action: #selector(showDockInfo), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "About DockClick", action: #selector(showAbout), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = m
    }

    // MARK: Dock Monitoring
    @MainActor func setupDockMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }
    @MainActor @objc func dockChanged(_ n: Notification) {
        lastDockChangeAt = Date()
        pendingRescanAttempts = maxRescanAttempts
        dockUpdateTimer?.invalidate()
        dockUpdateTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(onDockUpdateTimer), userInfo: nil, repeats: false)
    }
    @objc private func onDockUpdateTimer(_ t: Timer) { updateDockItems() }
    @MainActor @objc func appActivated(_ n: Notification) {
        if debugMode, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            LogCat.app.debug("activated: \(app.localizedName ?? "?")")
        }
    }
    @MainActor @objc func refreshDock() { updateDockItems() }

    // MARK: Dock Enumeration
    func updateDockItems() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if let ax = self.fetchDockItemsUsingAXSafe() {
                DispatchQueue.main.async { self.applyDockUpdate(ax, source: "AX") }
                return
            }
            let script = """
            tell application "System Events"
              tell process "Dock"
                set outList to {}
                set elems to every UI element of list 1
                repeat with e in elems
                  try
                    set p to position of e
                    set s to size of e
                    set nm to name of e
                    set sr to subrole of e
                    set end of outList to {p,s,nm,sr}
                  end try
                end repeat
                return outList
              end tell
            end tell
            """
            var err: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
            var items: [DockItem] = []
            if let list = result, list.descriptorType == typeAEList {
                for i in 1...list.numberOfItems {
                    guard let item = list.atIndex(i), item.numberOfItems >= 4 else { continue }
                    let pos = item.atIndex(1)
                    let size = item.atIndex(2)
                    let nameD = item.atIndex(3)
                    let sub = item.atIndex(4)
                    let subrole = sub?.stringValue ?? ""
                    guard subrole == "AXApplicationDockItem" || subrole == "AXTrashDockItem" else { continue }
                    let axX = pos?.atIndex(1)?.doubleValue ?? 0
                    let axY = pos?.atIndex(2)?.doubleValue ?? 0
                    let w = size?.atIndex(1)?.doubleValue ?? 0
                    let h = size?.atIndex(2)?.doubleValue ?? 0
                    let rect = self.convertAXRectToAppKit(axX: axX, axY: axY, width: w, height: h)
                    let name = nameD?.stringValue ?? "Unknown"
                    items.append(DockItem(rect: rect, appName: name))
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyDockUpdate(items, source: "AppleScript")
            }
        }
    }
    @MainActor private func applyDockUpdate(_ newItems: [DockItem], source: String) {
        let prev = dockItems
        if newItems.isEmpty { scheduleRetryIfNeeded(reason: "empty-\(source)") }
        else { dockItems = newItems; pendingRescanAttempts = 0 }
        computeDockGeometry()
        updateMenu()
        validateSnapshotChange(previous: prev, newItems: dockItems, source: source)
    }
    @MainActor private func validateSnapshotChange(previous: [DockItem], newItems: [DockItem], source: String) {
        let ps = Set(previous.map { $0.appName })
        let cs = Set(newItems.map { $0.appName })
        if ps == cs {
            if Date().timeIntervalSince(lastDockChangeAt) < 3 && pendingRescanAttempts > 0 {
                scheduleRetryIfNeeded(reason: "no-delta")
            }
        } else if debugMode {
            LogCat.dock.debug("delta (\(source)) added=[\(cs.subtracting(ps).joined(separator: ","))] removed=[\(ps.subtracting(cs).joined(separator: ","))]")
        }
    }
    @MainActor private func scheduleRetryIfNeeded(reason: String) {
        guard pendingRescanAttempts > 0 else { return }
        pendingRescanAttempts -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.updateDockItems() }
    if self.debugMode { LogCat.dock.debug("retry scheduled (\(reason)) remaining=\(self.pendingRescanAttempts)") }
    }
    private func fetchDockItemsUsingAXSafe() -> [DockItem]? {
        guard AXIsProcessTrusted() else { return nil }
        return try? fetchDockItemsUsingAX()
    }
    enum AXErr: Error { case dockMissing }
    private func fetchDockItemsUsingAX() throws -> [DockItem] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { throw AXErr.dockMissing }
        let root = AXUIElementCreateApplication(pid)
        var out: [DockItem] = []
        func str(_ e: AXUIElement, _ a: CFString) -> String? { var v: CFTypeRef?; if AXUIElementCopyAttributeValue(e, a, &v) == .success { return v as? String }; return nil }
        func valPt(_ e: AXUIElement, _ a: CFString) -> CGPoint? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, a, &v) == .success, let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
            let axv = unsafeBitCast(val, to: AXValue.self)
            if AXValueGetType(axv) == .cgPoint { var p = CGPoint.zero; AXValueGetValue(axv, .cgPoint, &p); return p }
            return nil
        }
        func valSz(_ e: AXUIElement, _ a: CFString) -> CGSize? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, a, &v) == .success, let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
            let axv = unsafeBitCast(val, to: AXValue.self)
            if AXValueGetType(axv) == .cgSize { var s = CGSize.zero; AXValueGetValue(axv, .cgSize, &s); return s }
            return nil
        }
        func children(_ e: AXUIElement) -> [AXUIElement] { var v: CFTypeRef?; if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success, let arr = v as? [AXUIElement] { return arr }; return [] }
        func visit(_ n: AXUIElement) {
            if let sub = str(n, kAXSubroleAttribute as CFString), (sub == "AXApplicationDockItem" || sub == "AXTrashDockItem"), let p = valPt(n, kAXPositionAttribute as CFString), let s = valSz(n, kAXSizeAttribute as CFString) {
                let rect = convertAXRectToAppKit(axX: Double(p.x), axY: Double(p.y), width: Double(s.width), height: Double(s.height))
                let name = str(n, kAXTitleAttribute as CFString) ?? str(n, kAXDescriptionAttribute as CFString) ?? "Unknown"
                out.append(DockItem(rect: rect, appName: name))
                return
            }
            for c in children(n) { visit(c) }
        }
        visit(root)
        return out
    }

    // MARK: Geometry
    func currentDockOrientation() -> DockOrientation {
        if let v = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String { return DockOrientation(rawValue: v) ?? .unknown }
        return .unknown
    }
    @MainActor private func computeDockGeometry() {
        guard !dockItems.isEmpty else {
            dockBounds = nil; dockScreen = nil; dockBoundsOnScreen = nil; detectedDockOrientation = .unknown; return
        }
        let bounds = dockItems.reduce(NSRect.null) { $0.union($1.rect) }
        let sys = currentDockOrientation()
        func edgeDist(_ r: NSRect, _ s: NSScreen, _ o: DockOrientation) -> CGFloat {
            switch o {
            case .bottom: return abs(r.minY - s.frame.minY)
            case .left: return abs(r.minX - s.frame.minX)
            case .right: return abs(s.frame.maxX - r.maxX)
            case .unknown:
                let dB = abs(r.minY - s.frame.minY)
                let dL = abs(r.minX - s.frame.minX)
                let dR = abs(s.frame.maxX - r.maxX)
                return min(dB, min(dL, dR))
            }
        }
        var best: NSScreen?
        var bestDist = CGFloat.greatestFiniteMagnitude
        var bestArea: CGFloat = -1
        for s in NSScreen.screens {
            let d = edgeDist(bounds, s, sys)
            let a = bounds.intersection(s.frame).area
            if d < bestDist || (abs(d - bestDist) < 1 && a > bestArea) {
                bestDist = d; bestArea = a; best = s
            }
        }
        dockBounds = bounds
        dockScreen = best
        dockBoundsOnScreen = best.map { bounds.intersection($0.frame) } ?? bounds
        if let s = best {
            let dB = abs(bounds.minY - s.frame.minY)
            let dL = abs(bounds.minX - s.frame.minX)
            let dR = abs(s.frame.maxX - bounds.maxX)
            let minD = min(dB, min(dL, dR))
            let measured: DockOrientation = (minD == dB) ? .bottom : (minD == dL ? .left : .right)
            detectedDockOrientation = (sys == .unknown) ? measured : sys
        } else {
            detectedDockOrientation = sys
        }
    if self.debugMode { LogCat.dock.debug("geometry orientation=\(self.detectedDockOrientation.rawValue) bounds=\(NSStringFromRect(bounds))") }
    }
    private func convertAXRectToAppKit(axX: Double, axY: Double, width: Double, height: Double) -> NSRect {
        let union = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        return NSRect(x: axX, y: Double(union.maxY) - axY - height, width: width, height: height)
    }
    private func convertGlobalPoint(_ p: CGPoint) -> CGPoint {
        let union = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        return CGPoint(x: p.x, y: union.maxY - p.y)
    }

    // MARK: Event Monitoring
    @MainActor func startEventMonitoring() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            showNotification(title: "Permission Required", message: "Grant accessibility permissions for DockClick")
            return
        }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon, type == .leftMouseDown else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return app.handleMouseClick(event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap = eventTap else { LogCat.ev.error("tap create failed"); return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isMonitoring = true
        updateMenu()
        LogCat.ev.info("monitoring started")
    }
    @MainActor func stopEventMonitoring() {
        guard isMonitoring else { return }
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        isMonitoring = false
        dockUpdateTimer?.invalidate()
        dockUpdateTimer = nil
        updateMenu()
        LogCat.ev.info("monitoring stopped")
    }

    // MARK: Click Handling
    @MainActor func handleMouseClick(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isMonitoring else { return Unmanaged.passUnretained(event) }
        let global = event.location
        let point = convertGlobalPoint(global)
        if (dockBounds == nil || dockScreen == nil) && !dockItems.isEmpty { computeDockGeometry() }
        if let b = dockBoundsOnScreen ?? dockBounds, !b.insetBy(dx: -12, dy: -12).contains(point) { return Unmanaged.passUnretained(event) }
        if dockItems.isEmpty && Date().timeIntervalSince(lastDockChangeAt) < 2 { updateDockItems() }
        func expanded(_ r: NSRect) -> NSRect { r.insetBy(dx: -10, dy: -12) }
        guard let item = dockItems.first(where: { expanded($0.rect).contains(point) }) else { return Unmanaged.passUnretained(event) }
        let name = (item.appName == "Trash") ? "Finder" : item.appName
        guard let app = findRunningApp(named: name) else { return Unmanaged.passUnretained(event) }
        let bid = app.bundleIdentifier ?? "?"
        let now = Date()
        let dt = now.timeIntervalSince(lastDockClickAt)
        let same = (lastDockClickBundleID == app.bundleIdentifier)
        let lastAction = lastActionByBundleID[bid]
        let front = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleIdentifier)

        if lastAction == .minimized || lastAction == .hid {
            let t = PerfTimer()
            if lastAction == .hid { _ = restoreHiddenApp(app) } else { _ = restoreAppWindows(app) }
            logEv("restore bid=\(bid) last=\(String(describing: lastAction)) took=\(String(format: "%.2f", t.ms()))ms")
            lastActionByBundleID[bid] = .passedForActivation
            lastDockClickBundleID = app.bundleIdentifier
            lastDockClickAt = now
            return nil
        }
        if front {
            let t = PerfTimer()
            if minimizeBehavior == .hideApp {
                app.hide(); lastActionByBundleID[bid] = .hid; logEv("hide bid=\(bid)")
            } else {
                minimizeApp(app); lastActionByBundleID[bid] = .minimized; logEv("min bid=\(bid)")
            }
            logEv("front-minimize/hide bid=\(bid) took=\(String(format: "%.2f", t.ms()))ms windows=\(self.activeWindowCount(app: app))")
            lastDockClickBundleID = app.bundleIdentifier
            lastDockClickAt = now
            return nil
        }
        if same && dt < 0.5 && lastAction == .passedForActivation {
            let t = PerfTimer()
            if minimizeBehavior == .hideApp {
                app.hide(); lastActionByBundleID[bid] = .hid; logEv("force-hide bid=\(bid)")
            } else {
                minimizeApp(app); lastActionByBundleID[bid] = .minimized; logEv("force-min bid=\(bid)")
            }
            logEv("rapid-cycle minimize/hide bid=\(bid) took=\(String(format: "%.2f", t.ms()))ms windows=\(self.activeWindowCount(app: app))")
            lastDockClickBundleID = app.bundleIdentifier
            lastDockClickAt = now
            return nil
        }
        lastActionByBundleID[bid] = .passedForActivation
        lastDockClickBundleID = app.bundleIdentifier
        lastDockClickAt = now
        logEv("activate bid=\(bid)")
        return Unmanaged.passUnretained(event)
    }

    // Count non-minimized windows (best-effort) for diagnostics
    private func activeWindowCount(app: NSRunningApplication) -> Int {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var list: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &list) == .success, let ws = list as? [AXUIElement] {
            var c = 0
            for w in ws {
                var role: CFTypeRef?
                guard AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &role) == .success, (role as? String) == "AXWindow" else { continue }
                var mini: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini) == .success, let v = mini as? Bool, !v { c += 1 }
            }
            return c
        }
        return 0
    }

    // MARK: App Resolution
    func findRunningApp(named name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        let exact = apps.filter { ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame }
        if exact.count == 1 { return exact.first }
        if exact.count > 1 { return exact.first(where: { $0.isActive }) ?? exact.first }
        let alias: [String: String] = [
            "code": "com.microsoft.VSCode",
            "vscode": "com.microsoft.VSCode",
            "iterm": "com.googlecode.iterm2",
            "terminal": "com.apple.Terminal",
            "finder": "com.apple.finder"
        ]
        if let bid = alias[name.lowercased()], let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first { return app }
        func norm(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        let target = norm(name)
        var best: (NSRunningApplication, Int)?
        for a in apps {
            guard let n = a.localizedName else { continue }
            let nn = norm(n)
            var score = 0
            if nn == target { score += 100 }
            if nn.contains(target) || target.contains(nn) { score += 50 }
            if let bid = a.bundleIdentifier?.lowercased(), bid.contains(target) { score += 40 }
            if let last = a.bundleURL?.lastPathComponent.lowercased().replacingOccurrences(of: ".app", with: ""), norm(last) == target { score += 60 }
            if let cur = best { if score > cur.1 { best = (a, score) } } else { best = (a, score) }
        }
        return (best?.1 ?? 0) > 0 ? best!.0 : nil
    }

    // MARK: Minimize / Restore
    @MainActor func minimizeApp(_ app: NSRunningApplication) {
        let perf = PerfTimer()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var list: CFTypeRef?
        guard AXIsProcessTrusted(), AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success, let windows = list as? [AXUIElement] else {
            app.hide(); logAX("minimizeApp fallback hide bid=\(app.bundleIdentifier ?? "?") took=\(String(format: "%.2f", perf.ms()))ms"); return
        }
        var axWindows: [AXUIElement] = []
        axWindows.reserveCapacity(windows.count)
        for w in windows {
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &role) == .success, (role as? String) == "AXWindow" else { continue }
            axWindows.append(w)
        }
        let total = axWindows.count
        if total == 0 { app.hide(); logAX("minimizeApp no-windows hide bid=\(app.bundleIdentifier ?? "?") took=\(String(format: "%.2f", perf.ms()))ms"); return }
        // AppleScript batch path for multi-window apps (attempt simultaneous minimize animation)
        if appleScriptBatch && total > 1, let bid = app.bundleIdentifier, runAppleScriptMinimizeAll(bid: bid) {
            logAX("minimizeApp appleScriptBatch bid=\(bid) total=\(total) took=\(String(format: "%.2f", perf.ms()))ms")
            return
        }
        // Single window fast path
        if total == 1 {
            var mini: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindows[0], kAXMinimizedAttribute as CFString, &mini) == .success, let v = mini as? Bool, !v {
                _ = AXUIElementSetAttributeValue(axWindows[0], kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            } else { app.hide() }
            logAX("minimizeApp fastPath bid=\(app.bundleIdentifier ?? "?") took=\(String(format: "%.2f", perf.ms()))ms")
            return
        }
        var newlyMin = 0
        var already = 0
        for w in axWindows {
            var mini: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini) == .success, let v = mini as? Bool {
                if v { already += 1 }
                else if AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success { newlyMin += 1 }
            }
        }
        if newlyMin == 0 && already == 0 { app.hide() }
        logAX("minimizeApp batch bid=\(app.bundleIdentifier ?? "?") total=\(total) newly=\(newlyMin) already=\(already) took=\(String(format: "%.2f", perf.ms()))ms")
    }
    func restoreAppWindows(_ app: NSRunningApplication) -> Int {
        let perf = PerfTimer()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var list: CFTypeRef?
        guard AXIsProcessTrusted(), AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success, let windows = list as? [AXUIElement] else {
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: [.activateIgnoringOtherApps]) }
            logAX("restoreAppWindows fallback activate bid=\(app.bundleIdentifier ?? "?") took=\(String(format: "%.2f", perf.ms()))ms"); return 0
        }
        var axWindows: [AXUIElement] = []
        axWindows.reserveCapacity(windows.count)
        for w in windows {
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &role) == .success, (role as? String) == "AXWindow" else { continue }
            axWindows.append(w)
        }
        let total = axWindows.count
        if total == 0 {
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: [.activateIgnoringOtherApps]) }
            logAX("restoreAppWindows no-windows activate bid=\(app.bundleIdentifier ?? "?") took=\(String(format: "%.2f", perf.ms()))ms"); return 0
        }
        // Determine how many are minimized first
        var minimizedCount = 0
        for w in axWindows {
            var mini: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini) == .success, let isMin = mini as? Bool, isMin { minimizedCount += 1 }
        }
        // AppleScript batch restore for multi-window minimized sets
        if appleScriptBatch && minimizedCount > 1, let bid = app.bundleIdentifier, runAppleScriptRestoreAll(bid: bid) {
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: [.activateIgnoringOtherApps]) }
            logAX("restoreAppWindows appleScriptBatch bid=\(bid) minimized=\(minimizedCount) total=\(total) took=\(String(format: "%.2f", perf.ms()))ms")
            return minimizedCount
        }
        // Single window fast path
        if total == 1 {
            var mini: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindows[0], kAXMinimizedAttribute as CFString, &mini) == .success, let isMin = mini as? Bool, isMin {
                _ = AXUIElementSetAttributeValue(axWindows[0], kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(axWindows[0], kAXRaiseAction as CFString)
                logAX("restoreAppWindows fastPath bid=\(app.bundleIdentifier ?? "?") restored=1 took=\(String(format: "%.2f", perf.ms()))ms")
                return 1
            }
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: [.activateIgnoringOtherApps]) }
            logAX("restoreAppWindows fastPath noMin bid=\(app.bundleIdentifier ?? "?") took=\(String(format: "%.2f", perf.ms()))ms")
            return 0
        }
        var restored = 0
        // Restore all minimized but only raise the last one to reduce overhead
        for (idx, w) in axWindows.enumerated() {
            var mini: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini) == .success, let isMin = mini as? Bool, isMin {
                if AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success {
                    restored += 1
                    if idx == axWindows.count - 1 { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
                }
            }
        }
        if restored == 0 { if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: [.activateIgnoringOtherApps]) } }
        logAX("restoreAppWindows batch bid=\(app.bundleIdentifier ?? "?") total=\(total) restored=\(restored) took=\(String(format: "%.2f", perf.ms()))ms")
        return restored
    }
    // MARK: AppleScript batch helpers
    private func runAppleScriptMinimizeAll(bid: String) -> Bool {
        let script = "tell application id \"\(bid)\" to try\nset miniaturized of windows to true\non error\nreturn 0\nend try"
        return runAppleScript(source: script, label: "minAll")
    }
    private func runAppleScriptRestoreAll(bid: String) -> Bool {
        let script = "tell application id \"\(bid)\" to try\nset miniaturized of (every window whose miniaturized is true) to false\non error\nreturn 0\nend try"
        return runAppleScript(source: script, label: "restoreAll")
    }
    private func runAppleScript(source: String, label: String) -> Bool {
        let start = CFAbsoluteTimeGetCurrent()
        let asObj = NSAppleScript(source: source)
        var err: NSDictionary? = nil
        if let _ = asObj?.executeAndReturnError(&err), err == nil {
            logAX("appleScript \(label) ok time=\(String(format: "%.2f", (CFAbsoluteTimeGetCurrent()-start)*1000))ms")
            return true
        } else {
            if let e = err { logAX("appleScript \(label) fail err=\(e)") }
            return false
        }
    }
    func restoreHiddenApp(_ app: NSRunningApplication) -> Int {
        let perf = PerfTimer()
        if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: [.activateIgnoringOtherApps]) }
        if app.bundleIdentifier == "com.apple.finder" {
            let script = """
            tell application "Finder"
              try
                set miniaturized of every window to false
              end try
              activate
            end tell
            """
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let err, debugMode { LogCat.ax.debug("Finder restore script err: \(err)") }
        }
        if debugMode { LogCat.ax.debug("restoreHiddenApp bid=\(app.bundleIdentifier ?? "?") took=\(String(format: "%.2f", perf.ms()))ms") }
        return 1
    }

    // MARK: Login Items
    @MainActor func isInLoginItems() -> Bool { if #available(macOS 13.0, *) { return SMAppService.loginItem(identifier: helperBundleIdentifier).status == .enabled } else { return false } }
    @MainActor @objc func addToLoginItems() {
        if #available(macOS 13.0, *) {
            do { try SMAppService.loginItem(identifier: helperBundleIdentifier).register(); showNotification(title: "Login Item", message: "DockClick will launch at login") }
            catch { showNotification(title: "Login Item", message: "Failed to add – add manually in System Settings") }
        } else { showNotification(title: "Manual Step", message: "Add DockClick manually in Login Items") }
        updateMenu()
    }
    @MainActor @objc func removeFromLoginItems() {
        if #available(macOS 13.0, *) {
            do { try SMAppService.loginItem(identifier: helperBundleIdentifier).unregister(); showNotification(title: "Login Item", message: "Removed from login") }
            catch { showNotification(title: "Login Item", message: "Failed to remove") }
        } else { showNotification(title: "Manual Step", message: "Remove manually in Login Items") }
        updateMenu()
    }

    // MARK: Menu Actions
    @MainActor @objc func toggleMonitoring() { isMonitoring ? stopEventMonitoring() : startEventMonitoring() }
    @MainActor @objc func showDockInfo() {
        let a = NSAlert()
        a.messageText = "Current Dock Items"
        a.informativeText = dockItems.enumerated().map { "\($0+1). \($1.appName) @ (\(Int($1.rect.origin.x)),\(Int($1.rect.origin.y)))" }.joined(separator: "\n")
        a.runModal()
    }
    @MainActor @objc func showAbout() {
        let a = NSAlert()
        a.messageText = "DockClick"
        a.informativeText = "Click Dock icons to minimize / hide. Finder & Trash supported."
        a.runModal()
    }
    @MainActor @objc func toggleDebugLogging() {
        debugMode.toggle()
        UserDefaults.standard.set(debugMode, forKey: "DebugMode")
        updateMenu()
    LogCat.app.info("debugMode=\(self.debugMode)")
    }
    @MainActor @objc func selectMinimizeAllBehavior() { minimizeBehavior = .minimizeAll; UserDefaults.standard.set(minimizeBehavior.rawValue, forKey: "MinimizeBehavior"); updateMenu() }
    @MainActor @objc func selectHideAppBehavior() { minimizeBehavior = .hideApp; UserDefaults.standard.set(minimizeBehavior.rawValue, forKey: "MinimizeBehavior"); updateMenu() }
    @MainActor @objc func openAccessibilitySettings() {
        for url in [URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"), URL(string: "x-apple.systempreferences:com.apple.preference.security")] {
            if let u = url, NSWorkspace.shared.open(u) { break }
        }
    }
    @MainActor @objc func openNotificationSettings() {
        for url in [URL(string: "x-apple.systempreferences:com.apple.preference.notifications"), URL(string: "x-apple.systempreferences:")] {
            if let u = url, NSWorkspace.shared.open(u) { break }
        }
    }
    @MainActor @objc func enableNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { g, _ in if g { self.showNotification(title: "Notifications", message: "Enabled") } }
    }
    @MainActor @objc func quitApp() { stopEventMonitoring(); NSApplication.shared.terminate(nil) }
}

// MARK: Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()