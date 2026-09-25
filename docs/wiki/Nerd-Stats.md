# Read generation statistics

GOAT’s statistics help explain what a response is doing and how much context it uses. They describe the current engine/model work, not overall system CPU or memory.

## Read the current state

Waiting for an engine, generating output and running tools are different phases. GOAT labels them separately. Tool-input generation contributes to live output estimates; a waiting or tool phase can show the last measured rate rather than pretending text is still streaming.

Engine-supplied token counts and timing are preferred when available. An estimate is marked separately, including when the used-token count is known but the model’s context limit is estimated. Compare like-for-like model, hardware and context when interpreting speed.

## Inspect a response

Open the available statistics/chart controls to examine throughput, the context ring and recent response measurements. A filled context indicator is a prompt-budget signal; it is not a measure of task understanding or memory quality.

Use [Statistics reference](../reference/STATISTICS.md) for exact definitions, fallback behavior and chart limits. For slow first responses or missing usage, see [Troubleshooting](../how-to/TROUBLESHOOTING.md).

The Engine section sits above Model and groups the active engine identity with its version,
memory use and ceiling, request counts, and selected-model load state. Runtime values refresh
only while the inspector is visible and the app is active.

The Model section shows the parent model, Effort directly beneath it, then reported Tools,
Vision and Reasoning capabilities. Unknown or conflicting capability reports remain explicit. The message count sits
in the Stats header. A separate Subagent
section shows the selected worker (or None) in its dropdown. The Subagent menu contains
only None and the worker models. None clears this engine's worker selection and stops delegation
without disabling the Subagents extension. Advanced options stay in Settings → Extensions →
Subagents → Advanced, including the 180-second default investigation limit (10–300 seconds).

Select the worker directly from the Subagent section, the chat model menu,
or the menu-bar Model menu. Choices come from the current engine's catalogue and audited
worker architectures, excluding models that explicitly lack tool support. The parent must
have reported tool support; matching model families is not required. Selection does not
load models or guarantee memory capacity. GOAT checks current engine status at delegation.

The composer keeps the model and effort on one line. A branch icon indicates an active
subagent; its tooltip names the worker. The whole control opens the model menu. Inside
the menus, the selected model and its worker share one selectable item with a tree subtitle.

Expand **Options** in the Nerd Stats Subagent section, or open **Settings → Extensions → Subagents → Advanced**,
to edit the same saved Auto/Custom processing budget, round limit and time limit. Controls are
locked during a chat turn; changes apply to the next turn. Auto scales with configured rounds
(71,680 processing tokens for five rounds). Custom supports 32,768–131,072 tokens. Repeated input
counts toward this allowance; it is separate from the worker's context and memory limits.
Exploration reserves capacity for the final summary and switches to reporting before consuming it.

The composer reserves room for the parent and child labels. Both the chat model picker
and Chat → Model menu repeat the selected worker as an indented informational row beneath
the selected parent. Use the Subagent submenu to change the worker.
