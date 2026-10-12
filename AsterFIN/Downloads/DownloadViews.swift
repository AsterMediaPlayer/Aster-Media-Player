//
//  DownloadViews.swift
//  AsterFIN
//
//  The Downloads tab, the first-download setup sheet, and the storage and
//  quality choices they share with Settings › Downloads (iPhone and iPad).
//

#if !os(tvOS)
import SwiftUI
import UIKit

// MARK: - Choices

/// Storage, quality and network choices for downloads, as form sections.
struct DownloadOptionsSections: View {
    @AppStorage(AppSettings.downloadStorageLimitKey) private var limitGB = 0
    @AppStorage(AppSettings.downloadQualityKey) private var quality = DownloadQuality.high.rawValue
    @AppStorage(AppSettings.downloadHEVCKey) private var allowHEVC = false
    @AppStorage(AppSettings.downloadSubtitlesKey) private var includeSubtitles = true
    @AppStorage(AppSettings.downloadCellularKey) private var useCellular = false

    private let store = DownloadStore.shared

    private var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    /// Limits that fit what the device could hold, plus the one chosen.
    private var limitOptions: [Int] {
        let capacity = ((DownloadStore.freeBytes ?? 0) + store.usedBytes) / 1_000_000_000
        let fitting = [5, 10, 25, 50, 100, 250].filter { Int64($0) <= capacity }
        return Array(Set(fitting + (limitGB > 0 ? [limitGB] : []))).sorted()
    }

    var body: some View {
        Section {
            LabeledContent("Free on this \(deviceName)", value: DownloadStore.freeBytes.map(DownloadStore.format) ?? "Unknown")
            LabeledContent("Used by downloads", value: DownloadStore.format(store.usedBytes))
            Picker("Space for downloads", selection: $limitGB) {
                ForEach(limitOptions, id: \.self) { gigabytes in
                    Text("\(gigabytes) GB").tag(gigabytes)
                }
                Text("No limit").tag(0)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("A download that would go over this waits for you to make room. With no limit, downloads stop short of filling the \(deviceName).")
        }

        Section {
            Picker("Quality", selection: $quality) {
                ForEach(DownloadQuality.allCases) { option in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Quality")
        }

        Section {
            Toggle("Smaller files (HEVC)", isOn: $allowHEVC)
            Toggle("Include subtitles", isOn: $includeSubtitles)
            Toggle("Download over cellular", isOn: $useCellular)
        } footer: {
            Text("HEVC files are about a third smaller, but a server without hardware encoding takes longer to prepare them. The subtitles saved are the track your Audio & Subtitles settings would choose. Without cellular, downloads wait for Wi-Fi.")
        }
    }
}

// MARK: - Setup

/// Shown the first time Download is tapped: the free space, a limit and a
/// quality, then the download starts. Settings › Downloads changes them later.
struct DownloadSetupView: View {
    /// Called with true to go ahead with the download.
    var onFinish: (Bool) -> Void

    @AppStorage(AppSettings.downloadStorageLimitKey) private var limitGB = 0
    @AppStorage(AppSettings.downloadsSetUpKey) private var isSetUp = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose how much space downloads may use and the quality they're saved at. You can change these any time in Settings › Downloads.")
                        .foregroundStyle(.secondary)
                }
                DownloadOptionsSections()
            }
            .navigationTitle("Set Up Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        isSetUp = true
                        onFinish(true)
                    }
                }
            }
        }
        .onAppear {
            // Start from a limit that suits the space free.
            guard limitGB == 0, let free = DownloadStore.freeBytes else { return }
            limitGB = free > 60_000_000_000 ? 25 : free > 25_000_000_000 ? 10 : 5
        }
    }
}

// MARK: - Track choice

/// Before a download of a title with a choice of tracks: which audio and
/// subtitles to save, starting from what playback would pick. A download
/// holds one audio track, so this is the language it plays in offline.
struct DownloadTracksView: View {
    let item: BaseItem
    /// Called with the audio track (nil for the server's default) and the
    /// subtitles (-1 for none), or nil when cancelled.
    var onFinish: ((audio: Int?, subtitle: Int)?) -> Void

    @Environment(AppSession.self) private var session
    @State private var audio: Int?
    @State private var subtitle = -1

    private var source: MediaSourceInfo? { item.mediaSources?.first }
    private var streams: [MediaStream] { source?.mediaStreams ?? item.mediaStreams ?? [] }
    private var audioTracks: [MediaStream] { streams.filter { $0.type == "Audio" && $0.index != nil } }
    private var subtitleTracks: [MediaStream] { streams.filter { $0.type == "Subtitle" && $0.index != nil } }

    /// Whether a title has anything to choose.
    static func hasChoice(for item: BaseItem) -> Bool {
        let streams = item.mediaSources?.first?.mediaStreams ?? item.mediaStreams ?? []
        return streams.filter { $0.type == "Audio" }.count > 1 || streams.contains { $0.type == "Subtitle" }
    }

    var body: some View {
        NavigationStack {
            Form {
                if audioTracks.count > 1 {
                    Section {
                        Picker("Audio", selection: $audio) {
                            ForEach(audioTracks, id: \.index) { track in
                                row(track).tag(track.index)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Audio")
                    } footer: {
                        Text("A download keeps one audio track, the one it plays in offline.")
                    }
                }
                if !subtitleTracks.isEmpty {
                    Section {
                        Picker("Subtitles", selection: $subtitle) {
                            Text("None").tag(-1)
                            ForEach(subtitleTracks, id: \.index) { track in
                                row(track, burnedIn: !PlaybackCoordinator.isTextTrack(track)).tag(track.index ?? -1)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Subtitles")
                    } footer: {
                        Text("Text subtitles are saved alongside the video and can be turned off while watching. Picture-based ones are burned into the video and always show.")
                    }
                }
            }
            .navigationTitle(item.kind == .episode ? (item.seriesName ?? item.displayTitle) : item.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { onFinish((audio, subtitle)) }
                }
            }
        }
        .onAppear(perform: chooseDefaults)
    }

    private func row(_ track: MediaStream, burnedIn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title ?? track.trackTitle)
            Text([TracksTab.detail(for: track), burnedIn ? "Burned in" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What playback would choose: the server's default audio (which follows
    /// the account's language setting) and the preferred subtitles.
    private func chooseDefaults() {
        audio = source?.defaultAudioStreamIndex ?? audioTracks.first?.index
        if let source, DownloadSettings.includeSubtitles {
            subtitle = PlaybackCoordinator.resolveSubtitle(for: PlaybackQueueItem(itemId: item.id), source: source, among: subtitleTracks, preferences: session.playbackPreferences)
        }
    }
}

// MARK: - Downloads tab

/// Everything downloaded or downloading, newest first. Finished titles play
/// from the device, so this works with no connection.
struct DownloadsView: View {
    @Environment(AppSession.self) private var session
    @State private var playback: PlaybackRequest?
    @State private var errorMessage: String?
    /// Choosing downloads to delete, and those chosen.
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var confirmDeleteSelected = false
    @State private var confirmDeleteAll = false

    private let store = DownloadStore.shared

    var body: some View {
        List(selection: $selection) {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("Downloads")
                        .font(.largeTitle.weight(.bold))
                    Spacer()
                    // Here rather than in a navigation bar, which under the
                    // More tab would stack a second bar under More's.
                    if !store.records.isEmpty {
                        Button(isSelecting ? "Done" : "Select") {
                            withAnimation {
                                isSelecting.toggle()
                                selection = []
                            }
                        }
                        .font(.headline)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Lockup.screenPadding, bottom: 0, trailing: Lockup.screenPadding))
                .selectionDisabled()
            }
            if store.records.isEmpty {
                MessageView(systemImage: "arrow.down.circle", title: "No Downloads", detail: "Download a movie or episode from the ⋯ button on its page to watch it without a connection.")
                    .frame(height: Lockup.emptyStateHeight)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            } else {
                Section {
                    ForEach(store.records) { record in
                        row(for: record)
                            .tag(record.id)
                    }
                } footer: {
                    Text(storageSummary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: store.records.isEmpty) { _, empty in
            if empty {
                isSelecting = false
                selection = []
            }
        }
        .confirmationDialog(selectedTitle, isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                withAnimation {
                    store.remove(selection)
                    selection = []
                    isSelecting = false
                }
            }
        } message: {
            Text("This frees \(DownloadStore.format(bytes(of: selection))). Any of them still downloading stop.")
        }
        .confirmationDialog("Delete all downloads?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                withAnimation {
                    store.removeAll()
                    selection = []
                    isSelecting = false
                }
            }
        } message: {
            Text("This frees \(DownloadStore.format(store.usedBytes)) and stops any downloads in progress.")
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request) { playback = nil }
        }
        .alert("Couldn't Download", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// A download's row: tapped to play or resume, or, while choosing, to
    /// tick it.
    @ViewBuilder
    private func row(for record: DownloadRecord) -> some View {
        if isSelecting {
            DownloadRow(record: record)
        } else {
            Button {
                open(record)
            } label: {
                DownloadRow(record: record)
            }
            .buttonStyle(.plain)
            .swipeActions {
                Button(record.state == .downloading ? "Cancel" : "Remove", role: .destructive) {
                    withAnimation { store.remove(record.id) }
                }
            }
            .contextMenu {
                if record.state == .failed {
                    Button("Resume Download", systemImage: "arrow.clockwise") { retry(record) }
                }
                Button(record.state == .downloading ? "Cancel Download" : "Remove Download", systemImage: "trash", role: .destructive) {
                    store.remove(record.id)
                }
            }
        }
    }

    /// Delete All and Delete (n), along the bottom while choosing.
    private var selectionBar: some View {
        HStack {
            Button("Delete All", role: .destructive) { confirmDeleteAll = true }
            Spacer()
            Button(selection.isEmpty ? "Delete" : "Delete (\(selection.count))", role: .destructive) {
                confirmDeleteSelected = true
            }
            .disabled(selection.isEmpty)
            .fontWeight(.semibold)
        }
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var selectedTitle: String {
        selection.count == 1 ? "Delete this download?" : "Delete \(selection.count) downloads?"
    }

    /// The space the chosen downloads take, or will once finished.
    private func bytes(of ids: Set<String>) -> Int64 {
        store.records.filter { ids.contains($0.id) }.reduce(0) { total, record in
            total + (record.state == .finished ? record.bytesOnDisk : Int64(Double(record.expectedBytes) * record.progress))
        }
    }

    private var storageSummary: String {
        var parts = ["Using \(DownloadStore.format(store.usedBytes))"]
        if let limit = DownloadSettings.storageLimit {
            parts[0] += " of \(DownloadStore.format(limit))"
        }
        if let free = DownloadStore.freeBytes {
            parts.append("\(DownloadStore.format(free)) free on this device")
        }
        return parts.joined(separator: " · ")
    }

    private func open(_ record: DownloadRecord) {
        switch record.state {
        case .finished:
            // From where viewing stopped, unless it had all but finished.
            let runtime = record.item.runTimeTicks ?? 0
            let start = runtime > 0 && record.positionTicks > runtime * 95 / 100 ? 0 : record.positionTicks
            playback = PlaybackRequest(itemId: record.id, startTicks: start)
        case .failed:
            retry(record)
        case .downloading:
            break
        }
    }

    private func retry(_ record: DownloadRecord) {
        guard let client = session.client else { return }
        Task {
            do {
                try await store.retry(record.id, client: client, preferences: session.playbackPreferences, canDownload: session.canDownload)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A download's artwork, title and state.
private struct DownloadRow: View {
    let record: DownloadRecord

    private var artwork: UIImage? {
        DownloadStore.shared.artworkURL(for: record.id).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    private var title: String {
        record.item.kind == .episode ? (record.item.seriesName ?? record.item.displayTitle) : record.item.displayTitle
    }

    private var subtitle: String? {
        guard record.item.kind == .episode else { return record.item.yearText }
        let parts = [record.item.episodeCode, record.item.name].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    ArtworkPlaceholder(systemImage: record.item.kind == .episode ? "tv" : "film")
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                status
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch record.state {
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: record.progress)
                Text("Downloading · \(Int(record.progress * 100))% of about \(DownloadStore.format(record.expectedBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished:
            Text([DownloadStore.format(record.bytesOnDisk), DownloadQuality(rawValue: record.quality)?.title, record.audioTitle].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text("\(record.errorMessage ?? "Download failed.") Tap to resume.")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
#endif
