# ADR-0077: Host coordination and resource lifetimes

Status: Accepted · Refines [ADR-0025](0025-progressive-single-flight-startup.md), [ADR-0056](0056-bounded-rendering-and-responsive-io.md) and [ADR-0076](0076-hindsight-health-and-session-ownership.md)

## Context

AppModel and MemoryModel combined composition, store migration, routing, presentation and tool decoding in large files. Failed Hindsight extension registration remained cached as a completed task. Website graphics initialization could finish after component teardown. Acceptance tests also reported a composer update-cycle warning and recursive toolbar layout.

## Decision

Keep one observable main-actor owner for app state and one for memory configuration. Organize their operations into responsibility-specific extensions. Shared implementation members remain internal to the app target; module interfaces and durable formats are unchanged.

- `StartupDiskLoader` owns local startup reads and resumable migrations, returning the existing immutable snapshot. `AppModel` publishes it and owns progressive startup.
- `MemoryToolHandler` owns argument decoding, dispatch and bounded result encoding. `MemoryModel` continues to resolve current provider, scope and store authority. Browsing, configuration, Hindsight integration, retention and feedback have separate implementation files.
- App operations are grouped into startup, engines, engine profiles, chats, Pens, themes, message memory, generation and extension control. Existing revision checks and worker actors stay in place.
- `ExtensionRegistrationController` serializes Hindsight registration and removal. Concurrent refreshes share in-flight work. A failed attempt reports its error and can retry. A newer enable/disable intent invalidates earlier publication; a late registration is removed before replacement activation proceeds.
- `createAuroraRenderer` owns graphics resources from setup to disposal. Component unmount disconnects its visibility observer and disposes the renderer. Checks after asynchronous acquisition prevent late devices or fallback rendering from escaping teardown. Devices created before a setup failure are also released.
- Composer selection is tied to the current draft. Native edits reset menu selection and dismissal through their binding, without a second frame-based observer. Programmatic draft changes also start at the first matching result.
- The chat responsiveness fixture uses an `NSHostingController` in an AppKit-owned window. It bridges the title, while window toolbar integration remains with the app's SwiftUI scene. The focus fixture hosts its native search field beside the hosting view, not inside SwiftUI's managed view hierarchy.

## Consequences and validation

The refactor preserves one active generation turn, existing persistence ordering, provider selection and the Herd Guarantee. It introduces no dependency, schema change or new external endpoint.

Tests cover capacity recovery, shared registration, disable during activation, rapid re-enable, GPU acquisition during teardown and graphics cleanup after partial failure. Existing startup, storage, scope, prompt, permission and UI responsiveness tests exercise the moved code. The graphics tests run with Node's built-in test runner in website CI.

## Alternatives considered

Splitting every operation into a separate observable object would require new synchronization and publication rules without changing the ownership requirements. Keeping all operations in the original files would preserve those rules but leave review and navigation difficult. Focused extensions plus independently testable services retain the existing state model while separating distinct responsibilities.
