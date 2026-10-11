//
//  DiscMenuAudio.swift
//  AsterFIN
//
//  Menu music and button sounds (CLIENT_GUIDE §5.5): looping music with
//  volume fades, and the click / chime / beep presets synthesised exactly as
//  the reference renderer does, or sound files a menu ships with.
//

import AVFoundation
import Foundation

@Observable
final class DiscMenuAudio {
    enum SoundKind { case move, select, back }

    var enabled = true

    private var musicPlayer: AVQueuePlayer?
    private var musicLooper: AVPlayerLooper?
    private var musicKey: String?
    private var musicVolume: Float = 0.5
    private var fadeTask: Task<Void, Never>?

    private var sounds: DiscSounds?
    private var soundFiles: [SoundKind: URL] = [:]
    private var filePlayers: [URL: AVAudioPlayer] = [:]
    private var lastMove = Date.distantPast
    private let synth = DiscToneSynth()
    private var suspended = false

    // MARK: Screen changes

    func apply(_ audio: DiscAudio?, document: DiscMenuDocument, client: JellyfinClient) {
        guard enabled else { return }
        let resolver = DiscPictureResolver(client: client, itemId: "")
        sounds = audio?.sounds
        soundFiles = [:]
        if let spec = audio?.sounds {
            if let url = resolver.url(forAudio: spec.move) { soundFiles[.move] = url }
            if let url = resolver.url(forAudio: spec.select) { soundFiles[.select] = url }
            if let url = resolver.url(forAudio: spec.back) { soundFiles[.back] = url }
            for url in soundFiles.values { preloadFile(url, client: client) }
        }

        var url: URL?
        if let music = audio?.music {
            switch music.source {
            case "file":
                url = resolver.url(forAudio: music.file)
            case "themeSong":
                if let first = document.themeSongs?.first {
                    url = client.audioStreamURL(itemId: first)
                }
            default:
                url = nil
            }
        }
        let volume = Float(DiscMenuRules.clamp(audio?.music?.volume, 0...1, default: 0.5))
        setMusic(url: url, volume: volume)
    }

    private func setMusic(url: URL?, volume: Float) {
        let key = url?.absoluteString
        if key == musicKey {
            // Same track: just fade to the new volume.
            if let musicPlayer, musicVolume != volume {
                musicVolume = volume
                fade(musicPlayer, to: volume, over: 0.4)
            }
            return
        }
        if let old = musicPlayer {
            let fading = old
            fade(fading, to: 0, over: 0.6) {
                fading.pause()
                fading.removeAllItems()
            }
        }
        musicKey = key
        musicVolume = volume
        musicLooper = nil
        musicPlayer = nil
        guard let url else { return }
        let player = AVQueuePlayer()
        player.volume = 0
        musicLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        musicPlayer = player
        if !suspended {
            player.play()
            fade(player, to: volume, over: 0.8)
        }
    }

    private func fade(_ player: AVQueuePlayer, to target: Float, over seconds: Double, completion: (() -> Void)? = nil) {
        let start = player.volume
        let steps = max(1, Int(seconds * 30))
        Task { @MainActor in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000) / steps))
                player.volume = start + (target - start) * Float(step) / Float(steps)
            }
            player.volume = target
            completion?()
        }
    }

    func suspend() {
        suspended = true
        if let musicPlayer {
            fade(musicPlayer, to: 0, over: 0.4) { musicPlayer.pause() }
        }
    }

    func resume() {
        suspended = false
        if let musicPlayer {
            musicPlayer.play()
            fade(musicPlayer, to: musicVolume, over: 0.8)
        }
    }

    func stop() {
        if let musicPlayer {
            let player = musicPlayer
            fade(player, to: 0, over: 0.4) {
                player.pause()
                player.removeAllItems()
            }
        }
        musicPlayer = nil
        musicLooper = nil
        musicKey = nil
        synth.stop()
    }

    // MARK: Button sounds

    func play(_ kind: SoundKind) {
        guard enabled, let sounds else { return }
        if kind == .move {
            let now = Date()
            if now.timeIntervalSince(lastMove) < 0.045 { return }
            lastMove = now
        }
        let volume = Float(DiscMenuRules.clamp(sounds.volume, 0...1, default: 0.5))
        if let url = soundFiles[kind], let player = filePlayers[url] {
            player.volume = volume
            player.currentTime = 0
            player.play()
            return
        }
        guard let preset = DiscToneSynth.Preset(rawValue: sounds.preset ?? "none") else { return }
        synth.play(preset: preset, kind: kind, volume: volume)
    }

    private func preloadFile(_ url: URL, client: JellyfinClient) {
        guard filePlayers[url] == nil else { return }
        Task {
            guard let data = try? await client.data(from: url), let player = try? AVAudioPlayer(data: data) else { return }
            player.prepareToPlay()
            filePlayers[url] = player
        }
    }
}

// MARK: - Tone synthesis

/// Renders the reference renderer's WebAudio presets as PCM buffers and plays
/// them through an AVAudioEngine.
final class DiscToneSynth {
    enum Preset: String { case none, click, chime, beep }
    enum Wave { case sine, square }

    struct Tone {
        var frequency: Double
        var wave: Wave
        var duration: Double
        var gain: Double
        var start: Double = 0
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var started = false

    private var connected = false

    private func ensureRunning() -> Bool {
        if !connected {
            engine.attach(node)
            do {
                try engine.connectNode(node, to: engine.mainMixerNode, format: format)
                connected = true
            } catch {
                return false
            }
        }
        if !started {
            engine.prepare()
            do {
                try engine.start()
                started = true
            } catch {
                return false
            }
        }
        if !node.isPlaying {
            do {
                try node.playAudio()
            } catch {
                return false
            }
        }
        return true
    }

    func stop() {
        node.stop()
        if started { engine.stop() }
        started = false
    }

    static func tones(preset: Preset, kind: DiscMenuAudio.SoundKind) -> [Tone] {
        switch (preset, kind) {
        case (.click, .move): return [Tone(frequency: 1500, wave: .square, duration: 0.025, gain: 0.5)]
        case (.click, .select): return [Tone(frequency: 1100, wave: .square, duration: 0.04, gain: 0.6), Tone(frequency: 700, wave: .square, duration: 0.05, gain: 0.5, start: 0.04)]
        case (.click, .back): return [Tone(frequency: 600, wave: .square, duration: 0.05, gain: 0.6)]
        case (.chime, .move): return [Tone(frequency: 1320, wave: .sine, duration: 0.12, gain: 0.4)]
        case (.chime, .select): return [Tone(frequency: 880, wave: .sine, duration: 0.2, gain: 0.6), Tone(frequency: 1320, wave: .sine, duration: 0.3, gain: 0.5, start: 0.08)]
        case (.chime, .back): return [Tone(frequency: 660, wave: .sine, duration: 0.2, gain: 0.5), Tone(frequency: 440, wave: .sine, duration: 0.25, gain: 0.5, start: 0.08)]
        case (.beep, .move): return [Tone(frequency: 880, wave: .sine, duration: 0.04, gain: 0.5)]
        case (.beep, .select): return [Tone(frequency: 1040, wave: .sine, duration: 0.09, gain: 0.6)]
        case (.beep, .back): return [Tone(frequency: 520, wave: .sine, duration: 0.09, gain: 0.6)]
        case (.none, _): return []
        }
    }

    func play(preset: Preset, kind: DiscMenuAudio.SoundKind, volume: Float) {
        let tones = Self.tones(preset: preset, kind: kind)
        guard !tones.isEmpty, ensureRunning() else { return }
        let key = "\(preset.rawValue)-\(kind)-\(volume)"
        let buffer: AVAudioPCMBuffer
        if let cached = cache[key] {
            buffer = cached
        } else {
            guard let rendered = render(tones, volume: Double(volume)) else { return }
            cache[key] = rendered
            buffer = rendered
        }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    /// Each tone ramps exponentially from 0.0001 to max(0.0002, volume × gain × 0.3)
    /// over its first 5 ms, then back down to 0.0001 by its end.
    private func render(_ tones: [Tone], volume: Double) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = tones.map { $0.start + $0.duration }.max() ?? 0
        let frames = AVAudioFrameCount(max(1, Int(total * rate) + 64))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { channel[i] = 0 }
        for tone in tones {
            let peak = max(0.0002, volume * tone.gain * 0.3)
            let startFrame = Int(tone.start * rate)
            let count = Int(tone.duration * rate)
            let attack = max(1, Int(0.005 * rate))
            for i in 0..<count {
                let t = Double(i) / rate
                let envelope: Double
                if i < attack {
                    envelope = 0.0001 * pow(peak / 0.0001, Double(i) / Double(attack))
                } else {
                    let progress = Double(i - attack) / Double(max(1, count - attack))
                    envelope = peak * pow(0.0001 / peak, progress)
                }
                let phase = sin(2 * Double.pi * tone.frequency * t)
                let sample = tone.wave == .sine ? phase : (phase >= 0 ? 1.0 : -1.0)
                let index = startFrame + i
                if index < Int(frames) {
                    channel[index] += Float(sample * envelope)
                }
            }
        }
        return buffer
    }
}
