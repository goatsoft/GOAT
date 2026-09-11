# Try GOAT 0.1.1 (Kid)

Download the signed, notarized Mac app from [GitHub Releases](https://github.com/goatsoft/GOAT/releases/tag/v0.1.1). This guide covers getting started, exploring the features and reporting useful feedback.

0.1.1 (Kid) is a maintenance update. See the [roadmap](ROADMAP.md) for its scope and the separate M7 checklist.

## Install and connect

You need an Apple Silicon Mac running macOS 26 or later and a compatible model engine. Follow [Getting started](wiki/Getting-Started.md) to install GOAT and connect your engine. To build from source, use [Contributing](../CONTRIBUTING.md#build-locally).

Start with a small project and review each permission request. Model quality, tool calling and memory requirements depend on the model and engine you choose. Read [known issues](KNOWN-ISSUES.md), [engine compatibility](ENGINES.md) and [Privacy](PRIVACY.md) before using confidential work.

## Useful things to test

- **Everyday chat:** connect your engine, switch models, attach supported files and images, and inspect usage statistics.
- **Project work:** create a Pen, link a small workspace, review a proposed edit, run an approved command and guide the next step with Lead.
- **Memory and previews:** try local memory, inspect generated HTML or SVG, and connect Hindsight only if you already have a suitable service.
- **Usability:** test keyboard navigation, VoiceOver, your preferred theme and the clarity of instructions and permission prompts.

Try the features you need; you do not have to set up every integration. The [overview](overview/GOAT.md), [guides](wiki/Home.md) and [reference](reference/README.md) explain the supported paths. The [roadmap](ROADMAP.md) distinguishes implemented capabilities from future ideas.

## Give useful feedback

Use the [issue templates](https://github.com/goatsoft/GOAT/issues/new/choose) for bugs, engine compatibility and feature requests. Include the GOAT version/build and, for source builds, the source commit, macOS version, engine/model versions, reproduction steps and expected result. Remove credentials, private messages and project data from screenshots and logs.

Report security problems privately through [SECURITY.md](../SECURITY.md). Documentation corrections, small examples and accessibility improvements are welcome through [Contributing](../CONTRIBUTING.md). For general enquiries or sponsorship, contact [baa@goatapp.dev](mailto:baa@goatapp.dev).

## Follow development

Fixes land through pull requests, and published releases identify their source commit and download checksums. See the [roadmap](ROADMAP.md) for current priorities. Builds from `main` can include changes that are not yet in a published app.
