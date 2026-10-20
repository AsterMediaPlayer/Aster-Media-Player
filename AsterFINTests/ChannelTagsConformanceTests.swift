//
//  ChannelTagsConformanceTests.swift
//  AsterFINTests
//
//  Channel tags against Conformance/channel-tags.json: playlists' tags in,
//  whether they make a channel, and every tag a save writes back, in order.
//  Anything else that reads or writes the tags (the Jellyfin dashboard
//  plugin) runs the same file, so the two can't drift apart.
//

import Foundation
import Testing
@testable import AsterFIN

struct ChannelTagsConformanceTests {
    nonisolated struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let tags: [String]
            let isChannel: Bool
            let written: [String]
        }
        let cases: [Case]
    }

    /// Loaded inside the tests, never while they're being found, so a
    /// file that can't be read fails a test rather than the whole run.
    private static func vectors() throws -> Vectors {
        // Copied into the test bundle (a simulator can't see the source
        // folder); straight from the source folder where it can.
        let bundled = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }?.url(forResource: "channel-tags", withExtension: "json")
        let url = bundled ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Conformance/channel-tags.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test func theVectorsAreThere() throws {
        #expect(try Self.vectors().cases.count >= 10)
    }

    @Test func tagsAreReadAndWrittenAsTheVectorsSay() throws {
        for vector in try Self.vectors().cases {
            let tags = ChannelTags(tags: vector.tags)
            #expect(tags.isChannel == vector.isChannel, "\(vector.name)")
            #expect(tags.applied(to: vector.tags) == vector.written, "\(vector.name)")
            // Writing is settled: what was written writes the same again. (It
            // needn't read back identical: break settings without a filler
            // playlist, say, aren't written at all.)
            #expect(ChannelTags(tags: vector.written).applied(to: vector.written) == vector.written, "\(vector.name)")
        }
    }
}
