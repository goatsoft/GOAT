# Statistics reference

Open the right inspector with **⌥⌘I**. The **Stats** section at the top describes the current chat's inference,
not saved memories or your Mac's RAM. **Model**, Engine, and MCP details sit underneath.
The MCP section lists connected servers and their model-callable tool counts. Per-call results,
errors and timings appear in **Activity** (⌃`), keeping the inspector focused on current connections.

Context and speed indicators stay hidden until the first message is sent, then fade in. Reduce Motion disables the fade. The speed dial sits first, followed by its graph and context pressure, without a nested card.

Stats describe the currently open conversation, including saved responses from earlier app launches.
**Live** marks an active chat turn; the caption distinguishes generation, engine waiting and tool work. The speed label identifies the latest measured response in
that chat; it is not an average for the app session. Extra measurement explanations are available on hover.

## Throughput

The native tachometer refreshes four times per second from a rolling one-second estimate. Its needle reflects received output. After five seconds without output the dial shows a waiting state rather than presenting zero as model decode speed. The labelled scale grows when necessary and stays fixed for the rest of that response. The dial retains a numeric readout and an accessible speed value; **~** identifies estimates. Reduce Motion disables needle animation.

During generation, the line and shaded area show estimated tokens per second in one-second
intervals, using streamed text, reasoning and generated tool names/arguments. Initial engine waiting
is labelled separately and does not fill the graph with artificial zero-speed samples. Dips during
received output can reflect network delays, server buffering or generation pauses. A missing chunk does not establish that model decoding stopped. The estimate uses UTF-8 byte counts and can differ from the model tokenizer even during smooth delivery. The live caption identifies received output; completed server decode speed is labelled separately.

The trace keeps at most 60 samples and starts fresh for each response. Sampling stops when the
inspector closes or GOAT becomes inactive. Reopening during a response starts a fresh timing
baseline. A finished response shows the engine's decode rate when supplied, otherwise a rate
derived from output tokens and decode duration. First-token latency, output tokens, and total
request duration appear below it.

For responses completed in the current session, **Client delivery** separates first received output, the longest output gap and the longest UI publication. Publication time includes main-actor scheduling and applying the coalesced update and any due persistence checkpoint; it does not measure completed screen drawing. Counts and durations contain no prompt or response content, remain bounded, and are not persisted. Old saved responses do not invent these measurements.

First received output can include connection, queueing, model loading, prompt processing and buffered generation. A server-reported first-token time may cover a narrower interval. GOAT cannot identify an ongoing server phase from silence alone. Tool execution has its own labelled phase and is excluded from response decode speed.

While waiting for the engine or working through a tool step, the dial retains the last measured response
and labels it accordingly. A long first-token wait can coexist with a healthy final decode rate.
The live interval estimate can differ from the final whole-response rate. That is expected.

## Context ring

The ring shows the same context pressure as the composer: the current request's token usage
against its available budget. During generation the budget can reserve space for the answer.
The text identifies an input limit when applicable, and a trimming notice appears if GOAT removed
older prompt material to fit.

The estimate is calibrated per chat from the server's reported prompt tokens, so it converges on the
engine's real count after the first response. **~** means estimated usage or capacity. **?** means the engine or saved chat does not supply enough
information yet. An unknown value is not zero. Run another response to populate missing saved-chat
usage. This is a request budget indicator, not a promise that all earlier messages remain in context.

## Recent responses

Bars compare up to 12 recent responses with usable generation statistics, newest on the right.
Click or drag over a bar to inspect its rate. The legend distinguishes engine-reported from derived
rates. Different models, prompts, and output settings can change speed, so this is a history view,
not a controlled benchmark. Saved chats reuse whatever generation statistics were persisted;
missing measurements are not invented.

All charts run natively. They add no network calls or telemetry files. Live traces are temporary;
existing saved response statistics follow normal chat persistence.
