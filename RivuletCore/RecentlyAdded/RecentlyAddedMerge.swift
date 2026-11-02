// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Home's merged Recently Added row: every library's Recently Added row, on
/// every server, as one newest-first list.
enum RecentlyAddedMerge {
    /// The most items the merged row shows.
    static let limit = 40

    /// `rows` are newest first, as servers serve them. Dated items sort newest
    /// first; equal dates keep row order. An undated item in a dated row takes
    /// the date before it (or, at the head of its row, the first date after
    /// it), so it keeps its place in its row. Rows with no dates at all (cached
    /// before dates were kept) follow, interleaved one item per row in turn.
    /// The same title appears once, as its newest copy: items with the same
    /// `id`, or sharing any identity key (`ContinueWatchingMerge`: the same
    /// movie or show on another server). A dropped copy's keys still count,
    /// so a third copy matching only it goes too.
    static func merge<Item, ID: Hashable>(_ rows: [[Item]], id: (Item) -> ID,
                                          keys: (Item) -> [String] = { _ in [] },
                                          added: (Item) -> Date?, limit: Int = limit) -> [Item] {
        var dated: [(item: Item, date: Date, order: Int)] = []
        var undatedRows: [[Item]] = []
        for row in rows {
            let dates = row.map(added)
            guard var previous = dates.lazy.compactMap({ $0 }).first else {
                undatedRows.append(row)
                continue
            }
            for (item, date) in zip(row, dates) {
                previous = date ?? previous
                dated.append((item, previous, dated.count))
            }
        }
        let newestFirst = dated.sorted { ($0.date, $1.order) > ($1.date, $0.order) }.map(\.item)
        var seenIDs = Set<ID>()
        var seenKeys = Set<String>()
        var out: [Item] = []
        for item in newestFirst + roundRobin(undatedRows) where out.count < limit {
            let itemKeys = keys(item)
            let isNew = seenIDs.insert(id(item)).inserted && seenKeys.isDisjoint(with: itemKeys)
            seenKeys.formUnion(itemKeys)
            if isNew { out.append(item) }
        }
        return out
    }

    /// One item from each row in turn.
    static func roundRobin<Item>(_ rows: [[Item]]) -> [Item] {
        var out: [Item] = []
        for i in 0..<(rows.map(\.count).max() ?? 0) {
            for row in rows where i < row.count { out.append(row[i]) }
        }
        return out
    }
}
