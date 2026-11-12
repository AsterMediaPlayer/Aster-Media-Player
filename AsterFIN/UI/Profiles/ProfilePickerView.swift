//
//  ProfilePickerView.swift
//  AsterFIN
//
//  "Who's watching?": the household's people as tiles. Picking one
//  switches at once, or asks for their PIN first; the main screen then
//  starts afresh as theirs. Shown as the app opens (when the household
//  asks for it) and whenever someone asks to switch. The main account
//  can add someone from the end of the row, and manage the household:
//  then pressing a tile changes that profile instead.
//
//  On a Mac the arrow keys move along the tiles and down to the buttons,
//  and Return presses, as the Apple TV's remote does.
//

import SwiftUI

struct ProfilePickerView: View {
    let reason: ProfilePickerReason

    @Environment(AppSession.self) private var session
    @State private var model = ProfilePickerModel()
    @State private var pin = ""
    @State private var isAdding = false
    @State private var editing: HouseholdProfile?
    /// Managing: tiles open the profile to change rather than switch.
    @State private var isManaging = false
    #if os(macOS)
    @FocusState private var hasKeyboard: Bool
    @State private var keyboard = PickerKeyboard()
    #endif

    private var household: HouseholdProfiles { HouseholdProfiles.shared }

    /// Whether a form is up over the picker.
    private var isPresenting: Bool { isAdding || editing != nil }

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            OnboardingLayout {
                VStack(spacing: Onboarding.sectionSpacing) {
                    VStack(spacing: 8) {
                        Text(isManaging ? "Manage Profiles" : "Who's watching?")
                            .font(.system(size: Onboarding.serverNameSize, weight: .bold))
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)
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
        .animation(.easeInOut(duration: 0.2), value: isManaging)
        .task { await model.load(session: session, reason: reason) }
        // A wrong PIN is cleared, to type again.
        .onChange(of: model.errorAttempt) { _, _ in pin = "" }
        // Adding someone, or changing them: the form over the picker; the
        // row then shows the household as it is.
        .appCover(isPresented: $isAdding, onDismiss: {
            Task { await model.reload(session: session) }
        }) {
            ProfileCreateView()
        }
        .background {
            Color.clear
                .appCover(item: $editing, onDismiss: {
                    Task { await model.reload(session: session) }
                }) { profile in
                    ProfileCreateView(editing: profile)
                }
        }
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboard)
        .onKeyPress(.leftArrow) { moveKeyboard(.left) }
        .onKeyPress(.rightArrow) { moveKeyboard(.right) }
        .onKeyPress(.upArrow) { moveKeyboard(.up) }
        .onKeyPress(.downArrow) { moveKeyboard(.down) }
        .onKeyPress(.return) { pressKeyboard() }
        .onKeyPress(.space) { pressKeyboard() }
        .task {
            // Once it's up: set as it appears, focus is ignored.
            try? await Task.sleep(for: .milliseconds(300))
            hasKeyboard = true
        }
        // Back from the PIN pad or a form: the arrow keys again.
        .onChange(of: model.stage) { _, stage in
            if stage == .picking { hasKeyboard = true }
        }
        .onChange(of: isPresenting) { _, presenting in
            if !presenting { hasKeyboard = true }
        }
        .onChange(of: keyboardStops) { _, stops in keyboard.clamp(to: stops) }
        .onDisappear { WindowSidebar.returnKeyboardToContent() }
        #endif
        #if os(tvOS) || os(macOS)
        // Back (Menu, or Esc on a Mac) leaves the PIN first, then managing,
        // then the picker.
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
            ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                Button {
                    press(profile)
                } label: {
                    ProfileTile(
                        profile: profile,
                        isSwitching: model.isSwitching(profile),
                        isDimmed: model.isSwitching && !model.isSwitching(profile),
                        isKeyboardSelected: keyboardSelected(row: 0, column: index),
                        isManaging: isManaging && household.canEdit(profile)
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
                    AddProfileTile(isDimmed: model.isSwitching, isKeyboardSelected: keyboardSelected(row: 0, column: model.profiles.count))
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
        HStack(spacing: 24) {
            switch reason {
            case .launch:
                if let name = session.userName {
                    Button("Continue as \(name)") { session.dismissProfilePicker() }
                        .onboardingSecondaryButton()
                        .disabled(model.isSwitching)
                        .keyboardSelectionHighlight(keyboardSelected(row: 1, column: 0), capsule: true)
                }
            case .switcher:
                Button("Cancel", role: .cancel) { session.dismissProfilePicker() }
                    .onboardingSecondaryButton()
                    .disabled(model.isSwitching)
                    .keyboardSelectionHighlight(keyboardSelected(row: 1, column: 0), capsule: true)
            }
            if household.canCreateProfiles {
                Button(isManaging ? "Done" : "Manage Profiles") { isManaging.toggle() }
                    .onboardingSecondaryButton()
                    .disabled(model.isSwitching)
                    .keyboardSelectionHighlight(keyboardSelected(row: 1, column: 1), capsule: true)
            }
        }
    }

    /// A tile pressed: the profile to switch to, or (managing) to change.
    private func press(_ profile: HouseholdProfile) {
        if isManaging {
            guard household.canEdit(profile) else { return }
            editing = profile
        } else {
            pick(profile)
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
        } else if isManaging {
            isManaging = false
        } else {
            session.dismissProfilePicker()
        }
    }

    // MARK: The Mac's keyboard

    /// How many stops each row has: the tiles (and Add Profile), then the
    /// buttons under them.
    private var keyboardStops: [Int] {
        let tiles = model.profiles.count + (household.canCreateProfiles ? 1 : 0)
        var buttons = 0
        if reason == .switcher || session.userName != nil { buttons += 1 }
        if household.canCreateProfiles { buttons += 1 }
        return [tiles, buttons]
    }

    private func keyboardSelected(row: Int, column: Int) -> Bool {
        #if os(macOS)
        hasKeyboard && model.stage == .picking && !isPresenting && keyboard.row == row && keyboard.column == column
        #else
        false
        #endif
    }

    #if os(macOS)
    private func moveKeyboard(_ direction: PickerKeyboard.Direction) -> KeyPress.Result {
        guard model.stage == .picking, !model.isSwitching, !isPresenting else { return .ignored }
        return keyboard.move(direction, stops: keyboardStops) ? .handled : .ignored
    }

    private func pressKeyboard() -> KeyPress.Result {
        guard model.stage == .picking, !model.isSwitching, !isPresenting else { return .ignored }
        switch keyboard.row {
        case 0:
            if keyboard.column < model.profiles.count {
                press(model.profiles[keyboard.column])
            } else if household.canCreateProfiles {
                isAdding = true
            } else {
                return .ignored
            }
        default:
            if keyboard.column == 0, keyboardStops[1] > 0, reason == .switcher || session.userName != nil {
                session.dismissProfilePicker()
            } else if household.canCreateProfiles {
                isManaging.toggle()
            } else {
                return .ignored
            }
        }
        return .handled
    }
    #endif
}

/// Where the Mac's arrow keys are on the picker: a row (tiles, then
/// buttons) and a column in it.
struct PickerKeyboard: Equatable {
    enum Direction { case left, right, up, down }

    var row = 0
    var column = 0

    /// Moves one stop; false at an edge (the key is left for others).
    mutating func move(_ direction: Direction, stops: [Int]) -> Bool {
        guard !stops.isEmpty else { return false }
        switch direction {
        case .left:
            guard column > 0 else { return false }
            column -= 1
        case .right:
            guard column + 1 < (stops[safe: row] ?? 0) else { return false }
            column += 1
        case .down:
            guard let next = stops.indices.first(where: { $0 > row && stops[$0] > 0 }) else { return false }
            row = next
            column = min(column, stops[next] - 1)
        case .up:
            guard let previous = stops.indices.last(where: { $0 < row && stops[$0] > 0 }) else { return false }
            row = previous
            column = min(column, stops[previous] - 1)
        }
        return true
    }

    /// Keeps the selection on something as the rows change (a profile was
    /// added or removed).
    mutating func clamp(to stops: [Int]) {
        guard let count = stops[safe: row], count > 0 else {
            if let first = stops.firstIndex(where: { $0 > 0 }) {
                row = first
                column = 0
            }
            return
        }
        column = min(column, count - 1)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The tile at the end of the row that adds someone: a plus in a ring.
struct AddProfileTile: View {
    var isDimmed = false
    var isKeyboardSelected = false
    var size: CGFloat = ProfileLayout.tileSize

    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    private var isLifted: Bool { isFocused || isHovered || isKeyboardSelected }

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

    /// The household as the server has it now (someone was added, changed
    /// or removed).
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
