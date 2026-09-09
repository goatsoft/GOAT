# GOAT 0.1 (Kid): public source preview

GOAT is a native Mac workspace for local AI models, project files, tools and memory. This preview opens the source and documentation ahead of the first packaged release. You can build it locally, try it with your own engine and contribute improvements.

**There is no packaged Mac download yet.** Signing, notarization, clean-Mac installation and broader compatibility testing must be complete before the official 0.1 release. The source preview is intended for people comfortable building a Mac app and reporting issues.

## Build and try it

You need Apple Silicon, macOS 26 or later, Xcode with the macOS 26 SDK, XcodeGen and a compatible model engine. Apple Developer membership is not required. Follow [Contributing](../CONTRIBUTING.md#build-locally) to build and launch, then [Getting started](wiki/Getting-Started.md) to connect your engine.

Start with a small project and review each permission request. Model quality, tool calling and memory requirements depend on the model and engine you choose. Read [known issues](KNOWN-ISSUES.md), [engine compatibility](ENGINES.md) and [Privacy](PRIVACY.md) before using confidential work.

## Useful things to test

- **Everyday chat:** connect your engine, switch models, attach supported files and images, and inspect usage statistics.
- **Project work:** create a Pen, link a small workspace, review a proposed edit, run an approved command and guide the next step with Lead.
- **Memory and previews:** try local memory, inspect generated HTML or SVG, and connect Hindsight only if you already have a suitable service.
- **Usability:** test keyboard navigation, VoiceOver, your preferred theme and the clarity of instructions and permission prompts.

Try the features you need; you do not have to set up every integration. The [overview](overview/GOAT.md), [guides](wiki/Home.md) and [reference](reference/README.md) explain the supported paths. The [roadmap](ROADMAP.md) distinguishes implemented capabilities from future ideas.

## Give useful feedback

Use the [issue templates](https://github.com/goatsoft/GOAT/issues/new/choose) for bugs, engine compatibility and feature requests. Include the source commit, GOAT build, macOS version, engine/model versions, reproduction steps and expected result. Remove credentials, private messages and project data from screenshots and logs.

Report security problems privately through [SECURITY.md](../SECURITY.md). Documentation corrections, small examples and accessibility improvements are welcome through [Contributing](../CONTRIBUTING.md). For general enquiries or sponsorship, contact [baa@goatapp.dev](mailto:baa@goatapp.dev).

## What happens next

Preview fixes land as normal commits on `main`. The official release will identify an accepted commit with `v0.1.0`, provide a signed and notarized Mac download, and include installation instructions and known issues. Repository visibility and website availability alone do not mean that release has shipped.
