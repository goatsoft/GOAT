# ADR-0029: Contextual media workspaces and the Tether inspector

**Status:** Proposed · 2026-09-01 · Extends [ADR-0002](0002-ui-architecture.md), [ADR-0010](0010-paddock-artifacts.md), [ADR-0014](0014-activity-log-not-terminal.md), [ADR-0017](0017-engine-agnostic-openai-dialect.md), [ADR-0019](0019-pens-as-folders.md), and [ADR-0024](0024-deterministic-prompt-budgeting.md)

## Context

GOAT currently has one chat-shaped request path and one chat-shaped composer. Image and video engines introduce a different contract: some accept text only, some require one or more source images, and others accept masks, negative prompts, reference images, start and end frames, guidance, seed, dimensions, duration, or motion controls. Their result is normally one durable media item rather than a token stream.

Putting every possible control in the composer would make chat slower to scan and harder to use. Moving those controls into the left sidebar would also displace Pens and chats, which are the stable navigation model. A permanent top-level Edit mode is ambiguous because edit, inpaint, outpaint, variation, and transformation are operations on an existing image or video rather than peer application workspaces.

The existing shell already has the correct regions: Pens and chats on the left, the active workspace in the centre, a collapsible inspector on the right, and the read-only Activity log at the bottom. The media design must fit that shell rather than create a parallel application.

## Decision

### Three top-level workspaces

The centre workspace has exactly three user-visible modes:

1. **Chat** for streamed language and vision conversations.
2. **Image** for text-to-image, image-to-image, inpaint, outpaint, variation, and image editing.
3. **Video** for text-to-video, image-to-video, start/end-frame generation, variation, and later video transformations.

There is no global Edit mode. Opening **Edit**, **Mask**, **Variation**, or **Use as input** on a media result selects Image or Video as appropriate and seeds a new draft with that result and operation.

Chat never constructs or displays Tether. Its right inspector remains the existing Session, engine, MCP, and Paddock surface. Selecting Image or Video makes Tether available and selects it by default. Closing the right inspector expands the centre without discarding the draft.

### Tether owns the generation contract

**Tether** is the contextual right-inspector module for configuring a media generation. It owns a `MediaDraft`, not an engine or running job. The draft contains:

- workspace and operation;
- selected engine and model capability snapshot;
- prompt and optional negative prompt;
- typed source slots such as source image, reference image, start frame, end frame, or mask;
- standard output controls such as dimensions, aspect, duration, guidance, steps, seed, and motion;
- capability-declared extra parameters which GOAT can render safely; and
- validation state and a saved preset reference.

The primary prompt remains in the centre composer. Negative prompt is a progressive disclosure beside it because it is prompt text, while source roles and numeric controls live in Tether. Advanced controls are collapsed by default. A missing required source or invalid parameter disables **Generate** and identifies the exact requirement in Tether.

Saved media configurations are ordinary presets in the professional interface. The 1337 presentation pack may label them **Knots**, but persistence and identifiers remain presentation-neutral.

### Capabilities produce a contract, not name-based UI

Startup and engine/model changes already probe capabilities under ADR-0024. Media support extends that probe into a `MediaGenerationContract`. The contract declares supported workspaces, operations, source roles, output kinds, standard parameters, ranges, defaults, and any bounded extension fields. Views render the contract and do not branch on model-family names.

GOAT may use a conservative, versioned compatibility profile when an OpenAI-compatible server does not advertise enough metadata. The Activity log identifies inferred capabilities. Unsupported or unknown fields stay hidden rather than being sent optimistically.

Image-only or edit-only models are selectable only in compatible workspaces. Required uploads are enforced before dispatch. A model change revalidates the draft atomically; compatible values survive, incompatible values are retained only as inactive draft state and are never sent.

### Media jobs are not chat turns

Media generation uses a dedicated `MediaGenerationEngine` protocol and `MediaJobCoordinator`. It does not add image/video cases to the token-oriented `GenerationEvent` stream.

The engine protocol accepts a validated, Sendable media request and returns a job stream containing queued, progress, preview, completed, cancelled, and failed events. The coordinator owns cancellation, bounded concurrency, polling or streaming adaptation, engine revision checks, and publication of durable results. An engine defaults to one active media job unless its capability contract safely advertises more concurrency.

The centre workspace renders one typed `MediaResult` item per completed generation, including provenance needed to reproduce it: model, engine profile revision, operation, dimensions or duration, seed when supported, input references, and effective parameters. Media bytes live in the attachment/media store and are referenced by durable records. Large files and thumbnails follow ADR-0026 and never decode or copy on `MainActor`.

Chat turn ownership from ADR-0023 remains independent. A future policy may allow one chat turn and one media job concurrently when they do not contend for the same engine, but no view may infer that safety. The coordinators decide from engine identity and declared capacity.

### The existing shell remains authoritative

- **Left:** Pens, configurable Pen icon and OKLCH colour, nested chat groups, and chats. A Pen's groups and chat indicators inherit its accent subtly. Tether never occupies this region.
- **Centre:** the active Chat, Image, or Video workspace and its context-sensitive composer.
- **Right:** the collapsible inspector. Tether appears only for Image and Video. Paddock continues to own code and document artifact previews under ADR-0010.
- **Bottom:** the independently collapsible Activity log. Media capability inference, validation, queueing, progress, cancellation, and completion are logged here.

At constrained widths the right inspector collapses before the left navigation. Fullscreen uses the same regions and backing policy as ADR-0028. Collapsed state, the selected workspace, and unfinished media drafts restore without delaying the first interactive window.

## Consequences

- Chat stays focused and pays no observable Tether construction or rendering cost.
- Image and video workflows gain enough room for masks and model-specific controls without turning the composer into a settings form.
- Removing global Edit avoids a mode whose meaning changes with the selected asset.
- Capability contracts make local engines and model families extensible without `isQwenFamily`-style UI branching.
- Media needs its own durable schema, job coordinator, engine adapters, and cancellation tests. It is a new product surface, not a small extension to attachments.
- Inspector routing must arbitrate Tether, Session, MCP details, and Paddock without losing state when one surface temporarily replaces another.
- Pen colouring remains identity, not decoration. Accents must preserve contrast and cannot become the only indicator of grouping or selection.

This ADR records the post-M6 media direction. It does not expand M6 memory or permit media implementation to overtake the Kid hardening and memory sequence.

## Alternatives considered

Put all media controls in the composer (rejected: chat inherits irrelevant complexity and dense forms do not fit), replace the left sidebar with media settings (rejected: destroys stable navigation), keep Edit as a top-level mode (rejected: it is an operation whose contract depends on an existing asset), reuse `InferenceEngine.GenerationEvent` for media (rejected: token streams and queued binary jobs have different lifecycle and persistence semantics), put completed media in Paddock only (rejected: Paddock is an inspector for artifacts and a generation result is primary workspace content), and hardcode controls per known model family (rejected: brittle across server versions and contrary to ADR-0017).
