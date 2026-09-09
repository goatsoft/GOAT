# Getting started

Connect a model engine and send your first message. You can add project tools and memory once that basic connection works.

## Requirements

- An Apple Silicon Mac running macOS 26 or later.
- A compatible model engine, with a model that fits the memory available to it.
- An engine endpoint and any credentials it requires.

GOAT does not include model weights. Start with [models and engines](../overview/MODELS.md) if these concepts are new to you.

## Install GOAT

**0.1 (Kid) is a public source preview.** There is no packaged Mac download yet. Build from source using [Contributing](../../CONTRIBUTING.md). The [preview guide](../PUBLIC-PREVIEW.md) explains what to try, current limitations and how to give useful feedback.

Source builds require Xcode with the macOS 26 SDK and XcodeGen. From the repository root, `make gen` generates the Xcode project and `make build` builds the app. Launch instructions are in the contributor guide. Do not restart a running GOAT instance while a chat or command is active.

Source builds use ad-hoc signing by default and do not require Apple Developer membership. macOS may ask for local-network access when connecting to an engine on your network. Certificate-signed local builds are optional; see [Releasing](Releasing.md#signing-setup). Official downloads will have separate installation instructions after signing, notarization and clean-Mac testing are complete.

## Connect your engine

1. Start your engine and make a model available using that engine’s controls.
2. Open **Settings → Engine** in GOAT. Add or edit the engine, select its preset and enter its actual root URL. Conventional ports are defaults, not a requirement.
3. Enter the API key if the engine requires one. Use **Test** to check the connection, then save and select the engine.
4. Choose a model from the composer. Begin with a short text request such as “Explain what a project brief should contain.”
5. Send the message. A successful connection shows a response in the transcript; tool setup is not required for this first conversation.

If the model list is empty or the request fails, use [Connect an engine](Engines.md) and [Troubleshooting](../how-to/TROUBLESHOOTING.md). Check the endpoint, authentication and JUDAS policy before changing unrelated settings.

## Start project work

[Create a Pen](../how-to/CREATE-A-PEN.md) to group related chats and add project instructions. Bind a folder when you want to work with files. Linking a folder does not grant write or command permissions, and does not automatically add every file to a model request.

Next, [work on code](../how-to/WORK-ON-CODE.md), [use memory](Memory-and-Pens.md) or [inspect previews](../how-to/PREVIEWS.md). Read [Privacy](../PRIVACY.md) to understand local storage and the services you configure.

## Attach files and images

Paste copied files or an image into the composer, drop files onto it, or choose **Add files or photos**. Images show thumbnails; supported text/code files show a file icon and extension. Use the X to remove an attachment before sending. UTF-8 text/code files are limited to 512 KB each; image input is limited to 25 MB and resized for the engine. PDF, Office documents and archives are not supported. Attachments are copied into local chat storage; text files enter model context as labelled file content, subject to context budgeting. Image understanding depends on the selected model.
