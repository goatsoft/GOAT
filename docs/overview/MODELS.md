# Models and engines

A model supplies the language and coding capability. An engine loads the model, runs inference and serves requests. GOAT connects to that engine and turns responses into a conversation or a sequence of tool actions.

## Choose the capability for the work

A text model can answer questions and draft prose. A vision-capable pairing can process selected images. Coding tools require both a model that can use tools and an engine that returns structured tool calls. A model name or “Coder” label is a discovery hint, not a guarantee of tool reliability.

GOAT uses an OpenAI-compatible streaming interface, with additional bounded metadata requests for supported engine profiles. “OpenAI-compatible” describes the wire format; it does not mean GOAT sends requests to OpenAI. Compatibility depends on the endpoints and fields a particular server implements.

## Decide where processing happens

With an engine on this Mac, model requests can stay on this Mac. A LAN or internet endpoint processes requests on its host. Model servers may have their own downloads, logging and connections beyond GOAT’s control. Choose an endpoint appropriate for the data you intend to use.

## Effort and statistics

Graze, Trot, Climb and Summit set sampling and output presets. Native reasoning controls are sent only when the engine contract or metadata supports them. Turning the dial cannot add reasoning capability to a model.

Token counts and timing are reported by the engine when available. GOAT labels estimates separately. Speed depends on the model, hardware, context and engine; the website’s interface illustrations are not benchmarks.

Follow [Connect an engine](../wiki/Engines.md). For endpoints, defaults and compatibility evidence, use the [engine reference](../ENGINES.md).

## Model management

The current model-management work keeps engine ownership separate from model selection. The Models settings tab discovers models from configured engines, persists a small preference record, and derives model capabilities from engine metadata rather than hard-coded UI assumptions.

When no engine or model is configured, the UI explains that an engine must be added before model capabilities can be inspected. Model discovery can be refreshed manually and is also refreshed while the active app scene is open, so models that become available in an engine can appear without restarting the app.

Model selection is resolved per model at request time. Unsupported capabilities are surfaced before inference, and request provenance records the selected model, engine, resolved capabilities, and sanitized diagnostics. Model load failures, printed tool markup, and interrupted file repair are reported as recoverable states rather than being silently treated as successful inference.

The model-management design is recorded in [ADR-0084](../adrs/0084-model-inspection-favourites-and-recovery.md). Live engine and model qualification remains separate from catalog discovery and must not be inferred from the presence of a model in the menu.
