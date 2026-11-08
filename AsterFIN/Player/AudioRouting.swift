//
//  AudioRouting.swift
//  AsterFIN
//
//  Where sound goes on iPhone, iPad and Apple TV. Songs and audiobooks are
//  long-form audio: told so, the system offers AirPlay 2 speakers and
//  groups (a Sonos room, a HomePod pair) in the route picker, keeps playing
//  there with the phone locked, and hands the stream to the speaker rather
//  than mirroring it. Videos are told apart, so their AirPlay stays the
//  video kind. The AirPlay button itself is the system's.
//

import AVFoundation
import AVKit
import SwiftUI
import Synchronization

#if !os(macOS)
/// What the shared audio session is set up for before it's activated.
nonisolated enum AudioSessionUse: Sendable {
    /// A song or an audiobook.
    case longFormAudio
    /// A video, with its sound.
    case video

    /// Sets the session's category, mode and route-sharing policy for this
    /// use, once per change (setting it again is harmless but not free).
    static func prepare(_ use: AudioSessionUse) {
        guard current.withLock({ last in
            if last == use { return false }
            last = use
            return true
        }) else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            switch use {
            case .longFormAudio:
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            case .video:
                try session.setCategory(.playback, mode: .moviePlayback, policy: .default)
            }
        } catch {
            #if DEBUG
            print("DEBUG audio: session couldn't be set up for \(use): \(error)")
            #endif
            current.withLock { $0 = nil }
        }
    }

    private static let current = Mutex<AudioSessionUse?>(nil)
}
#endif

#if os(iOS)
/// The system's AirPlay button, for the players' control rows: a
/// `PlayerControl`-sized circle holding the route picker, which lists
/// speakers for audio and screens too for video.
struct AirPlayControl: View {
    var forVideo = false
    var size: CGFloat = 46
    var iconSize: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.3))
            AirPlayRoutePicker(forVideo: forVideo)
                .frame(width: iconSize + 8, height: iconSize + 8)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("AirPlay")
    }
}

struct AirPlayRoutePicker: UIViewRepresentable {
    var forVideo = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = forVideo
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.prioritizesVideoDevices = forVideo
    }
}
#endif
