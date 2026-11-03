// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What Rivulet reads off a Jellyfin server's `/socket`: the keepalive
/// handshake and the two changes that alter what Home and the libraries show.
nonisolated enum JellyfinSocketMessage: Equatable, Sendable {
    /// `ForceKeepAlive`: the server drops the socket unless a `KeepAlive`
    /// arrives within `timeout` seconds.
    case forceKeepAlive(timeout: TimeInterval)
    /// `LibraryChanged`: items added, updated or removed, or folders added to.
    case libraryChanged
    /// `UserDataChanged`: watched state or a resume point moved, on any device.
    case userDataChanged
    /// Anything else (sessions, playstate, scheduled tasks, the server's own
    /// `KeepAlive` reply) and anything unreadable.
    case ignored

    /// The message the client sends to keep the socket open.
    static let keepAlive = #"{"MessageType":"KeepAlive"}"#

    /// Reads one text frame. Only the type matters except for `ForceKeepAlive`,
    /// whose `Data` is the timeout in seconds (a number, or a string on some servers).
    init(text: String) {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["MessageType"] as? String
        else {
            self = .ignored
            return
        }
        switch type {
        case "ForceKeepAlive":
            let raw = object["Data"]
            let timeout = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init)
            if let timeout, timeout > 0 {
                self = .forceKeepAlive(timeout: timeout)
            } else {
                self = .ignored
            }
        case "LibraryChanged": self = .libraryChanged
        case "UserDataChanged": self = .userDataChanged
        default: self = .ignored
        }
    }

    /// How often to send `KeepAlive` for a server timeout: half of it, never
    /// faster than every 5 s.
    static func keepAliveInterval(forTimeout timeout: TimeInterval) -> TimeInterval {
        max(timeout / 2, 5)
    }
}

/// Folds the socket's change messages into single reloads. A library scan
/// sends a burst, so a reload waits for `quiet` seconds with no new message,
/// but never more than `maxWait` after the first one. A `UserDataChanged`
/// arriving within `echoWindow` of a reload is the echo of our own watch-state
/// action (which reloads by itself) and is dropped. Any reload, ours or the
/// socket's, clears a pending one.
nonisolated struct JellyfinRefreshDebouncer: Sendable {
    var quiet: TimeInterval = 3
    var maxWait: TimeInterval = 20
    var echoWindow: TimeInterval = 5

    /// When the pending reload is due, or nil when none is pending.
    private(set) var deadline: Date?
    private var firstPending: Date?
    private var lastReload: Date?

    /// Records a socket message and returns the new deadline, or nil when the
    /// message does not call for a reload (the deadline is left as it was).
    @discardableResult
    mutating func receive(_ message: JellyfinSocketMessage, at now: Date) -> Date? {
        switch message {
        case .libraryChanged:
            break
        case .userDataChanged:
            if let lastReload, now.timeIntervalSince(lastReload) < echoWindow { return nil }
        case .forceKeepAlive, .ignored:
            return nil
        }
        let first = firstPending ?? now
        firstPending = first
        let due = min(now.addingTimeInterval(quiet), first.addingTimeInterval(maxWait))
        deadline = due
        return due
    }

    /// Records a reload, from any cause.
    mutating func reloaded(at now: Date) {
        lastReload = now
        deadline = nil
        firstPending = nil
    }
}
