# ADR-0028: Measured, bounded rendering and fullscreen backing

**Status:** Accepted · 2026-09-01 · Extends [ADR-0002](0002-ui-architecture.md), [ADR-0010](0010-paddock-artifacts.md), [ADR-0011](0011-liquid-glass-and-window-translucency.md), [ADR-0016](0016-chat-content-pipeline.md), [ADR-0026](0026-main-actor-publication-and-worker-io.md), and [ADR-0027](0027-fail-closed-persistence-and-capability-bound-mcp.md)

## Context

GOAT must keep a streamed transcript responsive while model output, thinking, tool cards, Markdown, images, glass, and small ambient animations all update the same window. The prior transcript follower started an overlapping animated scroll for every 33 ms stream publication and derived its change identity by recounting accumulated strings. Completed Markdown could be parsed again whenever SwiftUI rebuilt a row. Thinking previews repeatedly split the whole accumulated thought, image thumbnails were decoded after every lazy-row reappearance, and syntax highlighting accepted unbounded inputs. Several always-live timelines continued ticking when the app was inactive or the visual no longer communicated live state.

The sidebar used SwiftUI `List`, which bridges to `NSTableView`. Progressive startup row publication produced an AppKit reentrant-delegate warning during app tests. Pen expansion also rescanned the full chat collection once per Pen.

The outstanding fullscreen defect had a separate compositor cause. A non-opaque native fullscreen `NSWindow` has no desktop behind it, so macOS composites it against a grey void. Liquid Glass samples that void. Switching the window to an opaque themed backing only after `didEnterFullScreen` left the transition itself exposed to a grey flash and stale glass sample.

## Decision

### Measure named render boundaries

GOAT emits low-cost points-of-interest signposts for `StreamPublication`, `MarkdownParse`, `ImageDecode`, `TranscriptFollow`, and `WindowBackingChange`. Instruments is the source of truth for duration, frequency, hangs, and target-hardware frame behavior. Unit tests prove bounds and publication rules, but do not claim a physical frame rate.

### Keep UI ownership on MainActor and reduce its work

SwiftUI state, AppKit view mutation, layout, and animation decisions remain on `MainActor`. GOAT does not create a dedicated animation thread. Core Animation, WindowServer, and the GPU already own composition outside the application main thread; manually moving SwiftUI animation state would violate framework ownership without moving layout or view updates.

Work that can produce an immutable value runs on an actor first. MainActor only publishes that result or performs the required AppKit mutation. Continuously visible decorative timelines run only when animation is enabled, Reduce Motion is off, and the scene is active. Episodic goat animations honor Reduce Motion and pause when the scene is inactive. Timeline cadence is capped at 20 or 30 Hz. A completed speed badge is static, and the send-button pulse exists only while the control is actionable.

### Bound transcript invalidation and following

Each message carries an increment-only render revision. Streaming appends update that revision and maintain the latest thinking line incrementally, so the follower and collapsed thinking UI never scan the accumulated response to detect a publication. Completion, errors, tool-call state, and persistence warnings also advance the revision.

While the user remains at the bottom, explicit transcript scroll commands are capped at 15 Hz. A single trailing task coalesces intermediate publications. Scrolls use a transaction with animation disabled, so a new 33 ms publication cannot overlap a longer implicit scroll animation. Leaving the bottom or the view cancels pending following. New messages and chat switches deliberately re-arm and snap the follower.

Completed Markdown is parsed once on a dedicated cache actor, not during SwiftUI body evaluation. Parsed immutable values are cached by message or artifact identifier in an LRU with at most 32 entries, 8 MiB of admitted source, and 2 MiB for one source. Source bytes are an admission proxy rather than a claim about the Markdown tree's retained size. Oversized Markdown remains selectable plain text. The raw text stays visible while parsing so a completed row does not collapse and jump.

Code fence highlighting is limited to 256 KiB; larger fences remain selectable monospaced text without an expensive line-number gutter. JSON editor highlighting is debounced, reuses compiled regular expressions, removes only prior brace highlights, and stops rich highlighting and line numbering above 512 Ki UTF-16 code units. Editing remains available up to the separate 5 MiB file safety limit.

Immutable attachment thumbnails use a worker-owned LRU capped at 64 entries and 64 MiB of actual bitmap row storage. Preview replacement paths which can change beneath the same logical name are not cached.

### Use native lazy layout without the table bridge

The sidebar is a vertical `ScrollView` and `LazyVStack`, which preserves lazy row construction without an `NSTableView` delegate. One grouping pass partitions chats into pinned, loose, and Pen-owned rows in O(chats + Pens). App tests must launch without the former table reentrancy warning.

### Own fullscreen backing for the complete transition

`WindowConfigurator` applies the current window configuration immediately when the `NSWindow` is already available and owns removable notification tokens for that exact window. `willEnterFullScreen` installs an opaque theme-colored backing before the transition. It stays opaque through `willExitFullScreen`, and `didExitFullScreen` restores the clear non-opaque window. Theme changes continue to flow through `updateNSView`. This fixes the compositor input rather than covering the grey result with another SwiftUI layer.

## Required tests and measurement

- App tests cover incremental render revisions and thinking tails, the transcript-follow rate limit, Markdown cache reuse and eviction, oversized Markdown fallback, and decoded-image LRU eviction.
- The complete app suite launches during `make test-app`; the former `NSTableView` reentrancy diagnostic must not appear.
- Strict concurrency, formatting, package tests, app tests, and a Debug build remain the repository commit gate through `make verify`.
- Instruments points-of-interest and Animation Hitches runs on representative Apple Silicon remain the acceptance method for the 60 fps product target.

## Consequences

- Stream publication remains visually prompt, but avoids repeated O(total response) bookkeeping and overlapping scroll animations.
- Completed Markdown, images, highlighting, sidebar grouping, and ambient timelines have explicit work or retention bounds.
- Rich rendering degrades to selectable plain text rather than risking an unbounded parse.
- SwiftUI layout and final text drawing necessarily remain on MainActor. The parsed Markdown cache is bounded by source size, not measured retained tree size, so Instruments must validate the chosen limits against real conversations.
- MarkdownUI does not declare its immutable parsed value `Sendable`. GOAT isolates the unchecked conformance to one wrapper consumed only by views; dependency changes require re-auditing that assumption.
- The fullscreen fix depends on the configured theme backing matching the root content. New window types must opt into the same configurator rather than assuming transparent native fullscreen has a desktop sample.
- Physical frame rate, GPU cost, and compositor behavior cannot be proven by deterministic unit tests. They remain release smoke tests on target hardware.
- With all six hardening decisions committed and verified, M6 may begin. This decision does not implement M6.

## Alternatives considered

Create a dedicated application animation thread (rejected: SwiftUI and AppKit view mutation remain main-thread-owned while Core Animation already composites elsewhere), animate every stream-follow scroll (rejected: publications arrive faster than the animation completes), parse Markdown in every `body` evaluation (rejected: unrelated state changes repeat work), cache without byte or entry bounds (rejected: long histories become retained-memory growth), rich-render arbitrarily large model output (rejected: model-controlled work must degrade safely), retain `List` and suppress the AppKit warning (rejected: the warning describes a real reentrant delegate path), and clear the window backing at `willExitFullScreen` (rejected: the native transition still samples the grey fullscreen void).
