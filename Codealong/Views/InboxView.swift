import SwiftUI

/// Every session on your linked Macs in one quiet list, most urgent first, as the Mac's board ranks
/// them. Nothing above the content: the controls are the glass toolbar at the bottom, where the
/// thumb is (Macs and projects, search, a new session), as iOS 26's own apps have them.
struct InboxView: View {
    @Environment(Store.self) private var store
    @State private var showingMacs = false
    @State private var showingNew = false
    @State private var query = ""
    @State private var path: [String] = []
    /// The project the list is narrowed to, as the Macs line projects up; empty for all of them.
    @AppStorage("project") private var project = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // A Mac that dropped this phone still shows what it last sent, so say why it's old.
                if !forgotten.isEmpty {
                    Button { showingMacs = true } label: {
                        Label("\(forgotten.map { Names.short($0.name) }.formatted()) no longer has this phone linked. Link again", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    .listRowSeparator(.hidden)
                }
                ForEach(sections, id: \.title) { section in
                    Section {
                        ForEach(section.rows, id: \.key) { row in
                            SessionRowView(row: row, showDevice: store.devices.count > 1, showProject: project.isEmpty)
                                .contentShape(.rect)
                                .onTapGesture { path.append(row.key) }
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
                    } header: {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            // Just a breath below the status bar: there's no title above the list.
            .contentMargins(.top, 0, for: .scrollContent)
            .overlay { emptyState }
            .searchable(text: $query, prompt: "Search")
            // A project's name takes the toolbar's room, so search folds into its button then.
            .searchToolbarBehavior(project.isEmpty ? .automatic : .minimize)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button { showingMacs = true } label: {
                        Label("Macs", systemImage: macsSymbol)
                            .labelStyle(.iconOnly)
                    }
                    .tint(macsNeedAttention ? .orange : nil)
                }
                // Beside Macs, in the same glass: a folder while every project shows, the
                // project's name while the list is narrowed to it.
                if projects.count > 1 || !project.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Menu {
                            Picker("Project", selection: $project) {
                                Text("All projects").tag("")
                                ForEach(projects, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                        } label: {
                            if project.isEmpty {
                                Label("Projects", systemImage: "folder")
                                    .labelStyle(.iconOnly)
                            } else {
                                Text(project)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityLabel(project.isEmpty ? "Projects" : "Project: \(project)")
                    }
                }
                ToolbarSpacer(.fixed, placement: .bottomBar)
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button { showingNew = true } label: {
                        Label("New session", systemImage: "square.and.pencil")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(store.devices.isEmpty)
                }
            }
            .navigationDestination(for: String.self) { key in
                // A view of its own per session: going from one to another by a link keeps nothing.
                SessionView(key: key).id(key)
            }
            .sheet(isPresented: $showingMacs) {
                DevicesView()
            }
            .sheet(isPresented: $showingNew) {
                NewSessionView(project: project.isEmpty ? nil : project)
            }
            // A session started here, or a link to one, opens once its Mac lists it.
            .onChange(of: store.sessions) { _, _ in openListed() }
            .onChange(of: store.openWhenListed) { _, _ in openListed() }
            .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button("OK", role: .cancel) { store.notice = nil }
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

    @ViewBuilder
    private var emptyState: some View {
        if store.devices.isEmpty {
            ContentUnavailableView {
                Label("Link a Mac", systemImage: "laptopcomputer.and.iphone")
            } description: {
                Text("Make a link code on your Mac in Codealong's Settings › Devices, then scan it or enter it here.")
            } actions: {
                Button("Link a Mac") { showingMacs = true }
                    .buttonStyle(.glassProminent)
            }
        } else if !query.isEmpty && sections.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if sections.isEmpty && !project.isEmpty {
            ContentUnavailableView {
                Label("All quiet in \(project)", systemImage: "checkmark.circle")
            } description: {
                Text("Nothing in it needs you, and nothing ran in the last three days.")
            } actions: {
                Button("Show all projects") { project = "" }
            }
        } else if sections.isEmpty {
            ContentUnavailableView("All quiet", systemImage: "checkmark.circle", description: Text("Nothing needs you, and nothing ran in the last three days."))
        }
    }

    /// The Macs button: a Mac that isn't connected, or dropped this phone, turns it orange.
    private var macsNeedAttention: Bool {
        store.devices.contains { !$0.online || !$0.linkedBack }
    }

    private var macsSymbol: String { "laptopcomputer" }

    private func openListed() {
        if let key = store.openWhenListed, store.sessions.contains(where: { $0.key == key }) {
            store.openWhenListed = nil
            path = [key]
        }
    }

    /// Connected Macs that don't have this phone on their list.
    private var forgotten: [DeviceRow] {
        store.devices.filter { $0.online && !$0.linkedBack }
    }

    /// The projects the list can narrow to, as the core lists them. One narrowed to stays while
    /// it has nothing to show, so the menu still says so.
    private var projects: [String] {
        project.isEmpty || store.projects.contains(project) ? store.projects : [project] + store.projects
    }

    private struct Group {
        let title: String
        let rows: [SessionRow]
    }

    private var sections: [Group] {
        let words = query.lowercased().split(separator: " ")
        let inProject = project.isEmpty ? store.sessions : store.sessions.filter { $0.project == project }
        let shown = words.isEmpty ? inProject : inProject.filter { row in
            let text = "\(row.title) \(row.project) \(row.repo) \(row.branch ?? "") \(row.deviceName) \(row.detail ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let buckets: [(String, (Status) -> Bool)] = [
            ("Needs you", { $0 == .needs || $0 == .error }),
            ("Your turn", { $0 == .unread }),
            ("Working", { $0 == .working }),
            ("Recent", { $0 == .idle || $0 == .stopped }),
        ]
        return buckets.compactMap { title, test in
            let rows = shown.filter { test($0.status) }
            return rows.isEmpty ? nil : Group(title: title, rows: rows)
        }
    }
}

/// How a Mac's name reads where space is short: without its owner ("Gordon’s MacBook Pro" is
/// "MacBook Pro"), since every Mac here is yours.
enum Names {
    static func short(_ name: String) -> String {
        for mark in ["’s ", "'s "] {
            if let r = name.range(of: mark), r.lowerBound > name.startIndex {
                let rest = name[r.upperBound...]
                if !rest.isEmpty { return String(rest) }
            }
        }
        return name
    }
}
