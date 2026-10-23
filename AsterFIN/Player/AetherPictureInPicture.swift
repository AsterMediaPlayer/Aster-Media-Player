//
//  AetherPictureInPicture.swift
//  AsterFIN
//
//  Picture in Picture for the app's own player on iPhone and iPad: a video
//  playing when the app leaves the screen carries on in a floating window.
//  Built around whichever picture the engine has: AVPlayer's layer, or the
//  software path's sample-buffer layer. A channel's window has no skipping,
//  as it keeps to its schedule.
//

#if canImport(AetherEngine) && os(iOS)
import AetherEngine
import AVKit
import Combine

@MainActor
final class AetherPictureInPicture: NSObject {
    /// The engine whose picture the window shows.
    let engine: AetherEngine
    private var controller: AVPictureInPictureController?
    private var cancellables: Set<AnyCancellable> = []

    /// Playing on a timeline the viewer can't move (a channel): the window
    /// offers no skipping.
    var followsTimeline: Bool {
        didSet { controller?.requiresLinearPlayback = followsTimeline }
    }

    init(engine: AetherEngine, followsTimeline: Bool) {
        self.engine = engine
        self.followsTimeline = followsTimeline
        super.init()
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // A new player or route: the window follows it. @Published tells
        // before the value is stored, so it's read on the next turn of the
        // main queue, once the engine has finished the change.
        Publishers.CombineLatest(engine.$currentAVPlayer, engine.$softwarePiPSource)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.rebuild() }
            .store(in: &cancellables)
        // The software window asks whether it's paused; it's told to ask again.
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.engine.softwarePiPSource != nil else { return }
                self.controller?.invalidatePlaybackState()
            }
            .store(in: &cancellables)
    }

    /// The player is closing, or another engine is taking over: any window
    /// goes with it.
    func stop() {
        cancellables.removeAll()
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller = nil
        engine.pictureInPictureActive = false
    }

    private func rebuild() {
        // An open window keeps what it has: the engine hands the next item
        // over in place while it's open.
        guard controller?.isPictureInPictureActive != true else { return }
        let source: AVPictureInPictureController.ContentSource
        if let software = engine.softwarePiPSource {
            source = .init(sampleBufferDisplayLayer: software.layer, playbackDelegate: self)
        } else if let layer = engine.nativePlayerLayer {
            source = .init(playerLayer: layer)
        } else {
            controller = nil
            return
        }
        if let controller {
            controller.contentSource = source
        } else {
            let made = AVPictureInPictureController(contentSource: source)
            made.delegate = self
            controller = made
        }
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        controller?.requiresLinearPlayback = followsTimeline
    }
}

extension AetherPictureInPicture: @preconcurrency AVPictureInPictureControllerDelegate {
    // Set on "will start", ahead of the app's background notification, so
    // the engine keeps the video rather than letting it go.
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        engine.pictureInPictureActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        engine.pictureInPictureActive = false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        #if DEBUG
        print("DEBUG pip: didn't start: \(error)")
        #endif
        engine.pictureInPictureActive = false
    }

    // The full player is still there under the window, so there's nothing
    // to put back.
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension AetherPictureInPicture: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        engine.softwarePiPSource?.setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        engine.softwarePiPSource?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        engine.softwarePiPSource?.isPaused ?? true
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        if !followsTimeline { engine.softwarePiPSource?.skip(by: skipInterval.seconds) }
        completionHandler()
    }
}
#endif
