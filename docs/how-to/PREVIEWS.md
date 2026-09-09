# Inspect previews in the Paddock

The Paddock displays supported documents alongside your conversation. Use it to inspect output before saving or opening it elsewhere.

1. Ask for a supported HTML, SVG, Markdown or Mermaid document, or open supported content through its preview action.
2. Open the Paddock and inspect the rendered document.
3. Switch between **Preview** and **Source** to compare the result with its contents.
4. Use the available copy, save or open action for the output you want to keep. Check the destination when saving.

Previewing code does not create project files. Use native Pen tools for writes and approved commands for builds. A browser preview is also not evidence that the underlying project passes its tests.

## Control preview connections

Open **Settings → JUDAS → Paddock previews**. In Configured connections mode, **Off-grid previews** restricts preview content to local and loopback resources. Other JUDAS modes override this preference and show the effective access.

Restricted HTML and SVG disable page scripts. Bundled Mermaid rendering remains available. Native Markdown images are blocked in chat, memory and the Paddock. An allowed browser handoff opens an external browser whose subsequent traffic GOAT does not control.

See the [connection-policy reference](../reference/CONNECTIONS.md#preview-behavior). Image/video generation and a separate media-job workspace are not available in Kid.

HTML, SVG and Mermaid code blocks have Preview and Source controls in chat once a response finishes. During generation, formatted source is shown at a bounded update cadence. Open the artifact in Paddock for a larger view.
