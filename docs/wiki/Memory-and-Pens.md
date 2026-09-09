# Memory and Pens

Memory stores useful context so a later request can use it. You can inspect the saved material and choose its provider. It is separate from the conversation transcript and does not train model weights.

## Choose a provider

| Provider | Where data lives | Use it for |
| --- | --- | --- |
| Markdown | Files under the selected local memory scope | Straightforward notes you can read in a text editor. |
| LLM Wiki | Local linked pages and sources | Structured project knowledge with Pages, Map and Connections views. |
| Hindsight | A configured Hindsight service and bank | Service-backed retention and retrieval with provider-specific records and relationships. |

Local providers keep their files on your Mac. Hindsight processes data on its configured host. Choose its deployment and policies accordingly.

## Set the scope

Global memory belongs to chats outside a Pen. A Pen uses its own configured memory scope; it does not automatically combine Global and Pen memory.

1. For Global memory, open **Settings → Memory**. For project memory, open the Pen’s **Memory** tab.
2. Enable memory and select the intended provider.
3. For a local provider, inspect its folder or recent records. For Hindsight, follow [Connect Hindsight](../how-to/HINDSIGHT.md).
4. Save useful context through the available memory actions, then inspect the record to verify what was retained.

The recent list is a bounded preview, not a complete export. Hindsight records may be extracted memories rather than whole transcripts. Changing provider or bank selects future reads and writes; it does not migrate or delete existing records.

The brain button below an assistant response saves that response to its chat's memory scope. It shows progress while sending, then highlights with a checkmark when the provider accepts the save. Hover to see **Saved to memory** or **Queued for memory**; queued work may still be processing in Hindsight. An error leaves the button available to retry, with the reason in its tooltip. This indicator lasts for the current app session and acknowledges the save request; it does not track later edits or deletions in the provider.

## Explore saved knowledge

Local LLM Wiki provides Pages, Map and Connections. Hindsight uses Records and Map with its own relationship types. Click a map to activate navigation, then pan, zoom or right-drag to rotate. Leave the map to release scrolling back to the page.

Use the [memory reference](../reference/MEMORY.md) for map controls, preview limits and provider-specific behavior. See [storage and backups](../reference/STORAGE.md) before moving or removing files.
