---
glossary: false
---

# Privacy

GOAT is a local-first AI workspace. It stores chats and settings on your Mac and has no app analytics, automatic crash uploads or background update checks. Your choices about engines, tools, memory and previews determine which other services can receive data.

This page describes the current application and the static websites at goatapp.dev and goatherd.dev.

## The application

### Local storage

Chats, attachments, settings, local memory and permission grants are stored on your Mac. Engine credentials currently use a file with owner-only permissions, rather than the macOS Keychain. GOAT does not provide its own encryption at rest. Account security, FileVault and backup protection are separate controls.

See [Storage, backups and deletion](reference/STORAGE.md) for locations and practical instructions. Removing the application does not remove its data or your workspace files.

### Engines and tools

The selected engine receives the context needed for a request. This can include messages, instructions, memory, selected attachments, tool definitions and tool results. Engines run separately from GOAT and can be configured on this Mac, a local network or a remote endpoint. A local address does not establish what that server does with received data.

MCP servers receive the tool arguments sent to them and run under their own process or service permissions. File tools can return approved workspace content to the conversation. Confined commands can access their authorised resources and may use the network only when explicitly enabled and permitted by policy. Review approvals before exposing confidential material.

### Memory

Local Markdown and LLM Wiki memory are stored in GOAT’s home directory. If you configure Hindsight, GOAT sends recall requests and retained context to the selected server and bank. Its operator controls retention, deletion, backups and any model services it uses. Changing providers does not delete records already retained by a previous provider.

### Previews and other applications

Paddock can display generated HTML and diagrams. Preview resource requests follow the preview settings and JUDAS connection policy. Opening a link, document or service in another application transfers control to that application and its policies.

### Connection controls and diagnostics

JUDAS governs GOAT’s managed connections. It is not a system-wide firewall and does not control every action taken independently by an engine, external MCP process or another application. The Activity Log records selected application events, not a complete network capture.

The Activity Log and performance signposts remain local unless you choose to share them. Diagnostic exports, screenshots and operating-system reports can contain project or device information. Review them before attaching them to an issue.

Read [Connection controls](wiki/JUDAS.md) and [Tools and permissions](overview/TOOLS.md) for the available choices.

## The websites

The sites do not add analytics, advertising, tracking pixels, remote fonts or third-party embeds. Site assets and the documentation search index are served with the sites. There are no GOAT accounts or submission forms, and the site code does not set cookies.

The documentation site uses browser storage:

| Key | Storage | Purpose |
| --- | --- | --- |
| `vitepress-theme-appearance` | Local storage | Remember the selected appearance. |
| `vitepress:local-search-detailed-list` | Local storage | Remember the search result display preference. |
| `vitepress:local-search-filter` | Session storage | Retain the local search query during the browser session. |

Search runs in your browser. These values are not sent to a GOAT analytics service; clearing the site’s browser data removes them.

The production sites are intended for GitHub Pages hosting. GitHub processes hosting requests and logs visitors’ IP addresses for security purposes, including visitors who are not signed in. See [About GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages) and [GitHub’s privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) for its practices.

Links to GitHub, engine projects and the sponsorship provider take you to independently operated services. Their privacy policies apply when you visit them. Sponsorship payments are handled by the linked provider, not these static sites.

## Community contributions and questions

GitHub issues, pull requests and discussions can be public. Do not include credentials, private conversations or confidential project files. Information you voluntarily submit is handled by the relevant platform and the maintainers who receive it.

For privacy questions or requests, email [privacy@goatapp.dev](mailto:privacy@goatapp.dev). For general enquiries, email [baa@goatapp.dev](mailto:baa@goatapp.dev). Send vulnerability reports through the [security reporting channels](../SECURITY.md); do not include private information in a public issue.
