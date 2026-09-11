---
glossary: false
---

# Glossary

A plain-language guide to the names and concepts used in GOAT. Follow the links for setup instructions and technical detail.

## Inference

Running a model to generate a response. An external engine performs inference; GOAT sends the request and displays the result.

Aliases: inferencing, infer

See: [Engines](ENGINES.md)

## Engine

A server that hosts models and answers GOAT’s requests. It can run on your Mac or at a configured network endpoint; compatibility depends on its API and the selected model.

Aliases: engines, inference engine

See: [Engines](ENGINES.md)

## oMLX

The recommended engine: a native menu-bar app that downloads, manages and serves MLX models on Apple Silicon. GOAT is its client, not its replacement.

See: [Engines](ENGINES.md)

## MLX

Apple's array framework for machine learning on Apple Silicon. Engines like oMLX use it to run models fast on the unified memory of an M-series Mac.

## OpenAI-compatible

An API format model servers use for chat requests and responses. GOAT requires a compatible streaming chat endpoint and model list; support for tools, images and reasoning varies.

Aliases: OpenAI-compatible API, OpenAI compatible

See: [ADR-0017](adrs/0017-engine-agnostic-openai-dialect.md)

## Model

The weights an engine loads and runs. Models live with the engine, never inside GOAT or its repo; GOAT lists what the engine serves and picks one per chat.

Aliases: models

## Streaming

Showing a reply as it is generated, token by token. GOAT coalesces those updates to the display's cadence and checkpoints the transcript to disk about once a second.

Aliases: streams, stream

## Token

A chunk of text a model reads or writes. Its size varies with the model, language and content. Context windows and effort budgets are measured in tokens.

Aliases: tokens

## Context window

How much text a model can attend to at once: system prompt, memory digest, tool schemas and transcript together. The pasture meter shows how full it is.

Aliases: context

## Thinking

A model's visible reasoning before its answer, when the model exposes it. GOAT shows it as a collapsed disclosure; long reasoning stays folded by default.

Aliases: reasoning

## Effort

The dial that sets response budget and sampling per turn: Graze, Trot, Climb or Summit, ⌘1 to ⌘4. The server determines which requested controls it supports.

Aliases: Graze, Trot, Climb, Summit

See: [Engines](ENGINES.md)

## Vision model

A model that accepts images as well as text. Paste a screenshot into the composer and GOAT sends it along when the model can see.

Aliases: vision

## MCP

Model Context Protocol, the open standard for giving a model tools and resources from external servers. GOAT is an MCP client; every tool call passes a permission gate you control.

Aliases: Model Context Protocol, MCP servers, MCP server

See: [ADR-0006](adrs/0006-mcp-integration.md)

## Tool

A capability the model can call during a turn: an MCP server tool, a memory tool, a skill loader or a bundled extension tool. Tools are typed routes; a name never grants permission.

Aliases: tools, tool call, tool calls

## Skills

Read-only Agent Skills, folders with a `SKILL.md`, loaded from the built-in bundle, `~/.goat/skills` and each Pen. Instructions are context for the model, never executable code.

Aliases: skill, Agent Skills

See: [Extensions](EXTENSIONS.md)

## Memory

What GOAT remembers between chats. One app-wide provider: Markdown notes in a folder you own (default), a local LLM Wiki, or a Hindsight server. Scoped to Global or one Pen, never both.

See: [ADR-0005](adrs/0005-memory-architecture.md)

## LLM Wiki

A curated local knowledge base the model maintains: immutable sources in `raw/`, curated pages in `wiki/`, an index and a log. An optional memory provider.

See: [LLM wiki contract](llm-wiki-contract.md)

## Hindsight

An optional external memory service. GOAT can recall knowledge and retain chat context in a configured bank; the server’s storage and network behaviour are controlled separately.

See: [ADR-0036](adrs/0036-native-skills-and-hindsight-lifecycle.md)

## Herd Guarantee

The product invariant: GOAT's own code never phones home. No analytics, no update pings, no crash reports. Configured services, permitted preview content and explicitly approved command networking have separate network boundaries.

See: [ADR-0015](adrs/0015-preview-network-policy.md)

## Herd

The whole flock: the project, the release codename family, and your Herd workspaces, the real working folders a Pen can bind to.

Aliases: Herd workspace, Herd workspaces

See: [ADR-0032](adrs/0032-herd-workspaces-and-read-only-git-status.md)

## Pen

A project that groups chats, instructions, skills and memory. Its configuration lives under `~/.goat/projects/`; it can also bind to a working folder with separate file and command permissions.

Aliases: Pens

See: [ADR-0019](adrs/0019-pens-as-folders.md)

## Paddock

The inspector for HTML, SVG, Mermaid, Markdown and code produced during a chat. Web previews run with a separate content and connection policy.

See: [ADR-0010](adrs/0010-paddock-artifacts.md)

## Off-grid previews

A Paddock setting that restricts preview connections to permitted local resources. JUDAS can impose stricter restrictions; blocked resources may leave a preview incomplete.

Aliases: off-grid

See: [ADR-0015](adrs/0015-preview-network-policy.md)

## JUDAS

GOAT’s connection policy for engines, MCP, Hindsight and preview content, with decisions recorded in the Activity Log. It is not a system firewall or a complete network traffic capture.

See: [ADR-0045](adrs/0045-judas-central-egress-policy.md)

## Activity Log

The read-only log panel (⌃`): engine, MCP, memory and JUDAS events with timestamps. Not a terminal, and not a tamper-evident journal.

See: [ADR-0014](adrs/0014-activity-log-not-terminal.md)

## Shepherd

The actor that runs one turn: plan the prompt, stream, run tool calls behind the permission gate, persist, hand off to memory. The only place inference, tools and memory meet.

See: [Architecture](ARCHITECTURE.md)

## GOATed

GOAT Extension Dynamics: the typed, in-process extension runtime. Scoped, atomic, revocable registrations; bundled Swift only in Kid. Surfaced as Settings → Extensions.

Aliases: extensions, extension

See: [Extensions](EXTENSIONS.md)

## Hitch

The optional local control API and the `goat` command line tool. A Unix socket owned by the running app, same user only, off by default. No TCP, no daemon.

Aliases: goat CLI

See: [ADR-0043](adrs/0043-local-goat-control-and-cli.md)

## Herder

The built-in extension for workspace file operations and confined commands. File and command permissions are controlled separately for each Pen, with approval scopes for individual actions, a chat or future Pen work.

See: [Work on code](how-to/WORK-ON-CODE.md)

## Pronk

The bundled example extension: one fictional goat per Pen that accepts treats and counts adventures. A pronk is a goat's celebratory stiff-legged jump.

See: [Pronk example](wiki/Pronk-Example.md)

## Tether

A proposed inspector module for configuring image and video generation. Documented in ADR-0029, not yet built.

See: [ADR-0029](adrs/0029-contextual-media-workspaces-and-tether.md)

## Caprine

Of or relating to goats. Also GOAT's design language: semantic colour tokens, a 4 pt grid, spring motion and a personality budget.

See: [Design](DESIGN.md)

## Theme

A look for GOAT as data: one folder, one `theme.json` in the GOAT Theme Format. Built-ins are System, Light, Pasture and Midnight; duplicate one to edit it.

Aliases: themes, GTF, GOAT Theme Format

See: [Themes](THEMES.md)

## Liquid Glass

Apple's macOS 26 material: translucent, refractive surfaces that show what sits behind the window. GOAT uses the real thing, not a blurred screenshot.

## Kid

The 0.1 release line, including its 0.1.1 maintenance update. Patch releases retain Kid; Yearling is reserved for the planned 0.2 polish release. Later codenames include Billy, Nanny, Wether, Ram, Capra and Ibex at 1.0.

Aliases: 0.1 (Kid)

See: [Codenames](CODENAMES.md)

## GOAT home

The folder GOAT keeps your files in: `~/.goat` by default, or `GOAT_HOME`. Config, memory, skills, Pens and themes all live here, in plain files you own.

Aliases: ~/.goat, GOAT_HOME

See: [ADR-0009](adrs/0009-goat-home-and-mcp-config.md)

## 1337

The unlockable playful presentation: type `1337` in About for the alternate icons, the 1337 theme and the mascot. A preference only; it never changes behaviour.

See: [ADR-0038](adrs/0038-professional-presentation-gate.md)

## Bleet

The chat domain module. Owns session and message state, streaming display revisions and incremental live metrics. Shepherd coordinates its turns.

See: [Modules](MODULES.md#bleet)

## Hoofprint

The activity and diagnostics module. Owns the bounded in-memory Activity Log and local Instruments signposts. It sends no telemetry.

See: [Modules](MODULES.md#hoofprint)
