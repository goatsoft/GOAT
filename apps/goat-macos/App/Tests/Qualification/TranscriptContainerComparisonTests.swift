import AppKit
import Bleet
import Darwin
import Hoofprint
import SwiftUI
import XCTest

@testable import GOAT

extension TranscriptPerformanceTests {
    /// Run each backend in a fresh Release process. Defaults exercise 2 MiB per live channel.
    @MainActor func testContainerComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let backend = environment["GOAT_COMPARE"], ["swiftui", "appkit"].contains(backend) else {
            throw XCTSkip("Set TEST_RUNNER_GOAT_COMPARE=swiftui or appkit")
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
        let host = NSHostingView(
            rootView: TranscriptComparisonSurface(fixture: fixture, backend: backend).environment(model))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 1180, height: 780), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "GOAT container comparison: \(backend)"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        print("COMPARISON_READY backend=\(backend) pid=\(getpid()) bytes=\(bytes) dense=\(dense) follows=\(follows)")
        try await Task.sleep(for: .seconds(environment["GOAT_COMPARE_INSTRUMENTS"] == "1" ? 15 : 3))
        guard let scroll = comparisonScroll(host) else {
            XCTFail("No outer transcript scroll view")
            return
        }
        XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.contentSize.height)
        let initial = comparisonUsage()
        let scrollStart = ProcessInfo.processInfo.systemUptime
        try await comparisonGesture(scroll, direction: 1)
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
            let after = comparisonUsage()
            let anchorDrift = anchor.flatMap { saved in fixture.frames[saved.0].map { Double($0.minY - saved.1) } }
            let completionDrift = beforeCompletion.flatMap { saved in
                fixture.frames[saved.0].map { Double($0.minY - saved.1) }
            }
            let preparation = await fixture.markdown.snapshot()
            XCTAssertEqual(preparation.work.mainThreadPreparations, 0)
            let result: [String: Any] = [
                "preparation_main_thread_refreshes": preparation.work.mainThreadPreparations,
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
        try await comparisonGesture(scroll, direction: 1)
        try await Task.sleep(for: .milliseconds(500))
        let anchor = comparisonAnchor(fixture, host: host)
        window.setContentSize(NSSize(width: 820, height: 780))
        try await Task.sleep(for: .seconds(1))
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

@MainActor private func comparisonAnchor(_ fixture: TranscriptComparisonFixture, host: NSView) -> (String, CGFloat)? {
    // Include a partially visible tall row, not only rows whose top edge is on screen.
    fixture.frames.filter { $0.value.maxY > 80 && $0.value.minY < host.bounds.height - 60 }
        .min(by: { $0.value.minY < $1.value.minY }).map { ($0.key, $0.value.minY) }
}

@MainActor private func comparisonGesture(_ scroll: NSScrollView, direction: Int32) async throws {
    for tick in 0..<24 {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: direction * 60, wheel2: 0, wheel3: 0
            )
        else { continue }
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase, value: tick == 0 ? 1 : tick == 15 ? 4 : tick < 15 ? 2 : 0)
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase, value: tick == 16 ? 1 : tick == 23 ? 3 : tick > 16 ? 2 : 0)
        if let native = NSEvent(cgEvent: event) { scroll.scrollWheel(with: native) }
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
