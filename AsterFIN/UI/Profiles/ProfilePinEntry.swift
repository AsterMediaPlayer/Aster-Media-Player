//
//  ProfilePinEntry.swift
//  AsterFIN
//
//  A locked profile's PIN, under the row of tiles: a box per digit, the
//  keypad on Apple TV, checked by the server (or plex.tv); a wrong one
//  shakes the boxes and clears them.
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

    var body: some View {
        VStack(spacing: Onboarding.controlSpacing) {
            Text("Enter \(profile.name)'s PIN")
                .font(.title3)
                .foregroundStyle(.secondary)
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
