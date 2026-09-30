import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Form {
            Section("Reddit API") {
                TextField("Approved installed-app client ID", text: $store.clientID)
                Button("Save client ID") { store.saveClientID() }.disabled(store.mockMode)
                Text("Register callback: \(OAuth.redirect)").font(.caption).textSelection(.enabled)
            }
            Section("Accounts") {
                ForEach(store.accounts) { account in
                    VStack(alignment: .leading) {
                        HStack {
                            Text("u/" + account.username)
                            Spacer()
                            Button("Remove") { store.remove(account.id) }
                        }
                        Toggle("Notifications", isOn: Binding(get: { store.accounts.first(where: { $0.id == account.id })?.notifications ?? false }, set: { store.toggleNotifications(account.id, enabled: $0) }))
                        if let status = store.statuses[account.id] { Text(status).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button("Add / Reconnect account") { store.addAccount() }.disabled(store.mockMode)
                Text("Links open in Safari using Safari’s current Reddit login.").font(.caption)
            }
            Section("Preferences") {
                Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: store.setLogin))
                Button("Request notification permission") { Task { await store.requestNotifications() } }
                Toggle("Demo mode (separate mock accounts)", isOn: Binding(get: { store.mockMode }, set: store.setMock))
                if store.mockMode { Button("Simulate reply for selected account") { Task { await store.simulate() } } }
            }
            if !store.message.isEmpty { Text(store.message).font(.caption).textSelection(.enabled) }
        }
        .formStyle(.grouped).padding().frame(width: 520, height: 620)
    }
}
