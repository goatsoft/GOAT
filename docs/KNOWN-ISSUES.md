# Known issues

Current limitations to consider when evaluating the Kid source preview. This page separates reproducible behavior from compatibility that still needs qualification.

## Fullscreen sidebar on macOS 26

A dark area can appear over the top corners of the sidebar in native fullscreen. Windowed mode is unaffected. GOAT uses an opaque fullscreen backdrop to reduce related compositing artifacts, but this does not establish that the sidebar issue is resolved.

Workaround: use a normal window if the artifact interferes with reading. The original investigation covered macOS 26; a fix on a later macOS version has not been verified for this release. Include your exact OS/build and a non-sensitive screenshot when reporting a change.

## Native command compatibility

Jobs are non-interactive and confined to a Pen, with isolated home/cache directories. Interactive generators, detached services, authenticated registries and tools dependent on unrelated host configuration may not work. Some Apple launcher paths need an explicit installed runtime/SDK path. See [Permissions](reference/PERMISSIONS.md) and [Troubleshooting](how-to/TROUBLESHOOTING.md).

## Model and service support

A saved engine preset is not proof that every model or server version supports structured tools, vision or reasoning controls. Basic chat and tool calling must be qualified separately. See [Engine compatibility](ENGINES.md#compatibility-evidence).

Hindsight’s Open in Hindsight action currently targets port 9999 on the configured hostname. Custom web UI ports/reverse proxies must be opened manually. Browser/graph views are bounded previews, not complete service exports.

## Local-network access in source builds

macOS can ask again for local-network permission when an ad-hoc build changes. Check **System Settings → Privacy & Security → Local Network**, allow GOAT, then retry the connection. A configured endpoint also needs permission in JUDAS. Optional certificate signing is documented in [Releasing](wiki/Releasing.md#signing-setup); stable permissions across signed builds remain part of release acceptance.

## Release qualification

Clean-machine installation, signing/notarization, full scale profiling and live-service combinations remain release gates. Consult [Release readiness](RELEASE-CHECKLIST.md) for the current acceptance scope. There is no approved public Kid download yet.
