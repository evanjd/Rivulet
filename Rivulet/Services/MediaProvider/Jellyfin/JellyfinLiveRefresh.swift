// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinLiveRefresh.swift
//  Rivulet
//
//  Keeps a WebSocket open to the signed-in Jellyfin server's `/socket` and
//  refetches that server's slice of ServerDataStore when it reports new
//  content or a watch-state change, so Home follows the server without the
//  user leaving the app. Driven from `ServerDataStore.reload()`, which already
//  follows the account, sign-out and the restricted-profile rule. A server
//  that refuses the socket (a reverse proxy without upgrade support) leaves
//  the app as it was without it: there is no fallback poll.
//

import Foundation

@MainActor
final class JellyfinLiveRefresh {
    static let shared = JellyfinLiveRefresh()

    /// Refetches the server's content. Set by ServerDataStore.
    var onRefresh: ((JellyfinProvider) -> Void)?

    /// LibraryChanged lists every item id it covers, so a big scan's frame
    /// passes URLSession's 1 MiB default.
    private static let maximumMessageSize = 16 * 1024 * 1024

    private var provider: JellyfinProvider?
    private var socket: URLSessionWebSocketTask?
    /// Bumped on every connect and teardown, so a stale loop stops itself.
    private var generation = 0
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var failures = 0
    /// The socket dropped: messages sent meanwhile are lost, so the next open refetches.
    private var needsCatchUp = false
    /// In the background: track the provider, but stay closed until `resume`.
    private var suspended = false
    /// The server and token that refused the handshake; not retried before `resume`.
    private var refused: (id: String, token: String?)?
    private var debouncer = JellyfinRefreshDebouncer()

    /// Follows `provider`: connects to it, keeps an open socket to the same
    /// server and token, or tears down for nil. Also records the reload that
    /// called it, so our own watch-state echoes are dropped.
    func sync(_ provider: JellyfinProvider?) {
        debouncer.reloaded(at: Date())
        refreshTask?.cancel()
        guard let provider else {
            if self.provider != nil { DiagLog.notice(.servers, "jellyfin socket: signed out") }
            self.provider = nil
            teardown()
            return
        }
        let same = self.provider.map { Self.sameServer($0, provider) } ?? false
        self.provider = provider
        guard !suspended else { return }
        if let refused, refused.id == provider.id, refused.token == provider.client.token { return }
        if same, socket != nil || reconnectTask != nil { return }
        failures = 0
        needsCatchUp = false
        connect()
    }

    /// Closes the socket on background. A reload while backgrounded does not reopen it.
    func suspend() {
        suspended = true
        guard socket != nil || reconnectTask != nil else { return }
        teardown()
        DiagLog.notice(.servers, "jellyfin socket: closed for background")
    }

    /// Back in the foreground: the next `sync` (the foreground reload, which
    /// also covers whatever changed meanwhile) reconnects, and a server that
    /// refused the socket gets another try.
    func resume() {
        suspended = false
        refused = nil
    }

    private static func sameServer(_ a: JellyfinProvider, _ b: JellyfinProvider) -> Bool {
        a.id == b.id && a.client.token == b.client.token
    }

    private func teardown() {
        generation += 1
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        reconnectTask?.cancel()
        refreshTask?.cancel()
        receiveTask = nil
        keepAliveTask = nil
        reconnectTask = nil
        refreshTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func connect() {
        teardown()
        guard let provider, let url = Self.socketURL(provider.client.url("socket")) else { return }
        var request = URLRequest(url: url)
        request.setValue(provider.client.authorization, forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = Self.maximumMessageSize
        self.socket = socket
        let generation = self.generation
        socket.resume()
        DiagLog.notice(.servers, "jellyfin socket: connecting \(DiagLog.describe(url: url.absoluteString))")
        receiveTask = Task { [weak self] in await self?.receive(on: socket, generation: generation) }
    }

    /// `http(s)://host/base/socket` -> `ws(s)://host/base/socket`.
    nonisolated static func socketURL(_ httpURL: URL) -> URL? {
        guard var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        return components.url
    }

    private func receive(on socket: URLSessionWebSocketTask, generation: Int) async {
        var opened = false
        while generation == self.generation {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await socket.receive()
            } catch {
                guard generation == self.generation else { return }
                dropped(socket, error: error, opened: opened)
                return
            }
            guard generation == self.generation else { return }
            if !opened {
                opened = true
                failures = 0
                DiagLog.notice(.servers, "jellyfin socket: open")
                if needsCatchUp {
                    needsCatchUp = false
                    refresh()
                }
            }
            let text: String? = switch frame {
            case .string(let string): string
            case .data(let data): String(data: data, encoding: .utf8)
            @unknown default: nil
            }
            handle(JellyfinSocketMessage(text: text ?? ""), on: socket, generation: generation)
        }
    }

    private func handle(_ message: JellyfinSocketMessage, on socket: URLSessionWebSocketTask, generation: Int) {
        switch message {
        case .forceKeepAlive(let timeout):
            let interval = JellyfinSocketMessage.keepAliveInterval(forTimeout: timeout)
            keepAliveTask?.cancel()
            keepAliveTask = Task { [weak self] in
                while !Task.isCancelled, self?.generation == generation {
                    do {
                        try await socket.send(.string(JellyfinSocketMessage.keepAlive))
                    } catch {
                        return // The receive loop sees the drop and reconnects.
                    }
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        case .libraryChanged, .userDataChanged:
            guard let deadline = debouncer.receive(message, at: Date()) else { return }
            DiagLog.notice(.servers, "jellyfin socket: \(message == .libraryChanged ? "library" : "user data") changed")
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.refresh()
            }
        case .ignored:
            break
        }
    }

    /// Refetches the server, unless a player is on screen: our own playback
    /// start and stop come back as UserDataChanged, and the player's exit
    /// reloads every server anyway (`.plexDataNeedsRefresh`), covering
    /// whatever else changed while it was up.
    private func refresh() {
        debouncer.reloaded(at: Date())
        guard let provider else { return }
        if PlayerContainerViewController.isOnScreen {
            DiagLog.notice(.servers, "jellyfin socket: refresh skipped, player on screen")
            return
        }
        onRefresh?(provider)
    }

    /// The socket closed or never opened. A refused handshake (401, 403, 404, a
    /// proxy that does not upgrade) is not retried until the next foreground;
    /// anything else reconnects with backoff, 2 s doubling to 5 minutes, and
    /// refetches once open.
    private func dropped(_ socket: URLSessionWebSocketTask, error: Error, opened: Bool) {
        keepAliveTask?.cancel()
        self.socket = nil
        guard let provider else { return }
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        if !opened, let status, (400..<500).contains(status) {
            refused = (provider.id, provider.client.token)
            DiagLog.error(.servers, "jellyfin socket: refused, HTTP \(status); live refresh off until next foreground")
            return
        }
        guard !suspended else { return }
        needsCatchUp = true
        failures += 1
        let delay = min(pow(2, Double(failures)), 300)
        DiagLog.error(.servers, "jellyfin socket: dropped (\(DiagLog.describe(error))), retry in \(Int(delay))s")
        let generation = self.generation
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }
}
