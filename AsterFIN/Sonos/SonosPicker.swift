//
//  SonosPicker.swift
//  AsterFIN
//
//  Play On: this device or a Sonos room, for the music or audiobook player,
//  with the room's volume once one's playing.
//

#if os(iOS)
import SwiftUI
import UIKit

/// Which player the picker sends to a room.
enum SonosTarget {
    case music, audiobook
}

/// The players' Sonos button: lit while a room is playing.
struct SonosControl: View {
    let target: SonosTarget
    var size: CGFloat = 46

    @Environment(AppSession.self) private var session
    @State private var picking = false

    private var room: SonosGroup? {
        target == .music ? session.music.sonosRoom : session.audiobooks.sonosRoom
    }

    var body: some View {
        Button {
            picking = true
        } label: {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(room == nil ? Color.white : Color.black)
                .frame(width: size, height: size)
                .background(Circle().fill(room == nil ? Color(white: 0.3) : Color.white))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(room.map { "Playing on \($0.name)" } ?? "Play on Sonos")
        .sheet(isPresented: $picking) {
            SonosPicker(target: target)
                .presentationDetents([.medium, .large])
        }
    }
}

/// "Playing on Living Room" under the controls, while a room is.
struct SonosPlayingLabel: View {
    let target: SonosTarget
    @Environment(AppSession.self) private var session

    var body: some View {
        let room = target == .music ? session.music.sonosRoom : session.audiobooks.sonosRoom
        if let room {
            Label("Playing on \(room.name)", systemImage: "hifispeaker.2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct SonosPicker: View {
    let target: SonosTarget

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    private let rooms = SonosRooms.shared

    private var active: SonosGroup? {
        target == .music ? session.music.sonosRoom : session.audiobooks.sonosRoom
    }

    private var thisDevice: (name: String, image: String) {
        UIDevice.current.userInterfaceIdiom == .pad ? ("This iPad", "ipad") : ("This iPhone", "iphone")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(thisDevice.name, systemImage: thisDevice.image, chosen: active == nil) { choose(nil) }
                }
                Section {
                    if rooms.groups.isEmpty {
                        HStack(spacing: 12) {
                            if rooms.isSearching { ProgressView() }
                            Text(rooms.isSearching ? "Looking for Sonos speakers…" : "No Sonos speakers found")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rooms.groups) { group in
                        row(group.name, systemImage: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill",
                            chosen: group.id == active?.id) { choose(group) }
                    }
                } header: {
                    Text("Sonos")
                } footer: {
                    Text("Sonos rooms on this Wi-Fi network play straight from your server, so they keep playing with this device locked or away. The speaker must be able to reach the server's address. Group rooms in the Sonos app.")
                }
                if let active {
                    Section("Volume") {
                        if let level = rooms.volume {
                            HStack {
                                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                                Slider(value: Binding(get: { level }, set: { rooms.setVolume($0, of: active) }), in: 0 ... 100)
                                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Volume of \(active.name)")
                        } else {
                            ProgressView()
                        }
                    }
                    .task(id: active.id) { rooms.readVolume(of: active) }
                }
            }
            .navigationTitle("Play On")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { rooms.startSearching() }
        .onDisappear { rooms.stopSearching() }
    }

    private func row(_ title: String, systemImage: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                if chosen {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func choose(_ group: SonosGroup?) {
        switch target {
        case .music: session.music.play(on: group)
        case .audiobook: session.audiobooks.play(on: group)
        }
    }
}
#endif
