// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfFeed.swift
//  Rivulet
//
//  The Top Shelf row: every server's Continue Watching in one list,
//  most recently watched first, then Recently Added; or Recently Added alone, by
//  choice or when there is no Continue Watching. Both stores call `refresh` when their row changes.
//

import Foundation

@MainActor
enum TopShelfFeed {
    // The poster row shows all of them; the full screen carousel the first 5.
    static let limit = 10
    // Composites run in call order, so the newest refresh writes last. An older one still
    // writes, but leaves pruning to the newer run, whose files it would otherwise delete.
    private static var generation = 0

    static func refresh() async {
        generation += 1
        let current = generation
        let auth = PlexAuthManager.shared
        let profiles = PlexUserProfileManager.shared
        // The Home screen row sits outside the PIN gate (a remembered PIN reopens it unasked).
        guard !auth.relocksOnLaunch || profiles.selectedUser.map(profiles.hasRememberedPin(for:)) ?? false else {
            DiagLog.notice(.topShelf, "Cleared: profile relocks and its PIN is not remembered")
            TopShelfCache.shared.clear()
            return
        }
        // Until a Home profile is entered there is no Plex row to show; keep the last one.
        guard !auth.isContentWithheld else {
            DiagLog.notice(.topShelf, "Skipped: content withheld until a profile is entered")
            return
        }
        let serverURL = auth.selectedServerURL
        let token = auth.selectedServerToken
        let sources = ServerDataStore.shared.sources
        // Settings > Appearance > Top Shelf > Content picks which row leads; an empty one gives way to the other.
        let content = TopShelfCache.shared.content
        var recent = recentlyAdded(serverURL: serverURL, token: token)
        var row = content == .recentlyAdded && !recent.isEmpty ? [] : continueWatching(serverURL: serverURL, token: token)
        let source = row.isEmpty ? "Recently Added" : "Continue Watching"
        // Recently Added leads: the carousel shows it, and there is no second row.
        if row.isEmpty {
            row = recent
            recent = []
        }
        let cwKeys = Set(row.map(\.ratingKey))
        recent.removeAll { cwKeys.contains($0.ratingKey) }
        let items = await TopShelfComposer.composite(items: row, serverURL: serverURL, token: token)
        // A profile changed, locked or signed out during the composite.
        guard auth.selectedServerToken == token, ServerDataStore.shared.sources == sources else {
            DiagLog.notice(.topShelf, "Dropped: profile or sources changed while composing")
            return
        }
        DiagLog.notice(.topShelf, "Refresh: \(items.count) items from \(source), \(recent.count) recently added, \(items.filter { $0.compositeFileName != nil }.count) composites")
        TopShelfCache.shared.writeItems(items, sectionTitle: source, recent: recent)
        // Only after the write, so a dropped refresh leaves the cached row's files in place.
        if generation == current {
            TopShelfCache.shared.pruneComposites(keeping: Set(items.compactMap(\.compositeFileName)))
        }
    }

    /// Every server's Continue Watching, most recently watched first.
    private static func continueWatching(serverURL: String?, token: String?) -> [TopShelfItem] {
        var plex: [TopShelfItem] = []
        // Top Shelf shows the rows Home shows: a row hidden in Settings > Home Rows stays off it.
        let cwHub = PlexDataStore.shared.continueWatchingHub
        if let serverURL, let token, !HomeRowSettings.isHidden(cwHub?.hubIdentifier) {
            // /hubs/continueWatching, as the in-app row uses. The global /hubs drops movies (#194).
            plex = TopShelfMapper.items(from: cwHub?.Metadata ?? [],
                                        serverURL: serverURL, token: token, limit: limit * 2)
        }
        let otherRows = ServerDataStore.shared.visibleHomeRows.filter(\.isContinueWatching).map(\.items)
        var others = otherRows.flatMap { TopShelfMapper.items(from: $0, limit: limit * 2) }
        // The same title on two servers is one card, as in Home's merged row.
        if !otherRows.isEmpty, let primaryID = MediaProviderRegistry.shared.plexProvider?.id {
            let primaryRow = PlexDataStore.shared.homeItems.first(where: \.isContinueWatching)?.items ?? []
            let shown = Set(ContinueWatchingRow.shared.cards([primaryRow] + otherRows, identity: { $0.identity ?? [] },
                                                             showKey: \.showKey, watched: \.userState.lastViewedAt)
                                .map(\.item.ref))
            plex.removeAll { !shown.contains(MediaItemRef(providerID: primaryID, itemID: $0.ratingKey)) }
            others.removeAll { !shown.contains(MediaItemRef(providerID: $0.serverIdentifier, itemID: $0.ratingKey)) }
        }
        return TopShelfMapper.merge(plex, others, limit: limit)
    }

    /// Newest unwatched titles from the selected Plex server's loaded library hubs and the
    /// other servers' Recently Added rows.
    private static func recentlyAdded(serverURL: String?, token: String?) -> [TopShelfItem] {
        var plex: [TopShelfItem] = []
        if let serverURL, let token {
            let store = PlexDataStore.shared
            let metadata = store.librariesPinnedToHome
                .flatMap { store.libraryHubs[$0.key] ?? [] }
                .filter { $0.promoted == true && !HomeRowSettings.isHidden($0.hubIdentifier) }
                .filter { ($0.hubIdentifier ?? "").lowercased().contains("recentlyadded") }
                .flatMap { $0.Metadata ?? [] }
            plex = TopShelfMapper.recentlyAddedItems(from: metadata, serverURL: serverURL, token: token, limit: limit * 2)
        }
        let others = ServerDataStore.shared.visibleHomeRows
            .filter { $0.id.hasSuffix(".recentlyAdded") }
            .flatMap { TopShelfMapper.items(from: $0.items.filter { !$0.userState.isPlayed }, limit: limit * 2) }
        return TopShelfMapper.merge(plex, others, limit: limit)
    }
}
