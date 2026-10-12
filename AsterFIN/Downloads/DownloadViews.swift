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

// MARK: - Downloads tab

/// Everything downloaded or downloading, newest first. Finished titles play
/// from the device, so this works with no connection.
struct DownloadsView: View {
    @Environment(AppSession.self) private var session
    @State private var playback: PlaybackRequest?
    @State private var errorMessage: String?

    private let store = DownloadStore.shared

    var body: some View {
        List {
            Section {
                Text("Downloads")
                    .font(.largeTitle.weight(.bold))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: Lockup.screenPadding, bottom: 0, trailing: Lockup.screenPadding))
            }
            if store.records.isEmpty {
                MessageView(systemImage: "arrow.down.circle", title: "No Downloads", detail: "Download a movie or episode from the ⋯ button on its page to watch it without a connection.")
                    .frame(height: Lockup.emptyStateHeight)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(store.records) { record in
                        Button {
                            open(record)
                        } label: {
                            DownloadRow(record: record)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(record.state == .downloading ? "Cancel" : "Remove", role: .destructive) {
                                store.remove(record.id)
                            }
                        }
                        .contextMenu {
                            if record.state == .failed {
                                Button("Try Again", systemImage: "arrow.clockwise") { retry(record) }
                            }
                            Button(record.state == .downloading ? "Cancel Download" : "Remove Download", systemImage: "trash", role: .destructive) {
                                store.remove(record.id)
                            }
                        }
                    }
                } footer: {
                    Text(storageSummary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request) { playback = nil }
        }
        .alert("Couldn't Download", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
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
            Text([DownloadStore.format(record.bytesOnDisk), DownloadQuality(rawValue: record.quality)?.title].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text("\(record.errorMessage ?? "Download failed.") Tap to try again.")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
#endif
