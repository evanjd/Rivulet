// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Jellyfin's `/socket` messages and the reload debounce built on them.
final class JellyfinSocketTests: XCTestCase {

    // MARK: Parsing

    func test_forceKeepAlive_readsTheTimeout() {
        let text = #"{"MessageType":"ForceKeepAlive","Data":60,"MessageId":"a1"}"#
        XCTAssertEqual(JellyfinSocketMessage(text: text), .forceKeepAlive(timeout: 60))
    }

    func test_forceKeepAlive_acceptsAStringTimeout() {
        XCTAssertEqual(JellyfinSocketMessage(text: #"{"MessageType":"ForceKeepAlive","Data":"30"}"#),
                       .forceKeepAlive(timeout: 30))
    }

    func test_forceKeepAlive_withoutAUsableTimeout_isIgnored() {
        XCTAssertEqual(JellyfinSocketMessage(text: #"{"MessageType":"ForceKeepAlive","Data":0}"#), .ignored)
        XCTAssertEqual(JellyfinSocketMessage(text: #"{"MessageType":"ForceKeepAlive"}"#), .ignored)
    }

    func test_libraryChanged() {
        let text = #"{"MessageType":"LibraryChanged","Data":{"ItemsAdded":["x"],"ItemsUpdated":[],"ItemsRemoved":[],"FoldersAddedTo":[]}}"#
        XCTAssertEqual(JellyfinSocketMessage(text: text), .libraryChanged)
    }

    func test_userDataChanged() {
        let text = #"{"MessageType":"UserDataChanged","Data":{"UserId":"u","UserDataList":[]}}"#
        XCTAssertEqual(JellyfinSocketMessage(text: text), .userDataChanged)
    }

    func test_otherTypesAndJunk_areIgnored() {
        XCTAssertEqual(JellyfinSocketMessage(text: #"{"MessageType":"KeepAlive"}"#), .ignored)
        XCTAssertEqual(JellyfinSocketMessage(text: #"{"MessageType":"Sessions","Data":[]}"#), .ignored)
        XCTAssertEqual(JellyfinSocketMessage(text: "not json"), .ignored)
        XCTAssertEqual(JellyfinSocketMessage(text: #"["MessageType"]"#), .ignored)
    }

    func test_keepAliveInterval_isHalfTheTimeoutWithAFloor() {
        XCTAssertEqual(JellyfinSocketMessage.keepAliveInterval(forTimeout: 60), 30)
        XCTAssertEqual(JellyfinSocketMessage.keepAliveInterval(forTimeout: 4), 5)
    }

    // MARK: Debounce

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func test_aBurst_isOneReloadAfterTheLastMessage() {
        var debouncer = JellyfinRefreshDebouncer()
        debouncer.receive(.libraryChanged, at: at(0))
        debouncer.receive(.libraryChanged, at: at(1))
        XCTAssertEqual(debouncer.receive(.libraryChanged, at: at(2)), at(5))
        XCTAssertEqual(debouncer.deadline, at(5))
    }

    func test_aLongBurst_stillReloadsByMaxWait() {
        var debouncer = JellyfinRefreshDebouncer()
        for second in stride(from: 0.0, through: 30, by: 2) {
            debouncer.receive(.libraryChanged, at: at(second))
        }
        XCTAssertEqual(debouncer.deadline, at(20))
    }

    func test_userDataChanged_soonAfterAReload_isOurOwnEcho() {
        var debouncer = JellyfinRefreshDebouncer()
        debouncer.reloaded(at: at(0))
        XCTAssertNil(debouncer.receive(.userDataChanged, at: at(2)))
        XCTAssertNil(debouncer.deadline)
    }

    func test_userDataChanged_fromAnotherDevice_reloads() {
        var debouncer = JellyfinRefreshDebouncer()
        debouncer.reloaded(at: at(0))
        XCTAssertEqual(debouncer.receive(.userDataChanged, at: at(60)), at(63))
    }

    func test_libraryChanged_soonAfterAReload_stillReloads() {
        var debouncer = JellyfinRefreshDebouncer()
        debouncer.reloaded(at: at(0))
        XCTAssertEqual(debouncer.receive(.libraryChanged, at: at(1)), at(4))
    }

    func test_aReload_clearsThePendingOne_andRestartsMaxWait() {
        var debouncer = JellyfinRefreshDebouncer()
        debouncer.receive(.userDataChanged, at: at(0))
        debouncer.reloaded(at: at(1))
        XCTAssertNil(debouncer.deadline)
        XCTAssertEqual(debouncer.receive(.libraryChanged, at: at(30)), at(33))
    }

    func test_keepAliveAndIgnored_leaveThePendingReloadAlone() {
        var debouncer = JellyfinRefreshDebouncer()
        debouncer.receive(.libraryChanged, at: at(0))
        XCTAssertNil(debouncer.receive(.forceKeepAlive(timeout: 60), at: at(1)))
        XCTAssertNil(debouncer.receive(.ignored, at: at(2)))
        XCTAssertEqual(debouncer.deadline, at(3))
    }
}
