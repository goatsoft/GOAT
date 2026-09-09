# What & why

<!-- What does this change, and what problem does it solve? Link any issue: Closes #123 -->

## How I tested

<!-- Repro / manual steps. GOAT can't be CI-screenshotted, so describe what you saw. -->

## Checklist

- [ ] `make verify` is green (lint + package tests + app tests + build)
- [ ] No new dependency without an ADR (the approved set is small on purpose)
- [ ] Colors/fonts/spacing go through Caprine tokens: no hardcoded values in views
- [ ] Kept the Herd Guarantee: no code that makes GOAT itself phone home
- [ ] Docs/ADRs updated if behavior moved
