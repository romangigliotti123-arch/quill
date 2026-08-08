import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Quill"
        )
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if !Permissions.missing.isEmpty {
            for p in Permissions.missing {
                let mi = NSMenuItem(
                    title: "Grant \(p.rawValue)…",
                    action: #selector(grant(_:)),
                    keyEquivalent: ""
                )
                mi.target = self
                mi.representedObject = p
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: "Quit Quill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func statusLine() -> String {
        if Permissions.secureInputEnabled {
            return "Blocked — Secure Input is on"
        }
        let missing = Permissions.missing
        if missing.isEmpty { return "Ready" }
        return "Needs \(missing.map(\.rawValue).joined(separator: ", "))"
    }

    @objc private func grant(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Permission else { return }
        Permissions.request(p)
    }
}
