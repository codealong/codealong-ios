import SwiftUI

/// Every session on your linked Macs in one list, most urgent first, as the Mac's board ranks them.
struct InboxView: View {
    @Environment(Store.self) private var store
    @State private var showingMacs = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.rows, id: \.key) { row in
                            SessionRowView(row: row)
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
            .sheet(isPresented: $showingMacs) {
                DevicesView()
            }
        }
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
