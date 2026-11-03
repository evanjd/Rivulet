// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SeasonTitleTests: XCTestCase {
    func test_yearNumberedSeason_hasNoGroupingSeparator() {
        XCTAssertEqual(SeasonTitle.title(2026), "Season 2026")
    }

    func test_seasonZero_isSpecials() {
        XCTAssertEqual(SeasonTitle.title(0), "Specials")
    }
}
