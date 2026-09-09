# Known issues

Current limitations in 0.1 (Kid). This page separates reproducible behavior from compatibility that still needs qualification.

## Fullscreen sidebar on macOS 26

A dark area can appear over the top corners of the sidebar in native fullscreen. Windowed mode is unaffected. GOAT uses an opaque fullscreen backdrop to reduce related compositing artifacts, but this does not establish that the sidebar issue is resolved.

Workaround: use a normal window if the artifact interferes with reading. The original investigation covered macOS 26; a fix on a later macOS version has not been verified for this release. Include your exact OS/build and a non-sensitive screenshot when reporting a change.

## First-launch setup

The initial window and sidebar proportions may need adjustment. Resize them to suit your display.

Kid includes a Custom engine profile on first launch. It does not mean an engine is installed or connected. Open **Settings → Engine** and configure the actual endpoint for your engine. A guided setup with no preconfigured engines is planned for the next release.

## Native command compatibility

Jobs are non-interactive and confined to a Pen, with isolated home/cache directories. Interactive generators, detached services, authenticated registries and tools dependent on unrelated host configuration may not work. Some Apple launcher paths need an explicit installed runtime/SDK path. See [Permissions](reference/PERMISSIONS.md) and [Troubleshooting](how-to/TROUBLESHOOTING.md).

## Model and service support

A saved engine preset is not proof that every model or server version supports structured tools, vision or reasoning controls. Basic chat and tool calling must be qualified separately. See [Engine compatibility](ENGINES.md#compatibility-evidence).

Some Devstral Small 2 conversions include a chat template that rejects a user message immediately after a tool result. Lead can trigger this with an HTTP 400 about alternating conversation roles. The installed 24B 4-bit conversion reproduced this during Kid acceptance, including with a minimal request outside GOAT. See the [upstream template report](https://huggingface.co/mistralai/Devstral-Small-2-24B-Instruct-2512/discussions/30). Use an updated template or another compatible model; switching the affected chat to Qwen3 Coder 30B resumed the completed file result in the tested configuration.

A model can request another write after you deny one. Each unapproved write remains blocked, but a new request may open another approval prompt. Use Stop to end the turn. Kid acceptance verified that Deny left the file absent and Stop cancelled a subsequent request.

Hindsight’s Open in Hindsight action currently targets port 9999 on the configured hostname. Custom web UI ports/reverse proxies must be opened manually. Browser/graph views are bounded previews, not complete service exports.

## Local-network access in source builds

macOS can ask again for local-network permission when an ad-hoc build changes. Check **System Settings → Privacy & Security → Local Network**, allow GOAT, then retry the connection. A configured endpoint also needs permission in JUDAS. Optional certificate signing is documented in [Releasing](wiki/Releasing.md#signing-setup); stable permissions across signed builds remain part of release acceptance.

## Release qualification

The official 0.1.0 build 1342 passed signing, notarization and installation checks on a separate Mac Studio with an M1 Max, 64 GB RAM and macOS 26.6.2. The owner confirmed launch without security warnings and chat/engine settings persisting across quit and reopen.

Broader engine/service combinations, full accessibility coverage and long-workload profiling remain ongoing. A successful installation does not establish compatibility with every model or integration. Consult [Release readiness](RELEASE-CHECKLIST.md) for the acceptance scope.
