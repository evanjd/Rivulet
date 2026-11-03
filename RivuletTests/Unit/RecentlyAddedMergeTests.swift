// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Home's merged Recently Added row.
final class RecentlyAddedMergeTests: XCTestCase {

    private struct Item: Equatable {
        let id: String
        let added: TimeInterval?
        var keys: [String] = []
    }

    private func merge(_ rows: [[Item]], limit: Int = RecentlyAddedMerge.limit) -> [String] {
        RecentlyAddedMerge.merge(rows, id: \.id, keys: \.keys,
                                 added: { $0.added.map(Date.init(timeIntervalSince1970:)) }, limit: limit).map(\.id)
    }

    // MARK: Across servers

    func test_sameTitleOnTwoServers_keepsTheNewestCopy() {
        let plex = [Item(id: "plex-moscow", added: 30, keys: ["s:tvdb:1"]), Item(id: "plex-ferris", added: 10, keys: ["m:imdb:tt1"])]
        let jellyfin = [Item(id: "jf-moscow", added: 40, keys: ["s:tmdb:9", "s:tvdb:1"]), Item(id: "jf-other", added: 20, keys: ["m:imdb:tt2"])]
        XCTAssertEqual(merge([plex, jellyfin]), ["jf-moscow", "jf-other", "plex-ferris"])
    }

    func test_movieAndShowWithTheSameNumberDoNotMerge() {
        let a = [Item(id: "movie", added: 20, keys: ["m:tmdb:5"])]
        let b = [Item(id: "show", added: 10, keys: ["s:tmdb:5"])]
        XCTAssertEqual(merge([a, b]), ["movie", "show"], "tmdb numbers repeat across movies and TV")
    }

    func test_droppedCopyStillBridgesAThird() {
        let row = [Item(id: "a", added: 30, keys: ["k1"]),
                   Item(id: "b", added: 20, keys: ["k1", "k2"]),
                   Item(id: "c", added: 10, keys: ["k2"])]
        XCTAssertEqual(merge([row]), ["a"])
    }

    func test_itemsWithoutKeysNeverMerge() {
        let row = [Item(id: "a", added: 20), Item(id: "b", added: 10)]
        XCTAssertEqual(merge([row]), ["a", "b"])
    }

    // MARK: Order

    func test_interleavesLibrariesNewestFirst() {
        let movies = [Item(id: "m1", added: 50), Item(id: "m2", added: 20)]
        let shows = [Item(id: "s1", added: 40), Item(id: "s2", added: 30), Item(id: "s3", added: 10)]
        XCTAssertEqual(merge([movies, shows]), ["m1", "s1", "s2", "m2", "s3"])
    }

    func test_equalDatesKeepRowOrder() {
        let a = [Item(id: "a1", added: 10), Item(id: "a2", added: 10)]
        let b = [Item(id: "b1", added: 10)]
        XCTAssertEqual(merge([a, b]), ["a1", "a2", "b1"])
    }

    func test_undatedItemKeepsItsPlaceInItsRow() {
        let movies = [Item(id: "m1", added: 50), Item(id: "m2", added: nil), Item(id: "m3", added: 10)]
        let shows = [Item(id: "s1", added: 30)]
        XCTAssertEqual(merge([movies, shows]), ["m1", "m2", "s1", "m3"])
    }

    /// Jellyfin's Latest lists a season by its newest episode but dates it by
    /// the season itself (Jeopardy!'s "Season 2026": listed third, dated July).
    func test_itemDatedOlderThanTheOneAfterIt_keepsItsPlaceInItsRow() {
        let shows = [Item(id: "frenemies", added: 50), Item(id: "jeopardy", added: 1),
                     Item(id: "hotSeat", added: 40), Item(id: "robot", added: 1)]
        let movies = [Item(id: "gattaca", added: 45), Item(id: "memento", added: 5)]
        XCTAssertEqual(merge([shows, movies]), ["frenemies", "gattaca", "jeopardy", "hotSeat", "memento", "robot"])
    }

    func test_undatedHeadTakesTheFirstDateAfterIt() {
        let movies = [Item(id: "m1", added: nil), Item(id: "m2", added: 50)]
        let shows = [Item(id: "s1", added: 40)]
        XCTAssertEqual(merge([movies, shows]), ["m1", "m2", "s1"], "the row's newest item stays at its head")
    }

    func test_undatedRowFollowsDatedRows() {
        let cached = [Item(id: "c1", added: nil), Item(id: "c2", added: nil)]
        let fresh = [Item(id: "f1", added: 5)]
        XCTAssertEqual(merge([cached, fresh]), ["f1", "c1", "c2"])
    }

    func test_allUndatedRowsInterleave() {
        let movies = [Item(id: "m1", added: nil), Item(id: "m2", added: nil), Item(id: "m3", added: nil)]
        let shows = [Item(id: "s1", added: nil)]
        XCTAssertEqual(merge([movies, shows]), ["m1", "s1", "m2", "m3"],
                       "a cold launch from cache still shows every library near the front")
    }

    func test_duplicateKeyKeepsNewestCopy() {
        let a = [Item(id: "x", added: 10)]
        let b = [Item(id: "x", added: 20), Item(id: "y", added: 5)]
        XCTAssertEqual(merge([a, b]), ["x", "y"])
    }

    func test_capsAtLimit() {
        let row = (0..<10).map { Item(id: "i\($0)", added: TimeInterval(100 - $0)) }
        XCTAssertEqual(merge([row], limit: 3), ["i0", "i1", "i2"])
    }
}
