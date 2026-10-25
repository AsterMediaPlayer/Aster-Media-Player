//
//  SeriesTimerOptionsView.swift
//  AsterFIN
//
//  The options of one series recording rule: which episodes to record, how
//  many to keep, and padding around each airing.
//

import SwiftUI

struct SeriesTimerOptionsView: View {
    let timerId: String
    /// Called after the rule is saved or cancelled.
    var onChanged: () -> Void = {}

    @Environment(AppSession.self) private var session
    @Environment(\.coverDismiss) private var dismiss
    @State private var timer: SeriesTimerInfo?
    @State private var isWorking = false
    @State private var confirmCancel = false
    @State private var errorMessage: String?

    private static let keepUpToOptions: [(String, Int)] = [("All", 0), ("1", 1), ("3", 3), ("5", 5), ("10", 10), ("20", 20)]
    private static let keepUntilOptions: [(String, String)] = [
        ("Until deleted", "UntilDeleted"),
        ("Until space is needed", "UntilSpaceNeeded"),
        ("Until watched", "UntilWatched"),
    ]
    private static let paddingOptions: [(String, Int)] = [("None", 0), ("1 min", 60), ("2 min", 120), ("5 min", 300), ("10 min", 600), ("15 min", 900)]

    var body: some View {
        #if os(tvOS)
        form
        #else
        // No remote Back button on iOS: a navigation bar gives a way out.
        NavigationStack {
            form
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Text(timer?.name ?? "Series Recording")
                    .font(.largeTitle.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                if let channel = timer?.channelName {
                    Text(channel)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            if timer != nil {
                Section("Record") {
                    Toggle("New episodes only", isOn: bind(\.recordNewOnly, default: false))
                    Toggle("On any channel", isOn: bind(\.recordAnyChannel, default: false))
                    Toggle("At any time", isOn: bind(\.recordAnyTime, default: true))
                    Toggle("Skip episodes already in the library", isOn: bind(\.skipEpisodesInLibrary, default: false))
                }

                Section("Keep") {
                    Picker("Keep up to", selection: bind(\.keepUpTo, default: 0)) {
                        ForEach(Self.keepUpToOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    Picker("Keep recordings", selection: bind(\.keepUntil, default: "UntilDeleted")) {
                        ForEach(Self.keepUntilOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                }

                Section("Padding") {
                    Picker("Start early", selection: bind(\.prePaddingSeconds, default: 0)) {
                        ForEach(Self.paddingOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    Picker("End late", selection: bind(\.postPaddingSeconds, default: 0)) {
                        ForEach(Self.paddingOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                }

                Section {
                    Button("Save") { save() }
                        .disabled(isWorking)
                    Button("Cancel Series Recording", role: .destructive) { confirmCancel = true }
                        .disabled(isWorking)
                }
            } else if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            } else {
                Section {
                    ProgressView()
                }
            }
        }
        .task { await load() }
        .alert("Cancel this series recording?", isPresented: $confirmCancel) {
            Button("Cancel Series Recording", role: .destructive) { cancelSeries() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Scheduled recordings for this series will be removed. Finished recordings are kept.")
        }
        .alert("Series Recording", isPresented: Binding(get: { errorMessage != nil && timer != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// A binding into the optional rule, substituting a default while it loads.
    private func bind<Value>(_ keyPath: WritableKeyPath<SeriesTimerInfo, Value?>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { timer?[keyPath: keyPath] ?? fallback },
            set: { value in timer?[keyPath: keyPath] = value }
        )
    }

    private func load() async {
        guard let client = session.jellyfin else { return }
        do {
            timer = try await client.seriesTimer(timerId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let client = session.jellyfin, let timer else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await client.updateSeriesTimer(timer)
                onChanged()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelSeries() {
        guard let client = session.jellyfin else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await client.cancelSeriesTimer(timerId)
                onChanged()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}