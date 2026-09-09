# ADR-0064: Composer and Pen file-permission controls

Status: Accepted · 2026-09-08

Refines ADR-0063.

## Context

The user wants a descriptive permission menu at the bottom of chat, beside the attachment button, and a Pen-wide section below Skills on the Pen page. Permission choices should be available before the first file change.

## Decision

Move the chat permission chip from the toolbar into the composer, beside `+`. Its upward-opening native popover presents Ask for approval, Allow for this chat and Always allow for this Pen, with icons, descriptions and a checkmark for the active scope. This is an explicit owner control over native Herder file creation and editing. It can create a scoped grant before a tool call. Keep the per-change Allow Once split button and its default Return-key action.

Place File permissions immediately below Skills in the Pen page's Workspace tab. It offers Ask for approval and Always allow for this Pen. A Pen without a bound folder explains that a folder must be chosen first. Remove the previous control from Edit Pen.

Scope changes are atomic SQLite replacements, using the existing physical-folder identity. Choosing Ask from a chat with only a chat grant clears that grant. Narrowing an active Pen-wide grant affects other chats, so the menu explicitly says they will return to asking. Choosing Ask on the Pen page clears every file grant in that Pen, including chat grants. A Pen-wide selection replaces the narrower grants to prevent their later resurrection. Persistence errors leave the controls open and report the failure.

## Consequences

The current policy is visible where the user types, and Pen-wide permissions are managed with the Pen's other capabilities. Draft chat choices apply to the same chat when its first send is accepted. No new access to shell tools, external MCP servers, the internet or files outside the configured workspace is granted. All ADR-0061 filesystem checks still run.

## Alternatives considered

- Keep status in the toolbar: less discoverable and separate from the coding workflow.
- Require a tool call before changing permission: prevents choosing the workflow before sending.
- Copy the reference's Full access option: would imply authority outside the native Pen file scopes.
