# Frequently asked questions

## Does GOAT run the model?

No. Your configured engine runs it. GOAT provides the workspace, context, tool coordination and interface. See [Models and engines](../overview/MODELS.md).

## Do I need an account?

GOAT does not require a GOAT account. An engine, MCP service, Hindsight deployment or external funding provider may have its own authentication.

## Can everything stay on my Mac?

Local engines and local memory providers can keep that processing and storage on your Mac. Configured remote services, previews and approved network-enabled commands can communicate externally. Local servers may also make their own connections. See [Privacy](../PRIVACY.md).

## Is every OpenAI-compatible server supported?

Compatibility depends on actual endpoints, streaming and feature behavior. The [engine reference](../ENGINES.md) distinguishes presets from live-tested combinations. A preset alone is not a compatibility certification.

## Does a Pen send all my files to the model?

No. Binding a folder does not automatically ingest its contents. Context depends on the instructions, selected content and tools in use.

## Does memory train the model?

No. Memory supplies retained context to later requests. Its storage and retrieval depend on the selected provider.

## Can GOAT run a terminal or background server?

Native command jobs are non-interactive, bounded and confined to a Pen. Detached services are unsupported. External MCP tools have independent behavior and permissions.

## Which Macs are supported?

Kid targets Apple Silicon and macOS 26 or later. Model memory requirements depend on the model and engine. Intel builds are not provided.

## Where is the download?

[Download 0.1 (Kid)](https://github.com/goatsoft/GOAT/releases/tag/v0.1.0) from GitHub Releases. The Mac app is signed and notarized; it requires Apple Silicon and macOS 26 or later. Follow [Getting started](Getting-Started.md) for installation and engine setup. Source build instructions remain available in [Contributing](Contributing.md).

## Do rendering caches contain my only copy of a chat?

No. Chats use durable SQLite storage and attachments use files. Rendering caches are bounded, disposable work; evicting them is not deletion of the saved transcript. See [Storage](../reference/STORAGE.md).

For a specific failure, start with [Troubleshooting](../how-to/TROUBLESHOOTING.md).
