// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The one label for a season number. The number goes in as text: an `Int`
/// interpolation is localized with grouping, so a year-numbered season read
/// "Season 2,026".
enum SeasonTitle {
    static func title(_ number: Int) -> String {
        number == 0 ? String(localized: "Specials") : String(localized: "Season \(String(number))")
    }
}
