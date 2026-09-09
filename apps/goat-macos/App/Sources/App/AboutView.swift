import AppKit
import Caprine
import SwiftUI

struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clicks = 0
    @State private var pose: Goatie?
    @State private var progress = 0
    @State private var celebrating = false
    @State private var showUnlockMessage = false

    private var playful: Bool { model.presentation.isEnabled }

    private func cycleMascot() {
        guard playful else { return }
        let poses = Goatie.allCases
        withAnimation(reduceMotion || !model.animationsEnabled ? nil : .easeInOut(duration: 0.2)) {
            pose = poses[clicks % poses.count]
            clicks += 1
        }
    }

    private var artwork: some View {
        Group {
            if playful, let pose { GoatieView(pose: pose, size: 240) } else { FigureheadView(size: 240) }
        }
        .scaleEffect(celebrating && !reduceMotion && model.animationsEnabled ? 1.04 : 1)
        .overlay {
            Circle()
                .trim(from: 0, to: celebrating ? 1 : CGFloat(progress) / 4)
                .stroke(model.theme.tokens.accentGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(8)
                .opacity(progress > 0 || celebrating ? 1 : 0)
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if playful {
                    Button(action: cycleMascot) { artwork }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show next mascot")
                        .help("Show next mascot")
                } else {
                    artwork.accessibilityElement(children: .ignore).accessibilityLabel("GOAT")
                }
            }

            VStack(spacing: 4) {
                Text("GOAT")
                    .font(.system(size: 30, weight: .bold, design: model.theme.isMono ? .monospaced : .default))
                    .foregroundStyle(model.theme.tokens.accentGradient)
                Text(playful ? "GOATed Open AI Tool" : "Your private AI workspace")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(AppInfo.versionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppInfo.diagnostics)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(
                celebrating
                    ? "1337 mode unlocked"
                    : (playful
                        ? (clicks >= 5 ? "🐐 you found the Herd. maaaa." : "100% local · 1337% native")
                        : "Local intelligence. Native to Mac.")
            )
            .font(.caption.weight(celebrating ? .semibold : .regular))
            .foregroundStyle(celebrating ? model.theme.tokens.tint : model.theme.tokens.muted)
            .accessibilityAddTraits(celebrating ? .updatesFrequently : [])
            Text(playful ? "Nothing leaves the HERD." : "Private by design. No account. No telemetry.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 400, height: 460)
        .background(CaprineBackground(model.theme.tokens, transparency: model.windowTransparency, extraOpacity: 0.24))
        .background(WindowConfigurator())
        .background(
            AboutKeyCapture(progress: { if progress != $0 { progress = $0 } }) {
                guard model.unlockPresentation() else { return }
                withAnimation(reduceMotion || !model.animationsEnabled ? nil : .easeOut(duration: 0.3)) {
                    celebrating = true
                }
                showUnlockMessage = true
            }
        )
        .goatPresentation()
        .alert("1337 mode unlocked", isPresented: $showUnlockMessage) {
            Button("Let’s GOAT!") {}
        } message: {
            Text("You’ve unlocked extra themes, mascots and app icons. Make them yours in Settings → Appearance.")
        }
        .task(id: celebrating) {
            guard celebrating else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { celebrating = false }
        }
        .onChange(of: playful) { _, _ in
            pose = nil
            clicks = 0
        }
    }
}

/// App-local event monitor, installed only while About exists and restricted to its key window.
/// Other windows, shortcuts, repeated keys, and text editors never contribute to the sequence.
struct AboutKeyCapture: NSViewRepresentable {
    let progress: (Int) -> Void
    let unlock: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(progress: progress, unlock: unlock) }
    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.didAttach = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.detach() }

    final class CaptureView: NSView {
        var didAttach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            didAttach?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let progress: (Int) -> Void
        let unlock: () -> Void
        var sequence = AboutUnlockSequence()
        var monitor: Any?
        var timeout: Task<Void, Never>?
        weak var window: NSWindow?

        init(progress: @escaping (Int) -> Void, unlock: @escaping () -> Void) {
            self.progress = progress
            self.unlock = unlock
        }

        func attach(_ window: NSWindow?) {
            detach()
            guard let window else { return }
            self.window = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(reset), name: NSWindow.didResignKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                var handled = false
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, NSApp.isActive, window.isKeyWindow,
                        event.window === window
                    else {
                        return
                    }
                    guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                        !(window.firstResponder is NSTextView)
                    else {
                        self.reset()
                        return
                    }
                    guard !event.isARepeat else { return }
                    let wasCapturing = self.sequence.progress > 0
                    let completed = self.sequence.consume(
                        event.charactersIgnoringModifiers ?? "", at: ProcessInfo.processInfo.systemUptime,
                        isRepeat: event.isARepeat)
                    handled = wasCapturing || self.sequence.progress > 0 || completed
                    self.progress(self.sequence.progress)
                    if completed {
                        self.reset()
                        self.unlock()
                    }
                    if self.sequence.progress == 1 {
                        self.timeout?.cancel()
                        self.timeout = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(10)) } catch { return }
                            self?.reset()
                        }
                    }
                    return
                }
                return handled ? nil : event
            }
        }

        @objc func reset() {
            sequence.reset()
            timeout?.cancel()
            timeout = nil
            progress(0)
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NotificationCenter.default.removeObserver(self)
            window = nil
            reset()
        }
    }
}
