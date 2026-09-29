// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriLayoutHandler {
    /// Confirms the selected column's display mode with a transient pill.
    /// Skips columns that have no rendered frame yet rather than guessing a position.
    func showColumnModeToast(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        motion: MotionSnapshot
    ) {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              let selectedId = state.selectedNodeId,
              let selectedNode = engine.findNode(by: selectedId, in: workspaceId),
              let column = engine.column(of: selectedNode),
              let frame = column.renderedFrame,
              !frame.isNull,
              !frame.isInfinite,
              frame.width > 0,
              frame.height > 0
        else {
            // Never leave an earlier pill showing a mode this toggle just changed
            columnModeToast.hide()
            return
        }
        columnModeToast.show(
            isTabbed: column.isTabbed,
            columnFrame: frame,
            visibleFrame: monitor.visibleFrame,
            motion: motion
        )
    }
}
