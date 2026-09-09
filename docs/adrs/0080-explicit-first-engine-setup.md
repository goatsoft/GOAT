# ADR-0080: Explicit first-engine setup

Status: Accepted
Date: 2026-09-10

## Context

A pre-created Custom connection looked like a working engine on a fresh installation. Failed connection messages appeared before the user had configured a server. New users also needed clearer window and sidebar defaults.

## Decision

Start with an empty engine list when there is no saved list or explicit legacy connection. Preserve existing lists, including an intentionally empty list, and migrate explicit legacy endpoints or presets. Never replace a corrupt configuration with fresh defaults.

After local startup succeeds, request Engine settings once for an empty, writable store. The page explains how to start an external server, add its connection and test it. Custom remains an editor option. Chat and status controls link directly to Engine settings when no connection exists. Recovery requires an active profile.

Activate the first saved engine automatically. Save its profile and optional credential before starting the connection. Keep the editor open when either write fails, and reject stale connection-test results after input changes. Additional connections preserve the active selection.

Use a default window size of 1180 by 780 points and an ideal sidebar width of 260 points. Restored window geometry and user resizing remain authoritative.

## Consequences

No model server is contacted merely because GOAT was installed. Users configure their own server before chatting. Existing connections continue to work without onboarding. Setup remains accessible after dismissing Settings, and an empty configuration can be retained deliberately.

No dependency or storage schema changes. Tests cover legacy migration, empty and corrupt stores, first selection, failed saves and one-time settings routing. Clean-machine acceptance also checks native window layout and a first real response.
