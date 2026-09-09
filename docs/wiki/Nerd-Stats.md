# Read generation statistics

GOAT’s statistics help explain what a response is doing and how much context it uses. They describe the current engine/model work, not overall system CPU or memory.

## Read the current state

Waiting for an engine, generating output and running tools are different phases. GOAT labels them separately. Tool-input generation contributes to live output estimates; a waiting or tool phase can show the last measured rate rather than pretending text is still streaming.

Engine-supplied token counts and timing are preferred when available. An estimate is marked separately, including when the used-token count is known but the model’s context limit is estimated. Compare like-for-like model, hardware and context when interpreting speed.

## Inspect a response

Open the available statistics/chart controls to examine throughput, the context ring and recent response measurements. A filled context indicator is a prompt-budget signal; it is not a measure of task understanding or memory quality.

Use [Statistics reference](../reference/STATISTICS.md) for exact definitions, fallback behavior and chart limits. For slow first responses or missing usage, see [Troubleshooting](../how-to/TROUBLESHOOTING.md).
