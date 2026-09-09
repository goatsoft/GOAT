# Release codenames: the herd

The first live release is presented as **0.1 (Kid)**; its canonical bundle/tag version is `0.1.0`. The [versioning guide](VERSIONING.md) defines the implemented single-source metadata and validation workflow.

Every GOAT release carries a herd codename alongside its semver number (ADR-0018). The number is for machines; the name is for us. Roughly a goat's life and the wider family, ascending.

Set the codename in `apps/goat-macos/release.json`; generated build settings and bundle metadata carry it into the app. Versions increment per release, not per milestone number (see [ROADMAP.md](ROADMAP.md)).

| Codename | Meaning | Version | Milestone |
|---|---|---|---|
| **Kid** | a baby goat, the first of the herd | 0.1.0 (current) | M0–M6, memory, and the professional-default identity pivot |
| **Yearling** | a goat in its first year, finding its feet | 0.2.0 | Polish (M7) |
| **Billy** | an intact male, sure-footed | 0.3.0 | n/a |
| **Nanny** | a doe, keeper of the herd | 0.4.0 | n/a |
| **Wether** | steady and even-tempered | 0.5.0 | n/a |
| **Ram** | horns and momentum | 0.6.0 | n/a |
| **Capra** | the genus itself | 0.7.0 | n/a |
| **Ibex** | wild mountain goat, fearless on cliffs | 1.0.0 | Definition of GOAT |
| **Markhor** | the spiral-horned king | reserved | n/a |
| **Tur** | the Caucasian summit-dweller | reserved | n/a |

`1.0.0` (Ibex) is earned when the Definition of GOAT (PLAN §13) passes: Herd Guarantee tested, notarized builds, onboarding, 60fps. Not before.

Unreleased codenames may be reordered as milestones shift. Published release identities remain fixed, and patch releases retain the codename of their release line.
