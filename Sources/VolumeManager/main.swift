import AppKit

// The app is plain AppKit: a menu bar item, a popover panel and two windows that
// `AppWindows` opens by hand. Nothing here needs a SwiftUI scene.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
