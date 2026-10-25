//
//  ItemQueryTests.swift
//  AsterFINTests
//
//  Typed queries give Jellyfin exactly the parameters the screens sent
//  before they used them: each expectation is the literal dictionary the
//  screen built by hand.
//

import Foundation
import Testing
@testable import AsterFIN

struct ItemQueryTests {
    @Test func libraryFavorites() {
        let query = ItemQuery(kinds: [.movie, .series, .episode], recursive: true, sort: .name, filters: [.favorite], limit: 40)
        #expect(query.jellyfinParameters == [
            "recursive": "true",
            "filters": "IsFavorite",
            "includeItemTypes": "Movie,Series,Episode",
            "sortBy": "SortName",
            "limit": "40",
        ])
    }

    @Test func eachSortAsBefore() {
        let expected: [(ItemSort, Bool, String, String)] = [
            (.name, false, "SortName", "Ascending"),
            (.dateAdded, true, "DateCreated,SortName", "Descending"),
            (.releaseDate, true, "PremiereDate,SortName", "Descending"),
            (.rating, true, "CommunityRating,SortName", "Descending"),
        ]
        for (sort, descending, sortBy, order) in expected {
            let query = ItemQuery(kinds: [.movie], recursive: true, sort: sort, descending: descending)
            #expect(query.jellyfinParameters == [
                "includeItemTypes": "Movie",
                "recursive": "true",
                "sortBy": sortBy,
                "sortOrder": order,
            ])
        }
    }

    @Test func aLibrarysTitles() {
        let movies = ItemQuery(parentId: "lib", kinds: [.movie], recursive: true, sort: .name, descending: false)
        #expect(movies.jellyfinParameters == [
            "parentId": "lib",
            "sortBy": "SortName",
            "sortOrder": "Ascending",
            "includeItemTypes": "Movie",
            "recursive": "true",
        ])
        // A folder library: just its own contents.
        let folder = ItemQuery(parentId: "lib", sort: .dateAdded, descending: true)
        #expect(folder.jellyfinParameters == [
            "parentId": "lib",
            "sortBy": "DateCreated,SortName",
            "sortOrder": "Descending",
        ])
    }

    @Test func aPersonsFilmography() {
        let query = ItemQuery(kinds: [.movie, .series], recursive: true, sort: .releaseDate, descending: true, personId: "p1")
        #expect(query.jellyfinParameters == [
            "personIds": "p1",
            "recursive": "true",
            "includeItemTypes": "Movie,Series",
            "sortBy": "PremiereDate,SortName",
            "sortOrder": "Descending",
        ])
    }

    /// Music's grids still take the sort in Jellyfin's terms.
    @Test func librarySortsKeepTheirJellyfinNames() {
        #expect(LibrarySort.name.query == ("SortName", "Ascending"))
        #expect(LibrarySort.dateAdded.query == ("DateCreated,SortName", "Descending"))
        #expect(LibrarySort.releaseDate.query == ("PremiereDate,SortName", "Descending"))
        #expect(LibrarySort.rating.query == ("CommunityRating,SortName", "Descending"))
    }

    @Test func exactTitles() {
        #expect(ItemQuery(ids: ["a", "b"]).jellyfinParameters == ["ids": "a,b"])
    }

    @Test func pagesAddTheirPlace() {
        let query = ItemQuery(kinds: [.series], recursive: true).page(from: 200, size: 100)
        #expect(query.jellyfinParameters == [
            "includeItemTypes": "Series",
            "recursive": "true",
            "startIndex": "200",
            "limit": "100",
        ])
    }
}
