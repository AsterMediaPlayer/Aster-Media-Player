//
//  PlexClient+Playback.swift
//  AsterFIN
//
//  Playing from Plex, answered in the shapes the players were written for:
//  the file (Plex's "part") as the source that plays as it is, and Plex's
//  universal transcoder as the converted stream. Progress goes to Plex's
//  timeline, which also keeps the resume point and marks what's finished
//  as watched.
//

import Foundation

nonisolated extension PlexClient {
    /// The item's file and tracks, and the transcoder's stream for when it
    /// isn't played as it is.
    func playbackInfo(_ request: PlaybackInfoRequest) async throws -> PlaybackInfoResponse {
        guard let metadata = try await metadata(request.itemId),
              let media = metadata.media?.first, let part = media.part?.first else {
            throw PlexError.http(404)
        }
        let session = UUID().uuidString
        let streams = part.stream ?? []
        let container = (part.container ?? media.container ?? "").lowercased()
        let direct = request.allowDirect && !request.mostCompatible

        // The transcoder plays the part's selected tracks: choose them first
        // when it will be used (Plex's own apps do the same, which also
        // makes them the title's default on the server).
        let burnIn = request.subtitleStreamIndex.flatMap { index in
            streams.first { $0.streamType == 3 && $0.index == index && !Self.isFetchableText($0) }
        }
        let willConvert = !direct || !["mp4", "m4v", "mov"].contains(container)
        if willConvert, request.audioStreamIndex != nil || request.subtitleStreamIndex != nil {
            let audio = request.audioStreamIndex.flatMap { index in streams.first { $0.streamType == 2 && $0.index == index } }
            var query: [String: String?] = ["subtitleStreamID": burnIn.map { String($0.id) } ?? "0"]
            if let audio { query["audioStreamID"] = String(audio.id) }
            _ = try? await send(url("/library/parts/\(part.id)", query: query), method: "PUT")
        }

        var source = MediaSourceInfo(id: String(part.id))
        source.container = container
        source.runTimeTicks = (part.duration ?? media.duration).map { Int64($0) * PlexMapper.ticksPerMillisecond }
        source.bitrate = media.bitrate.map { $0 * 1000 }
        source.size = part.size.map(Int64.init)
        source.supportsDirectPlay = direct
        source.supportsDirectStream = direct
        source.supportsTranscoding = true
        source.mediaStreams = streams.map(Self.playbackStream)
        source.defaultAudioStreamIndex = (streams.first { $0.streamType == 2 && $0.default == true } ?? streams.first { $0.streamType == 2 })?.index
        let transcode = transcodeQuery(
            itemId: request.itemId, session: session, startTicks: request.startTicks, maxBitrate: request.maxBitrate,
            keepsSurround: !request.allowDirect && !request.mostCompatible, mostCompatible: request.mostCompatible,
            burnIn: burnIn?.index
        )
        // Plex refuses to start a conversion ("session lacking decision")
        // unless the same session first asked for its decision, with the
        // same settings, as Plex's own apps do.
        if willConvert {
            _ = try? await send(url("/video/:/transcode/universal/decision", query: transcode))
        }
        source.transcodingUrl = url("/video/:/transcode/universal/start.m3u8", query: transcode).absoluteString
        source.transcodingContainer = "ts"
        source.transcodingSubProtocol = "hls"
        return PlaybackInfoResponse(mediaSources: [source], playSessionId: session, errorCode: nil)
    }

    /// The part's file, with the token in the address (players can't send
    /// headers).
    func directStreamURL(itemId: String, mediaSourceId: String, playSessionId: String?, container: String?) -> URL {
        url("/library/parts/\(mediaSourceId)/file", query: [
            "X-Plex-Token": accessToken,
            "X-Plex-Client-Identifier": PlexDevice.clientIdentifier,
            "X-Plex-Session-Identifier": playSessionId,
        ])
    }

    func absoluteURL(serverRelative path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    func reportStart(_ report: PlaybackReport) async {
        await timeline(report, state: report.isPaused ? "paused" : "playing")
    }

    func reportProgress(_ report: PlaybackReport, resumePoint: ResumePoints.Saving) async {
        await timeline(report, state: report.isPaused ? "paused" : "playing")
        guard resumePoint != .never else { return }
        await ResumePoints.shared.progress(report, client: self, force: resumePoint == .now)
    }

    func reportStopped(_ report: PlaybackReport) async {
        await ResumePoints.shared.stopping(report.itemId)
        await timeline(report, state: "stopped")
    }

    /// Plex's own resume point, as a timeline report does.
    func saveResumePosition(itemId: String, ticks: Int64) async throws {
        try await send(url("/:/progress", query: [
            "key": itemId,
            "identifier": "com.plexapp.plugins.library",
            "time": String(ticks / PlexMapper.ticksPerMillisecond),
            "state": "stopped",
        ]))
    }

    func stopTranscoding(playSessionId: String) async {
        _ = try? await send(url("/video/:/transcode/universal/stop", query: ["session": playSessionId]))
    }

    /// A subtitle file beside the video (embedded tracks Plex won't hand
    /// out: they're drawn by AetherEngine from the file, or burned in).
    func subtitleCues(itemId: String, mediaSourceId: String, streamIndex: Int) async throws -> [SubtitleCue] {
        guard let metadata = try await metadata(itemId),
              let stream = metadata.media?.first?.part?.first?.stream?.first(where: { $0.streamType == 3 && $0.index == streamIndex }),
              let key = stream.key else { throw PlexError.notBuilt }
        let data = try await data(from: url(key), fresh: false)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return PlexSubtitles.cues(from: text, codec: stream.codec)
    }

    /// Plex Pass's intro and credits markers; failing those, chapters
    /// named as an opening or ending (anime libraries have them).
    func mediaSegments(itemId: String) async throws -> [MediaSegment] {
        guard let metadata = try await metadata(itemId) else { return [] }
        return PlexSegments.segments(markers: metadata.marker ?? [], chapters: metadata.chapter ?? [],
                                     itemId: itemId, durationMilliseconds: metadata.duration)
    }

    func trickplayTileURL(itemId: String, width: Int, index: Int, mediaSourceId: String) -> URL { baseURL }
    func chapterImageURL(itemId: String, index: Int, stamp: Int64?) -> URL { baseURL }
    func chapterImageURL(itemId: String, index: Int, tag: String) -> URL { baseURL }

    // MARK: Helpers

    private func metadata(_ id: String) async throws -> PlexMetadata? {
        let data = try await perform(request(url("/library/metadata/\(id)", query: ["includeMarkers": "1", "includeChapters": "1"])))
        return try JSONDecoder().decode(PlexReply.self, from: data).mediaContainer.metadata?.first
    }

    @discardableResult
    private func send(_ url: URL, method: String = "GET") async throws -> Data {
        try await perform(request(url, method: method))
    }

    private func timeline(_ report: PlaybackReport, state: String) async {
        var request = request(url("/:/timeline", query: [
            "ratingKey": report.itemId,
            "key": "/library/metadata/\(report.itemId)",
            "state": state,
            "time": String(report.positionTicks / PlexMapper.ticksPerMillisecond),
            "duration": report.runTimeTicks.map { String($0 / PlexMapper.ticksPerMillisecond) },
            "identifier": "com.plexapp.plugins.library",
        ]))
        if let session = report.playSessionId {
            request.setValue(session, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }
        _ = try? await URLSession.shared.data(for: request)
    }

    /// The transcoder's settings, for its decision and its HLS stream.
    /// Converted video always comes as H.264: Plex sends HLS as MPEG-TS,
    /// where AVFoundation (which shows AetherEngine's converted streams)
    /// has no picture for HEVC, and AetherEngine only rewraps HEVC once it
    /// has read the playlist's first segment, which a conversion starting
    /// partway in (a resume, or new subtitles) doesn't make. Files Apple TV
    /// plays as they are, HEVC and HDR included, never come here.
    /// `keepsSurround` lets audio come as E-AC-3; `mostCompatible` is a
    /// plain H.264 + AAC encode. A picture subtitle is burned in, and the
    /// address says so the way Jellyfin's does, so the players see it.
    private func transcodeQuery(itemId: String, session: String, startTicks: Int64, maxBitrate: Int,
                                keepsSurround: Bool, mostCompatible: Bool, burnIn: Int?) -> [String: String?] {
        var query: [String: String?] = [
            "path": "/library/metadata/\(itemId)",
            "mediaIndex": "0",
            "partIndex": "0",
            "protocol": "hls",
            "fastSeek": "1",
            "directPlay": "0",
            "directStream": mostCompatible ? "0" : "1",
            "directStreamAudio": mostCompatible ? "0" : "1",
            "videoQuality": "100",
            "maxVideoBitrate": String(max(1, maxBitrate / 1000)),
            "offset": String(Double(startTicks) / 10_000_000),
            "subtitles": burnIn == nil ? "none" : "burn",
            "location": baseURL.host().map { $0.contains("plex.direct") || $0.hasPrefix("192.168.") || $0.hasPrefix("10.") ? "lan" : "wan" },
            "session": session,
            "X-Plex-Session-Identifier": session,
            "X-Plex-Client-Identifier": PlexDevice.clientIdentifier,
            "X-Plex-Product": PlexDevice.product,
            "X-Plex-Platform": PlexDevice.platform,
            "X-Plex-Token": accessToken,
        ]
        if keepsSurround {
            query["X-Plex-Client-Profile-Extra"] = "append-transcode-target-codec(type=videoProfile&context=streaming&protocol=hls&audioCodec=eac3)"
        }
        if let burnIn {
            query["SubtitleMethod"] = "Encode"
            query["SubtitleStreamIndex"] = String(burnIn)
        }
        return query
    }

    /// A subtitle file beside the video, in a text format the app reads.
    static func isFetchableText(_ stream: PlexStream) -> Bool {
        stream.key != nil && PlexSubtitles.isText(stream.codec)
    }

    /// A track for the players: subtitle files the app fetches count as
    /// text; tracks inside the file (which Plex won't hand out) are burned
    /// in when the stream is converted, and drawn by AetherEngine when
    /// the file plays as it is.
    static func playbackStream(_ stream: PlexStream) -> MediaStream {
        var mapped = MediaStream()
        mapped.type = switch stream.streamType {
        case 1: "Video"
        case 2: "Audio"
        case 3: "Subtitle"
        default: nil
        }
        mapped.index = stream.index
        mapped.codec = stream.codec
        mapped.language = stream.languageCode
        mapped.displayTitle = stream.displayTitle
        mapped.title = stream.title
        mapped.isDefault = stream.default
        mapped.isForced = stream.forced
        mapped.isExternal = stream.key != nil
        mapped.width = stream.width
        mapped.height = stream.height
        mapped.channels = stream.channels
        if stream.streamType == 3 {
            let text = isFetchableText(stream)
            mapped.isTextSubtitleStream = text
            mapped.deliveryMethod = text ? "External" : "Encode"
        }
        return mapped
    }
}

/// Plex's markers and chapters as the app's skip segments.
nonisolated enum PlexSegments {
    /// The longest a chapter can be and still be taken for an opening or
    /// ending: some files name their whole first half "Intro".
    static let longestThemeMilliseconds = 4 * 60 * 1000

    static func segments(markers: [PlexMarker], chapters: [PlexChapter], itemId: String, durationMilliseconds: Int?) -> [MediaSegment] {
        func ticks(_ ms: Int) -> Int64 { Int64(ms) * PlexMapper.ticksPerMillisecond }
        var found: [MediaSegment] = []
        for marker in markers where marker.endTimeOffset > marker.startTimeOffset {
            switch marker.type {
            case "intro":
                found.append(MediaSegment(id: "\(itemId)-intro", itemId: itemId, type: "Intro", startTicks: ticks(marker.startTimeOffset), endTicks: ticks(marker.endTimeOffset)))
            case "credits":
                found.append(MediaSegment(id: "\(itemId)-credits", itemId: itemId, type: "Outro", startTicks: ticks(marker.startTimeOffset), endTicks: ticks(marker.endTimeOffset)))
            default:
                break
            }
        }
        if !found.isEmpty { return found }

        // Chapters named for what they are, ending where the next begins.
        let sorted = chapters.sorted { $0.startTimeOffset < $1.startTimeOffset }
        for (index, chapter) in sorted.enumerated() {
            let name = (chapter.tag ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let type: String? = switch name {
            case "opening", "op", "intro", "opening credits": "Intro"
            case "ending", "ed", "credits", "end credits", "outro": "Outro"
            default: nil
            }
            guard let type, found.allSatisfy({ $0.type != type }) else { continue }
            let end = chapter.endTimeOffset ?? (index + 1 < sorted.count ? sorted[index + 1].startTimeOffset : durationMilliseconds)
            guard let end, end > chapter.startTimeOffset, end - chapter.startTimeOffset <= longestThemeMilliseconds else { continue }
            found.append(MediaSegment(id: "\(itemId)-\(type.lowercased())", itemId: itemId, type: type,
                                      startTicks: ticks(chapter.startTimeOffset), endTicks: ticks(end)))
        }
        return found
    }
}

/// Subtitle files beside a video: SRT, WebVTT, or ASS/SSA as plain text.
nonisolated enum PlexSubtitles {
    static func isText(_ codec: String?) -> Bool {
        ["srt", "subrip", "vtt", "webvtt", "ass", "ssa", "mov_text", "text"].contains((codec ?? "").lowercased())
    }

    static func cues(from text: String, codec: String?) -> [SubtitleCue] {
        let codec = (codec ?? "").lowercased()
        if codec == "ass" || codec == "ssa" || text.contains("[Events]") {
            return assCues(text)
        }
        return timedBlocks(text)
    }

    /// SRT and WebVTT: blocks of a time line and text, apart by blank lines.
    static func timedBlocks(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            let body = lines[(timeIndex + 1)...].joined(separator: "\n")
            let clean = stripTags(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: clean)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// ASS/SSA: each Dialogue line's times and text, styling taken out.
    static func assCues(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("Dialogue:") {
            let fields = line.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 10, let start = seconds(fields[1]), let end = seconds(fields[2]) else { continue }
            var body = fields[9].replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            body = body.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: clean)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03,456", "01:02:03.456", "02:03.456" or ASS's "1:02:03.45".
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
    }
}
