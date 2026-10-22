//
//  LibraryIndex.swift
//  AsterFIN
//
//  A library sorted by name, in letter sections with an index to jump
//  between them: a strip down the right edge on iPhone, iPad and the Mac,
//  a row of letters above the grid on the Apple TV.
//
//  Titles sort as Jellyfin's sort name has them (no leading "The", "A" or
//  "An"), compared the way the device's language does. The sections follow
//  the writing system: accented letters go with their letter, Cyrillic or
//  Greek get their own, Japanese kana go by row (あ か さ …), Korean by
//  its first consonant, Chinese by the pinyin of its first character, and
//  numbers and symbols under #.
//

import SwiftUI

/// How titles are put in order.
nonisolated enum TitleSort {
    /// Leading words a title is sorted without, as Jellyfin does by default.
    private static let articles = ["the ", "a ", "an "]

    /// What a title sorts by: Jellyfin's sort name when it has one, else the
    /// title without a leading article.
    static func key(_ title: String, sortName: String? = nil) -> String {
        if let sortName, !sortName.isEmpty { return sortName }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        for article in articles where lowered.hasPrefix(article) && lowered.count > article.count {
            return String(trimmed.dropFirst(article.count))
        }
        return trimmed
    }

    static func key(for item: BaseItem) -> String {
        key(item.displayTitle, sortName: item.sortName)
    }

    /// Whether `a` comes before `b`: numbers in number order, case and
    /// accents as the device's language orders them.
    static func ordered(_ a: String, _ b: String) -> Bool {
        let order = key(a).localizedStandardCompare(key(b))
        return order == .orderedAscending
    }
}

/// One letter's titles.
struct IndexSection: Identifiable, Hashable {
    let key: String
    let items: [BaseItem]
    var id: String { key }
}

nonisolated enum LibraryIndex {
    /// Where numbers, symbols and anything without a letter go: last, as on
    /// iOS.
    static let other = "#"

    /// `items` in order and in their letter sections.
    static func sections(_ items: [BaseItem]) -> [IndexSection] {
        let sorted = items
            .map { (item: $0, key: TitleSort.key(for: $0)) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        var order: [String] = []
        var grouped: [String: [BaseItem]] = [:]
        for entry in sorted {
            let section = sectionKey(entry.key)
            if grouped[section] == nil { order.append(section) }
            grouped[section, default: []].append(entry.item)
        }
        // Latin letters first, then other writing systems as the language
        // orders them, # last.
        let keys = order.sorted { a, b in
            if a == other || b == other { return b == other && a != other }
            let aLatin = isLatinLetter(a), bLatin = isLatinLetter(b)
            if aLatin != bLatin { return aLatin }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return keys.map { IndexSection(key: $0, items: grouped[$0] ?? []) }
    }

    /// The section a sort key goes in.
    static func sectionKey(_ text: String) -> String {
        let skipped = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        guard let scalar = text.unicodeScalars.first(where: { !skipped.contains($0) }) else { return other }
        if CharacterSet.decimalDigits.contains(scalar) { return other }
        let value = scalar.value
        let character = String(scalar)

        // Chinese: the first letter of its pinyin.
        if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
            if let latin = character.applyingTransform(.mandarinToLatin, reverse: false), let letter = folded(latin).first, letter.isLetter {
                return String(letter)
            }
            return other
        }
        // Korean: the syllable's first consonant, doubled ones with their single.
        if (0xAC00...0xD7A3).contains(value) {
            let initials = Array("ㄱㄱㄴㄷㄷㄹㅁㅂㅂㅅㅅㅇㅈㅈㅊㅋㅌㅍㅎ")
            return String(initials[Int((value - 0xAC00) / 588)])
        }
        // Japanese kana: its row, katakana with hiragana, voiced with plain.
        if (0x3041...0x3096).contains(value) || (0x30A1...0x30FA).contains(value) {
            let hiragana = character.applyingTransform(.hiraganaToKatakana, reverse: true) ?? character
            // The voicing marks (゛ ゜) split off as their own character;
            // folding accents doesn't remove them.
            let plain = hiragana.decomposedStringWithCanonicalMapping.unicodeScalars.first.map(String.init) ?? hiragana
            if let row = kanaRows.first(where: { $0.contains(plain) }), let head = row.first {
                return String(head)
            }
            return other
        }
        let letter = folded(character)
        guard let first = letter.first, first.isLetter else { return other }
        return String(first)
    }

    /// The gojūon rows, each led by its index letter.
    private static let kanaRows = ["あいうえおぁぃぅぇぉ", "かきくけこゕゖ", "さしすせそ", "たちつてとっ", "なにぬねの",
                                   "はひふへほ", "まみむめも", "やゆよゃゅょ", "らりるれろ", "わゐゑをんゎ"]

    /// Without accents, width or case: "é" → "E", "ｆ" → "F".
    private static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current).uppercased()
    }

    private static func isLatinLetter(_ key: String) -> Bool {
        key.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
    }
}

/// A grid of titles in their letter sections, each led by its letter.
struct SectionedItemGrid: View {
    let sections: [IndexSection]
    var landscape = false
    var focus: FocusState<String?>.Binding? = nil

    private var columns: [GridItem] {
        let width = landscape ? Lockup.landscapeWidth : Lockup.posterWidth
        return [GridItem(.adaptive(minimum: width, maximum: width), spacing: Lockup.gridSpacing, alignment: .top)]
    }

    /// Up to this many titles, the grid is built whole rather than as it
    /// scrolls into view. A lazy grid stands placeholders in for rows not yet
    /// built, and on Apple TV a press down lands on one, then jumps to the
    /// real card a moment later: the bounce, and sometimes a second press.
    /// Big libraries stay lazy, to open quickly.
    static let builtWholeUpTo = 200

    private var buildsWhole: Bool {
        sections.reduce(0) { $0 + $1.items.count } <= Self.builtWholeUpTo
    }

    /// The grid's width, for how many titles fit in a row when built whole.
    @State private var width: CGFloat = 0
    /// The last focus change in the grid: from which card to which, and
    /// when. A press whose own move already went card to card is left alone;
    /// one that bounced off a stand-in (back from nothing) is carried on.
    /// Kept in a box SwiftUI doesn't watch, so a move doesn't rebuild every
    /// card mid-animation.
    @State private var focusChanges = FocusChangeLog()

    private var itemWidth: CGFloat { landscape ? Lockup.landscapeWidth : Lockup.posterWidth }

    private var perRow: Int {
        guard width > 0 else { return 1 }
        return max(1, Int((width + Lockup.gridSpacing) / (itemWidth + Lockup.gridSpacing)))
    }

    var body: some View {
        // No focus sections here: a section fills its empty space with
        // invisible stand-ins to catch presses, and the space under each card
        // (its title) caught every press down and sent it back to the card.
        Group {
            if buildsWhole {
                VStack(alignment: .leading, spacing: Lockup.gridRowSpacing) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: Lockup.gridRowSpacing) {
                            #if !os(tvOS)
                            header(section)
                            #endif
                            ForEach(Array(stride(from: 0, to: section.items.count, by: perRow)), id: \.self) { start in
                                HStack(alignment: .top, spacing: Lockup.gridSpacing) {
                                    ForEach(section.items[start ..< min(start + perRow, section.items.count)]) { item in
                                        lockup(item)
                                    }
                                }
                                #if os(tvOS)
                                // The letter sits in the margin beside its first
                                // row, so every row is spaced alike. A heading of
                                // its own made a tall gap, where the focus engine
                                // put a stand-in that bounced each press across
                                // letters, stuttering the scroll.
                                .overlay(alignment: .topLeading) {
                                    if start == 0 { marginLetter(section) }
                                }
                                #endif
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: Lockup.gridRowSpacing) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: Lockup.gridRowSpacing) {
                            header(section)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: Lockup.gridRowSpacing) {
                                ForEach(section.items) { item in
                                    lockup(item)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        #if os(tvOS)
        // Up and down move a row at a time, by the grid's own layout. Left to
        // the focus engine, a press landed on invisible stand-ins it puts in
        // the gaps between cards (the titles, the letter headings), which sent
        // it straight back: every move took two presses.
        // Watched from a background view, so only that view redraws per move.
        .background {
            if let focus { FocusChangeWatcher(focus: focus, log: focusChanges) }
        }
        .onMoveCommand { direction in
            guard buildsWhole, direction == .down || direction == .up, let focus, let current = focus.wrappedValue else { return }
            // The focus engine's own move got there, card to card, just now.
            if let change = focusChanges.last, change.to == current, change.from != nil, change.from != current,
               Date().timeIntervalSince(change.at) < 0.3 {
                return
            }
            guard let target = Self.target(from: current, down: direction == .down, in: sections, perRow: perRow) else { return }
            focus.wrappedValue = target
            // Again once the focus engine has had its own go, in case it moved
            // focus back meanwhile.
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                if focus.wrappedValue != target { focus.wrappedValue = target }
            }
        }
        #endif
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.vertical, 40)
    }

    /// The card a press up or down from `current` goes to: the same column a
    /// row along (the last card of a shorter row), crossing into the letter
    /// before or after at its ends; nil off the top or bottom, or for left and
    /// right, which the focus engine handles.
    static func target(from current: String, down: Bool, in sections: [IndexSection], perRow: Int) -> String? {
        guard perRow > 0,
              let sectionIndex = sections.firstIndex(where: { $0.items.contains { $0.id == current } }),
              let index = sections[sectionIndex].items.firstIndex(where: { $0.id == current }) else { return nil }
        let items = sections[sectionIndex].items
        let column = index % perRow
        let row = index / perRow
        let rows = (items.count + perRow - 1) / perRow
        func card(row: Int, in items: [BaseItem]) -> String? {
            let start = row * perRow
            guard start < items.count else { return nil }
            return items[min(start + column, items.count - 1)].id
        }
        if down {
            if row + 1 < rows { return card(row: row + 1, in: items) }
            guard sectionIndex + 1 < sections.count else { return nil }
            return card(row: 0, in: sections[sectionIndex + 1].items)
        } else {
            if row > 0 { return card(row: row - 1, in: items) }
            guard sectionIndex > 0 else { return nil }
            let previous = sections[sectionIndex - 1].items
            return card(row: (previous.count - 1) / perRow, in: previous)
        }
    }

    private func header(_ section: IndexSection) -> some View {
        Text(section.key)
            .font(.title3.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .id(LibraryIndexBar.anchor(section.key))
            .accessibilityAddTraits(.isHeader)
    }

    /// A letter's label in the left margin, level with its first row's top.
    private func marginLetter(_ section: IndexSection) -> some View {
        Text(section.key)
            .font(.title3.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: Lockup.screenPadding, alignment: .center)
            .offset(x: -Lockup.screenPadding)
            .padding(.top, 8)
            .id(LibraryIndexBar.anchor(section.key))
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func lockup(_ item: BaseItem) -> some View {
        if landscape {
            LandscapeLockup(item: item, focus: focus)
        } else {
            PosterLockup(item: item, focus: focus)
        }
    }
}

/// A grid's last focus change, in a plain object: writing to it doesn't
/// redraw anything.
final class FocusChangeLog {
    var last: (from: String?, to: String?, at: Date)?
}

/// Notes each focus change in a `FocusChangeLog`. Being its own small view,
/// it's the only thing that redraws when focus moves.
private struct FocusChangeWatcher: View {
    let focus: FocusState<String?>.Binding
    let log: FocusChangeLog

    var body: some View {
        Color.clear
            .onChange(of: focus.wrappedValue) { old, new in
                log.last = (old, new, Date())
            }
    }
}

/// The index of a sectioned grid's letters. `jump` brings one's section up.
struct LibraryIndexBar: View {
    let keys: [String]
    var jump: (String) -> Void

    /// The scroll anchor of a section's header.
    static func anchor(_ key: String) -> String { "index-section-\(key)" }

    /// Room the grid leaves on the right for the strip (none on the TV,
    /// where the letters sit above the grid).
    static var stripRoom: CGFloat {
        #if os(tvOS)
        0
        #else
        28
        #endif
    }

    var body: some View {
        #if os(tvOS)
        // A row of letters above the grid: down from it goes into the titles.
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        jump(key)
                    } label: {
                        Text(key)
                            .font(.callout.weight(.semibold))
                            .frame(minWidth: 36)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Jump to \(key)")
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .focusSection()
        #else
        // The usual strip down the right edge: tap a letter, or drag along it.
        VStack(spacing: 0) {
            ForEach(keys, id: \.self) { key in
                Button {
                    jump(key)
                } label: {
                    Text(key)
                        .font(.caption2.weight(.semibold))
                        .frame(width: 22, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel("Jump to \(key)")
            }
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
            // 15 points a letter, after the 6-point top padding.
            let index = Int((value.location.y - 6) / 15)
            if keys.indices.contains(index), lastDragged != keys[index] {
                lastDragged = keys[index]
                jump(keys[index])
            }
        }.onEnded { _ in lastDragged = nil })
        .sensoryFeedback(.selection, trigger: lastDragged)
        #endif
    }

    #if !os(tvOS)
    @State private var lastDragged: String?
    #endif
}
