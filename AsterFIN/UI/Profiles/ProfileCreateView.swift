//
//  ProfileCreateView.swift
//  AsterFIN
//
//  Adding someone to the household, or changing them: a name, a picture
//  (or a letter on a colour), a PIN if they want one, how far up the
//  ratings they may watch, and which libraries they see. The main
//  account's own PIN is asked when it has one. A profile being changed
//  can be removed from here too. Done on the server; the picker then
//  shows the household as it is.
//

import SwiftUI

struct ProfileCreateView: View {
    /// The profile being changed; nil to add one.
    var editing: HouseholdProfile?

    @Environment(AppSession.self) private var session
    @Environment(\.coverDismiss) private var dismiss

    @State private var draft = ProfileDraft()
    @State private var confirmPin = ""
    @State private var options: ProfileCreationOptions?
    @State private var isSaving = false
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    /// Counts the tries that failed, so each message shows afresh.
    @State private var errorAttempt = 0
    @FocusState private var nameFocused: Bool

    private var household: HouseholdProfiles { HouseholdProfiles.shared }

    private var isEditing: Bool { editing != nil }
    /// The main account changing itself: its colour, picture and PIN, not
    /// its name or what it may watch.
    private var editsMaster: Bool { editing?.isMaster ?? false }

    /// The picture as the preview shows it: the one picked, or (changing)
    /// the one it has.
    private var previewURL: URL? {
        if let id = draft.avatarId { return options?.avatars.first { $0.id == id }?.url }
        return editing?.imageURL
    }

    private var allLibraries: Binding<Bool> {
        Binding(
            get: { draft.libraryIds == nil },
            set: { all in draft.libraryIds = all ? nil : Set(options?.libraries.map(\.id) ?? []) }
        )
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            ScrollView {
                VStack(spacing: Onboarding.sectionSpacing) {
                    VStack(spacing: 16) {
                        Text(isEditing ? "Edit Profile" : "Add a Profile")
                            .font(.system(size: Onboarding.serverNameSize, weight: .bold))
                        ProfileAvatarView(initial: draft.initial, colorHex: draft.colorHex, imageURL: previewURL, size: ProfileLayout.tileSize)
                            .animation(.easeInOut(duration: 0.2), value: draft.colorHex)
                        if !isEditing, let remaining = options?.remaining {
                            Text(remaining == 1 ? "Room for one more profile." : "Room for \(remaining) more profiles.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    section("Name") {
                        TextField("Name", text: $draft.name)
                            #if !os(macOS)
                            .textInputAutocapitalization(.words)
                            #endif
                            .autocorrectionDisabled()
                            .onboardingField()
                            .focused($nameFocused)
                            .disabled(editsMaster)
                        if editsMaster {
                            Text("The main account keeps its own name.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let options {
                        pictureSection(options)
                    }

                    pinSection

                    if !editsMaster, let options, !options.ratings.isEmpty {
                        ratingSection(options)
                    }

                    if !editsMaster, let options, !options.libraries.isEmpty {
                        librarySection(options)
                    }

                    if options?.asksMasterPin == true {
                        section("Your PIN") {
                            PinCodeField(title: "Your own PIN", pin: $draft.masterPin, errorAttempt: errorAttempt)
                            Text("The main account's PIN, to confirm it's you changing the household.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if options == nil {
                        ProgressView()
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: Onboarding.fieldWidth)
                            .id(errorAttempt)
                            .transition(.opacity)
                    }

                    HStack(spacing: 24) {
                        Button {
                            save()
                        } label: {
                            HStack {
                                if isSaving { ProgressView().controlSize(.small) }
                                Text(isEditing ? "Save" : "Add Profile")
                            }
                            .frame(maxWidth: Onboarding.signInButtonWidth)
                        }
                        .onboardingPrimaryButton()
                        .disabled(isSaving || draft.trimmedName.isEmpty || options == nil)
                        Button("Cancel", role: .cancel) { dismiss() }
                            .onboardingSecondaryButton()
                            .disabled(isSaving)
                    }
                    .frame(maxWidth: .infinity)
                    .tvFocusSection()

                    if let editing, !editing.isMaster {
                        VStack(spacing: 10) {
                            Button("Remove \(editing.name)", role: .destructive) { confirmingDelete = true }
                                .onboardingSecondaryButton()
                                .disabled(isSaving)
                            Text("Their watch history and settings go with them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .tvFocusSection()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                #if os(tvOS)
                .padding(.vertical, 60)
                #else
                .padding(.vertical, 32)
                #endif
            }
            #if !os(tvOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }
        .animation(.easeInOut(duration: 0.2), value: errorAttempt)
        .animation(.easeInOut(duration: 0.2), value: draft.pin.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: draft.removePin)
        .animation(.easeInOut(duration: 0.2), value: draft.libraryIds == nil)
        .task {
            if let editing {
                // The profile as it is, and the choices, side by side.
                async let filled = household.draft(editing: editing)
                async let choices = household.creationOptions()
                draft = await filled
                options = await choices
            } else {
                options = await household.creationOptions()
            }
            // To the name once the form's up: set as it appears, focus is ignored.
            try? await Task.sleep(for: .milliseconds(350))
            if !editsMaster { nameFocused = true }
        }
        .confirmationDialog("Remove \(editing?.name ?? "this profile")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove Profile", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their account on the server goes, with what they've watched and their settings. This can't be undone.")
        }
        #if os(tvOS) || os(macOS)
        .onExitCommand { if !isSaving { dismiss() } }
        #endif
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: Onboarding.fieldWidth, alignment: .leading)
        .tvFocusSection()
    }

    private func pictureSection(_ options: ProfileCreationOptions) -> some View {
        section("Picture") {
            if !options.avatars.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        // The letter on the colour as it is without a picture,
                        // or (changing) the picture it has.
                        choice(selected: draft.avatarId == nil, label: editing?.imageURL != nil ? "Current picture" : "Letter") {
                            draft.avatarId = nil
                        } content: {
                            ProfileAvatarView(initial: draft.initial, colorHex: draft.colorHex, imageURL: editing?.imageURL, size: Self.choiceSize)
                        }
                        ForEach(options.avatars) { avatar in
                            choice(selected: draft.avatarId == avatar.id, label: avatar.name) {
                                draft.avatarId = avatar.id
                            } content: {
                                ProfileAvatarView(initial: "", colorHex: draft.colorHex, imageURL: avatar.url, size: Self.choiceSize)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                }
                .scrollClipDisabled()
            }
            HStack(spacing: 14) {
                ForEach(ProfileDraft.colors, id: \.self) { hex in
                    choice(selected: draft.colorHex == hex, label: "Colour") {
                        draft.colorHex = hex
                    } content: {
                        Circle()
                            .fill(Color(profileHex: hex))
                            .frame(width: Self.colorSize, height: Self.colorSize)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
    }

    private var pinSection: some View {
        section("PIN") {
            if let editing, editing.hasPin {
                Toggle("Remove the PIN", isOn: $draft.removePin)
                if !draft.removePin {
                    PinCodeField(title: "New PIN (leave empty to keep it)", pin: $draft.pin, errorAttempt: errorAttempt)
                }
            } else {
                PinCodeField(title: "PIN (optional)", pin: $draft.pin, errorAttempt: errorAttempt)
            }
            if !draft.pin.isEmpty, !draft.removePin {
                PinCodeField(title: "Confirm PIN", pin: $confirmPin, errorAttempt: errorAttempt)
            }
            if !draft.removePin, !draft.pin.isEmpty || editing?.hasPin == true {
                Toggle("Skip the PIN on the home network", isOn: $draft.bypassPinOnLocalNetwork)
            }
            Text(pinNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pinNote: String {
        if draft.removePin { return "Anyone on the household's devices will be able to open this profile." }
        if editing?.hasPin == true { return "This profile has a PIN. Type a new one to change it, 4 to 8 digits." }
        return draft.pin.isEmpty
            ? "4 to 8 digits. With a PIN, switching to this profile asks for it."
            : "Switching to this profile asks for the PIN; without it, anyone on the household's devices can open it."
    }

    private func ratingSection(_ options: ProfileCreationOptions) -> some View {
        section("Viewing Limit") {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    chip("No Limit", selected: draft.ratingScore == nil) { draft.ratingScore = nil }
                    ForEach(options.ratings) { rating in
                        chip(rating.label, selected: draft.ratingScore == rating.score) { draft.ratingScore = rating.score }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
            .scrollClipDisabled()
            Text("Up to this rating\(options.ratingCountry.map { " (\($0))" } ?? ""), and never past what the main account may watch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func librarySection(_ options: ProfileCreationOptions) -> some View {
        section("Libraries") {
            Toggle("All Libraries", isOn: allLibraries)
            if draft.libraryIds != nil {
                ForEach(options.libraries) { library in
                    Toggle(library.name, isOn: Binding(
                        get: { draft.libraryIds?.contains(library.id) ?? true },
                        set: { on in
                            var ids = draft.libraryIds ?? Set(options.libraries.map(\.id))
                            if on { ids.insert(library.id) } else { ids.remove(library.id) }
                            draft.libraryIds = ids
                        }
                    ))
                }
            }
            Text(draft.libraryIds == nil
                 ? "Everything the main account can see, including libraries added later."
                 : "Only the libraries ticked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    #if os(tvOS)
    private static let choiceSize: CGFloat = 120
    private static let colorSize: CGFloat = 56
    #else
    private static let choiceSize: CGFloat = 64
    private static let colorSize: CGFloat = 36
    #endif

    /// A picture or colour to pick: ringed when chosen, lifted with focus.
    private func choice<Content: View>(selected: Bool, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .overlay {
                    Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.15), lineWidth: selected ? 4 : 1.5)
                }
                .padding(4)
        }
        .buttonStyle(ChoiceButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark") }
                Text(title)
            }
            .lineLimit(1)
        }
        .onboardingSecondaryButton()
        .tint(selected ? .accentColor : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func fail(_ message: String) {
        errorAttempt += 1
        errorMessage = message
    }

    private func save() {
        guard !isSaving else { return }
        if let message = draft.validationMessage(confirmPin: confirmPin) {
            fail(message)
            return
        }
        if options?.asksMasterPin == true, draft.masterPin.isEmpty {
            fail("Enter the main account's PIN.")
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                if isEditing {
                    try await household.update(draft, session: session)
                } else {
                    _ = try await household.create(draft, session: session)
                }
                dismiss()
            } catch {
                DebugLog.note("profiles", "\(isEditing ? "Changing" : "Making") a profile failed: \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }

    private func delete() {
        guard let editing, !isSaving else { return }
        if options?.asksMasterPin == true, draft.masterPin.isEmpty {
            fail("Enter the main account's PIN to remove a profile.")
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await household.delete(editing, masterPin: draft.masterPin, session: session)
                dismiss()
            } catch {
                DebugLog.note("profiles", "Removing a profile failed: \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }
}

/// A picked picture or colour: it draws its own ring, so the system's
/// platter stays out of it; focus and hover lift it a little.
private struct ChoiceButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : (isFocused || isHovered ? 1.12 : 1))
            .shadow(color: .black.opacity(isFocused || isHovered ? 0.4 : 0), radius: 14, y: 8)
            .animation(.easeOut(duration: 0.15), value: isFocused || isHovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            #if !os(tvOS)
            .onHover { isHovered = $0 }
            #endif
    }
}
