// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import os

/// Looks a host name up through the system resolver (hosts file, mDNS, split DNS).
nonisolated enum HostResolver {
    /// The name's numeric addresses, or nil when the lookup fails or outlasts `timeout`.
    /// getaddrinfo blocks and can't be cancelled, so it runs on a global queue and a late
    /// answer is dropped.
    static func addresses(of host: String, timeout: TimeInterval = 3) async -> [String]? {
        await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable ([String]?) -> Void = { value in
                let first = finished.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).async { finish(lookup(host)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private static func lookup(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
        }
        return addresses.isEmpty ? nil : addresses
    }
}
