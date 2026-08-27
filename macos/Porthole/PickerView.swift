import SwiftUI

/// The machine picker: Porthole's home window (US-007). A card grid of
/// discovered and pinned machines with live-polling thumbnails; one click
/// opens a session and connects immediately.
struct PickerView: View {
    @EnvironmentObject private var store: MachineStore

    /// Auto-reconnect to the last session on launch (US-012 preview).
    @AppStorage("autoReconnect") private var autoReconnect = true

    @State private var manualHost = ""
    @State private var didAttemptAutoReconnect = false

    var body: some View {
        ZStack {
            // Dark base with a faint cool glow at the top edge.
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.12), .black],
                           startPoint: .top,
                           endPoint: .bottom)

            VStack(spacing: 0) {
                header
                    .padding(.top, 14)

                if store.cards.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 400),
                                            spacing: 20,
                                            alignment: .top)],
                                  spacing: 20) {
                            ForEach(store.cards) { card in
                                MachineCardView(card: card) {
                                    connect(to: card.machine)
                                }
                            }
                        }
                        .padding(24)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard autoReconnect, !didAttemptAutoReconnect,
                  let machine = MachineStore.lastSessionMachine() else { return }
            didAttemptAutoReconnect = true
            store.openSession(to: machine)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 1) {
                Text("Porthole")
                    .font(.headline)
                Text("Machines on your network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Auto-reconnect", isOn: $autoReconnect)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Reopen the last session on launch")
            TextField("Add by address (Tailscale)", text: $manualHost)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
                .onSubmit(addManual)
            Button("Add", action: addManual)
                .disabled(manualHost.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "display.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No machines found")
                .font(.title3)
            Text("Porthole agents announce themselves over mDNS.\n"
                 + "Off-LAN machines (Tailscale) can be added by address above.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private func addManual() {
        guard !manualHost.isEmpty else { return }
        let machine = store.addManual(host: manualHost)
        manualHost = ""
        connect(to: machine)
    }

    private func connect(to machine: Machine) {
        store.openSession(to: machine)
    }
}

/// One machine card: live thumbnail, name, address, caps, online state.
struct MachineCardView: View {
    let card: MachineStore.Card
    let onConnect: () -> Void

    @EnvironmentObject private var store: MachineStore
    @State private var hovering = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var editingAddress = false
    @State private var addressText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if !card.online {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.black.opacity(0.45))
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(card.online ? .green : .gray)
                        .frame(width: 7, height: 7)
                    Text(card.machine.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if !card.online {
                        Text("Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(card.machine.host)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !card.machine.capBadges.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(card.machine.capBadges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(hovering ? 0.25 : 0.08), lineWidth: 1)
        }
        .scaleEffect(hovering ? 1.015 : 1)
        .shadow(color: .black.opacity(hovering ? 0.5 : 0.3), radius: hovering ? 14 : 8, y: 4)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onConnect)
        .contextMenu {
            Button(card.isPinned ? "Unpin" : "Pin") {
                if card.isPinned {
                    store.unpin(id: card.id)
                } else {
                    store.pin(card.machine)
                }
            }
            Button("Rename...") {
                renameText = card.machine.name
                renaming = true
            }
            // Discovered machines get their address from mDNS; only manual
            // entries have one to edit (US-012).
            if card.machine.isManual {
                Button("Edit address...") {
                    addressText = card.machine.host
                    editingAddress = true
                }
            }
            Divider()
            Button("Remove", role: .destructive) {
                store.remove(id: card.id)
            }
        }
        .alert("Rename machine", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if !renameText.isEmpty {
                    store.rename(id: card.id, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit address", isPresented: $editingAddress) {
            TextField("Host or IP", text: $addressText)
            Button("Save") {
                if !addressText.isEmpty {
                    store.updateAddress(id: card.id, host: addressText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .opacity(card.online ? 1 : 0.75)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = card.thumbnail {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    Image(systemName: card.online ? "display" : "display.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(card.online ? "No preview yet" : "Offline")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
