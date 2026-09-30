import AppKit
import SwiftUI
import UserNotifications

@main
struct RedditMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var store: AppStore!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        store = AppStore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Reddit Menu Bar")
        store.changed = { [weak self] in self?.rebuild() }
        rebuild()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { store?.callback(url) }
    }
    private func item(_ title: String, action: Selector?, value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.representedObject = value
        return item
    }
    private func rebuild() {
        let menu = NSMenu()
        let accountMenu = NSMenu()
        for account in store.accounts {
            let entry = item("u/" + account.username, action: #selector(selectAccount), value: account.id)
            entry.state = store.selectedID == account.id ? .on : .off
            accountMenu.addItem(entry)
        }
        accountMenu.addItem(.separator())
        accountMenu.addItem(item("Manage Accounts…", action: #selector(settings)))
        let selector = item(store.selected.map { "u/" + $0.username } ?? "Connect an account…", action: nil)
        selector.submenu = accountMenu; menu.addItem(selector)
        if store.mockMode { menu.addItem(item("Demo Mode", action: nil)) }
        menu.addItem(.separator())
        menu.addItem(item("Home", action: #selector(browse), value: RedditLinks.home))
        menu.addItem(item("Popular", action: #selector(browse), value: RedditLinks.popular))
        menu.addItem(.separator())
        if let account = store.selected {
            for sub in account.subreddits.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                menu.addItem(item("r/" + sub, action: #selector(browse), value: RedditLinks.subreddit(sub)))
            }
            if account.subreddits.isEmpty { menu.addItem(item("No subscriptions loaded", action: nil)) }
            if let status = store.statuses[account.id] { menu.addItem(item(status, action: nil)) }
        }
        menu.addItem(.separator())
        menu.addItem(item("Refresh", action: #selector(refresh)))
        menu.addItem(item("Settings…", action: #selector(settings)))
        menu.addItem(item("Quit", action: #selector(quit)))
        statusItem.menu = menu
    }
    @objc private func selectAccount(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { store.select(id) } }
    @objc private func browse(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { openSafari(url) } }
    @objc private func refresh() { Task { await store.refresh(forceSubscriptions: true) } }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func settings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Reddit Menu Bar Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store)); window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func openSafari(_ url: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { store.message = "Safari could not be found."; settings(); return }
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.store.message = error.localizedDescription } }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let string = response.notification.request.content.userInfo["url"] as? String {
            Task { @MainActor in self.openSafari(RedditLinks.inbox(string)) }
        }
        completionHandler()
    }
}
