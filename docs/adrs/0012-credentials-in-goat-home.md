# ADR-0012: The engine API key lives in `~/.goat`, not the Keychain

**Status:** Accepted · 2026-08-30

## Context

The oMLX engine key was stored in the macOS Keychain (`KeychainStore`). Under **ad-hoc code signing** (the dev machine has no signing identity, `security find-identity` = 0 valid), every rebuild is a *new* code identity the Keychain ACL doesn't recognise, so it re-prompts for the login password on every launch that reads the key, and an eager `SecItemCopyMatching` at startup froze the app behind an invisible modal. We tried lazy/flag-gated reads; the prompt still fired whenever an auth-walled engine was hit. JB: "annoying and not very goat."

## Decision

Store the key in **`~/.goat/config/credentials.json`, `chmod 0600`** (`CredentialStore` in GoatCore), never the Keychain. File reads never prompt. This is the same pattern as `~/.aws/credentials`, `~/.npmrc`, `~/.netrc`, GitHub CLI. Standard for local dev tokens. It's a localhost engine key (low sensitivity), and it lives in the GOAT home JB already owns (ADR-0009).

Migration is impossible without a prompt (reading the old Keychain value is the very op that prompts), so the user re-enters the key once via Settings → Engine; the stale Keychain item is left untouched (harmless).

## Consequences

Zero popups; the key is plaintext-at-rest behind owner-only perms. Tradeoff accepted for a local key. `KeychainStore` remains in the tree, unused. **If GOAT ever ships stable-signed + notarized**, revisit: a stable identity makes Keychain ACLs stick, and secrets could move back. A self-signed dev certificate would achieve the same during development (offered to JB; not taken this session).

## Alternatives considered

Lazy/once-per-run Keychain reads (rejected: still prompts under ad-hoc signing), self-signed cert for a stable identity (deferred, JB's call), encrypt the file with a machine-derived key (rejected: security theatre, key is derivable).
