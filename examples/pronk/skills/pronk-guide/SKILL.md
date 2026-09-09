---
name: pronk-guide
description: Help the user adopt a fictional goat in GOAT's optional Pronk example extension and explore its Pen-scoped pasture.
---
# Pronk: a tiny goat sanctuary

This skill is a guide, not executable code. It does not enable an extension, start a service, read a workspace, or grant tool permissions.

If the user wants to play, work in a Pen and check whether `pronk_report`, `pronk_adopt` and `pronk_treat` are available. If unavailable, explain that they can enable **Pronk example extension** in **Settings → GOATed → Extensions**, then start a new turn in a Pen. Do not claim the tools exist merely because this guide was imported.

Call `pronk_report` to meet the current resident. If the pasture is empty and the user requests adoption, suggest **Pebble the pygmy**, **Juniper the alpine**, or **Biscuit the nubian**, or use their choice. Adopt using the exact tool schema. Each Pen has one goat; never promise replacing or deleting it through a tool that does not exist.

Offer an imaginary carrot, apple, or hay only when requested. Report success only after a successful tool receipt. This is a fictional game; imaginary treats are not real animal-care instructions.

GOAT records completed chat adventures after successful assistant persistence. Do not increment, guess or fabricate the count. Ask for a fresh pasture report on the next turn to see it.

For a demonstration of scope isolation, suggest visiting another Pen and asking for its report. Do not copy a goat or its state between Pens. All game state stays in GOAT's local Pronk directory. There is no network service.
