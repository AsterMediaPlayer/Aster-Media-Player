//
//  LibraryIndexTests.swift
//  AsterFINTests
//
//  Titles' sort order and letter sections, across writing systems.
//

import Foundation
import Testing
@testable import AsterFIN

struct LibraryIndexTests {
    @Test func aLeadingArticleIsLeftOut() {
        #expect(TitleSort.key("The Dark Knight") == "Dark Knight")
        #expect(TitleSort.key("A Bug's Life") == "Bug's Life")
        #expect(TitleSort.key("An American Tail") == "American Tail")
        // A title that's only the word, or starts with it inside a word, keeps it.
        #expect(TitleSort.key("The") == "The")
        #expect(TitleSort.key("Theodore Rex") == "Theodore Rex")
        #expect(TitleSort.key("Anastasia") == "Anastasia")
    }

    @Test func jellyfinsSortNameWins() {
        #expect(TitleSort.key("The 13 Ghosts of Scooby-Doo", sortName: "0000000013 ghosts of scoobydoo") == "0000000013 ghosts of scoobydoo")
    }

    @Test func titlesSortWithoutTheirArticle() {
        let titles = ["The Zoo", "Apple", "The Bear", "Cat"]
        #expect(titles.sorted(by: TitleSort.ordered) == ["Apple", "The Bear", "Cat", "The Zoo"])
        // Numbers in number order, not character order.
        #expect(["Episode 10", "Episode 2"].sorted(by: TitleSort.ordered) == ["Episode 2", "Episode 10"])
    }

    @Test func latinLettersFoldAccentsAndCase() {
        #expect(LibraryIndex.sectionKey("dark knight") == "D")
        #expect(LibraryIndex.sectionKey("Élan") == "E")
        #expect(LibraryIndex.sectionKey("ñandú") == "N")
        #expect(LibraryIndex.sectionKey("ｆｕｌｌ width") == "F")
    }

    @Test func numbersAndSymbolsGoUnderHash() {
        #expect(LibraryIndex.sectionKey("0000000013 ghosts") == "#")
        #expect(LibraryIndex.sectionKey("¡Three Amigos!") == "T")
        #expect(LibraryIndex.sectionKey("...") == "#")
    }

    @Test func otherWritingSystems() {
        #expect(LibraryIndex.sectionKey("Брат") == "Б")
        #expect(LibraryIndex.sectionKey("Ωμέγα") == "Ω")
        // Kana by row, katakana and voiced kana with their plain hiragana.
        #expect(LibraryIndex.sectionKey("かぐや様") == "か")
        #expect(LibraryIndex.sectionKey("ガンダム") == "か")
        #expect(LibraryIndex.sectionKey("ちはやふる") == "た")
        // Hangul by its first consonant, doubled with single.
        #expect(LibraryIndex.sectionKey("기생충") == "ㄱ")
        #expect(LibraryIndex.sectionKey("까치") == "ㄱ")
        // Chinese by the pinyin of its first character.
        #expect(LibraryIndex.sectionKey("霸王别姬") == "B")
    }

    @Test func sectionsAreInOrderWithHashLast() {
        func item(_ name: String, _ sortName: String? = nil) -> BaseItem {
            var item = try! JSONDecoder().decode(BaseItem.self, from: Data(#"{"Id":"\#(UUID().uuidString)","Name":"\#(name)","Type":"Movie"}"#.utf8))
            item.sortName = sortName
            return item
        }
        let sections = LibraryIndex.sections([
            item("The Zoo", "zoo"), item("Брат"), item("2001", "0000002001"), item("Apple"), item("The Bear", "bear"),
        ])
        #expect(sections.map(\.key) == ["A", "B", "Z", "Б", "#"])
        #expect(sections[1].items.map(\.displayTitle) == ["The Bear"])
    }
}
