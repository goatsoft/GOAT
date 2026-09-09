# Security policy

GOAT’s security boundaries include connection policy, tool approvals, workspace confinement, local credentials and preview content. Reports that identify a failure in those boundaries are welcome.

## Report privately

Do not publish exploit details, credentials or private project data in an issue or pull request.

Email [security@goatapp.dev](mailto:security@goatapp.dev). If GitHub private vulnerability reporting is enabled, you can also use **Security → Advisories → Report a vulnerability** in [goatsoft/GOAT](https://github.com/goatsoft/GOAT/security/advisories).

Include the GOAT version and build, macOS version, relevant engine or tool version, reproduction steps, expected and actual behaviour, and likely impact. A minimal example without private data is most useful. Let the maintainers know whether the issue has been disclosed elsewhere.

Maintainers will assess the report, discuss remediation and coordinate disclosure with the reporter. The project does not currently promise a response-time service level or a paid bounty.

## Scope

- Unexpected outbound requests initiated by GOAT, credential exposure or sensitive data in diagnostic output.
- File, command, MCP or extension actions that bypass the intended approval or scope checks.
- Access outside an authorised Pen workspace or an unintended expansion of a command’s permitted resources.
- Preview content escaping GOAT’s content or connection restrictions.
- Problems in local control, package validation, persistence or dependency integration that compromise GOAT users.

A vulnerability in an independently operated engine or MCP server may need to be reported upstream. Reports about how GOAT configures or invokes those services remain relevant; choosing a third-party service does not excuse a bug in GOAT’s own boundaries.

## Supported releases

0.1 (Kid) is a public source preview. Reports against current `main` are welcome. Development and candidate builds have not completed binary release acceptance; supported release versions and security fixes will be listed with published releases.

Unsigned or ad hoc candidate builds can trigger macOS warnings. That expected distribution state does not establish that a build is safe, and a signing or update-integrity defect is still reportable.

See [Privacy](docs/PRIVACY.md), [Permissions](docs/reference/PERMISSIONS.md) and [Release readiness](docs/RELEASE-CHECKLIST.md).
