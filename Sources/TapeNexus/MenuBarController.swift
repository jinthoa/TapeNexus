import AppKit

/// Owns the menu-bar status item for menu-bar mode. When installed, the app
/// hides from the Dock (NSApp.setActivationPolicy(.accessory)) and lives in the
/// status bar; the status menu can re-show the window, pause/resume, or quit.
@MainActor
final class MenuBarController {
    weak var state: AppState?
    weak var delegate: AppDelegate?
    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Cassette-tape template icon (the app's identity) rather than a generic
        // SF Symbol — drawn programmatically so it stays crisp + tints correctly.
        item.button?.image = TapeIcon.statusImage()
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Tape Nexus", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pause all", action: #selector(pauseAll), keyEquivalent: "")
        menu.addItem(withTitle: "Resume all", action: #selector(resumeAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tape Nexus", action: #selector(quit), keyEquivalent: "q")
        for m in menu.items where m.action != nil { m.target = self }
        item.menu = menu
        statusItem = item

        NSApp.setActivationPolicy(.accessory)
    }

    func uninstall() {
        if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
        statusItem = nil
        NSApp.setActivationPolicy(.regular)
    }

    @objc func showWindow() { delegate?.showWindow() }
    @objc func pauseAll() { state?.pauseAll() }
    @objc func resumeAll() { state?.resumeAll() }
    @objc func quit() { NSApp.terminate(nil) }
}