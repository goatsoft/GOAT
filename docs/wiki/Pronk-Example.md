# Pronk: build a tiny goat sanctuary

Pronk is a working GOATed example: one fictional goat lives in each Pen, accepts imaginary treats, and counts completed chat adventures. It works entirely on your Mac.

## Try it

1. Enable **Settings → GOATed → Extensions → Pronk example extension**.
2. Open a chat inside a Pen and start a new turn. Loose chats have no pasture.
3. Ask: “Adopt Pebble the pygmy goat, give it an imaginary carrot, and show its pasture report.”
4. On your next turn, ask for another report to see the completed-adventure count.
5. Open a different Pen and ask for its report. That pasture is independent.

Your chat model must support tool calling. The `/pronk` companion skill explains the tools when the extension is available. The example never pretends that an adoption or treat succeeded without a tool result. These are fictional game actions, not real animal-care advice.

Disabling Pronk removes its tools and companion skill. State remains under `<GOAT_HOME>/extensions/pronk/<PEN_UUID>.json` and is reused when you enable it again. It does not read the Pen's workspace, make a network request or retain your chat transcript. To reset a pasture, disable Pronk and remove that Pen's JSON file yourself; Kid has no destructive reset tool.

## Learn from the implementation

The [source](../../apps/goat-macos/Modules/Sources/Pronk/PronkExtension.swift) is the actual builtin compiled in CI, rather than a separate tutorial copy. The [example folder](../../examples/pronk/README.md) contains its introduction and importable `pronk-guide` skill.

| Contribution | What it demonstrates |
|---|---|
| Manifest `goat.pronk`, version `0.1.0`, API 1 | Stable identity and explicit compatibility |
| Explicit state-directory constructor | The host supplies authority; the extension invents no hidden path or endpoint |
| `PromptProvider` | Bounded, untrusted context describing this Pen's resident |
| `ModelToolProvider` | Typed adoption, treat and report schemas; domain validation; real result receipts |
| Scoped companion skill | Instructions appear only when the extension is active and a Pen is selected |
| `TurnObserver` | Adventure counts advance only after successful assistant persistence |
| Actor-owned local store | Disk work stays off the main actor; each Pen uses a separate UUID-named record |

Tool schemas reject unknown fields, invalid breeds/treats and oversized names before the host authorizes dispatch. Adoption rejects an occupied pasture; reporting an empty one returns an honest empty result. No fictional behavior can alter memory configuration or approve another tool.

The package tests create a temporary directory, adopt a goat, give a treat, publish the same persistence event twice, check that the count changes once, verify another Pen cannot see the goat, and restore it with a fresh runtime. Other runtime tests cover deactivation, stale handles and deadlines. No live model or server is needed to test this example.

## Make your own compiled builtin

Start with the source, choose a unique extension ID and tool names, and accept required resources in the initializer. Build providers without starting background work. Register them through `ExtensionContributions`, retain the activation token, and unregister it on disable. Keep tool inputs strict and side effects bounded; cancellation cannot undo a write that has already committed.

Use [the API reference](../EXTENSIONS.md) for signatures and limits. Your host supplies authorization and the turn's immutable scope. Keep application state behind narrow host services, and verify behavior through public runtime calls with fake dependencies. Kid supports this source workflow; it does not install third-party executable extension packages at runtime.
