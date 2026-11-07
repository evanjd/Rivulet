// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Network

/// The device's network path. Cellular, a personal hotspot and Low Data Mode count as Away.
nonisolated final class NetworkPathMonitor: Sendable {
    static let shared = NetworkPathMonitor()
    private let monitor = NWPathMonitor()

    private init() {
        monitor.start(queue: DispatchQueue(label: "rivulet.network-path"))
    }

    var isAwayPath: Bool { Self.isAway(monitor.currentPath) }

    static func isAway(_ path: NWPath) -> Bool {
        path.usesInterfaceType(.cellular) || path.isExpensive || path.isConstrained
    }
}

extension StreamingQuality {
    /// Home: a local server address on a path that is not cellular, expensive or constrained.
    /// A host name is looked up first (`ServerLocation.resolving`), so a server reached by
    /// name is not taken for a remote one.
    nonisolated static func isHome(resolving serverURL: String) async -> Bool {
        await ServerLocation.resolving(serverURL) == .local && !NetworkPathMonitor.shared.isAwayPath
    }
}
