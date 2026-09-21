# Release notes

## Kid 0.1.2: in preparation

GOAT 0.1.2 makes local-model work easier to set up, easier to follow and more dependable over a long session. It brings model management into the app, keeps large conversations responsive and gives coding workflows clearer recovery when a model or engine has a difficult turn.

This release keeps **oMLX 0.6.4** as the qualified baseline.

### Your models, in one place

- A new **Models** area in Settings shows what the active engine can run, with favourites, capability filters, compatibility details and a direct model picker.
- Model menus now put the current model and favourites first. Clear icons distinguish coding, vision, multimodal, reasoning and general models.
- GOAT can apply bounded context and sampling guidance for a model while respecting engine facts and your explicit overrides. Response diagnostics show where the effective settings came from.

### Long work stays usable

- Conversations can compact when they run out of context, and `/compact` lets you start that process yourself. The original messages remain available for recovery and review.
- Large transcripts no longer ask the interface to lay out an entire oversized response at once. Earlier and Later navigation keeps the full conversation reachable, while your reading position stays steady as new output arrives.
- Very large responses and reasoning remain selectable and copyable. Copying the full source preserves Markdown, code fences, Unicode and whitespace.
- A saved Custom engine stays selected when it is temporarily offline, so GOAT reports the real connection state instead of quietly switching to another discovered service.

### More dependable coding conversations

- GOAT can retry a transient engine failure when no output has arrived. Once a response has started, it will not silently replay the turn.
- Printed or malformed tool markup is treated as text and never executed as a command.
- File reads can return more useful plain text, search supports globs and regular expressions, and independent read-only tool calls can run together. Edits and commands remain ordered and permission-controlled.
- Approved Pen commands use the selected Xcode toolchain and report clearer permission failures while remaining confined to the Pen.
- oMLX connections show clearer model, memory, queue and output-limit information when the server provides it. A response stopped at the effective output limit offers **Continue response**.
- Stats now separates server-reported decode speed from GOAT's received-output estimate and records bounded timing diagnostics without saving prompt or response content.

### Testing and developer experience

- Tests are organised by the domain that owns the behaviour, including Bleet, Paddock, Pens, Memory and Inference. Website checks are separate from macOS app and embedded-preview tests.
- Focused commands such as `make test MODULE=Bleet` and `make test MODULE=Paddock` run the relevant package and hosted coverage together. The release gate rejects empty test selections.
- `GOAT.xcodeproj` is maintained source. A fresh checkout can open, build, debug and test in Xcode without regenerating the project or installing XcodeGen.
- Shared schemes, domain test plans and the app's dependency lock are committed. `make build-signed` creates a hardened, timestamped Developer ID build and verifies its publisher, team and release entitlements.

### Installation and upgrade

GOAT 0.1.2 requires Apple Silicon and macOS 26 or later. The signed and notarized download will be added to GitHub Releases after the final candidate passes qualification.

An ordinary upgrade replaces the app without resetting chats, engine profiles, memory, permissions or Pens. Finish active work before quitting GOAT to install the update, and keep a [backup of local data](reference/STORAGE.md#back-up-safely).

### Qualification and known limits

The final release record will identify the exact accepted source revision and build. The candidate must pass the complete Release suite, website checks, supported-host Xcode builds, Developer ID signing, notarization, mounted-DMG validation and Gatekeeper assessment before publication.

The previously reported difference between a 37 tok/s server reading and a 2–3 tok/s live display has not been reproduced. This release makes those measurements distinct and easier to diagnose; it does not claim an engine-speed improvement. Model and tool results apply to the tested configurations, including stable oMLX 0.6.4, rather than every compatible server or workload.

## 0.1.1 (Kid)

A maintenance update to Kid, focused on everyday navigation, managing an installation and a clearer Finder installer. This release does not complete M7 or change the release line to Yearling.

### Changes

- Sidebar labels remain visible at maximum width. The preferred starting width is 300 points and the maximum is 600 points.
- Chat rendering avoids repeated layout work during updates.
- Settings → General → Manage presents storage locations in an expandable tree.
- Reset preferences applies the listed appearance and general defaults immediately, without restarting GOAT or clearing chats, connections, memory or permissions.
- Automatic uninstall offers Partial and All presets, explicit removal choices, cancellation and a private recovery folder. It waits for GOAT to close normally. External workspaces and independently managed services are preserved.
- A Retina Finder installer shows the real build number, a standard Applications-folder symbol, a separate CLI tile, aligned labels and a document-style Licence icon. Hidden support folders occupy the bottom row when shown.

### Installation and upgrade

Requires Apple Silicon and macOS 26 or later. Download the signed, notarized [0.1.1 (Kid) release](https://github.com/goatsoft/GOAT/releases/tag/v0.1.1), build 1353, with its manifest and checksums.

An ordinary upgrade replaces the app without a data reset. Finish active work before quitting to install an update, and keep a [backup of local data](reference/STORAGE.md#back-up-safely). See [Getting started](wiki/Getting-Started.md) and [Manage storage, reset preferences and uninstall](how-to/MANAGE-GOAT-DATA.md).

### Qualification and limitations

The maintainer accepted the tested maintenance candidate. The official package was rebuilt from the same source content and passed Developer ID signing, notarization/stapling, mounted-DMG checks, checksums and Gatekeeper assessment. Automated tests and maintainer acceptance do not establish compatibility with every engine, integration or workload.

The macOS fullscreen compositing limitation, model-template compatibility, non-interactive command boundaries and broader service/accessibility/performance qualification remain documented in [Known issues](KNOWN-ISSUES.md). The [roadmap](ROADMAP.md#m7-the-polish-pass) tracks the remaining M7 work.

## 0.1.0 (Kid)

The first signed, notarized Mac download. See its immutable [release notes and artifacts](https://github.com/goatsoft/GOAT/releases/tag/v0.1.0).
