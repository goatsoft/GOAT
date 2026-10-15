# Release notes

## Kid 0.1.4

GOAT 0.1.4 makes long replies and long conversations easier to read and work with. Large answers keep their formatting, stored chats open with recent messages first, and code, tool edits and themes are clearer. It also adds a bounded way for a model to hand a read-only investigation to a smaller local worker.

This release keeps **oMLX 0.6.4** as the qualified baseline.

### Faster transcripts

- The whole conversation scrolls as one continuous transcript, from the first message to the end of the longest reply, with nothing to page through. Only what is near the screen is laid out, so long chats and long replies stay responsive while a reply streams. On a Mac Studio running macOS 26, streaming 2 MiB of open reasoning took about 24 seconds instead of about 154.
- Your place is kept when earlier messages load above it, when a reply grows below it and when the window is resized.
- The streaming cursor shows only on the reply that is still arriving.

### Long replies keep their formatting

- Answers up to 2 MiB render as formatted Markdown instead of plain text after 8 KiB, and longer text stays selectable plain text. All of it scrolls in place.
- A finishing reply no longer jumps. Its footer, **Regenerate** and **Continue response** are laid out while it streams.
- Reasoning is folded or shown in full: finished reasoning folds to one "Thought for 12s" line, and opening it shows all of it in place. Your choice is remembered. **Fold reasoning after replies** in Appearance settings turns this off.
- Prose keeps a comfortable reading width in a centred column. Wide tables scroll sideways, and display math appears as labelled, selectable source.

### Long conversations open at the latest messages

- A stored chat opens with its latest 40 messages and loads more as you scroll, keeping your place. Generating, retrying and editing still use the full conversation.
- **Find in conversation…** searches the whole chat and shows a highlighted excerpt for each match.
- New reader actions include **Copy last reply**, **Export Markdown…**, editing a sent message with **Resend**, and **Retry reply**. **Regenerate** now works on replies that used tools.
- Command-F opens Find, Shift-Command-C copies the last reply, Command-End jumps to the latest message, and Option-Command-Up/Down move between the conversation and the composer.

### Clearer code, tool edits and colours

- Code is highlighted natively, including while it streams, in colours taken from your theme and adjusted to stay readable.
- Code blocks have a compact header with language, filename, line count and copy. Blocks over 40 lines collapse. **Wrap code** in Appearance settings sets the default, and each block can override it.
- File edits from tools appear as line diffs in the transcript and approval sheets, with a toggle back to the raw request. **Tool diffs** in Appearance settings turns this off.
- User themes gain **Edit Colours…** with a picker for each colour. Pens use the same picker. Existing colours are unchanged.

### Bounded read-only delegation

- With **Subagents** set up under **Settings → GOATed → Extensions**, a model can hand a read-only investigation of the current Pen to a local worker model and continue with its summary and verified citations. The worker can only list, read and search files.
- Delegation has fixed limits on time, rounds and output. If the worker is missing or not loaded, GOAT says so instead of switching models.
- The composer supports macOS **Writing Tools** when you invoke them.

### Testing and developer experience

- CI runs package tests, app tests and the Release build in parallel and reuses Xcode's compilation cache. A warm verification run takes about 6 minutes instead of about 19.
- Hosted test runs summarise known WebKit framework messages and keep complete logs. `make lint` rejects raw colours in transcript code.
- An opt-in macOS 26 qualification job measures transcript streaming, paging and reflow.

### Installation and upgrade

GOAT 0.1.4 requires Apple Silicon and macOS 26 or later. Download the signed, notarized [latest release](https://github.com/goatsoft/GOAT/releases/latest) with its manifest and checksums.

An ordinary upgrade replaces the app without resetting chats, engine profiles, memory, permissions or Pens. Finish active work before quitting GOAT to install the update, and keep a [backup of local data](reference/STORAGE.md#back-up-safely).

### Qualification and known limits

The official Release-channel package is built from the immutable `v0.1.4` source. The release workflow verifies the complete Release suite, website and docs, Developer ID publisher identity, hardened runtime, notarization, stapling and artifact checksums. See the [release metadata](https://github.com/goatsoft/GOAT/releases/latest) for the exact source revision and artifact hashes.

On macOS 26, the reader is slow when reasoning is expanded while a very large (multi-MiB) reply streams. CI measured about 180 to 260 seconds for 2 MiB of expanded reasoning. The default collapsed reasoning view is not affected. Inline previews reload when you scroll back to them, so interactive page state is not kept. Subagent delegation needs a supported Qwen worker, loaded and pinned, on a local or LAN engine. Writing Tools is a macOS feature and, depending on your system settings, may process text outside GOAT. Full keyboard and VoiceOver qualification of the new reader is still open; see [Known issues](KNOWN-ISSUES.md).

The previously reported difference between a 37 tok/s server reading and a 2-3 tok/s live display has not been reproduced. This release does not claim an engine-speed improvement. Model and tool results apply to the tested configurations, including stable oMLX 0.6.4, rather than every compatible server or workload.

## Kid 0.1.3

GOAT 0.1.3 makes local-model work easier to set up, easier to follow and more dependable over a long session. It brings model management into the app, keeps large conversations responsive and gives coding workflows clearer recovery when a model or engine has a difficult turn.

This release keeps **oMLX 0.6.4** as the qualified baseline.

0.1.3 supersedes the withdrawn 0.1.2 candidate. It is the same app with release-signing and packaging fixes so the automated build can produce a signed, notarized DMG.

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

GOAT 0.1.3 requires Apple Silicon and macOS 26 or later. Download the signed, notarized [latest release](https://github.com/goatsoft/GOAT/releases/latest) with its manifest and checksums.

An ordinary upgrade replaces the app without resetting chats, engine profiles, memory, permissions or Pens. Finish active work before quitting GOAT to install the update, and keep a [backup of local data](reference/STORAGE.md#back-up-safely).

### Qualification and known limits

The official Release-channel package is built from the immutable `v0.1.3` source. The release workflow verifies the complete Release suite, website and docs, Developer ID publisher identity, hardened runtime, notarization, stapling and artifact checksums. See the [release metadata](https://github.com/goatsoft/GOAT/releases/latest) for the exact source revision and artifact hashes.

The previously reported difference between a 37 tok/s server reading and a 2-3 tok/s live display has not been reproduced. This release makes those measurements distinct and easier to diagnose; it does not claim an engine-speed improvement. Model and tool results apply to the tested configurations, including stable oMLX 0.6.4, rather than every compatible server or workload.

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
