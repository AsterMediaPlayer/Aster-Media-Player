//
//  ChannelDial.swift
//  AsterFIN
//
//  Changing channel on iPhone and iPad: a ridged dial on the right edge of
//  the picture, like the tuning wheel on an old set. Drag it up or down and
//  it clicks through the channels, a tick (felt, and heard unless the
//  phone is on silent) at each one, with the channel's number and what's
//  on beside it; flick it and it spins on, slowing down. Let go and it
//  tunes, with a firmer thunk, and slides away: it's only out while
//  tuning, or for a moment after the screen's touched, with the controls.
//  The Apple TV has its own row of channels instead (`ChannelFlickBar`);
//  both go through `ChannelFlickModel`.
//

import CoreGraphics

/// The dial's arithmetic, kept apart so it can be tested.
nonisolated enum ChannelDialMath {
    /// Drag needed to pass one channel.
    static let detent: CGFloat = 40
    /// Most channels a flick spins on by, past where the finger let go.
    static let flingCap = 8
    /// How fast (points a second) a finger must be moving as it lets go to
    /// spin the dial on: slower, and lifting it doesn't add a channel.
    static let flingSpeed: CGFloat = 900
    /// How long the dial waits, still, before tuning: time to lift the
    /// finger and take another turn when the wheel runs out.
    static let settleMilliseconds = 1000

    /// Channels passed by a drag of `translation` points: up (a negative
    /// translation) is towards higher numbers, as with CH+.
    static func steps(from translation: CGFloat, spacing: CGFloat = detent) -> Int {
        guard spacing > 0 else { return 0 }
        return Int((-translation / spacing).rounded(.towardZero))
    }

    /// How many more channels a flick carries on by: the drag's predicted
    /// end beyond its actual one, at most `cap` either way; none unless the
    /// finger was really flicking.
    static func flingSteps(predicted: CGFloat, actual: CGFloat, velocity: CGFloat, spacing: CGFloat = detent, cap: Int = flingCap) -> Int {
        guard abs(velocity) >= flingSpeed else { return 0 }
        let extra = steps(from: predicted, spacing: spacing) - steps(from: actual, spacing: spacing)
        return min(max(extra, -cap), cap)
    }

    /// The pause before each of a flick's `count` steps, in milliseconds:
    /// quick at first, slowing to a stop.
    static func flingDelays(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return (0 ..< count).map { index in
            let progress = count == 1 ? 1 : Double(index) / Double(count - 1)
            return 40 + Int((progress * progress * 100).rounded())
        }
    }
}

#if os(iOS) && canImport(AetherEngine)
import AudioToolbox
import SwiftUI

/// The dial and the card beside it, over the right side of the picture.
/// It slides out with the player's controls, after a touch on the screen,
/// and stays out while it's turning; once a channel's tuned it slides away,
/// with the controls.
struct ChannelDialOverlay: View {
    let playback: AetherPlayback
    let model: ChannelFlickModel
    /// The player's controls are up (the screen's just been touched).
    var controlsShown: Bool
    /// Called while the dial is in use, so the controls stay up.
    var onActivity: () -> Void
    /// Called once a channel's tuned: the controls go, and the dial with them.
    var onTuned: () -> Void

    /// A finger is on the dial.
    @State private var isHeld = false
    /// Channels already moved by the drag under way.
    @State private var appliedSteps = 0
    /// Where the ridges have turned to, in points.
    @State private var turned: CGFloat = 0
    @State private var turnedAtDragStart: CGFloat = 0
    @State private var spinTask: Task<Void, Never>?
    @State private var tuneTask: Task<Void, Never>?
    /// Let go, and about to tune.
    @State private var tunePending = false
    /// Bumped at each channel passed, and at each tune, for the haptics.
    @State private var ticks = 0
    @State private var tunes = 0

    private var isSpinning: Bool { spinTask != nil }
    private var isTuning: Bool { isHeld || isSpinning || tunePending }
    private var isOut: Bool { isTuning || controlsShown }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if isTuning, let channel = model.selectedChannel {
                ChannelDialCard(model: model, channel: channel, isPlaying: channel.id == playingId)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            wheel
        }
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.spring(duration: 0.3), value: isTuning)
        .animation(.spring(duration: 0.35), value: isOut)
        .sensoryFeedback(.selection, trigger: ticks)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: tunes)
        .onDisappear {
            spinTask?.cancel()
            tuneTask?.cancel()
        }
    }

    private var wheel: some View {
        ChannelDialWheel(turned: turned, isHeld: isHeld)
            .frame(width: 46)
            .containerRelativeFrame(.vertical) { height, _ in height * 0.6 }
            .contentShape(Rectangle().inset(by: -10))
            .gesture(drag)
            // Tucked away past the edge until the screen's touched.
            .offset(x: isOut ? 0 : 90)
            .opacity(isOut ? (isTuning ? 1 : 0.85) : 0)
            .allowsHitTesting(isOut)
            .accessibilityElement()
            .accessibilityLabel("Channel dial")
            .accessibilityValue(spokenChannel)
            .accessibilityAdjustableAction { direction in
                step(direction == .increment ? 1 : -1)
                scheduleTune()
            }
    }

    /// "12 Anime Nights", for VoiceOver.
    private var spokenChannel: String {
        guard let channel = model.selectedChannel else { return "" }
        return [channel.number, channel.name].compactMap { $0 }.joined(separator: " ")
    }

    /// The channel playing, or being tuned to: going back to the one still
    /// on screen while another's being tuned drops that tune.
    private var playingId: String { model.currentId }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isHeld {
                    isHeld = true
                    appliedSteps = 0
                    turnedAtDragStart = turned
                    spinTask?.cancel()
                    spinTask = nil
                    tuneTask?.cancel()
                    tunePending = false
                }
                onActivity()
                turned = turnedAtDragStart + value.translation.height
                let steps = ChannelDialMath.steps(from: value.translation.height)
                while appliedSteps != steps {
                    let direction = steps > appliedSteps ? 1 : -1
                    appliedSteps += direction
                    step(direction, turnsRidges: false)
                }
            }
            .onEnded { value in
                isHeld = false
                onActivity()
                // The ridges settle into the detent of the channel picked, so
                // what's shown is what tunes.
                withAnimation(.spring(duration: 0.2)) {
                    turned = turnedAtDragStart - CGFloat(appliedSteps) * ChannelDialMath.detent
                }
                let extra = ChannelDialMath.flingSteps(
                    predicted: value.predictedEndTranslation.height,
                    actual: value.translation.height,
                    velocity: value.velocity.height
                )
                spin(extra)
            }
    }

    /// One channel along, with its tick.
    private func step(_ direction: Int, turnsRidges: Bool = true) {
        model.move(by: direction)
        ticks += 1
        DialSounds.shared.tick()
        if turnsRidges {
            withAnimation(.easeOut(duration: 0.1)) { turned -= CGFloat(direction) * ChannelDialMath.detent }
        }
    }

    /// A flick carries on by `count` channels, slowing down, then tunes.
    private func spin(_ count: Int) {
        guard count != 0 else {
            scheduleTune()
            return
        }
        let direction = count > 0 ? 1 : -1
        spinTask = Task {
            for delay in ChannelDialMath.flingDelays(count: abs(count)) {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                step(direction)
            }
            spinTask = nil
            scheduleTune()
        }
    }

    /// Tunes once the dial's been still a second, so lifting the finger to
    /// take another turn (the wheel's run out) doesn't tune what it passed;
    /// the dial and card stay out meanwhile.
    private func scheduleTune() {
        tuneTask?.cancel()
        tunePending = true
        tuneTask = Task {
            try? await Task.sleep(for: .milliseconds(ChannelDialMath.settleMilliseconds))
            guard !Task.isCancelled, !isHeld else { return }
            tune()
        }
    }

    private func tune() {
        tunePending = false
        // Back where it started: nothing to change, and the dial stays out
        // with the controls.
        guard let picked = model.selectedChannel, picked.id != playingId else { return }
        playback.switchChannel(to: picked.id)
        model.playing(picked.id)
        tunes += 1
        DialSounds.shared.clunk()
        onTuned()
    }
}

/// The wheel: a drum of ridges that turns with the finger, bunching and
/// darkening towards its ends as a cylinder's do.
struct ChannelDialWheel: View, Animatable {
    var turned: CGFloat
    var isHeld: Bool

    var animatableData: CGFloat {
        get { turned }
        set { turned = newValue }
    }

    /// Between ridges, along the drum's surface.
    private static let ridgeSpacing: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            let radius = size.height / 2
            let centre = size.height / 2
            let angleStep = Self.ridgeSpacing / radius
            let phase = (turned / radius).truncatingRemainder(dividingBy: angleStep)
            let count = Int((.pi / 2) / angleStep) + 1
            for index in -count ... count {
                let angle = CGFloat(index) * angleStep + phase
                guard abs(angle) < .pi / 2 else { continue }
                let facing = cos(angle)
                let y = centre + radius * sin(angle)
                let thickness = max(0.6, 2.6 * facing)
                let inset = size.width * (0.18 + 0.12 * (1 - facing))
                let ridge = CGRect(x: inset, y: y - thickness / 2, width: size.width - inset * 2, height: thickness)
                context.fill(Path(roundedRect: ridge, cornerRadius: thickness / 2), with: .color(.white.opacity(0.15 + 0.6 * facing * facing)))
            }
            // The notch at the middle marks the channel picked.
            var notch = Path()
            notch.move(to: CGPoint(x: 0, y: centre - 6))
            notch.addLine(to: CGPoint(x: 7, y: centre))
            notch.addLine(to: CGPoint(x: 0, y: centre + 6))
            notch.closeSubpath()
            context.fill(notch, with: .color(.accentColor))
        }
        .background {
            Capsule()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.85), location: 0),
                            .init(color: Color(white: 0.22).opacity(0.85), location: 0.5),
                            .init(color: .black.opacity(0.85), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(Capsule().strokeBorder(.white.opacity(isHeld ? 0.35 : 0.15), lineWidth: 1))
        }
        .clipShape(Capsule())
        .scaleEffect(isHeld ? 1.06 : 1)
        .animation(.spring(duration: 0.25), value: isHeld)
    }
}

/// The channel the dial's on: a big number, the channel, and what's on,
/// with the ones either side faded above and below, as on a drum.
private struct ChannelDialCard: View {
    let model: ChannelFlickModel
    let channel: FlickChannel
    var isPlaying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            neighbour(model.neighbour(1))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let number = channel.number {
                        Text(number)
                            .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name)
                            .font(.headline)
                            .lineLimit(1)
                        if isPlaying {
                            Text("Watching")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    Spacer(minLength: 0)
                    if let logo = channel.logoURL ?? channel.bugURL {
                        RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                            .frame(width: 56, height: 32)
                    }
                }
                if let program = channel.now {
                    ChannelProgramLines(program: program)
                }
            }
            .padding(16)
            .frame(width: 320, alignment: .leading)
            .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 22))
            neighbour(model.neighbour(-1))
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.15), value: channel.id)
    }

    @ViewBuilder
    private func neighbour(_ channel: FlickChannel?) -> some View {
        if let channel, channel.id != self.channel.id {
            HStack(spacing: 8) {
                if let number = channel.number {
                    Text(number)
                        .font(.callout.weight(.bold).monospacedDigit())
                }
                Text(channel.name)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .opacity(0.55)
            .frame(width: 320, alignment: .leading)
        }
    }
}

/// What's on a channel: its title, the episode, and how far through it is.
struct ChannelProgramLines: View {
    let program: FlickProgram

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(program.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = program.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let progress = program.progress(at: context.date) {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .tint(.white)
                        if let left = program.timeLeft(at: context.date) {
                            Text(left)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }
}

/// The dial's clicks: a short tick per channel and a lower clunk on tuning.
/// Played as system sounds, which the silent switch mutes even while a
/// channel's sound plays.
@MainActor
final class DialSounds {
    static let shared = DialSounds()

    private var tickSound: SystemSoundID = 0
    private var clunkSound: SystemSoundID = 0
    private var lastTick = Date.distantPast

    private init() {
        tickSound = Self.register("dial-tick", samples: Self.tickSamples())
        clunkSound = Self.register("dial-clunk", samples: Self.clunkSamples())
    }

    func tick() {
        // A fast flick would run the ticks together.
        guard Date().timeIntervalSince(lastTick) > 0.03, tickSound != 0 else { return }
        lastTick = Date()
        AudioServicesPlaySystemSound(tickSound)
    }

    func clunk() {
        if clunkSound != 0 { AudioServicesPlaySystemSound(clunkSound) }
    }

    private static let sampleRate = 44_100.0

    /// 12 ms of bright noise, dying away fast: a detent's click.
    private static func tickSamples() -> [Float] {
        var generator = SystemRandomNumberGenerator()
        let count = Int(sampleRate * 0.012)
        var previous: Float = 0
        return (0 ..< count).map { index in
            let noise = Float.random(in: -1 ... 1, using: &generator)
            // The difference from the last sample keeps only the top end.
            let bright = noise - previous
            previous = noise
            let envelope = Float(exp(-Double(index) / (sampleRate * 0.0025)))
            return bright * envelope * 0.22
        }
    }

    /// 60 ms of a low knock with a little noise: the thunk of tuning.
    private static func clunkSamples() -> [Float] {
        var generator = SystemRandomNumberGenerator()
        let count = Int(sampleRate * 0.06)
        return (0 ..< count).map { index in
            let time = Double(index) / sampleRate
            let knock = sin(2 * .pi * 120 * time) * 0.8 + sin(2 * .pi * 310 * time) * 0.25
            let noise = Double.random(in: -1 ... 1, using: &generator) * 0.15
            let envelope = exp(-time / 0.012)
            return Float((knock + noise) * envelope * 0.4)
        }
    }

    /// Writes `samples` as a 16-bit mono WAV in Caches and registers it.
    private static func register(_ name: String, samples: [Float]) -> SystemSoundID {
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let url = folder.appendingPathComponent("\(name).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? wav(samples).write(to: url, options: .atomic)
        }
        var sound: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr ? sound : 0
    }

    private static func wav(_ samples: [Float]) -> Data {
        let rate = UInt32(sampleRate)
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
#endif
