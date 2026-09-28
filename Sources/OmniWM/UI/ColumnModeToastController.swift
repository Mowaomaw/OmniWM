// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

/// Transient, click-through pill confirming a column display mode change.
@MainActor
final class ColumnModeToastController {
    static let surfaceId = "column-mode-toast"
    static let topInset: CGFloat = 16

    private let ownedWindowRegistry: OwnedWindowRegistry
    private let displayDuration: Duration
    private let fadeDuration: TimeInterval
    private var surface: (panel: NSPanel, hostingView: NSHostingView<ColumnModeToastView>)?
    private var dismissalTask: Task<Void, Never>?
    private var generation = 0

    /// Visible and not faded out; an invisible-but-ordered-in panel counts as hidden
    var isShowing: Bool {
        guard let panel = surface?.panel else { return false }
        return panel.isVisible && panel.alphaValue > 0.99
    }

    init(
        ownedWindowRegistry: OwnedWindowRegistry = .shared,
        displayDuration: Duration = .milliseconds(1500),
        fadeDuration: TimeInterval = 0.2
    ) {
        self.ownedWindowRegistry = ownedWindowRegistry
        self.displayDuration = displayDuration
        self.fadeDuration = fadeDuration
    }

    isolated deinit {
        destroy()
    }

    func show(isTabbed: Bool, columnFrame: CGRect, visibleFrame: CGRect, motion: MotionSnapshot) {
        // A non-activating panel never triggers .moveToActiveSpace; recreate it if it is visible on another Space
        if let visiblePanel = surface?.panel, visiblePanel.isVisible, !visiblePanel.isOnActiveSpace {
            destroy()
        }
        let (panel, hostingView) = surface ?? makeSurface()

        // Replace any pill already on screen: new content, new position, fresh timer
        dismissalTask?.cancel()
        generation += 1
        hostingView.rootView = ColumnModeToastView(isTabbed: isTabbed)
        panel.setFrame(
            Self.pillFrame(size: hostingView.fittingSize, columnFrame: columnFrame, visibleFrame: visibleFrame),
            display: true
        )
        // Reset through the animator so an in-flight fade-out is superseded, not left running
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        // Fade out after the display duration unless another toggle replaces it
        let shownGeneration = generation
        let displayDuration = displayDuration
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: displayDuration)
            guard !Task.isCancelled else { return }
            self?.fadeOut(generation: shownGeneration, animated: motion.animationsEnabled)
        }
    }

    func hide() {
        dismissalTask?.cancel()
        dismissalTask = nil
        surface?.panel.orderOut(nil)
    }

    func destroy() {
        hide()
        guard let surface else { return }
        ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        surface.panel.close()
        self.surface = nil
    }

    /// Centered on the column, just below its top edge, clamped into the visible screen area.
    /// Frames use AppKit screen coordinates (origin bottom-left, y grows upward).
    static func pillFrame(size: CGSize, columnFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let x = columnFrame.midX - size.width / 2
        let y = columnFrame.maxY - topInset - size.height
        let clampedX = min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width)
        let clampedY = min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: size)
    }

    private func fadeOut(generation shownGeneration: Int, animated: Bool) {
        guard let panel = surface?.panel, animated else {
            hide()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A toggle during the fade shows a new pill; leave that one alone
                guard let self, self.generation == shownGeneration else { return }
                self.hide()
            }
        }
    }

    // Borderless, non-activating, click-through panel; clear background so the glass renders
    private func makeSurface() -> (panel: NSPanel, hostingView: NSHostingView<ColumnModeToastView>) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        // Live only on the Space where it is shown, not on every Space (show() recreates it across Spaces)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hostingView = NSHostingView(rootView: ColumnModeToastView(isTabbed: false))
        panel.contentView = hostingView

        ownedWindowRegistry.register(
            panel,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        surface = (panel, hostingView)
        return (panel, hostingView)
    }
}

struct ColumnModeToastView: View {
    let isTabbed: Bool

    var body: some View {
        Text(isTabbed ? "Tabbed mode on" : "Tabbed mode off")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .omniGlassEffect(in: Capsule())
            .fixedSize()
    }
}
