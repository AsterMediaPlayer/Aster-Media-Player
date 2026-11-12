//
//  PinCodeEntry.swift
//  AsterFIN
//
//  A PIN typed the way a streaming service asks for one: a box per digit
//  filling with dots, growing from four boxes to eight as more are typed
//  (a Bonfire PIN is four to eight digits, and which isn't known until it's
//  checked). On Apple TV the digits come from a keypad under the boxes, the
//  remote moving between them; on iPhone and iPad from the number pad; on
//  a Mac from the keyboard. A wrong PIN shakes the boxes.
//
//  `PinCodeEntry` is the full pad, for opening a profile. `PinCodeField`
//  is the boxes alone, for a form that sets a PIN (on Apple TV, there,
//  the system's number keyboard).
//

import SwiftUI

/// The boxes and, on Apple TV, the keypad.
struct PinCodeEntry: View {
    @Binding var pin: String
    /// Counts the tries that failed: each shakes the boxes.
    var errorAttempt = 0
    var isDisabled = false
    /// Takes the keys as it appears.
    var autoFocus = true
    /// Return, or the keypad's tick, with enough digits typed.
    var onSubmit: () -> Void

    #if os(tvOS)
    @FocusState private var focusedKey: String?
    #else
    @FocusState private var fieldFocused: Bool
    #endif

    var body: some View {
        VStack(spacing: PinCode.padSpacing) {
            PinDigitBoxes(pin: pin, errorAttempt: errorAttempt, isActive: isTakingKeys)
                #if !os(tvOS)
                .contentShape(Rectangle())
                .onTapGesture { fieldFocused = true }
                .background { hiddenField }
                #endif
            #if os(tvOS)
            keypad
            #endif
        }
        .disabled(isDisabled)
        .onChange(of: pin) { _, typed in
            let digits = PinCode.digits(in: typed)
            if digits != typed { pin = digits }
        }
        .task {
            guard autoFocus else { return }
            // Set as it appears, focus is ignored: a moment later.
            try? await Task.sleep(for: .milliseconds(350))
            takeKeys()
        }
        .onChange(of: errorAttempt) { _, _ in takeKeys() }
    }

    private var isTakingKeys: Bool {
        #if os(tvOS)
        focusedKey != nil
        #else
        fieldFocused
        #endif
    }

    private func takeKeys() {
        #if os(tvOS)
        focusedKey = "5"
        #else
        fieldFocused = true
        #endif
    }

    private func submitIfReady() {
        guard PinCode.isComplete(pin) else { return }
        onSubmit()
    }

    #if !os(tvOS)
    /// Where the digits are typed: a field nobody sees, under the boxes.
    private var hiddenField: some View {
        TextField("PIN", text: $pin)
            .focused($fieldFocused)
            #if os(iOS)
            .keyboardType(.numberPad)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .labelsHidden()
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .accessibilityHidden(true)
            .onSubmit { submitIfReady() }
    }
    #endif

    #if os(tvOS)
    private var keypad: some View {
        VStack(spacing: PinCode.keySpacing) {
            ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                HStack(spacing: PinCode.keySpacing) {
                    ForEach(row, id: \.self) { digit in key(digit) { type(digit) } }
                }
            }
            HStack(spacing: PinCode.keySpacing) {
                key("delete", systemImage: "delete.left") { backspace() }
                    .disabled(pin.isEmpty)
                key("0") { type("0") }
                key("done", systemImage: "checkmark") { submitIfReady() }
                    .disabled(!PinCode.isComplete(pin))
            }
        }
        .tvFocusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PIN keypad")
    }

    private func key(_ id: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(id)
                }
            }
            .font(.system(size: 34, weight: .medium, design: .rounded))
            .frame(width: PinCode.keyWidth, height: PinCode.keyHeight)
        }
        .focused($focusedKey, equals: id)
        .accessibilityLabel(systemImage == nil ? id : (id == "delete" ? "Delete" : "Done"))
    }

    private func type(_ digit: String) {
        guard pin.count < PinCode.maxLength else { return }
        pin.append(digit)
    }

    private func backspace() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
    }
    #endif
}

/// The boxes alone, for a form setting a PIN. On iPhone, iPad and Mac the
/// digits are typed into them; on Apple TV the system's number keyboard
/// opens, as a keypad under every PIN on the form would crowd it.
struct PinCodeField: View {
    let title: String
    @Binding var pin: String
    var errorAttempt = 0

    #if !os(tvOS)
    @FocusState private var fieldFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        SecureField(title, text: $pin)
            .keyboardType(.numberPad)
            .onChange(of: pin) { _, typed in
                let digits = PinCode.digits(in: typed)
                if digits != typed { pin = digits }
            }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            PinDigitBoxes(pin: pin, errorAttempt: errorAttempt, isActive: fieldFocused, size: .compact)
                .contentShape(Rectangle())
                .onTapGesture { fieldFocused = true }
                .background {
                    TextField(title, text: $pin)
                        .focused($fieldFocused)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .labelsHidden()
                        .frame(width: 1, height: 1)
                        .opacity(0.02)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(pin.isEmpty ? "Empty" : "\(pin.count) digits")
                .accessibilityAddTraits(.isButton)
        }
        .onChange(of: pin) { _, typed in
            let digits = PinCode.digits(in: typed)
            if digits != typed { pin = digits }
        }
        #endif
    }
}

/// A box per digit: dots for the ones typed, the next one lit while the
/// keys are being taken, more appearing as the PIN grows past four.
struct PinDigitBoxes: View {
    enum Size { case regular, compact }

    let pin: String
    var errorAttempt = 0
    var isActive = false
    var size = Size.regular

    private var boxCount: Int {
        min(PinCode.maxLength, max(PinCode.minLength, pin.count + 1))
    }

    var body: some View {
        HStack(spacing: size == .regular ? PinCode.boxSpacing : PinCode.compactBoxSpacing) {
            ForEach(0..<boxCount, id: \.self) { index in
                box(filled: index < pin.count, isNext: isActive && index == pin.count)
            }
        }
        .modifier(PinShake(animatableData: CGFloat(errorAttempt)))
        .animation(.easeInOut(duration: 0.45), value: errorAttempt)
        .animation(.easeOut(duration: 0.15), value: boxCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN")
        .accessibilityValue(pin.isEmpty ? "Empty" : "\(pin.count) digits")
    }

    private func box(filled: Bool, isNext: Bool) -> some View {
        let width = size == .regular ? PinCode.boxWidth : PinCode.compactBoxWidth
        let height = size == .regular ? PinCode.boxHeight : PinCode.compactBoxHeight
        let corner = size == .regular ? PinCode.boxCorner : PinCode.compactBoxCorner
        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(.white.opacity(isNext ? 0.14 : 0.08))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(isNext ? 0.9 : (filled ? 0.5 : 0.25)), lineWidth: isNext ? 3 : 1.5)
            }
            .overlay {
                if filled {
                    Circle()
                        .fill(.white)
                        .frame(width: width * 0.28, height: width * 0.28)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: width, height: height)
            .animation(.easeOut(duration: 0.15), value: filled)
            .animation(.easeOut(duration: 0.15), value: isNext)
    }
}

/// A sideways shake, once per whole step of `animatableData`.
struct PinShake: GeometryEffect {
    var amount: CGFloat = 12
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(animatableData * .pi * shakes * 2), y: 0))
    }
}

/// The rules and sizes shared by the PIN views.
enum PinCode {
    static let minLength = Bonfire.pinLengths.lowerBound
    static let maxLength = Bonfire.pinLengths.upperBound

    /// Only ASCII digits, and no more than a PIN can hold.
    static func digits(in text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(maxLength))
    }

    /// Enough digits to be a PIN.
    static func isComplete(_ pin: String) -> Bool {
        Bonfire.pinLengths.contains(pin.count)
    }

    // Apple TV: the picture, the boxes, four rows of keys and the buttons
    // must all fit a 1080-point screen with its margins, so the keys are
    // kept to what a remote needs.
    #if os(tvOS)
    static let boxWidth: CGFloat = 64
    static let boxHeight: CGFloat = 80
    static let boxCorner: CGFloat = 14
    static let boxSpacing: CGFloat = 16
    static let padSpacing: CGFloat = 28
    static let keyWidth: CGFloat = 128
    static let keyHeight: CGFloat = 62
    static let keySpacing: CGFloat = 12
    #else
    static let boxWidth: CGFloat = 44
    static let boxHeight: CGFloat = 56
    static let boxCorner: CGFloat = 12
    static let boxSpacing: CGFloat = 12
    static let padSpacing: CGFloat = 20
    static let keyWidth: CGFloat = 0
    static let keyHeight: CGFloat = 0
    static let keySpacing: CGFloat = 0
    #endif
    static let compactBoxWidth: CGFloat = 36
    static let compactBoxHeight: CGFloat = 46
    static let compactBoxCorner: CGFloat = 10
    static let compactBoxSpacing: CGFloat = 10
}
