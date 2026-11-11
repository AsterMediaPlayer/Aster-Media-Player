//
//  SettingsComponents.swift
//  AsterFIN
//
//  The pieces every settings page is made of: the page with its title,
//  the grey notes, and the rows that open a page of choices.
//

import SwiftUI

/// A settings form with the large page title as its first row, like the
/// in-page titles elsewhere. (A navigation bar title would add a second bar
/// under iPhone's More tab.)
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(macOS)
        // A page of the Settings window, named in its toolbar.
        Form {
            content()
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        #else
        Form {
            Section {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
            }
            content()
        }
        #endif
    }
}

/// What to call this device in settings notes: "Apple TV", "iPhone" or "iPad".
var deviceName: String {
    #if os(tvOS)
    "Apple TV"
    #elseif os(macOS)
    "Mac"
    #else
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    #endif
}

/// The small grey explanation under a group of settings.
struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A row showing the current choice that opens a page of options. Stands in
/// for a navigation-style Picker, whose pushed list hangs on tvOS when the
/// picker sits on a page that was itself pushed and uses a computed binding.
struct SettingsChoiceRow<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, name: String)]
    let selection: Binding<Value>

    var body: some View {
        #if os(macOS)
        // The Settings window has no pages to push: a pop-up menu.
        Picker(title, selection: selection) {
            ForEach(options, id: \.value) { option in
                Text(option.name).tag(option.value)
            }
        }
        .pickerStyle(.menu)
        #else
        NavigationLink {
            SettingsChoicePage(title: title, options: options, selection: selection)
        } label: {
            LabeledContent(title, value: options.first { $0.value == selection.wrappedValue }?.name ?? "")
        }
        #endif
    }
}

/// The options list: picking one saves it and goes back.
struct SettingsChoicePage<Value: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let options: [(value: Value, name: String)]
    let selection: Binding<Value>
    @State private var current: Value

    init(title: String, options: [(value: Value, name: String)], selection: Binding<Value>) {
        self.title = title
        self.options = options
        self.selection = selection
        _current = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        SettingsPage(title: title) {
            Section {
                ForEach(options, id: \.value) { option in
                    Button {
                        current = option.value
                        selection.wrappedValue = option.value
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.name)
                            Spacer()
                            if option.value == current {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A row showing the choices made from a list, which opens a page of them to
/// tick; each tick is applied as it's made. `none` names choosing nothing.
struct SettingsMultiChoiceRow: View {
    let title: String
    let options: [String]
    let selection: [String]
    var none = "None"
    var apply: ([String]) -> Void

    private var summary: String {
        selection.isEmpty ? none : selection.joined(separator: ", ")
    }

    var body: some View {
        #if os(macOS)
        Menu {
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { selection.contains { $0.caseInsensitiveCompare(option) == .orderedSame } },
                    set: { on in apply(SettingsMultiChoicePage.toggled(option, on: on, in: selection, order: options)) }
                ))
            }
        } label: {
            LabeledContent(title, value: summary)
        }
        #else
        NavigationLink {
            SettingsMultiChoicePage(title: title, options: options, selection: selection, apply: apply)
        } label: {
            LabeledContent(title) {
                Text(summary).lineLimit(1)
            }
        }
        #endif
    }
}

/// The page of choices to tick; it stays open, each tick applied at once.
struct SettingsMultiChoicePage: View {
    let title: String
    let options: [String]
    var apply: ([String]) -> Void
    @State private var current: [String]

    init(title: String, options: [String], selection: [String], apply: @escaping ([String]) -> Void) {
        self.title = title
        self.options = options
        self.apply = apply
        _current = State(initialValue: selection)
    }

    var body: some View {
        SettingsPage(title: title) {
            Section {
                ForEach(options, id: \.self) { option in
                    let isOn = current.contains { $0.caseInsensitiveCompare(option) == .orderedSame }
                    Button {
                        current = Self.toggled(option, on: !isOn, in: current, order: options)
                        apply(current)
                    } label: {
                        HStack {
                            Text(option)
                            Spacer()
                            if isOn { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        }
    }

    /// `selection` with `option` ticked or not, kept in `order`.
    static func toggled(_ option: String, on: Bool, in selection: [String], order: [String]) -> [String] {
        var chosen = selection.filter { $0.caseInsensitiveCompare(option) != .orderedSame }
        if on { chosen.append(option) }
        let rank = Dictionary(order.enumerated().map { ($1.lowercased(), $0) }) { first, _ in first }
        return chosen.sorted { (rank[$0.lowercased()] ?? .max) < (rank[$1.lowercased()] ?? .max) }
    }
}
