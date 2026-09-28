import SwiftUI

/// Every session on your linked Macs in one list, most urgent first, as the Mac's board ranks them.
struct InboxView: View {
    @Environment(Store.self) private var store
    @State private var showingMacs = false

    var body: some View {
        NavigationStack {
            List {
                // A Mac that dropped this phone still shows what it last sent, so say why it's old.
                if !forgotten.isEmpty {
                    Section {
                        Label {
                            Text("\(forgotten.map(\.name).formatted()) doesn't have this phone linked any more, so what's here is from before. Link it again with a new code.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Button("Link again") { showingMacs = true }
                    }
                }
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.rows, id: \.key) { row in
                            NavigationLink(value: row.key) {
                                SessionRowView(row: row)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Archive", systemImage: "archivebox") { store.archive(row.key) }
                                    .tint(.gray)
                            }
                            .swipeActions(edge: .leading) {
                                if row.status == .unread {
                                    Button("Seen", systemImage: "checkmark") { store.markSeen(row.key) }
                                        .tint(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if store.devices.isEmpty {
                    ContentUnavailableView {
                        Label("Link a Mac", systemImage: "laptopcomputer.and.iphone")
                    } description: {
                        Text("Make a link code on your Mac, in Settings › Devices, then enter it here.")
                    } actions: {
                        Button("Link a Mac") { showingMacs = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if store.sessions.isEmpty {
                    ContentUnavailableView("Nothing going on", systemImage: "checkmark.circle", description: Text("No sessions in the last three days."))
                }
            }
            .navigationTitle("Codealong")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingMacs = true } label: {
                        Label("Macs", systemImage: "laptopcomputer")
                    }
                    .badge(store.devices.filter(\.online).count)
                }
            }
            .navigationDestination(for: String.self) { key in
                SessionView(key: key)
            }
            .sheet(isPresented: $showingMacs) {
                DevicesView()
            }
            .alert("Link with this Mac?", isPresented: Binding(get: { store.offeredLink != nil }, set: { if !$0 { store.offeredLink = nil } })) {
                Button("Link") {
                    if let code = store.offeredLink {
                        Task { await store.link(code) }
                    }
                    store.offeredLink = nil
                }
                Button("Cancel", role: .cancel) { store.offeredLink = nil }
            } message: {
                Text("This phone will see the sessions on the Mac that showed this code, and the Mac will list it as a phone.")
            }
        }
    }

    /// Connected Macs that don't have this phone on their list.
    private var forgotten: [DeviceRow] {
        store.devices.filter { $0.online && !$0.linkedBack }
    }

    private struct Group {
        let title: String
        let rows: [SessionRow]
    }

    private var sections: [Group] {
        let buckets: [(String, (Status) -> Bool)] = [
            ("Needs you", { $0 == .needs || $0 == .error }),
            ("Your turn", { $0 == .unread }),
            ("Working", { $0 == .working }),
            ("Recent", { $0 == .idle || $0 == .stopped }),
        ]
        return buckets.compactMap { title, test in
            let rows = store.sessions.filter { test($0.status) }
            return rows.isEmpty ? nil : Group(title: title, rows: rows)
        }
    }
}
