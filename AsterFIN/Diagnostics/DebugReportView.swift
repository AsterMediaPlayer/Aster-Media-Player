//
//  DebugReportView.swift
//  AsterFIN
//
//  Send Debug Report: asks what happened, says what a report holds, sends
//  it, and shows the id the service gave it. `afterCrash` opens it as the
//  app's offer after the last run ended in a crash, which goes with the
//  report; Not Now puts that crash aside.
//

import SwiftUI

struct DebugReportView: View {
    var afterCrash = false

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var email = ""
    @State private var sending = false
    @State private var code: String?
    @State private var failure: String?

    /// The Apple TV's remote makes typing slow: there the words are optional and no reply address is asked for.
    private var isTV: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private var title: String {
        code != nil ? "Report Sent" : afterCrash ? "Aster Closed Unexpectedly" : "Send Debug Report"
    }

    var body: some View {
        #if os(tvOS)
        content
        #else
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if code == nil, !sending { Button(afterCrash ? "Not Now" : "Cancel") { close() } }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if code != nil { Button("Done") { dismiss() } }
                        else if !sending { Button(failure == nil ? "Send" : "Try Again") { Task { await send() } } }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .interactiveDismissDisabled(sending)
        #endif
    }

    private var content: some View {
        Form {
            #if os(tvOS)
            Section {
                Text(title).font(.largeTitle.weight(.bold))
            }
            .listRowBackground(Color.clear)
            #endif
            if let code {
                Section {
                    Text("Thanks. Your report is")
                    Text(code)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .frame(maxWidth: .infinity)
                    Text("If you open a bug report at github.com/AsterMediaPlayer/Aster-Media-Player/issues, quote it there.")
                        .foregroundStyle(.secondary)
                }
            } else if sending {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Sending…")
                    }
                }
            } else {
                Section {
                    if afterCrash { Text("Sending a debug report helps find out why.") }
                    TextField(isTV ? "What happened? (optional)" : "What happened?", text: $description, axis: .vertical)
                        .lineLimit(isTV ? 1...3 : 3...8)
                    #if !os(tvOS)
                    TextField("Email for a reply (optional)", text: $email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    #endif
                } footer: {
                    Text(DebugReport.contents)
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
                #if os(tvOS)
                Section {
                    HStack(spacing: 40) {
                        ActionButton(title: failure == nil ? "Send" : "Try Again", systemImage: "paperplane", prominent: true) {
                            Task { await send() }
                        }
                        ActionButton(title: afterCrash ? "Not Now" : "Cancel", systemImage: "xmark") { close() }
                    }
                }
                .listRowBackground(Color.clear)
                #endif
            }
            #if os(tvOS)
            if code != nil {
                Section {
                    ActionButton(title: "Done", systemImage: "checkmark", prominent: true) { dismiss() }
                }
                .listRowBackground(Color.clear)
            }
            #endif
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private func close() {
        if afterCrash { CrashReports.clear() }
        dismiss()
    }

    private func send() async {
        sending = true
        failure = nil
        defer { sending = false }
        let crash = CrashReports.pending
        let report = await DebugReport.build(session: session, description: description, crash: crash, contactEmail: isTV ? nil : email)
        do {
            code = try await DebugReport.send(report)
            if crash != nil { CrashReports.clear() }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "The report couldn't be sent."
        }
    }
}
