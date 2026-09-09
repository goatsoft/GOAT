# Add MCP tools

MCP servers provide external tools over stdio or HTTP. Configure services you understand and use a harmless tool call to verify setup before connecting sensitive work.

1. Open **Settings → MCP** and choose **Add Server**, or import an existing compatible configuration.
2. Review the executable and arguments for a stdio server, or the endpoint and authentication for an HTTP server. Importing configuration does not establish that the service is trustworthy or compatible.
3. Connect the server and inspect its discovered tools. Confirm JUDAS allows its transport; restricted modes block external MCP processes.
4. Enable tools in the chat and select the needed server through the composer’s **+** menu.
5. Ask for a small read-only action. Review the exact arguments in the approval dialog, then allow or deny it. Inspect its result in the transcript.

MCP approvals are independent of native Herder file/command grants. Remembered approval binds to the configured server/tool authority, and an external server may impose additional rules or its own approval queue.

If a call times out, its outcome may be unknown. Inspect the affected service/files and reconnect deliberately before retrying. GOAT does not execute tool markup printed as ordinary text. See [Troubleshooting](TROUBLESHOOTING.md) and the [connection reference](../reference/CONNECTIONS.md).
