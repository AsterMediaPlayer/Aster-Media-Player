//
//  ProfilePickerView.swift
//  AsterFIN
//
//  "Who's watching?": the household's people as tiles. Picking one
//  switches at once, or asks for their PIN first; the main screen then
//  starts afresh as theirs. Shown as the app opens (when the household
//  asks for it) and whenever someone asks to switch. The main account
//  can add someone from the end of the row.
//

import SwiftUI

struct ProfilePickerView: View {
    let reason: ProfilePickerReason

    @Environment(AppSession.self) private var session
    @State private var model = ProfilePickerModel()
    @State private var pin = ""
    @State private var isAdding = false

    private var household: HouseholdProfiles { HouseholdProfiles.shared }

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            OnboardingLayout {
                VStack(spacing: Onboarding.sectionSpacing) {
                    VStack(spacing: 8) {
                        Text("Who's watching?")
                            .font(.system(size: Onboarding.serverNameSize, weight: .bold))
                            .multilineTextAlignment(.center)
                        if let serverName = session.serverName {
                            Text(serverName)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if model.profiles.isEmpty {
                        if model.isLoading {
                            ProgressView()
                        } else if let loadError = model.loadError {
                            Text(loadError)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: Onboarding.credentialsWidth)
                        }
                    } else {
                        tiles
                    }

                    if case .enteringPin(let profile) = model.stage {
                        ProfilePinEntry(
                            profile: profile, pin: $pin,
                            errorMessage: model.errorMessage, errorAttempt: model.errorAttempt,
                            isChecking: model.isSwitching,
                            onSubmit: submitPin,
                            onCancel: cancelPin
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        VStack(spacing: Onboarding.controlSpacing) {
                            if let errorMessage = model.errorMessage {
                                Text(errorMessage)
                                    .foregroundStyle(.red)
                                    .font(.callout.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: Onboarding.credentialsWidth)
                                    .id(model.errorAttempt)
                                    .transition(.opacity)
                            }
                            footer
                        }
                        .frame(maxWidth: .infinity)
                        .tvFocusSection()
                    }
                }
                #if os(tvOS)
                .padding(.vertical, 60)
                #endif
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.stage)
        .animation(.easeInOut(duration: 0.25), value: model.profiles.isEmpty)
        .task { await model.load(session: session, reason: reason) }
        // A wrong PIN is cleared, to type again.
        .onChange(of: model.errorAttempt) { _, _ in pin = "" }
        // Adding someone: the form over the picker; the row then shows them.
        .appCover(isPresented: $isAdding, onDismiss: {
            Task { await model.reload(session: session) }
        }) {
            ProfileCreateView()
        }
        #if os(tvOS) || os(macOS)
        // Back (Menu, or Esc on a Mac) leaves the PIN first, then the picker.
        .onExitCommand { goBack() }
        #endif
    }

    /// The tiles: centred when they fit, scrolling sideways when they don't.
    private var tiles: some View {
        ViewThatFits(in: .horizontal) {
            tileRow
            ScrollView(.horizontal) { tileRow }
                .scrollClipDisabled()
        }
        .tvFocusSection()
    }

    private var tileRow: some View {
        HStack(alignment: .top, spacing: ProfileLayout.tileSpacing) {
            ForEach(model.profiles) { profile in
                Button {
                    pick(profile)
                } label: {
                    ProfileTile(
                        profile: profile,
                        isSwitching: model.isSwitching(profile),
                        isDimmed: model.isSwitching && !model.isSwitching(profile)
                    )
                    .padding(16)
                }
                .buttonStyle(ProfileTileButtonStyle())
                .disabled(model.isSwitching)
            }
            if household.canCreateProfiles {
                Button {
                    isAdding = true
                } label: {
                    AddProfileTile(isDimmed: model.isSwitching)
                        .padding(16)
                }
                .buttonStyle(ProfileTileButtonStyle())
                .disabled(model.isSwitching)
            }
        }
        .padding(.horizontal, Onboarding.avatarRowPadding)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var footer: some View {
        switch reason {
        case .launch:
            if let name = session.userName {
                Button("Continue as \(name)") { session.dismissProfilePicker() }
                    .onboardingSecondaryButton()
                    .disabled(model.isSwitching)
            }
        case .switcher:
            Button("Cancel", role: .cancel) { session.dismissProfilePicker() }
                .onboardingSecondaryButton()
                .disabled(model.isSwitching)
        }
    }

    private func pick(_ profile: HouseholdProfile) {
        pin = ""
        Task { await model.pick(profile, session: session) }
    }

    private func submitPin() {
        let entered = pin
        Task { await model.submitPin(entered, session: session) }
    }

    private func cancelPin() {
        pin = ""
        model.cancelPin()
    }

    private func goBack() {
        guard !model.isSwitching else { return }
        if case .enteringPin = model.stage {
            cancelPin()
        } else {
            session.dismissProfilePicker()
        }
    }
}

/// The tile at the end of the row that adds someone: a plus in a ring.
struct AddProfileTile: View {
    var isDimmed = false
    var size: CGFloat = ProfileLayout.tileSize

    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    private var isLifted: Bool { isFocused || isHovered }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.white.opacity(isLifted ? 0.16 : 0.07))
                Circle()
                    .strokeBorder(.white.opacity(isLifted ? 0.9 : 0.35), style: StrokeStyle(lineWidth: isLifted ? 4 : 2.5, dash: isLifted ? [] : [size * 0.08, size * 0.06]))
                Image(systemName: "plus")
                    .font(.system(size: size * 0.4, weight: .light))
                    .foregroundStyle(.white.opacity(isLifted ? 1 : 0.7))
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(isLifted ? 0.45 : 0), radius: 24, y: 12)
            .scaleEffect(isLifted ? 1.08 : 1)
            Text("Add Profile")
                .font(ProfileLayout.nameFont)
                .foregroundStyle(isLifted ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(width: size * 1.4)
        .opacity(isDimmed ? 0.35 : 1)
        .animation(.easeOut(duration: 0.18), value: isLifted)
        .animation(.easeInOut(duration: 0.25), value: isDimmed)
        #if !os(tvOS)
        .onHover { isHovered = $0 }
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add a profile")
    }
}

/// What the picker is doing: showing the tiles, or asking a PIN; and who,
/// if anyone, is being switched to meanwhile.
@MainActor
@Observable
final class ProfilePickerModel {
    enum Stage: Equatable {
        case picking
        case enteringPin(HouseholdProfile)
    }

    private(set) var stage: Stage = .picking
    /// The profile being switched to (from a tile, or once its PIN was
    /// typed): a spinner on their tile, the others faded.
    private(set) var switching: HouseholdProfile?
    /// Its own copy: the shared list is cleared as the switch goes through,
    /// and the tiles should stay while the picker fades.
    private(set) var profiles: [HouseholdProfile] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var errorMessage: String?
    /// Counts the tries that failed, so each message shows afresh.
    private(set) var errorAttempt = 0

    var isSwitching: Bool { switching != nil }

    func isSwitching(_ profile: HouseholdProfile) -> Bool {
        switching?.id == profile.id
    }

    /// The tiles as last seen, at once; then the server's fresh list (a
    /// PIN can stop being asked on the home network, say).
    func load(session: AppSession, reason: ProfilePickerReason) async {
        let household = HouseholdProfiles.shared
        await household.restoreCached(session: session)
        if !household.profiles.isEmpty { profiles = household.profiles }
        isLoading = profiles.isEmpty
        await household.refresh(session: session, force: true)
        isLoading = false
        if household.provider != nil {
            profiles = household.profiles
            loadError = nil
        } else if profiles.isEmpty {
            loadError = household.lastError ?? ProfileSwitchError.unavailable.localizedDescription
        }
        // Opened to ask who's watching, and there's no one else to pick:
        // straight in.
        if reason == .launch, household.checked, household.provider == nil || profiles.count <= 1 {
            session.dismissProfilePicker()
        }
    }

    /// The household as the server has it now (someone was just added).
    func reload(session: AppSession) async {
        let household = HouseholdProfiles.shared
        await household.refresh(session: session, force: true)
        if household.provider != nil { profiles = household.profiles }
    }

    func pick(_ profile: HouseholdProfile, session: AppSession) async {
        guard !isSwitching else { return }
        errorMessage = nil
        switch ProfileSwitchPlan.make(for: profile, stored: session.reusableSession(forUserId: profile.id)) {
        case .alreadyCurrent:
            session.dismissProfilePicker()
        case .needsPin:
            stage = .enteringPin(profile)
        case .reuseStored(let stored):
            switching = profile
            // A beat, so the tile is seen to be chosen before the screen changes.
            try? await Task.sleep(for: .milliseconds(250))
            session.switchProfile(to: stored)
        case .switchNow:
            await perform(profile, pin: nil, session: session)
        }
    }

    func submitPin(_ pin: String, session: AppSession) async {
        guard case .enteringPin(let profile) = stage, !pin.isEmpty, !isSwitching else { return }
        await perform(profile, pin: pin, session: session)
    }

    func cancelPin() {
        guard case .enteringPin = stage, !isSwitching else { return }
        stage = .picking
        errorMessage = nil
    }

    private func perform(_ profile: HouseholdProfile, pin: String?, session: AppSession) async {
        guard let provider = HouseholdProfiles.shared.provider else {
            errorAttempt += 1
            errorMessage = ProfileSwitchError.unavailable.localizedDescription
            return
        }
        switching = profile
        errorMessage = nil
        do {
            let fresh = try await provider.switchSession(to: profile, pin: pin)
            session.switchProfile(to: fresh)
        } catch {
            DebugLog.note("profiles", "Switch to \(profile.name) failed: \(error.localizedDescription)")
            switching = nil
            errorAttempt += 1
            errorMessage = error.localizedDescription
            // A wrong PIN (or too many tries): the pad again. Anything
            // else: back to the tiles.
            switch error as? ProfileSwitchError {
            case .wrongPin, .rateLimited, .pinNeeded:
                stage = .enteringPin(profile)
            default:
                stage = .picking
            }
        }
    }
}
