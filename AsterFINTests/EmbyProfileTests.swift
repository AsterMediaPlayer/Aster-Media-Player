//
//  EmbyProfileTests.swift
//  AsterFINTests
//
//  Emby's fMP4 HLS fails (its HEVC stream is refused, its H.264 one freezes
//  or drifts), so Aster asks Emby for MPEG-TS only; Jellyfin keeps fMP4.
//

import Foundation
import Testing
@testable import AsterFIN

struct EmbyProfileTests {
    @Test func embyGetsMPEGTSOnly() {
        for profile in [DeviceProfile.appleTV(maxBitrate: 4_000_000), .appleTVMostCompatible(maxBitrate: 4_000_000)] {
            let emby = profile.withoutFragmentedMP4Streams()
            let video = emby.TranscodingProfiles.filter { $0.kind == "Video" }
            #expect(!video.isEmpty)
            #expect(video.allSatisfy { $0.Container == "ts" && $0.VideoCodec == "h264" })
            // Audio-only conversions are untouched.
            #expect(emby.TranscodingProfiles.contains { $0.kind == "Audio" })
        }
    }

    @Test func jellyfinKeepsFragmentedMP4First() {
        let profile = DeviceProfile.appleTV(maxBitrate: 4_000_000)
        #expect(profile.TranscodingProfiles.first?.Container == "mp4")
    }
}
