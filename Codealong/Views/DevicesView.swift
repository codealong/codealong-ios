import SwiftUI
import UIKit

/// Your linked Macs, and linking another with the code it shows.
struct DevicesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @AppStorage(Sounds.needsYouKey) private var needsYouSound = true
    @AppStorage(Sounds.yourTurnKey) private var yourTurnSound = true

    var body: some View {
        NavigationStack {
            Form {
                if !store.devices.isEmpty {
                    Section("Macs") {
                        ForEach(store.devices, id: \.key) { device in
                            DeviceRowView(device: device)
                                .swipeActions {
                                    Button("Unlink", role: .destructive) { store.unlink(device) }
                                }
                        }
                    }
                }
                Section {
                    TextField("Link code", text: $code, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Paste") { code = UIPasteboard.general.string ?? code }
                        Spacer()
                        if store.linking {
                            ProgressView()
                        } else {
                            Button("Link") {
                                Task {
                                    await store.link(code)
                                    if store.linkError == nil { code = "" }
                                }
                            }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .buttonStyle(.borderless)
                    if let error = store.linkError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                } header: {
                    Text("Link a Mac")
                } footer: {
                    Text("On the Mac, make a link code in Codealong's Settings › Devices, or run `codealong devices code`. It works once, for ten minutes.")
                }
                Section {
                    Toggle("A session needs you", isOn: $needsYouSound)
                    Toggle("A session’s turn ended", isOn: $yourTurnSound)
                } header: {
                    Text("Sounds")
                } footer: {
                    Text("While Codealong is open, a short sound when a session on one of your Macs starts to wait on you: a pop when it needs you, a lighter tink when its turn ends. None with the phone silenced.")
                }
                // Turned on, it plays, so you know what you'll hear.
                .onChange(of: needsYouSound) { _, on in if on { Sounds.play(.needsYou) } }
                .onChange(of: yourTurnSound) { _, on in if on { Sounds.play(.yourTurn) } }
                if let problem = store.problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ImproveButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct DeviceRowView: View {
    let device: DeviceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle()
                    .fill(device.online ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(device.name).font(.body.weight(.medium))
                Spacer()
                Text("\(device.sessions)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        var parts: [String] = []
        if device.online {
            parts.append(device.loading ? "Connected, still loading" : "Connected")
        } else if let seen = device.lastSeen {
            parts.append("Last seen \(Clock.ago(seen, now: .now)) ago")
        } else {
            parts.append("Not connected")
        }
        parts.append(device.remoteControl ? "remote control on" : "remote control off")
        if !device.linkedBack { parts.append("it forgot this phone") }
        return parts.joined(separator: " · ")
    }
}
