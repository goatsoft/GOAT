# Herd

Local home, credentials, attachment files and user workspace bindings.

Public seams: `Home`, `LocalFileStore`, `CredentialStore`, `AttachmentStore`, `HerdWorkspaceFileWorker`, `GitWorkspaceWorker`.

Dependencies: none.

Owner-only credentials and bounded filesystem reads; Git probes stay local and initialization is explicit.

Validation: HerdTests covers credentials, bounded filesystem reads and attachments; hosted Herd tests cover workspaces and image preparation. Run `make test MODULE=Herd`.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
