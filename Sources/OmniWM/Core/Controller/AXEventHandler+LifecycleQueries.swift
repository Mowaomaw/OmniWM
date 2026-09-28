// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension AXEventHandler {
    enum LifecycleQueryError: Error {
        case unavailable
    }

    enum LifecycleQueryKind {
        case created(WindowCreatePlacementContext?)
        case spaceDestroyed
        case closed
        case orderChanged
    }

    struct LifecycleQuery {
        let sequence: UInt64
        let windowId: UInt32
        let kind: LifecycleQueryKind
        var destructionIdentity: LifecycleIdentity?
    }

    struct LifecycleIdentity {
        let handle: WindowHandle?
        let token: WindowToken?
        let axRef: AXWindowRef?
        var retryGeneration: UInt64?
        let hiddenState: HiddenState?
    }

    struct LifecycleQueries {
        var query: @MainActor (UInt32) async throws -> WindowServerInfo? = {
            guard let result = try await SkyLight.shared.queryWindowInfoDeferred(windowIds: [$0]) else {
                throw LifecycleQueryError.unavailable
            }
            return result[$0]
        }

        var pending: [LifecycleQuery] = []
        var active: LifecycleQuery?
        var nextSequence: UInt64 = 1
        var task: Task<Void, Never>?
        var deferredCloseProbeExpiration: IntentID?
    }

    func enqueueLifecycleQuery(windowId: UInt32, kind: LifecycleQueryKind) {
        guard let controller, !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        if case .created = kind,
           let previous = lifecycleQueries.pending.last(where: { $0.windowId == windowId })
           ?? lifecycleQueries.active.flatMap({ $0.windowId == windowId ? $0 : nil }),
           case .created = previous.kind
        {
            return
        }
        if case .orderChanged = kind,
           lifecycleQueries.pending.contains(where: {
               guard $0.windowId == windowId else { return false }
               if case .orderChanged = $0.kind { return true }
               return false
           })
        {
            return
        }
        let destructionIdentity: LifecycleIdentity? = switch kind {
        case .closed,
             .spaceDestroyed: lifecycleIdentity(windowId: windowId)
        case .created,
             .orderChanged: nil
        }
        let query = LifecycleQuery(
            sequence: lifecycleQueries.nextSequence, windowId: windowId,
            kind: kind, destructionIdentity: destructionIdentity
        )
        lifecycleQueries.nextSequence &+= 1
        lifecycleQueries.pending.append(query)
        guard lifecycleQueries.task == nil else { return }
        lifecycleQueries.task = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, !self.lifecycleQueries.pending.isEmpty {
                let request = self.lifecycleQueries.pending.removeFirst()
                self.lifecycleQueries.active = request
                await self.performLifecycleQuery(request)
            }
            guard !Task.isCancelled else { return }
            self?.lifecycleQueries.task = nil
        }
    }

    func cancelQueuedWindowCreation(windowId: UInt32) {
        lifecycleQueries.pending.removeAll {
            guard $0.windowId == windowId else { return false }
            if case .created = $0.kind { return true }
            return false
        }
        if let active = lifecycleQueries.active, active.windowId == windowId,
           case .created = active.kind
        {
            lifecycleQueries.active = nil
        }
    }

    func cancelLifecycleQueries() {
        lifecycleQueries.task?.cancel()
        lifecycleQueries.task = nil
        lifecycleQueries.active = nil
        lifecycleQueries.pending.removeAll()
        lifecycleQueries.deferredCloseProbeExpiration = nil
    }

    private func performLifecycleQuery(_ request: LifecycleQuery) async {
        defer { finishLifecycleQuery(request) }
        let identity = request.destructionIdentity ?? lifecycleIdentity(windowId: request.windowId)
        let info: WindowServerInfo?
        do {
            info = try await lifecycleQueries.query(request.windowId)
        } catch {
            guard !Task.isCancelled, lifecycleQueries.active?.sequence == request.sequence else { return }
            DiagnosticsEventRecorder.shared.recordLifecycle(name: "cgs.windowQuery.failed.\(request.windowId)")
            guard case .created = request.kind else { return }
            info = nil
        }
        guard !Task.isCancelled, lifecycleQueries.active?.sequence == request.sequence else { return }
        lifecycleQueries.active = nil
        applyLifecycleObservation(request, identity: identity, windowInfo: info)
    }

    private func applyLifecycleObservation(
        _ request: LifecycleQuery, identity: LifecycleIdentity, windowInfo: WindowServerInfo?
    ) {
        guard let controller, !controller.isOwnedWindow(windowNumber: Int(request.windowId)) else { return }
        let current = controller.workspaceManager.entry(forWindowId: Int(request.windowId))
        guard current?.token == identity.token,
              current.flatMap({ controller.workspaceManager.handle(for: $0.token) }) === identity.handle,
              current.map({ CFEqual($0.axRef.element, identity.axRef?.element) }) ?? (identity.axRef == nil)
        else { return }

        let retryGeneration = admissionRetryStateByWindowId[request.windowId]?.generation
        defer { advanceQueuedLifecycleRetryGeneration(windowId: request.windowId, from: retryGeneration) }

        switch request.kind {
        case .created:
            applyLifecycleCreate(request, windowInfo: windowInfo)
        case .spaceDestroyed,
             .closed:
            guard admissionRetryStateByWindowId[request.windowId]?.generation == identity.retryGeneration
            else { return }
            if case .spaceDestroyed = request.kind {
                guard current?.hiddenState == identity.hiddenState else { return }
                guard windowInfo == nil else { return }
                cancelFrameObservation(windowId: request.windowId)
                guard current?.hiddenState == nil else { return }
            }
            if case .closed = request.kind {
                handleWindowDestroyed(
                    windowId: request.windowId, pidHint: nil, evidence: .windowClosed, windowInfo: windowInfo
                )
            } else {
                completeCGSWindowDestroyed(
                    windowId: request.windowId, evidence: .transientLifecycle, windowInfo: windowInfo
                )
            }
        case .orderChanged:
            applyWindowOrderChanged(windowId: request.windowId, windowInfo: windowInfo)
        }
    }

    private func advanceQueuedLifecycleRetryGeneration(windowId: UInt32, from previous: UInt64?) {
        let generation = admissionRetryStateByWindowId[windowId]?.generation
        guard generation != previous else { return }
        for index in lifecycleQueries.pending.indices
            where lifecycleQueries.pending[index].windowId == windowId
            && lifecycleQueries.pending[index].destructionIdentity?.retryGeneration == previous
        {
            lifecycleQueries.pending[index].destructionIdentity?.retryGeneration = generation
        }
    }

    private func applyLifecycleCreate(_ request: LifecycleQuery, windowInfo: WindowServerInfo?) {
        guard case let .created(context) = request.kind else { return }
        if let context { createPlacementContextsByWindowId[request.windowId] = context }
        guard canProcessCreatedWindow(windowId: request.windowId, retryExecution: nil) else { return }
        processCreatedWindowObservation(windowId: request.windowId, windowInfo: windowInfo)
    }

    private func lifecycleIdentity(windowId: UInt32) -> LifecycleIdentity {
        let entry = controller?.workspaceManager.entry(forWindowId: Int(windowId))
        return LifecycleIdentity(
            handle: entry.flatMap { controller?.workspaceManager.handle(for: $0.token) },
            token: entry?.token,
            axRef: entry?.axRef,
            retryGeneration: admissionRetryStateByWindowId[windowId]?.generation,
            hiddenState: entry?.hiddenState
        )
    }

    func hasPendingLifecycleDestruction(_ token: WindowToken) -> Bool {
        guard let controller, let entry = controller.workspaceManager.entry(for: token) else { return false }
        let handle = controller.workspaceManager.handle(for: token)
        func matches(_ request: LifecycleQuery) -> Bool {
            guard let identity = request.destructionIdentity else { return false }
            return identity.token == token && identity.handle === handle
                && CFEqual(identity.axRef?.element, entry.axRef.element)
        }
        return lifecycleQueries.active.map(matches) == true || lifecycleQueries.pending.contains(where: matches)
    }

    private func finishLifecycleQuery(_ request: LifecycleQuery) {
        guard !Task.isCancelled else { return }
        if lifecycleQueries.active?.sequence == request.sequence { lifecycleQueries.active = nil }
        guard let intentId = lifecycleQueries.deferredCloseProbeExpiration,
              let open = controller?.intentLedger.openSameAppCloseProbe(), open.intent.id == intentId
        else {
            lifecycleQueries.deferredCloseProbeExpiration = nil
            return
        }
        guard !hasPendingLifecycleDestruction(open.payload.focusedToken) else { return }
        lifecycleQueries.deferredCloseProbeExpiration = nil
        handleIntentExpired(intentId)
    }
}
