# Extensions and skills

Extensions add capabilities to GOAT; skills provide reusable instructions and resources. Both work within the host’s existing tool and connection rules. Start with [Tools and permissions](../overview/TOOLS.md) for the concepts.

## Choose built-ins

Open **Settings → GOATed → Extensions → Built-in**. Expand a row to inspect its description, configuration and enable control.

| Built-in | Role | Initial state |
| --- | --- | --- |
| Herder | Native Pen file and command tools | On |
| Hindsight Memory | Optional configured memory-service integration | On; requires a configured provider |
| Hitch | Same-user local API and CLI | Off |
| Pronk | Fictional educational extension | Off |
| Skills and JUDAS | Required instruction and connection-policy services | Required core |

Availability changes wait until the active chat turn finishes. Disabling a capability revokes its callable handles, while saved project data and settings remain. Registration diagnostics do not establish that an external service is connected.

Herder has separate controls for file creation/edits and shell commands, plus a default timeout. Turning off native writes does not prevent an approved shell command from modifying files. Use [permission controls](../how-to/PERMISSIONS.md) to review actual authority.

## Add skills or packages

Use **Settings → GOATed → Skills → Add Skill…** for a Global skill folder containing `SKILL.md`. Manage Pen skills on the Pen page. Available user-invocable skills appear through composer `/` and `+` menus.

Skills first advertise a short description; their instructions and resources load when needed. Loading a skill never executes its scripts or grants access. Kid does not include managed skill setup or a GitHub URL installer.

The **User** extensions tab installs local declarative `.goated` packages. See [GOATed packages](GOATed-Packages.md) for review, scope and activation. Third-party executable plugin loading is unsupported.

## Connect external tools

Use [Add MCP tools](../how-to/MCP.md) for configured stdio or HTTP services. GOAT’s approval is separate from any permissions imposed by that server.

For practical examples, [work on code](../how-to/WORK-ON-CODE.md), [use Hitch](CLI-and-API.md) or explore [Pronk](Pronk-Example.md). Contributors can read the [extension API](../EXTENSIONS.md). If a capability fails or is quarantined, follow [Troubleshooting](../how-to/TROUBLESHOOTING.md); never restart during active work.
