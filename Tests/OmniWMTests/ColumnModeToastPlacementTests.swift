// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import Testing

@Suite struct ColumnModeToastPlacementTests {
    private let size = CGSize(width: 140, height: 30)
    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // Centered horizontally on the column, inset below its top edge
    @Test @MainActor func centersBelowColumnTop() {
        let column = CGRect(x: 200, y: 100, width: 400, height: 600)
        let frame = ColumnModeToastController.pillFrame(size: size, columnFrame: column, visibleFrame: visible)
        #expect(frame.midX == column.midX)
        #expect(frame.maxY == column.maxY - ColumnModeToastController.topInset)
    }

    // A column hanging off either screen edge keeps the pill fully on screen
    @Test @MainActor func clampsIntoVisibleFrame() {
        let offLeft = CGRect(x: -380, y: 100, width: 400, height: 600)
        let offRight = CGRect(x: 980, y: 100, width: 400, height: 600)
        #expect(ColumnModeToastController.pillFrame(size: size, columnFrame: offLeft, visibleFrame: visible).minX == 0)
        #expect(
            ColumnModeToastController.pillFrame(size: size, columnFrame: offRight, visibleFrame: visible).maxX == 1000
        )
    }
}

@Suite(.serialized) struct ColumnModeToastLifecycleTests {
    private let column = CGRect(x: 200, y: 100, width: 400, height: 600)
    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // The pill disappears on its own after display + fade
    @Test @MainActor func dismissesAfterFade() async throws {
        let toast = ColumnModeToastController(displayDuration: .milliseconds(50), fadeDuration: 0.1)
        defer { toast.destroy() }
        toast.show(isTabbed: true, columnFrame: column, visibleFrame: visible, motion: .enabled)
        #expect(toast.isShowing)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!toast.isShowing)
    }

    // A toggle that lands mid-fade must leave a fully opaque pill after the old fade would have ended.
    // Timeline: fade 1.0-1.4s, re-show at 1.2s, check at 1.7s (new fade starts at 2.2s)
    @Test @MainActor func toggleDuringFadeKeepsNewPillVisible() async throws {
        let toast = ColumnModeToastController(displayDuration: .seconds(1), fadeDuration: 0.4)
        defer { toast.destroy() }
        toast.show(isTabbed: true, columnFrame: column, visibleFrame: visible, motion: .enabled)
        try await Task.sleep(for: .milliseconds(1200))
        toast.show(isTabbed: false, columnFrame: column, visibleFrame: visible, motion: .enabled)
        try await Task.sleep(for: .milliseconds(500))
        #expect(toast.isShowing)
    }
}
