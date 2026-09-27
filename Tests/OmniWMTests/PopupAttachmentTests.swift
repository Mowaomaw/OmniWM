// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class PopupAttachmentTests: XCTestCase {
    private let size = CGSize(width: 360, height: 420)
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 950)

    func testCentersBelowAnchor() {
        let frame = PopupAttachment(anchor: CGPoint(x: 756, y: 900)).frame(size: size, visibleFrame: screen)

        XCTAssertEqual(frame.midX, 756)
        XCTAssertEqual(frame.maxY, 896)
        XCTAssertEqual(frame.size, size)
    }

    func testClampsAtDisplayEdges() {
        let left = PopupAttachment(anchor: CGPoint(x: 10, y: 900)).frame(size: size, visibleFrame: screen)
        XCTAssertEqual(left.minX, 8)

        let right = PopupAttachment(anchor: CGPoint(x: 1508, y: 900)).frame(size: size, visibleFrame: screen)
        XCTAssertEqual(right.maxX, screen.maxX - 8)

        let bottom = PopupAttachment(anchor: CGPoint(x: 756, y: 100)).frame(size: size, visibleFrame: screen)
        XCTAssertEqual(bottom.minY, 8)
    }

    func testOversizedWidthPinsToDisplayMinimumX() {
        let narrow = CGRect(x: 100, y: 0, width: 150, height: 900)
        let frame = PopupAttachment(anchor: CGPoint(x: 175, y: 900))
            .frame(size: CGSize(width: 200, height: 60), visibleFrame: narrow)
        XCTAssertEqual(frame.minX, narrow.minX + 8)
    }
}
