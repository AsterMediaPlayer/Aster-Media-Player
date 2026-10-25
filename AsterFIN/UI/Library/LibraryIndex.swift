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

#if !os(tvOS)
/// A grid of titles in their letter sections, each led by its letter, on
/// iPhone, iPad and the Mac. The Apple TV's grid is `TVCollectionGrid`.
struct SectionedItemGrid: View {
    let sections: [IndexSection]
    var landscape = false

    private var columns: [GridItem] {
        let width = landscape ? Lockup.landscapeWidth : Lockup.posterWidth
        return [GridItem(.adaptive(minimum: width, maximum: width), spacing: Lockup.gridSpacing, alignment: .top)]
    }

    /// Up to this many titles the grid is built whole rather than as it
    /// scrolls into view; big libraries stay lazy, to open quickly.
    static let builtWholeUpTo = 200

    private var buildsWhole: Bool {
        sections.reduce(0) { $0 + $1.items.count } <= Self.builtWholeUpTo
    }

    /// The grid's width, for how many titles fit in a row when built whole.
    @State private var width: CGFloat = 0

    private var itemWidth: CGFloat { landscape ? Lockup.landscapeWidth : Lockup.posterWidth }

    private var perRow: Int {
        guard width > 0 else { return 1 }
        return max(1, Int((width + Lockup.gridSpacing) / (itemWidth + Lockup.gridSpacing)))
    }

    var body: some View {
        Group {
            if buildsWhole {
                VStack(alignment: .leading, spacing: Lockup.gridRowSpacing) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: Lockup.gridRowSpacing) {
                            header(section)
                            ForEach(Array(stride(from: 0, to: section.items.count, by: perRow)), id: \.self) { start in
                                HStack(alignment: .top, spacing: Lockup.gridSpacing) {
                                    ForEach(section.items[start ..< min(start + perRow, section.items.count)]) { item in
                                        lockup(item)
                                    }
                                }
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
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.vertical, 40)
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

    @ViewBuilder
    private func lockup(_ item: BaseItem) -> some View {
        if landscape {
            LandscapeLockup(item: item)
        } else {
            PosterLockup(item: item)
        }
    }
}
#endif

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
        // UIKit buttons, as SwiftUI ones in a scroll view inside the grid's
        // hosted header never reach the focus engine.
        TVLetterRow(keys: keys, jump: jump)
            .frame(height: 90)
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

#if os(tvOS)
/// The Apple TV's letters: a scrolling row of UIKit buttons.
private struct TVLetterRow: UIViewRepresentable {
    let keys: [String]
    var jump: (String) -> Void

    func makeUIView(context: Context) -> TVLetterRowView {
        TVLetterRowView()
    }

    func updateUIView(_ view: TVLetterRowView, context: Context) {
        view.jump = jump
        view.show(keys)
    }
}

final class TVLetterRowView: UIView {
    var jump: ((String) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var keys: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        // A focused letter lifts past the row.
        clipsToBounds = false
        scrollView.clipsToBounds = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        addSubview(scrollView)
        scrollView.addSubview(stack)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = scrollView.contentLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Lockup.screenPadding),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Lockup.screenPadding),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Rebuilds the buttons when the letters change.
    func show(_ keys: [String]) {
        guard keys != self.keys else { return }
        self.keys = keys
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in keys {
            var configuration = UIButton.Configuration.bordered()
            configuration.cornerStyle = .capsule
            configuration.title = key
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
                return attributes
            }
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.jump?(key)
            })
            button.accessibilityLabel = "Jump to \(key)"
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
            stack.addArrangedSubview(button)
        }
    }
}
#endif
