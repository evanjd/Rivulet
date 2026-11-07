// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LegibilityLayoutTests.swift
//  RivuletTests
//
//  Body copy keeps its style when a reused label clears and refills, and the
//  info popup's meta row wraps its badges instead of squeezing them.
//

import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class LegibilityLayoutTests: XCTestCase {

    private let font = UIFont.systemFont(ofSize: 23, weight: .medium)
    private let color = UIColor.white.withAlphaComponent(0.7)

    private func styledLabel() -> UILabel {
        let label = UILabel()
        label.font = font
        label.textColor = color
        return label
    }

    private func assertStyled(_ label: UILabel, line: UInt = #line) {
        let attributes = label.attributedText?.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attributes?[.font] as? UIFont, font, line: line)
        XCTAssertEqual(attributes?[.foregroundColor] as? UIColor, color, line: line)
    }

    func test_setBodyText_appliesThePitch() {
        let label = styledLabel()
        label.setBodyText("Copy")
        let style = label.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.lineSpacing ?? 0, font.pointSize + 7 - font.lineHeight, accuracy: 0.01)
        XCTAssertEqual(style?.lineBreakMode, .byTruncatingTail)
        assertStyled(label)
    }

    /// EpisodeCell clears with `.text = nil` for a trailer, and passes a nil overview.
    func test_setBodyText_keepsStyleAfterClearing() {
        let label = styledLabel()
        label.setBodyText("One")
        label.text = nil
        label.setBodyText("Two")
        assertStyled(label)

        label.setBodyText(nil)
        label.setBodyText("Three")
        assertStyled(label)
    }

    /// An episode with an empty overview, then a reuse with a real one.
    func test_setBodyText_keepsStyleAfterEmptyText() {
        let label = styledLabel()
        label.setBodyText("")
        label.setBodyText("Real")
        assertStyled(label)
    }

    func test_metaRow_staysOnOneLineWhenItFits() {
        let row = InfoPopupContent.metaRow(text: "2024  ·  2 hr 15 min  ·  TV-MA", badges: ["4K", "DV"])
        XCTAssertEqual((row as? UIStackView)?.axis, .horizontal)
    }

    func test_metaRow_dropsBadgesToASecondLineWhenTooWide() {
        let row = InfoPopupContent.metaRow(
            text: "2024  ·  2 hr 15 min  ·  TV-MA",
            badges: ["4K", "DV", "HDR10+", "Dolby Atmos 7.1", "SDH", "AD"])
        let stack = row as? UIStackView
        XCTAssertEqual(stack?.axis, .vertical)
        XCTAssertEqual(stack?.arrangedSubviews.count, 2)
    }
}
