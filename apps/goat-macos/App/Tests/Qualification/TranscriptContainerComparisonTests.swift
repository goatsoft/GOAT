import AppKit
import Bleet
import Darwin
import Hoofprint
import Observation
import SwiftUI
import XCTest

@testable import GOAT

extension TranscriptPerformanceTests {
    /// Run each backend in a fresh Release process. Defaults exercise 2 MiB per live channel.
    @MainActor func testContainerComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let backend = environment["GOAT_COMPARE"], backend == "swiftui" else {
            throw XCTSkip(
                "Set TEST_RUNNER_GOAT_COMPARE=swiftui. The AppKit fallback is retired; use its historical revision to reproduce it."
            )
        }
        let bytes = Int(environment["GOAT_COMPARE_BYTES"] ?? "") ?? 2 * 1_024 * 1_024
        let rounds = Int(environment["GOAT_COMPARE_ROUNDS"] ?? "") ?? 48
        let dense = environment["GOAT_COMPARE_DENSE"] == "1"
        let follows = environment["GOAT_COMPARE_FOLLOW"] != "0"
        let channel = environment["GOAT_COMPARE_CHANNEL"] ?? "both"
        let model = AppModel.shared
        let oldTheme = model.themeID
        let oldFont = model.chatFontSize
        let oldAnimations = model.animationsEnabled
        model.themeID = "system"
        model.chatFontSize = 14
        model.animationsEnabled = false
        defer {
            model.themeID = oldTheme
            model.chatFontSize = oldFont
            model.animationsEnabled = oldAnimations
        }
        print(
            "COMPARISON_RUN run_id=\(environment["GOAT_COMPARE_RUN_ID"] ?? "unlabelled") commit=\(environment["GOAT_COMPARE_COMMIT"] ?? "unrecorded") scroll_writer=swiftui_scroll_position previews=\(environment["GOAT_COMPARE_NO_PREVIEWS"] != "1")"
        )
        print(
            "COMPARISON_HOST os=\(ProcessInfo.processInfo.operatingSystemVersionString) cores=\(ProcessInfo.processInfo.processorCount) memory_bytes=\(ProcessInfo.processInfo.physicalMemory)"
        )
        let fixture = TranscriptComparisonFixture()
        let setup = ProcessInfo.processInfo.systemUptime
        try await fixture.seed(rounds: rounds)
        XCTAssertEqual(Set(fixture.rows.map(\.id)).count, fixture.rows.count)
        let delegate = try XCTUnwrap(
            TranscriptComparisonFixture.tools(0).first { $0.tool == "subagent_delegate" }?.result)
        XCTAssertEqual(try JSONDecoder().decode(SubagentReceipt.self, from: Data(delegate.utf8)).status, .completed)
        print(
            "COMPARISON_SETUP backend=\(backend) rounds=\(rounds) rows=\(fixture.rows.count) seconds=\(ProcessInfo.processInfo.systemUptime - setup)"
        )
        // macOS 26 CI runners show legacy scrollers; reproduce that locally without changing user defaults.
        if environment["GOAT_COMPARE_LEGACY_SCROLLERS"] == "1" {
            UserDefaults.standard.setVolatileDomain(
                ["AppleShowScrollBars": "Always"], forName: UserDefaults.argumentDomain)
        }
        let host = NSHostingView(
            rootView: TranscriptComparisonSurface(fixture: fixture, backend: backend).environment(model))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 1180, height: 780), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "GOAT container comparison: \(backend)"
        window.isReleasedWhenClosed = false
        // Both candidates receive a viewport owned by the surrounding AppKit layout, as in
        // the app. A direct hosting root can resize its window to changing ideal content.
        let viewport = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        host.frame = viewport.bounds
        host.autoresizingMask = [.width, .height]
        viewport.addSubview(host)
        window.contentView = viewport
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            fixture.stopPreparation()
        }
        print("COMPARISON_READY backend=\(backend) pid=\(getpid()) bytes=\(bytes) dense=\(dense) follows=\(follows)")
        try await Task.sleep(for: .seconds(environment["GOAT_COMPARE_INSTRUMENTS"] == "1" ? 15 : 3))
        guard let scroll = comparisonScroll(host) else {
            XCTFail("No outer transcript scroll view")
            return
        }
        XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.contentSize.height)
        if environment["GOAT_COMPARE_LEGACY_SCROLLERS"] == "1" { scroll.scrollerStyle = .legacy }
        print(
            "COMPARISON_SCROLLER style=\(scroll.scrollerStyle == .legacy ? "legacy" : "overlay") backing_scale=\(window.backingScaleFactor)"
        )
        if environment["GOAT_COMPARE_NAVIGATION"] == "1" {
            try await comparisonNavigation(fixture, backend: backend, host: host, scroll: scroll)
            return
        }
        let initial = comparisonUsage()
        let scrollStart = ProcessInfo.processInfo.systemUptime
        try await comparisonWheelSequence(scroll, direction: 1)
        try await Task.sleep(for: .milliseconds(500))
        print(
            "COMPARISON_SCROLL backend=\(backend) wall_s=\(ProcessInfo.processInfo.systemUptime - scrollStart) cpu_s=\(comparisonUsage().cpu - initial.cpu) offset=\(scroll.contentView.bounds.minY) peak_visible=\(fixture.peakVisible)"
        )
        if follows {
            fixture.following = true
            fixture.latestRequest += 1
        } else {
            fixture.following = false
        }
        try await Task.sleep(for: .seconds(1))
        try await fixture.replayTools()
        for reasoning in [true, false] where channel == "both" || channel == (reasoning ? "reasoning" : "answer") {
            let source = TranscriptComparisonFixture.source(bytes: bytes, reasoning: reasoning, dense: dense)
            let phase = reasoning ? "reasoning" : "answer"
            fixture.status = "Streaming \(phase), \(bytes) bytes"
            let anchor = comparisonAnchor(fixture, host: host)
            let before = comparisonUsage()
            let started = ProcessInfo.processInfo.systemUptime
            var delays: [Double] = []
            var work: [Double] = []
            var offset = source.startIndex
            var published = 0
            print("COMPARISON_PHASE_START backend=\(backend) phase=\(phase) pid=\(getpid())")
            RenderSignposts.event("TranscriptWorkloadPhase")
            while offset < source.endIndex {
                // Cut by UTF-8 bytes without splitting a Character. Publications are <= 16 KiB.
                var end =
                    source.utf8.index(offset, offsetBy: 16_384, limitedBy: source.utf8.endIndex) ?? source.endIndex
                while end < source.endIndex, String.Index(end, within: source) == nil {
                    end = source.utf8.index(before: end)
                }
                let delta = String(source[offset..<end])
                published += delta.utf8.count
                let publicationStart = ProcessInfo.processInfo.systemUptime
                try await fixture.append(delta, reasoning: reasoning)
                work.append(ProcessInfo.processInfo.systemUptime - publicationStart)
                offset = end
                let scheduled = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(120))
                delays.append(max(0, ProcessInfo.processInfo.systemUptime - scheduled - 0.120))
            }
            let beforeCompletion = comparisonAnchor(fixture, host: host)
            try await fixture.append("", reasoning: reasoning, complete: true)
            try await Task.sleep(for: .seconds(3))
            fixture.sampleFrames()
            let after = comparisonUsage()
            let anchorDrift = anchor.flatMap { saved in fixture.frames[saved.0].map { Double($0.minY - saved.1) } }
            let completionDrift = beforeCompletion.flatMap { saved in
                fixture.frames[saved.0].map { Double($0.minY - saved.1) }
            }
            let preparation = await fixture.markdown.snapshot()
            let endGap = (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.maxY
            let result: [String: Any] = [
                "preparation_cache_bytes": preparation.cost,
                "preparation_scanned_bytes": preparation.work.scannedBytes,
                "backend": backend, "phase": phase, "bytes": published, "follows": follows,
                "dense": dense, "rows": fixture.rows.count,
                "wall_s": ProcessInfo.processInfo.systemUptime - started,
                "cpu_s": after.cpu - before.cpu,
                "sleep_overrun_p95_ms": comparisonPercentile(delays) * 1_000,
                "publication_p95_ms": comparisonPercentile(work) * 1_000,
                "peak_rss_bytes": after.peakRSS, "resident_bytes": after.resident,
                "peak_appeared_rows": fixture.peakVisible, "height_updates": fixture.heightUpdates,
                "reader_anchor_drift_pt": anchorDrift as Any? ?? NSNull(),
                "completion_anchor_drift_pt": completionDrift as Any? ?? NSNull(),
                "follow_gap_pt": follows ? Double(endGap) : NSNull(),
            ]
            print(
                "COMPARISON_RESULT "
                    + String(
                        decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                        as: UTF8.self))
            XCTAssertEqual(published, bytes)
            XCTAssertEqual((reasoning ? fixture.active.thinking : fixture.active.text).utf8.count, bytes)
            XCTAssertEqual(Set(fixture.rows.map(\.id)).count, fixture.rows.count)
            XCTAssertFalse(fixture.rows.isEmpty)
        }
        fixture.status = "Streaming complete; scroll, inspect tools and test controls"
        fixture.following = false
        try await comparisonWheelSequence(scroll, direction: 1)
        try await Task.sleep(for: .milliseconds(500))
        let anchor = comparisonAnchor(fixture, host: host)
        window.setContentSize(NSSize(width: 820, height: 780))
        try await Task.sleep(for: .seconds(1))
        fixture.sampleFrames()
        if let anchor, let frame = fixture.frames[anchor.0] {
            print("COMPARISON_REFLOW backend=\(backend) anchor_drift_pt=\(frame.minY - anchor.1)")
        } else {
            print("COMPARISON_REFLOW backend=\(backend) anchor_unavailable=true")
        }
        if environment["GOAT_COMPARE_INTERACTIVE"] == "1" {
            let deadline = ContinuousClock.now.advanced(by: .seconds(900))
            while !fixture.finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        }
    }
}

@MainActor private func comparisonScroll(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView, scroll.hasVerticalScroller { return scroll }
    return view.subviews.lazy.compactMap(comparisonScroll).first
}

/// Mounted rows whose frame touches the viewport's top line, within a point, before a reflow.
@MainActor private func comparisonTopLineRows(
    _ fixture: TranscriptComparisonFixture, scroll: NSScrollView, host: NSView
) -> [(id: String, minY: CGFloat, height: CGFloat, viewportTop: CGFloat)] {
    fixture.sampleFrames()
    let top = comparisonViewportTop(scroll, host: host)
    return fixture.frames.filter { $0.value.minY <= top + 1 && $0.value.maxY >= top - 1 }
        .sorted { $0.value.minY < $1.value.minY }
        .map { (id: $0.key, minY: $0.value.minY, height: $0.value.height, viewportTop: top) }
}

@MainActor private func comparisonViewportTop(_ scroll: NSScrollView, host: NSView) -> CGFloat {
    let rect = scroll.contentView.convert(scroll.contentView.bounds, to: host)
    return host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
}

@MainActor private func comparisonAnchor(
    _ fixture: TranscriptComparisonFixture, host: NSView, inputDelta: CGFloat = 0
) -> (String, CGFloat)? {
    // Include a partially visible tall row, not only rows whose top edge is on screen.
    fixture.sampleFrames()
    guard let scroll = comparisonScroll(host) else { return nil }
    let rect = scroll.contentView.convert(scroll.contentView.bounds, to: host)
    let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
    let bottom = top + rect.height
    return fixture.frames.filter {
        $0.value.maxY > top + 1 && $0.value.minY < bottom
            && $0.value.maxY - inputDelta > top + 1 && $0.value.minY - inputDelta < bottom
    }
    .min(by: { $0.value.minY < $1.value.minY }).map { ($0.key, $0.value.minY) }
}

/// Replays the direct-move regression and sends upward input while async preparation, insertion
/// above the viewport and streamed tail growth run concurrently. Scripted events are not hardware
/// momentum; the latter remains manual qualification on each supported OS.
@MainActor private func comparisonNavigation(
    _ fixture: TranscriptComparisonFixture, backend: String, host: NSView, scroll: NSScrollView
) async throws {
    let calibration = try await comparisonInputCalibration()
    print(
        "COMPARISON_NAVIGATION backend=\(backend) input_mode=discrete_pixel_wheel input_control_max_error_pt=\(calibration)"
    )
    XCTAssertLessThanOrEqual(calibration, 1, "Synthetic input must work on a static AppKit control")
    fixture.following = true
    fixture.latestRequest += 1
    try await Task.sleep(for: .milliseconds(50))
    fixture.following = false
    let target = max(0, ((scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height) / 2)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
    scroll.reflectScrolledClipView(scroll.contentView)
    host.layoutSubtreeIfNeeded()
    // A lazy list has no native marker at the new offset until it mounts the first frame.
    // Bound that readiness wait and measure clip movement throughout it: waiting must not
    // conceal a startup jump or turn a missing anchor into a successful sample.
    let captureStarted = ContinuousClock.now
    let captureDeadline = captureStarted.advanced(by: .milliseconds(200))
    var directAnchor = comparisonAnchor(fixture, host: host)
    var uncapturedMovement: CGFloat = abs(scroll.contentView.bounds.minY - target)
    while directAnchor == nil, ContinuousClock.now < captureDeadline {
        try await Task.sleep(for: .milliseconds(10))
        host.layoutSubtreeIfNeeded()
        uncapturedMovement = max(uncapturedMovement, abs(scroll.contentView.bounds.minY - target))
        directAnchor = comparisonAnchor(fixture, host: host)
    }
    print(
        "COMPARISON_NAVIGATION backend=\(backend) startup_capture_wait=\(captureStarted.duration(to: ContinuousClock.now)) uncaptured_movement_pt=\(uncapturedMovement) anchor_available=\(directAnchor != nil)"
    )
    XCTAssertLessThanOrEqual(uncapturedMovement, 1, "Startup must not move while waiting for the first visible marker")
    XCTAssertNotNil(directAnchor, "Startup must produce a visible anchor within the bounded readiness interval")
    try await Task.sleep(for: .milliseconds(500))
    host.layoutSubtreeIfNeeded()
    fixture.sampleFrames()
    let replayDrift =
        directAnchor.flatMap { anchor in fixture.frames[anchor.0].map { abs($0.minY - anchor.1) } } ?? .infinity
    print(
        "COMPARISON_DIRECT target=\(target) origin=\(scroll.contentView.bounds.minY) row=\(directAnchor?.0 ?? "none") moved=\(directAnchor.flatMap { anchor in fixture.frames[anchor.0].map { $0.minY - anchor.1 } } ?? .nan)"
    )
    print("COMPARISON_NAVIGATION backend=\(backend) direct_move_drift_pt=\(replayDrift)")
    XCTAssertLessThanOrEqual(replayDrift, 1, "ADR-0097 direct-move replay")

    var inputError: CGFloat = 0
    for direction: Int32 in [1, -1, 1] {
        let before = scroll.contentView.bounds.minY
        let event = try XCTUnwrap(comparisonWheelEvent(direction: direction, tick: 0))
        let requested = -event.scrollingDeltaY
        // A reverse input can legitimately unmount the first short row. Track a visible
        // row that will still intersect the viewport after the requested movement.
        let anchor = comparisonAnchor(fixture, host: host, inputDelta: requested)
        scroll.scrollWheel(with: event)
        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
        let applied = max(0, min(maximum, before + requested)) - before
        try await Task.sleep(for: .milliseconds(100))
        fixture.sampleFrames()
        let residual =
            anchor.flatMap { saved in fixture.frames[saved.0].map { abs($0.minY - saved.1 + applied) } } ?? .infinity
        inputError = max(inputError, residual)
    }
    print("COMPARISON_NAVIGATION backend=\(backend) candidate_static_input_error_pt=\(inputError)")
    XCTAssertLessThanOrEqual(inputError, 1, "The candidate must receive input before growth is interpreted")
    if ProcessInfo.processInfo.environment["GOAT_COMPARE_INPUT_ONLY"] == "1" { return }

    let beforeAppend = comparisonAnchor(fixture, host: host)
    fixture.rows.append(ComparisonRow("initial-offset-replay", .label("Appended after a non-gesture move")))
    fixture.reasoningStart += 1
    fixture.answerStart += 1
    fixture.lastChanged = (fixture.rows.count - 1)..<fixture.rows.count
    fixture.generation += 1
    try await Task.sleep(for: .milliseconds(500))
    host.layoutSubtreeIfNeeded()
    fixture.sampleFrames()
    let initialDrift =
        beforeAppend.flatMap { anchor in fixture.frames[anchor.0].map { abs($0.minY - anchor.1) } } ?? .infinity
    print("COMPARISON_NAVIGATION backend=\(backend) initial_offset_growth_drift_pt=\(initialDrift)")
    XCTAssertLessThanOrEqual(initialDrift, 1, "Initial offset must not reapply after placement")

    // Start below unmeasured historical rows, then climb while the live answer grows to 2 MiB.
    fixture.following = false
    let source = TranscriptComparisonFixture.source(bytes: 2 * 1_024 * 1_024, reasoning: false, dense: false)
    let historicalIDs = Set(fixture.rows.map(\.id))
    let growth = Task { @MainActor in
        var offset = source.startIndex
        while offset < source.endIndex {
            var end = source.utf8.index(offset, offsetBy: 16_384, limitedBy: source.utf8.endIndex) ?? source.endIndex
            while end < source.endIndex, String.Index(end, within: source) == nil {
                end = source.utf8.index(before: end)
            }
            try Task.checkCancellation()
            try await fixture.append(String(source[offset..<end]), reasoning: false)
            offset = end
            if fixture.active.text.utf8.count.isMultiple(of: 262_144) {
                print(
                    "COMPARISON_NAVIGATION backend=\(backend) phase=growth bytes=\(fixture.active.text.utf8.count) resident_bytes=\(comparisonUsage().resident)"
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await fixture.append("", reasoning: false, complete: true)
    }
    defer { growth.cancel() }
    var residuals: [CGFloat] = []
    var failedTicks: [String] = []
    var missing = 0
    for tick in 0..<192 {
        host.layoutSubtreeIfNeeded()
        guard let anchor = comparisonAnchor(fixture, host: host) else {
            missing += 1
            try await Task.sleep(for: .milliseconds(50))
            continue
        }
        let before = scroll.contentView.bounds.minY
        let documentBefore = scroll.documentView?.bounds.height ?? 0
        let requestedDelta = comparisonWheel(scroll, direction: 1, tick: tick % 24)
        let maximumOrigin = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
        let applied = max(0, min(maximumOrigin, before + requestedDelta)) - before
        if tick == 24, let index = fixture.rows.firstIndex(where: { $0.id == anchor.0 }) {
            fixture.rows.insert(
                ComparisonRow("inserted-during-gesture", .label("Inserted above the reader")), at: index)
            fixture.reasoningStart += 1
            fixture.answerStart += 1
            fixture.structureRevision += 1
            fixture.generation += 1
        }
        if tick == 48, let index = fixture.rows.firstIndex(where: { $0.id == anchor.0 }), index > 0 {
            let above = fixture.rows[index - 1]
            above.content = .label(String(repeating: "Height changed above the reader.\n", count: 8))
            above.revision += 1
            fixture.lastChanged = (index - 1)..<index
            fixture.generation += 1
        }
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        fixture.sampleFrames()
        if let frame = fixture.frames[anchor.0] {
            // The native marker samples the same anchor-row screen displacement in both
            // candidates. Clip movement used to preserve content is not itself reader drift.
            let residual = abs(frame.minY - anchor.1 + applied)
            residuals.append(residual)
            if residual > 1 {
                failedTicks.append("\(tick):\(residual)")
                if failedTicks.count <= 12 {
                    print(
                        "COMPARISON_GROWTH_TICK tick=\(tick) row=\(anchor.0) moved=\(frame.minY - anchor.1) applied=\(applied) requested=\(requestedDelta) origin_before=\(before) origin_after=\(scroll.contentView.bounds.minY) document_before=\(documentBefore) document_after=\(scroll.documentView?.bounds.height ?? 0) height=\(frame.height) following=\(fixture.following)"
                    )
                }
            }

        } else {
            missing += 1
        }
    }
    try await growth.value
    print("COMPARISON_NAVIGATION backend=\(backend) phase=growth_complete resident_bytes=\(comparisonUsage().resident)")
    let worst = residuals.max() ?? .infinity
    print(
        "COMPARISON_NAVIGATION backend=\(backend) wheel_growth_max_residual_pt=\(worst) samples=\(residuals.count) missing=\(missing) failed_ticks=\(failedTicks.joined(separator: ","))"
    )
    XCTAssertEqual(missing, 0, "A missing growth anchor is a failed sample")
    XCTAssertEqual(residuals.count, 192, "Every growth/input event must retain a measurable anchor")
    XCTAssertEqual(fixture.active.text.utf8.count, 2 * 1_024 * 1_024)
    let finalIDs = Set(fixture.rows.map(\.id))
    XCTAssertEqual(finalIDs.count, fixture.rows.count)
    XCTAssertTrue(historicalIDs.isSubset(of: finalIDs), "Concurrent insertion must preserve all historical rows")
    let answer = fixture.rows.compactMap { row -> String? in
        guard case .markdown(let message, let segment, _) = row.content, message.id == fixture.active.id else {
            return nil
        }
        return segment.body
    }.joined()
    XCTAssertEqual(answer, fixture.active.text, "Every streamed byte remains in the row model after insertion")
    XCTAssertLessThanOrEqual(worst, 1, "Height changes must preserve the anchor after accounting for input")

    fixture.following = true
    fixture.latestRequest += 1
    try await Task.sleep(for: .milliseconds(500))
    host.layoutSubtreeIfNeeded()
    let gap = (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.maxY
    print(
        "COMPARISON_FOLLOW native_gap=\(gap) swiftui_end_distance=\(fixture.swiftUIEndDistance) document_height=\(scroll.documentView?.bounds.height ?? 0) last_row=\(fixture.rows.last?.id ?? "none") last_frame=\(fixture.rows.last.flatMap { fixture.frames[$0.id] }.map { "\($0)" } ?? "unmounted")"
    )
    print("COMPARISON_NAVIGATION backend=\(backend) following_gap_pt=\(gap)")
    XCTAssertLessThanOrEqual(abs(gap), 1, "Following uses the laid-out document height")

    fixture.following = false
    scroll.contentView.scroll(to: NSPoint(x: 0, y: (scroll.documentView?.bounds.height ?? 0) / 2))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(500))
    let window = try XCTUnwrap(host.window)
    // The third geometry is new to every row, so reading back afterwards resolves the lazy stack's estimates.
    for (width, font) in [(820.0, 20.0), (1180.0, 14.0), (1000.0, 17.0)] {
        host.layoutSubtreeIfNeeded()
        // The lazy stack keeps the top edge of its topmost visible row in place, as CSS scroll anchoring
        // does. When the viewport top falls on a row boundary it may keep either row there, so sample
        // every row touching the top line; the reader's position holds if one of them does.
        let anchors = comparisonTopLineRows(fixture, scroll: scroll, host: host)
        let originBefore = scroll.contentView.bounds.minY
        let documentBefore = scroll.documentView?.bounds.height ?? 0
        print(
            "COMPARISON_NAVIGATION backend=\(backend) phase=reflow_start width=\(width) font=\(font) resident_bytes=\(comparisonUsage().resident)"
        )
        let measuredBefore = ComparisonRowMeasure.measurements
        let rowBodiesBefore = ComparisonRowView.bodies
        let estimatesBefore = ComparisonRowMeasure.estimates
        ComparisonRowMeasure.measuredIDs.removeAll()
        let reflowStarted = ContinuousClock.now
        AppModel.shared.chatFontSize = font
        window.setContentSize(NSSize(width: width, height: 780))
        host.layoutSubtreeIfNeeded()
        let synchronous = reflowStarted.duration(to: .now)
        let synchronousMeasurements = ComparisonRowMeasure.measurements - measuredBefore
        let measuredIndices = fixture.rows.indices.filter {
            ComparisonRowMeasure.measuredIDs.contains(fixture.rows[$0].id)
        }
        let visibleIndices = fixture.rows.indices.filter { fixture.visible.contains(fixture.rows[$0].id) }
        print(
            "COMPARISON_REFLOW_ROWS width=\(width) measured=\(measuredIndices.first ?? -1)...\(measuredIndices.last ?? -1) visible=\(visibleIndices.first ?? -1)...\(visibleIndices.last ?? -1) document_height=\(scroll.documentView?.bounds.height ?? 0) origin=\(scroll.contentView.bounds.minY)"
        )
        try await Task.sleep(for: .milliseconds(500))
        print(
            "COMPARISON_REFLOW_COST backend=\(backend) width=\(width) font=\(font) synchronous_layout=\(synchronous) synchronous_row_measurements=\(synchronousMeasurements) total_row_measurements=\(ComparisonRowMeasure.measurements - measuredBefore) rows=\(fixture.rows.count) distinct_rows=\(ComparisonRowMeasure.measuredIDs.count) row_bodies=\(ComparisonRowView.bodies - rowBodiesBefore) reused_heights=\(ComparisonRowMeasure.estimates - estimatesBefore) window=\(fixture.sizing.window.count)"
        )
        // A reflow lays out the rows near the reader, not the rows above it (#85, #86).
        XCTAssertLessThanOrEqual(
            ComparisonRowMeasure.measuredIDs.count, 64, "A reflow must measure only rows near the viewport")
        host.layoutSubtreeIfNeeded()
        fixture.sampleFrames()
        let viewportTop = comparisonViewportTop(scroll, host: host)
        let held = anchors.compactMap { anchor in fixture.frames[anchor.id].map { (anchor, $0) } }
        guard let (anchor, frame) = held.min(by: { abs($0.1.minY - $0.0.minY) < abs($1.1.minY - $1.0.minY) })
        else {
            let nowAtTop = comparisonTopLineRows(fixture, scroll: scroll, host: host)
            print(
                "COMPARISON_NAVIGATION backend=\(backend) reflow_width=\(width) font=\(font) anchor_missing=true candidates=\(anchors.map(\.id)) now_at_top=\(nowAtTop.map(\.id)) origin=\(originBefore)->\(scroll.contentView.bounds.minY) document=\(documentBefore)->\(scroll.documentView?.bounds.height ?? 0) clip_width=\(scroll.contentView.bounds.width) style=\(scroll.scrollerStyle == .legacy ? "legacy" : "overlay") mounted=\(fixture.frames.count)"
            )
            XCTFail("Reflow must retain a measurable anchor at width \(width)")
            continue
        }
        let drift = abs(frame.minY - anchor.minY)
        // Where the viewport top falls inside the anchor row, before and after, as a fraction of its height.
        print(
            "COMPARISON_REFLOW_ANCHOR width=\(width) row=\(anchor.id) candidates=\(anchors.count) held=\(held.count) top_before=\(anchor.minY - anchor.viewportTop) height_before=\(anchor.height) top_after=\(frame.minY - viewportTop) height_after=\(frame.height)"
        )
        print("COMPARISON_NAVIGATION backend=\(backend) reflow_width=\(width) font=\(font) drift_pt=\(drift)")
        XCTAssertLessThanOrEqual(drift, 1)
    }
    let beforeInput = comparisonAnchor(fixture, host: host)
    let before = scroll.contentView.bounds.minY
    let requested = comparisonWheel(scroll, direction: 1, tick: 0)
    let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
    let applied = max(0, min(maximum, before + requested)) - before
    try await Task.sleep(for: .milliseconds(100))
    fixture.sampleFrames()
    let inputResidual =
        beforeInput.flatMap { saved in
            fixture.frames[saved.0].map { abs($0.minY - saved.1 + applied) }
        } ?? .infinity
    print("COMPARISON_NAVIGATION backend=\(backend) post_reflow_input_residual_pt=\(inputResidual)")
    XCTAssertLessThanOrEqual(inputResidual, 1, "Reflow must not leave a target that fights subsequent input")

    // Reading back up resolves the lazy stack's estimates above the reader; rows on screen stay put.
    var scrollBackResidual: CGFloat = 0
    var scrollBackMissing = 0
    for _ in 0..<24 {
        let saved = comparisonAnchor(fixture, host: host)
        let start = scroll.contentView.bounds.minY
        let target = max(0, start - 480)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        fixture.sampleFrames()
        guard let saved, let frame = fixture.frames[saved.0] else {
            scrollBackMissing += 1
            continue
        }
        scrollBackResidual = max(scrollBackResidual, abs(frame.minY - saved.1 + (target - start)))
    }
    print(
        "COMPARISON_NAVIGATION backend=\(backend) scroll_back_residual_pt=\(scrollBackResidual) missing=\(scrollBackMissing)"
    )
    XCTAssertEqual(scrollBackMissing, 0, "Every scroll-back step must retain a measurable anchor")
    XCTAssertLessThanOrEqual(
        scrollBackResidual, 1, "Resolving an estimate above the reader must not move the rows on screen")
    let afterInput = comparisonAnchor(fixture, host: host)
    try await fixture.append("\nOffscreen publication after reader input.\n", reasoning: false)
    try await Task.sleep(for: .milliseconds(500))
    fixture.sampleFrames()
    let replay = afterInput.flatMap { saved in fixture.frames[saved.0].map { abs($0.minY - saved.1) } } ?? .infinity
    print("COMPARISON_NAVIGATION backend=\(backend) post_reflow_publication_drift_pt=\(replay)")
    XCTAssertLessThanOrEqual(replay, 1, "Later output must not replay the reflow command")
}

/// Same events, no SwiftUI, preparation, height changes or anchor correction.
@MainActor private func comparisonInputCalibration() async throws -> CGFloat {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    scroll.hasVerticalScroller = true
    let document = ComparisonCalibrationDocument(frame: NSRect(x: 0, y: 0, width: 800, height: 100_000))
    scroll.documentView = document
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    window.orderFront(nil)
    defer {
        window.contentView = nil
        window.close()
    }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 50_000))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(100))
    var worst: CGFloat = 0
    for tick in 0..<24 {
        let before = scroll.contentView.bounds.minY
        let requested = comparisonWheel(scroll, direction: 1, tick: tick)
        try await Task.sleep(for: .milliseconds(16))
        worst = max(worst, abs(scroll.contentView.bounds.minY - before - requested))
    }
    return worst
}

@MainActor private final class ComparisonCalibrationDocument: NSView {
    override var isFlipped: Bool { true }
}

@discardableResult
@MainActor private func comparisonWheel(_ scroll: NSScrollView, direction: Int32, tick: Int) -> CGFloat {
    guard let native = comparisonWheelEvent(direction: direction, tick: tick) else { return 0 }
    let requested = -native.scrollingDeltaY
    scroll.scrollWheel(with: native)
    return requested
}

@MainActor private func comparisonWheelEvent(direction: Int32, tick: Int) -> NSEvent? {
    let boundary = [15, 23].contains(tick)
    guard
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: boundary ? 0 : direction * 60,
            wheel2: 0, wheel3: 0
        )
    else {
        XCTFail("Could not construct the scrolling event")
        return nil
    }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    // Do not fabricate gesture phases: a direct began call enters AppKit's event-tracking
    // loop, which expects subsequent events in its queue, not later direct method calls.
    // These are discrete pixel-wheel inputs. Hardware momentum remains manual qualification.
    guard let native = NSEvent(cgEvent: event) else {
        XCTFail("Could not bridge the scrolling event")
        return nil
    }
    return native
}

@MainActor private func comparisonWheelSequence(_ scroll: NSScrollView, direction: Int32) async throws {
    for tick in 0..<24 {
        comparisonWheel(scroll, direction: direction, tick: tick)
        try await Task.sleep(for: .milliseconds(16))
    }
}

private func comparisonPercentile(_ samples: [Double]) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
}

private func comparisonUsage() -> (cpu: Double, peakRSS: Int, resident: UInt64) {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return (
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)
            / 1e6,
        Int(usage.ru_maxrss), result == KERN_SUCCESS ? info.resident_size : 0
    )
}
