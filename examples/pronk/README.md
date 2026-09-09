# Pronk · the GOATed example

Adopt a fictional goat, offer imaginary treats and follow its adventures in a Pen. The example is bundled but disabled by default. Enable **Settings → GOATed → Extensions → Pronk example extension**, open a Pen chat, and ask: “Adopt Pebble the pygmy goat, give it an imaginary carrot, and show its pasture report.”

The actual compiled source is [PronkExtension.swift](../../apps/goat-macos/Modules/Sources/Pronk/PronkExtension.swift). Keeping one implementation avoids a tutorial copy that silently stops compiling. It uses public `GOATed` and the existing local file store; it imports no app model, SwiftUI, inference client or networking module.

The optional [pronk-guide skill](skills/pronk-guide/SKILL.md) can be imported with **Settings → GOATed → Skills → Add Skill…** by selecting its folder. It explains the example without granting any capability. The extension itself supplies a gated `/pronk` companion skill; the importable guide has a different name so both can coexist.

Read the [walkthrough](../../docs/wiki/Pronk-Example.md) and [extension API](../../docs/EXTENSIONS.md). Build and run its tests with:

```sh
swift test --package-path apps/goat-macos/Modules
```

Tests use a temporary directory, a fake host authorization callback and no model or server. Copy the source into your own compiled builtin, change the ID and tool names, and provide an explicitly owned state directory. Kid does not install third-party executable extension packages.
