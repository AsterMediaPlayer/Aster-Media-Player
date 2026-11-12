//
//  ProfilePinEntry.swift
//  AsterFIN
//
//  A locked profile's PIN, under the row of tiles: digits, checked by the
//  server (or plex.tv); a wrong one shakes the field and clears it.
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

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Onboarding.controlSpacing) {
            Text("Enter \(profile.name)'s PIN")
                .font(.title3)
                .foregroundStyle(.secondary)
            SecureField("PIN", text: $pin)
                .credentialField(isPin: true)
                .onboardingField()
                .frame(maxWidth: Onboarding.credentialsWidth)
                .focused($focused)
                // tvOS's keyboard can submit before the field has the last
                // key typed: nothing is checked until there's something.
                .onSubmit { if !pin.isEmpty { onSubmit() } }
                .modifier(Shake(animatableData: CGFloat(errorAttempt)))
                .animation(.easeInOut(duration: 0.45), value: errorAttempt)
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
                    if !pin.isEmpty { onSubmit() }
                } label: {
                    HStack {
                        if isChecking { ProgressView().controlSize(.small) }
                        Text("Continue")
                    }
                    .frame(maxWidth: Onboarding.signInButtonWidth)
                }
                .onboardingPrimaryButton()
                .disabled(isChecking || pin.isEmpty)
                Button("Cancel", role: .cancel, action: onCancel)
                    .onboardingSecondaryButton()
                    .disabled(isChecking)
            }
        }
        .frame(maxWidth: .infinity)
        .tvFocusSection()
        // To the field once it's on screen: set as it appears, focus is
        // ignored, so a moment later.
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
        .onChange(of: errorAttempt) { _, _ in focused = true }
    }
}

/// A sideways shake, once per whole step of `animatableData`.
private struct Shake: GeometryEffect {
    var amount: CGFloat = 12
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(animatableData * .pi * shakes * 2), y: 0))
    }
}
