import Foundation
import ImageIO
import SwiftUI

struct LoadingAnimation: Sendable {
    let frames: [CGImage]
    let delays: [TimeInterval]

    var duration: TimeInterval { delays.reduce(0, +) }
    var minimumDelay: TimeInterval { delays.min() ?? 0.1 }

    func frameIndex(at time: TimeInterval) -> Int {
        guard time.isFinite, duration > 0 else { return 0 }
        var remaining = max(0, time).truncatingRemainder(dividingBy: duration)
        for (index, delay) in delays.enumerated() {
            if remaining < delay { return index }
            remaining -= delay
        }
        return 0
    }

    static func decode(url: URL) -> LoadingAnimation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard (1...60).contains(count) else { return nil }
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                (1...512).contains(width), (1...512).contains(height),
                let frame = CGImageSourceCreateImageAtIndex(
                    source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let delay =
                (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double) ?? 0.1
            frames.append(frame)
            delays.append(delay.isFinite && delay > 0 ? max(1.0 / 60, delay) : 0.1)
        }
        return LoadingAnimation(frames: frames, delays: delays)
    }
}

/// Decode once off the main actor. Every loading view shares the same immutable frames.
actor LoadingAnimationStore {
    static let shared = LoadingAnimationStore()
    private var animations: [Bool: LoadingAnimation] = [:]
    private var missing: Set<Bool> = []

    func animation(dark: Bool) -> LoadingAnimation? {
        if let animation = animations[dark] { return animation }
        guard !missing.contains(dark),
            let url = Bundle.main.url(forResource: dark ? "spinner-dark" : "spinner-light", withExtension: "png"),
            let animation = LoadingAnimation.decode(url: url)
        else {
            missing.insert(dark)
            return nil
        }
        animations[dark] = animation
        return animation
    }
}

/// Shared indeterminate loading indicator. The source APNGs retain their transparency and colour.
struct GoatLoadingIndicator: View {
    private let title: String?
    @Environment(AppModel.self) private var model
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var animation: LoadingAnimation?

    init(_ title: String? = nil) { self.title = title }

    private var size: CGFloat {
        switch controlSize {
        case .mini: 20
        case .small: 26
        case .regular: 34
        case .large: 52
        case .extraLarge: 72
        @unknown default: 34
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let animation {
                    if model.animationsEnabled && !reduceMotion && scenePhase == .active {
                        TimelineView(.animation(minimumInterval: animation.minimumDelay)) { context in
                            artwork(
                                animation.frames[animation.frameIndex(at: context.date.timeIntervalSinceReferenceDate)])
                        }
                    } else {
                        artwork(animation.frames[0])
                    }
                } else {
                    Image(systemName: "hourglass")
                        .foregroundStyle(model.theme.tokens.tint)
                        .frame(width: size, height: size)
                }
            }
            // The square assets have transparent top/bottom margins around the infinity shape.
            .frame(width: size, height: size * 0.65)
            .clipped()
            if let title {
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? "Loading")
        .task(id: model.theme.isDark) {
            let loaded = await LoadingAnimationStore.shared.animation(dark: model.theme.isDark)
            guard !Task.isCancelled else { return }
            animation = loaded
        }
    }

    private func artwork(_ frame: CGImage) -> some View {
        Image(decorative: frame, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
