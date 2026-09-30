import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement

@MainActor
final class AppStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var selectedID: String = "" { didSet { persist() } }
    @Published var clientID: String = UserDefaults.standard.string(forKey: "clientID") ?? ""
    @Published var mockMode = UserDefaults.standard.bool(forKey: "mockMode")
    @Published var statuses: [String: String] = [:]
    @Published var message = ""
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var changed: (() -> Void)?
    private var live: LiveRedditClient?
    private let mock = MockRedditClient()
    private var timer: Timer?
    private var busy: Set<String> = []
    private var nextAttempt: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var subscriptionDates: [String: Date] = [:]
    private var generation = 0
    private var pending: (state: String, client: LiveRedditClient, date: Date)?
    private var awake = true
    var selected: Account? { accounts.first { $0.id == selectedID } }
    private var storageKey: String { mockMode ? "mockAccounts" : "accounts" }

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        Task { await refresh(forceSubscriptions: true) }
    }
    @objc private func sleep() { awake = false }
    @objc private func wake() { awake = true; Task { await refresh(forceSubscriptions: true) } }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey), let saved = try? JSONDecoder().decode([Account].self, from: data) { accounts = saved }
        else { accounts = mockMode ? [Account(id: "mock-alice", username: "alice (Demo)"), Account(id: "mock-bob", username: "bob (Demo)")] : [] }
        selectedID = UserDefaults.standard.string(forKey: storageKey + "Selected") ?? accounts.first?.id ?? ""
        if !accounts.contains(where: { $0.id == selectedID }) { selectedID = accounts.first?.id ?? "" }
        live = clientID.isEmpty ? nil : LiveRedditClient(clientID: clientID)
    }
    func persist() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: storageKey) }
        UserDefaults.standard.set(selectedID, forKey: storageKey + "Selected")
        changed?()
    }
    func setMock(_ enabled: Bool) {
        persist(); generation += 1; pending = nil
        mockMode = enabled; UserDefaults.standard.set(enabled, forKey: "mockMode")
        statuses = [:]; nextAttempt = [:]; subscriptionDates = [:]; failures = [:]; busy = []
        load(); changed?(); Task { await refresh(forceSubscriptions: true) }
    }
    func saveClientID() {
        let saved = UserDefaults.standard.string(forKey: "clientID") ?? ""
        clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved != clientID && !accounts.isEmpty && !mockMode {
            message = "Remove connected accounts before changing the client ID."
            clientID = saved; return
        }
        UserDefaults.standard.set(clientID, forKey: "clientID")
        pending = nil
        live = clientID.isEmpty ? nil : LiveRedditClient(clientID: clientID)
        message = "Client ID saved."
    }
    func select(_ id: String) { selectedID = id; Task { await refresh(forceSubscriptions: true, only: id) } }
    func addAccount() {
        guard !mockMode, let live else { message = "Save your approved Reddit client ID first."; return }
        let state = UUID().uuidString + UUID().uuidString
        pending = (state, live, Date())
        message = "Complete Reddit authorization in your browser. Switch Reddit accounts there if needed."
        NSWorkspace.shared.open(OAuth.authorization(clientID: clientID, state: state))
    }
    func callback(_ url: URL) {
        guard let pending else { message = "No sign-in is pending."; return }
        self.pending = nil
        let currentGeneration = generation
        Task {
            let temporaryID = UUID().uuidString
            do {
                guard Date().timeIntervalSince(pending.date) < 600 else { throw RedditError.invalidCallback }
                let code = try OAuth.code(from: url, expectedState: pending.state)
                try await pending.client.authorize(code: code, accountID: temporaryID)
                var account = try await pending.client.identity(accountID: temporaryID)
                let initial = try await pending.client.unread(accountID: temporaryID)
                _ = AlertTracker.ingest(initial, account: &account)
                account.subreddits = try await pending.client.subscriptions(accountID: temporaryID)
                guard generation == currentGeneration, !mockMode else { Keychain.remove(temporaryID); return }
                if let existing = accounts.firstIndex(where: { $0.username == account.username }) {
                    let old = accounts[existing]
                    try Keychain.write(Keychain.read(temporaryID), account: old.id)
                    Keychain.remove(temporaryID)
                    accounts[existing].subreddits = account.subreddits
                    statuses[old.id] = nil; nextAttempt[old.id] = nil
                    selectedID = old.id
                } else { accounts.append(account); selectedID = account.id }
                persist(); message = "Account connected."
                await requestNotifications()
            } catch { Keychain.remove(temporaryID); message = error.localizedDescription }
        }
    }
    func remove(_ id: String) {
        if !mockMode { Keychain.remove(id) }
        accounts.removeAll { $0.id == id }; statuses[id] = nil
        if selectedID == id { selectedID = accounts.first?.id ?? "" }
        persist()
    }
    func toggleNotifications(_ id: String, enabled: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].notifications = enabled; persist()
        if enabled { Task { await requestNotifications() } }
    }
    func requestNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            message = granted ? "Notifications enabled." : "Notifications are disabled in macOS System Settings."
        } catch { message = error.localizedDescription }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { message = "Approve launch at login in System Settings → Login Items." }
        } catch { message = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    func simulate() async {
        guard mockMode, let selected else { return }
        await refresh(only: selected.id)
        await mock.simulate(accountID: selected.id)
        await refresh(only: selected.id)
    }
    func refresh(forceSubscriptions: Bool = false, only: String? = nil) async {
        guard awake else { return }
        let client: any RedditClient
        if mockMode { client = mock } else if let live { client = live } else { return }
        let currentGeneration = generation
        for account in accounts where only == nil || account.id == only {
            guard !busy.contains(account.id), (nextAttempt[account.id] ?? .distantPast) <= Date() else { continue }
            busy.insert(account.id)
            do {
                let items = try await client.unread(accountID: account.id)
                guard generation == currentGeneration, let index = accounts.firstIndex(where: { $0.id == account.id }) else { busy.remove(account.id); continue }
                let fresh = AlertTracker.ingest(items, account: &accounts[index])
                persist()
                if accounts[index].notifications {
                    for item in fresh { await notify(item, account: accounts[index]) }
                }
                if forceSubscriptions || Date().timeIntervalSince(subscriptionDates[account.id] ?? .distantPast) >= 900 {
                    let subs = try await client.subscriptions(accountID: account.id)
                    if generation == currentGeneration, let index = accounts.firstIndex(where: { $0.id == account.id }) {
                        accounts[index].subreddits = subs; subscriptionDates[account.id] = Date(); persist()
                    }
                }
                if generation == currentGeneration { statuses[account.id] = nil; failures[account.id] = nil; nextAttempt[account.id] = nil }
            } catch {
                if generation == currentGeneration, accounts.contains(where: { $0.id == account.id }) {
                    let count = min((failures[account.id] ?? 0) + 1, 5); failures[account.id] = count
                    var delay = min(900, 60 * pow(2, Double(count - 1)))
                    if case RedditError.rateLimited(let seconds) = error { delay = max(delay, seconds) }
                    if case RedditError.reconnect = error { delay = 900 }
                    nextAttempt[account.id] = Date().addingTimeInterval(delay)
                    statuses[account.id] = error.localizedDescription
                }
            }
            if generation == currentGeneration { busy.remove(account.id) }
            changed?()
        }
    }
    private func notify(_ item: InboxItem, account: Account) async {
        let content = UNMutableNotificationContent()
        content.title = "u/\(account.username): \(item.subject)"
        content.body = String(item.body.prefix(240)); content.sound = .default
        content.userInfo = ["url": item.url.absoluteString]
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: account.id + ":" + item.id, content: content, trigger: nil)) }
        catch { message = "Could not deliver notification: \(error.localizedDescription)" }
    }
}
