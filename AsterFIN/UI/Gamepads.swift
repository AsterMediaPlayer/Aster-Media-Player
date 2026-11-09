//
//  Gamepads.swift
//  AsterFIN
//
//  Game controllers on the Mac, as Aster Linux has them: each button is
//  turned into the key the app already answers, so a controller moves
//  through every page, the sidebar and the player the way the keyboard
//  does. The d-pad and left stick are the arrows (repeating while held),
//  A is Return, B is Esc (back), X and Menu are Space (pause), and the
//  shoulder buttons skip songs or a book's chapters. Settings can swap A
//  with B and X with Y, for Nintendo's layout. The Apple TV has its
//  own focus engine, which controllers already drive.
//

#if os(macOS)
import AppKit
import GameController

@MainActor
final class Gamepads {
    static let shared = Gamepads()

    private enum Direction { case up, down, left, right }

    /// The direction held on the d-pad or stick, and the repeat while it is.
    private var held: Direction?
    private var repeating: Task<Void, Never>?
    private var started = false

    /// A and B, and X and Y, trade places (Settings › Playback ›
    /// Controllers), read at each press so a change applies at once.
    nonisolated static var swapped: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.swapControllerButtonsKey)
    }

    /// Listens for controllers, those already connected and any that come.
    func start() {
        guard !started else { return }
        started = true
        GCController.shouldMonitorBackgroundEvents = false
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { Gamepads.shared.configure(controller) }
        }
        GCController.controllers().forEach(configure)
    }

    private func configure(_ controller: GCController) {
        controller.handlerQueue = .main
        guard let pad = controller.extendedGamepad else { return }
        pad.dpad.valueChangedHandler = { _, x, y in
            MainActor.assumeIsolated { Gamepads.shared.steer(x: x, y: y) }
        }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in
            MainActor.assumeIsolated { Gamepads.shared.steer(x: x, y: y) }
        }
        // GameController names the face buttons by place (A at the bottom,
        // B on the right, X on the left, Y at the top) on every make, so
        // swapping is a matter of which place does what.
        pad.buttonA.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { Gamepads.shared.press(Gamepads.swapped ? .escape : .returnKey) }
        }
        pad.buttonB.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { Gamepads.shared.press(Gamepads.swapped ? .returnKey : .escape) }
        }
        pad.buttonX.pressedChangedHandler = { _, _, pressed in
            guard pressed, !Gamepads.swapped else { return }
            MainActor.assumeIsolated { Gamepads.shared.press(.space) }
        }
        pad.buttonY.pressedChangedHandler = { _, _, pressed in
            guard pressed, Gamepads.swapped else { return }
            MainActor.assumeIsolated { Gamepads.shared.press(.space) }
        }
        pad.buttonMenu.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { Gamepads.shared.press(.space) }
        }
        pad.leftShoulder.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { Gamepads.shared.skipAudio(forward: false) }
        }
        pad.rightShoulder.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { Gamepads.shared.skipAudio(forward: true) }
        }
    }

    // MARK: Arrows

    /// The d-pad or stick moved: an arrow at once on a new direction, then
    /// again after 0.4 s and every 0.11 s while it's held, as on Linux. The
    /// stick counts past halfway, so resting slack doesn't move anything.
    private func steer(x: Float, y: Float) {
        let threshold: Float = 0.5
        let direction: Direction? = if abs(x) < threshold, abs(y) < threshold {
            nil
        } else if abs(x) > abs(y) {
            x > 0 ? .right : .left
        } else {
            y > 0 ? .up : .down
        }
        guard direction != held else { return }
        held = direction
        repeating?.cancel()
        guard let direction else { return }
        press(key(for: direction))
        repeating = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                guard let self, self.held == direction else { return }
                self.press(self.key(for: direction))
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func key(for direction: Direction) -> Key {
        switch direction {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }

    // MARK: Keys

    /// A key the app answers, as macOS describes it.
    private struct Key {
        let code: UInt16
        let characters: String
        var flags: NSEvent.ModifierFlags = []

        static let up = Key(code: 126, characters: Self.function(NSUpArrowFunctionKey), flags: [.function, .numericPad])
        static let down = Key(code: 125, characters: Self.function(NSDownArrowFunctionKey), flags: [.function, .numericPad])
        static let left = Key(code: 123, characters: Self.function(NSLeftArrowFunctionKey), flags: [.function, .numericPad])
        static let right = Key(code: 124, characters: Self.function(NSRightArrowFunctionKey), flags: [.function, .numericPad])
        static let returnKey = Key(code: 36, characters: "\r")
        static let escape = Key(code: 53, characters: "\u{1b}")
        static let space = Key(code: 49, characters: " ")

        private static func function(_ key: Int) -> String {
            UnicodeScalar(key).map { String(Character($0)) } ?? ""
        }
    }

    /// Posts the key to the app as if it were typed, so whatever answers
    /// the keyboard (a page, the sidebar, the player) answers it too. Only
    /// while Aster is the app in front.
    private func press(_ key: Key) {
        guard NSApp.isActive, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: key.flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: key.characters,
                charactersIgnoringModifiers: key.characters,
                isARepeat: false,
                keyCode: key.code
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    // MARK: Shoulders

    /// The previous or next song, or a book's chapter, whichever is loaded.
    private func skipAudio(forward: Bool) {
        guard NSApp.isActive else { return }
        let session = AppSession.shared
        if session.audiobooks.book != nil {
            forward ? session.audiobooks.nextChapter() : session.audiobooks.previousChapter()
        } else if session.music.current != nil {
            forward ? session.music.next() : session.music.previous()
        }
    }
}
#endif
