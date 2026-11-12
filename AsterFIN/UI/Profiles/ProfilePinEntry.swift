//
//  ProfilePinEntry.swift
//  AsterFIN
//
//  A locked profile's PIN: their picture, a box per digit, the keypad on
//  Apple TV, checked by the server (or plex.tv); a wrong one shakes the
//  boxes and clears them. It stands in for the row of tiles while typed.
//

import SwiftUI

struct ProfilePinEntry: View {
    let profile: HouseholdProfile
    @Binding var pin: String
    var errorMessage: String?
    /// Counts the tries that failed, so each shows afresh and shakes again.
    var errorAttempt: Int
    var isChecking: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void

    #if os(tvOS)
    private static let avatarSize: CGFloat = 110
    #else
    private static let avatarSize: CGFloat = 72
    #endif

    var body: some View {
        VStack(spacing: Onboarding.controlSpacing) {
            VStack(spacing: 12) {
                ProfileAvatarView(profile: profile, size: Self.avatarSize)
                Text("Enter \(profile.name)'s PIN")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            PinCodeEntry(pin: $pin, errorAttempt: errorAttempt, isDisabled: isChecking, onSubmit: onSubmit)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Onboarding.credentialsWidth)
                    .id(errorAttempt)
                    .transition(.opacity)
            }
            HStack(spacing: 24) {
                Button {
                    if PinCode.isComplete(pin) { onSubmit() }
                } label: {
                    HStack {
                        if isChecking { ProgressView().controlSize(.small) }
                        Text("Continue")
                    }
                    .frame(maxWidth: Onboarding.signInButtonWidth)
                }
                .onboardingPrimaryButton()
                .disabled(isChecking || !PinCode.isComplete(pin))
                Button("Cancel", role: .cancel, action: onCancel)
                    .onboardingSecondaryButton()
                    .disabled(isChecking)
            }
            .tvFocusSection()
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("PIN on the picker") {
    @Previewable @State var pin = "24"
    let profile = HouseholdProfile(
        id: "kids", rawId: "kids", name: "Kids", imageURL: nil, initial: "K", colorHex: "#FF6B35",
        isCurrent: false, isMaster: false, requiresPin: true, hasPin: true, isOtherHousehold: false,
        masterUserId: nil, storedHousehold: StoredHousehold(masterUserId: "m", isMaster: false)
    )
    ZStack {
        OnboardingBackdrop()
        OnboardingLayout {
            VStack(spacing: Onboarding.sectionSpacing) {
                VStack(spacing: 8) {
                    Text("Who's watching?")
                        .font(.system(size: Onboarding.serverNameSize, weight: .bold))
                    Text("Living Room")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                ProfilePinEntry(profile: profile, pin: $pin, errorMessage: "That PIN isn't right.", errorAttempt: 1,
                                isChecking: false, onSubmit: {}, onCancel: {})
            }
            #if os(tvOS)
            .padding(.vertical, 60)
            #endif
        }
    }
    .environment(AppSession())
}
