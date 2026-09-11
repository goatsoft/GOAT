# Release notes

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
