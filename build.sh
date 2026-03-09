#!/bin/bash
set -euo pipefail

#
# DockClick Build Script with Automatic Icon Generation
# Created by: mac
# Builds the DockClick macOS application with auto-generated dock-themed icon
#

echo "🖱️ Building DockClick with automatic icon generation..."

# Clean previous build
rm -rf build/

# Create build directory
mkdir -p build

# Create icon generator Swift file
cat > build/icon_generator.swift << 'EOF'
import Cocoa
import CoreGraphics

func createIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: CGSize(width: size, height: size))
    
    image.lockFocus()
    
    // Background gradient - modern dock-like appearance
    let gradient = NSGradient(colors: [
        NSColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1.0), // Dark gray
        NSColor(red: 0.25, green: 0.25, blue: 0.27, alpha: 1.0)  // Lighter gray
    ])!
    
    gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: 135)
    
    // Draw dock representation
    let context = NSGraphicsContext.current!.cgContext
    let scale = size / 1024.0
    let centerX = size / 2
    let centerY = size / 2
    
    // Draw dock base
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.8))
    let dockRect = CGRect(x: centerX - 300 * scale, y: centerY - 80 * scale, width: 600 * scale, height: 100 * scale)
    context.addPath(CGPath(roundedRect: dockRect, cornerWidth: 25 * scale, cornerHeight: 25 * scale, transform: nil))
    context.fillPath()
    
    // Add dock highlight
    context.setStrokeColor(CGColor(red: 0.4, green: 0.4, blue: 0.45, alpha: 0.6))
    context.setLineWidth(3 * scale)
    context.addPath(CGPath(roundedRect: dockRect, cornerWidth: 25 * scale, cornerHeight: 25 * scale, transform: nil))
    context.strokePath()
    
    // Draw dock icons (simplified app representations)
    let iconSize: CGFloat = 60 * scale
    let iconSpacing: CGFloat = 80 * scale
    let startX = centerX - 200 * scale
    let iconY = centerY - 30 * scale
    
    // Draw 5 dock icons
    for i in 0..<5 {
        let iconX = startX + CGFloat(i) * iconSpacing
        let iconRect = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        
        if i == 2 { // Middle icon - highlighted (being clicked)
            // Active/clicked icon
            context.setFillColor(CGColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 0.8))
            context.addPath(CGPath(roundedRect: iconRect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
            context.fillPath()
            
            // Add click indicator
            context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.3))
            let clickRect = CGRect(x: iconX - 5 * scale, y: iconY - 5 * scale, width: iconSize + 10 * scale, height: iconSize + 10 * scale)
            context.addPath(CGPath(roundedRect: clickRect, cornerWidth: 15 * scale, cornerHeight: 15 * scale, transform: nil))
            context.fillPath()
        } else {
            // Normal dock icon
            context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 0.7))
            context.addPath(CGPath(roundedRect: iconRect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
            context.fillPath()
        }
        
        // Add icon border
        context.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.35, alpha: 0.8))
        context.setLineWidth(2 * scale)
        context.addPath(CGPath(roundedRect: iconRect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
        context.strokePath()
    }
    
    // Draw mouse cursor pointer
    let cursorX = centerX
    let cursorY = centerY + 60 * scale
    
    // Cursor body (arrow shape)
    context.setFillColor(CGColor.white)
    context.beginPath()
    context.move(to: CGPoint(x: cursorX, y: cursorY))
    context.addLine(to: CGPoint(x: cursorX + 20 * scale, y: cursorY - 30 * scale))
    context.addLine(to: CGPoint(x: cursorX + 8 * scale, y: cursorY - 25 * scale))
    context.addLine(to: CGPoint(x: cursorX + 15 * scale, y: cursorY - 15 * scale))
    context.closePath()
    context.fillPath()
    
    // Cursor border
    context.setStrokeColor(CGColor.black)
    context.setLineWidth(2 * scale)
    context.beginPath()
    context.move(to: CGPoint(x: cursorX, y: cursorY))
    context.addLine(to: CGPoint(x: cursorX + 20 * scale, y: cursorY - 30 * scale))
    context.addLine(to: CGPoint(x: cursorX + 8 * scale, y: cursorY - 25 * scale))
    context.addLine(to: CGPoint(x: cursorX + 15 * scale, y: cursorY - 15 * scale))
    context.closePath()
    context.strokePath()
    
    // Add minimize arrows (showing the minimize action)
    context.setStrokeColor(CGColor(red: 0.0, green: 0.8, blue: 0.2, alpha: 0.8))
    context.setLineWidth(6 * scale)
    context.setLineCap(.round)
    
    // Downward arrows indicating minimize
    let arrowY = centerY + 120 * scale
    for i in 0..<3 {
        let arrowX = centerX - 40 * scale + CGFloat(i) * 40 * scale
        context.beginPath()
        context.move(to: CGPoint(x: arrowX - 15 * scale, y: arrowY))
        context.addLine(to: CGPoint(x: arrowX, y: arrowY + 20 * scale))
        context.addLine(to: CGPoint(x: arrowX + 15 * scale, y: arrowY))
        context.strokePath()
    }
    
    image.unlockFocus()
    return image
}

func saveIcon(image: NSImage, size: CGFloat, path: String) {
    let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    
    let context = NSGraphicsContext(bitmapImageRep: bitmapRep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    
    NSGraphicsContext.restoreGraphicsState()
    
    let pngData = bitmapRep.representation(using: .png, properties: [:])!
    try! pngData.write(to: URL(fileURLWithPath: path))
}

// Generate all required icon sizes
let sizes: [(CGFloat, String)] = [
    (1024, "icon_512x512@2x.png"),
    (512, "icon_512x512.png"),
    (512, "icon_256x256@2x.png"),
    (256, "icon_256x256.png"),
    (256, "icon_128x128@2x.png"),
    (128, "icon_128x128.png"),
    (64, "icon_32x32@2x.png"),
    (32, "icon_32x32.png"),
    (32, "icon_16x16@2x.png"),
    (16, "icon_16x16.png")
]

// Create iconset directory
let iconsetPath = "build/DockClick.iconset"
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true, attributes: nil)

// Generate all sizes
for (size, filename) in sizes {
    let icon = createIcon(size: size)
    saveIcon(image: icon, size: size, path: "\(iconsetPath)/\(filename)")
    print("Generated \(filename)")
}

print("All icon files generated successfully!")
EOF

# Compile and run icon generator
echo "🎨 Generating dock-themed icon..."
swiftc -o build/icon_generator build/icon_generator.swift -framework Cocoa
./build/icon_generator

if [ $? -ne 0 ]; then
    echo "❌ Icon generation failed"
    exit 1
fi

# Create .icns file using iconutil (built into macOS)
echo "📄 Converting to .icns format..."
iconutil -c icns build/DockClick.iconset -o build/DockClick.icns

if [ $? -ne 0 ]; then
    echo "❌ Icon conversion failed"
    exit 1
fi

# Compile main Swift code (release-lean flags)
echo "🔨 Compiling DockClick..."
swiftc -Osize main.swift -o build/DockClick \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework UserNotifications \
    -framework ServiceManagement

if [ $? -ne 0 ]; then
    echo "❌ Swift compilation failed"
    exit 1
fi

# Create app bundle structure
echo "📦 Creating app bundle..."
mkdir -p build/DockClick.app/Contents/MacOS
mkdir -p build/DockClick.app/Contents/Resources
mkdir -p build/DockClick.app/Contents/Library/LoginItems

# Copy executable
cp build/DockClick build/DockClick.app/Contents/MacOS/

# Copy Info.plist and stamp version/build
cp Info.plist build/DockClick.app/Contents/
PLIST="build/DockClick.app/Contents/Info.plist"
# Stamp build number with date-time for traceability
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$PLIST" >/dev/null 2>&1 || true

# Copy icon
cp build/DockClick.icns build/DockClick.app/Contents/Resources/

# Set executable permissions
chmod +x build/DockClick.app/Contents/MacOS/DockClick

# Clean up temporary files
rm -rf build/DockClick.iconset
rm build/icon_generator.swift
rm build/icon_generator
rm build/DockClick.icns
rm build/DockClick

echo "✅ Build complete with custom dock-themed icon!"
echo ""
echo "🖱️ Your DockClick app is ready at: build/DockClick.app"
echo "🚀 To run: open build/DockClick.app"
echo "🎨 Icon: ✅ Auto-generated dock with click indicator"
echo "📋 Bundle ID: com.yourname.dockclick"
echo "📢 Version: 1.0"
echo "👤 Created by: mac"
echo ""
echo "🪟 Key Features:"
echo "   • Windows-style dock minimize behavior"
echo "   • Click frontmost dock app to minimize it"
echo "   • Works with all apps and dock positions"
echo "   • Global mouse click interception"
echo "   • Professional menu bar integration"
echo ""
echo "⚠️  IMPORTANT: Grant Accessibility permissions when prompted!"
echo "   System Settings > Privacy & Security > Accessibility"
echo ""
echo "🎯 Usage:"
echo "   1. Click any dock app → brings to front (normal)"
echo "   2. Click same app again → minimizes (Windows-style!)"

# Build a minimal SMLoginItem helper and embed it
echo "🧰 Building login helper (SMLoginItem)"

HELPER_SRC="build/HelperMain.swift"
cat > "$HELPER_SRC" << 'EOF'
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
EOF

echo "📦 Creating helper bundle..."
mkdir -p build/DockClickHelper.app/Contents/MacOS
mkdir -p build/DockClickHelper.app/Contents/Resources

cat > build/DockClickHelper.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>DockClickHelper</string>
  <key>CFBundleIdentifier</key>
  <string>com.yourname.dockclick.helper</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
  <key>CFBundleExecutable</key>
  <string>DockClickHelper</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
EOF

echo "🔨 Compiling helper..."
swiftc "$HELPER_SRC" -o build/DockClickHelper.app/Contents/MacOS/DockClickHelper -framework Cocoa
chmod +x build/DockClickHelper.app/Contents/MacOS/DockClickHelper

echo "📥 Embedding helper in main app..."
cp -R build/DockClickHelper.app "build/DockClick.app/Contents/Library/LoginItems/"

echo "ℹ️ Note: For production, both main app and helper must be signed with the same team."

# Ad-hoc sign helper and main app for local testing (no Developer ID required)
if command -v codesign >/dev/null 2>&1; then
    echo "🔏 Ad-hoc signing helper and main app..."
    codesign --force --sign - --timestamp=none "build/DockClick.app/Contents/Library/LoginItems/DockClickHelper.app/Contents/MacOS/DockClickHelper" || true
    codesign --force --sign - --timestamp=none "build/DockClick.app/Contents/Library/LoginItems/DockClickHelper.app" || true
    codesign --force --sign - --deep --timestamp=none "build/DockClick.app" || true
else
    echo "⚠️ codesign not available; SMLoginItem registration may fail."
fi