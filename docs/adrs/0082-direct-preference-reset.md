# ADR-0082: Direct preference reset

Status: Accepted

Date: 2026-09-10

## Context

The owner requested a direct Reset preferences button with its scope described on the tab, without a second review screen. Clearing the entire preferences domain while GOAT is running would also discard connection locations and authority decisions, and leave observed application state inconsistent.

## Decision

Reset preferences updates a fixed set of presentation and general settings through AppModel's existing observed setters. It restores the System theme and Dock icon, theme reading fonts at the normal sizes, transparency, animations, new-chat effort, automatic titles, the Pens overview layout and Settings always-on-top behaviour. The tab lists these defaults before the button, applies them immediately and reports completion inline. It does not restart the app or require an additional review or confirmation.

The reset preserves GOAT Home and workspace paths, connections and credentials, conversations, local files, current selection, window positions, presentation unlock, privacy policy, preview networking rules, tool permissions and extension configuration. It does not clear the preferences domain, touch file stores or invoke service lifecycle methods. Uninstall may separately remove the complete preferences domain after shutdown under ADR-0081.

Data management has two tabs: Reset preferences and Uninstall GOAT. Local-data choices are covered by the uninstall keep controls. Partial uninstall is the default and preserves GOAT Home data and chats/attachments while removing app preferences. Uninstall all clears every keep box. The uninstall review and final confirmation remain because they prepare app and data removal after shutdown.

## Verification

A hosted test verifies immediate observable and persisted defaults while all unrelated preference keys and active selection/connection/privacy state remain unchanged. It restores its isolated test domain and model state afterward. Native checks use the separately identified Settings preview; they must never reset the maintainer's real app preferences.
