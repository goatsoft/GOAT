import Bleet
import Caprine
import Charts
import SwiftUI

/// Native charts consume existing coalesced stream counters. Only the visible, active inspector
/// samples the dial four times per second and the graph once per second. Closing it ends sampling.
struct NerdStatsView: View {
    @Bindable var session: ChatSession
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var series = GenerationRateSeries()
    @State private var generationID: UUID?
    @State private var selectedResponse: String?
    @State private var meter = GenerationRateMeter()
    @State private var dialMaximum: Double = 100

    private var tokens: Caprine { model.theme.tokens }
    private var activeMessage: ChatMessage? {
        session.isStreaming ? session.messages.last(where: { $0.role == .assistant && !$0.complete }) : nil
    }
    private var history: [GenerationChartValue] {
        let messages = session.messages.reversed().lazy.filter { $0.complete && $0.stats != nil }.prefix(12).reversed()
        return messages.enumerated().compactMap { index, message in
            message.stats.flatMap { GenerationChartValue(id: message.id, ordinal: index + 1, stats: $0) }
        }
    }
    private var samplingKey: String {
        "\(session.id):\(activeMessage?.id.uuidString ?? "idle"):\(scenePhase == .active)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Stats", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                if session.isStreaming {
                    Text("Live")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(tokens.tint)
                }
            }
            throughputChart
            Divider().overlay(tokens.muted.opacity(0.15))
            contextChart
            if !history.isEmpty {
                Divider().overlay(tokens.muted.opacity(0.15))
                historyChart
            }
        }
        .task(id: samplingKey) {
            guard scenePhase == .active, let message = activeMessage else {
                series.pause()
                meter.reset()
                return
            }
            if generationID != message.id {
                generationID = message.id
                series = GenerationRateSeries()
                dialMaximum = 100
            }
            series.pause()
            meter.reset()
            if message.liveMetrics.startedAt != nil {
                series.sample(tokens: message.liveMetrics.estimatedTokens, at: .now)
                meter.sample(tokens: message.liveMetrics.estimatedTokens, at: .now)
            }
            var graphSampleDate = Date.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard scenePhase == .active, activeMessage?.id == message.id else { return }
                guard message.liveMetrics.startedAt != nil else { continue }
                let now = Date.now
                let count = message.liveMetrics.estimatedTokens
                meter.sample(tokens: count, at: now)
                dialMaximum = max(dialMaximum, GenerationRateMeter.scale(containing: meter.rate))
                if now.timeIntervalSince(graphSampleDate) >= 1 {
                    series.sample(tokens: count, at: now)
                    graphSampleDate = now
                }
            }
        }
        .onChange(of: session.id) { _, _ in
            series = GenerationRateSeries()
            generationID = nil
            selectedResponse = nil
            meter.reset()
            dialMaximum = 100
        }
    }

    @ViewBuilder private var contextChart: some View {
        if let status = ContextStatus(session: session, models: model.models, defaultModelID: model.defaultModelID) {
            let ratio = status.ratio
            let color = (ratio ?? 0) > 0.75 ? tokens.accent2 : tokens.tint
            HStack(spacing: 14) {
                ZStack {
                    if let ratio {
                        Chart {
                            SectorMark(angle: .value("Used", ratio), innerRadius: .ratio(0.79), angularInset: 2)
                                .foregroundStyle(color.gradient)
                            SectorMark(
                                angle: .value("Available", 1 - ratio), innerRadius: .ratio(0.79), angularInset: 2
                            )
                            .foregroundStyle(tokens.muted.opacity(0.14))
                        }
                        .chartLegend(.hidden)
                        .accessibilityHidden(true)
                    } else {
                        Circle().stroke(tokens.muted.opacity(0.18), lineWidth: 8)
                            .padding(5)
                    }
                    VStack(spacing: 0) {
                        Text(ratio.map { "\(Int(($0 * 100).rounded()))%" } ?? "?")
                            .font(.title3.weight(.semibold)).monospacedDigit()
                        Text("context").font(.caption2).foregroundStyle(tokens.muted)
                    }
                }
                .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Context pressure").font(.caption.weight(.semibold))
                    Text(status.label).font(.callout.weight(.medium)).monospacedDigit()
                    Text(
                        !status.usageKnown
                            ? "Usage unavailable until the next response."
                            : ratio == nil
                                ? "Window not reported by engine."
                                : status.exact && status.windowExact
                                    ? "Engine reported" : "~ Estimated"
                    )
                    .font(.caption2).foregroundStyle(tokens.muted)
                    if status.trimmed {
                        Label("Prompt trimmed to fit", systemImage: "scissors")
                            .font(.caption2).foregroundStyle(tokens.accent2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Context pressure, \(status.label)")
            .help(
                "Uses the same request budget as the composer. During generation this includes estimated output. An input limit reserves room for the response."
            )
        }
    }

    private var throughputChart: some View {
        let display = GenerationDisplayState(session: session)
        let stats = display.stats
        let generating = display.phase == .generating
        let rate = generating ? meter.rate : stats.flatMap { $0.toksPerSec > 0 ? $0.toksPerSec : nil }
        let estimated = generating || stats?.speedIsServerReported != true
        return VStack(alignment: .leading, spacing: 8) {
            ThroughputDial(
                rate: rate, maximum: max(dialMaximum, GenerationRateMeter.scale(containing: rate)),
                estimated: estimated, live: generating, tokens: tokens)
            Text(display.caption)
                .font(.caption2).foregroundStyle(tokens.muted)
            if series.samples.count >= 2 {
                Chart(series.samples) { sample in
                    AreaMark(x: .value("Time", sample.id), y: .value("Tokens per second", sample.rate))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [tokens.tint.opacity(0.28), tokens.tint.opacity(0.01)], startPoint: .top,
                                endPoint: .bottom))
                    LineMark(x: .value("Time", sample.id), y: .value("Tokens per second", sample.rate))
                        .foregroundStyle(tokens.tint).lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...max(1, (series.samples.map(\.rate).max() ?? 1) * 1.15))
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 82)
                .accessibilityLabel("Estimated throughput during this response, up to 60 samples")
            }
            if let stats, !session.isStreaming {
                HStack(alignment: .top) {
                    metric(
                        "First token",
                        stats.ttft.flatMap { $0.isFinite && $0 >= 0 ? String(format: "%.2fs", $0) : nil } ?? "Unknown")
                    Spacer(minLength: 4)
                    metric("Output", "\(stats.tokensAreExact ? "" : "~")\(max(0, stats.tokens))")
                    Spacer(minLength: 4)
                    metric(
                        "Duration",
                        stats.duration.isFinite && stats.duration >= 0
                            ? String(format: "%.1fs", stats.duration) : "Unknown")
                    if let cached = stats.cachedPromptTokens, cached >= 0 {
                        Spacer(minLength: 4)
                        metric("Cached", "\(cached)")
                            .help(
                                "Prompt tokens the engine served from its prefix cache on this response. Higher means more of the prompt was reused instead of re-read, which lowers first-token latency."
                            )
                    }
                }
            }
        }
        .help(
            session.isStreaming
                ? "The dial refreshes four times per second using a rolling one-second estimate. The graph samples once per second. Pauses appear as dips."
                : stats == nil
                    ? "This chat has no saved response measurements. A live trace appears while generating with the inspector open."
                    : "Latest measured response in this chat. "
                        + (estimated
                            ? "Speed derived from output tokens and decode duration." : "Speed reported by the engine.")
        )
    }

    private var historyChart: some View {
        let values = history
        let selected = values.first { String($0.ordinal) == selectedResponse }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent responses").font(.caption.weight(.semibold))
                Spacer()
                Text("tok/s").font(.caption2).foregroundStyle(tokens.muted)
            }
            Chart(values) { value in
                BarMark(
                    x: .value("Response", String(value.ordinal)), y: .value("Tokens per second", value.rate),
                    width: .ratio(0.62)
                )
                .cornerRadius(3)
                .foregroundStyle(value.reported ? tokens.tint.gradient : tokens.accent2.gradient)
                .opacity(selectedResponse == nil || selectedResponse == String(value.ordinal) ? 1 : 0.35)
            }
            .chartXScale(domain: values.map { String($0.ordinal) })
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartXSelection(value: $selectedResponse)
            .frame(height: 88)
            Text(
                selected.map {
                    "Response \($0.ordinal): \($0.reported ? "" : "~")\($0.rate.formatted(.number.precision(.fractionLength(1)))) tok/s"
                } ?? "Last \(values.count) measured responses · newest on right"
            )
            .font(.caption2).foregroundStyle(tokens.muted)
            HStack(spacing: 12) {
                key("Reported", color: tokens.tint)
                key("Derived", color: tokens.accent2)
            }
            .help(
                "Click or drag across the bars to inspect a response. Rates may use different models or output settings, and are not a controlled benchmark."
            )
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption2).foregroundStyle(tokens.muted)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }

    private func key(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.caption2).foregroundStyle(tokens.muted)
        }
    }
}
