# ADR-0075: Chat file attachments and inline artifact presentation

Status: Accepted

## Context

The native text editor consumed paste before the SwiftUI image handler. The importer accepted only images despite its file label. Chat presented HTML fences as source, streamed raw backticks, and only Mermaid had an inline preview. The website implied a more consistent artifact interface.

## Decision

- Route Finder file URLs and clipboard raster images through the native composer into the same asynchronous importer used by the file picker. Ordinary text and web URLs retain normal text-paste behaviour.
- Accept supported UTF-8 text/code files up to 512 KiB, without NUL bytes, alongside existing bounded images. Unsupported binary documents fail visibly. Text attachments are immutable name/text copies in UUID-named `.goatdoc` JSON files under the existing attachment store. Existing image paths and database records are unchanged.
- Herd validates the document envelope. Shepherd loads it off the main actor as labelled user-provided text, never as image bytes. Prompt budgeting still applies. Attachment persistence must succeed for the whole submitted batch before inference starts.
- Show thumbnails for images and filename/extension cards for documents, each removable before sending. Reopened chats retain attachment cards through the existing stored-path list.
- Format streaming Markdown at most four times per second through the bounded parser cache, retaining the last prepared snapshot while the next parses. Incomplete artifacts stay source-only. Completed HTML, SVG and Mermaid fences share Preview/Source controls and the existing restricted Paddock WebKit host. Full standalone HTML/SVG documents are wrapped for presentation without changing stored source.
- Preserve all JUDAS policies, renderer admission limits, source export and external-link controls. This introduces no dependency or new renderer.

## Consequences and validation

Text files require UTF-8. PDF, Office documents, archives and arbitrary binary files are not added as attachment formats. Image understanding remains an engine capability. The saved transcript text stays readable without embedding entire attached files into its bubble.

Regression coverage checks document bounds, metadata and storage round trips, image/text prompt separation, clipboard payload classification, failed imports, fence metadata, embedded-backtick preservation and actual inline HTML rendering. Native visual acceptance of the empty Pen state, tool disclosure and attachment interactions remains required. App validation uses a separate build and does not restart an active user session.
