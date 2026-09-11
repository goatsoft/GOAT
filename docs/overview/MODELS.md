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

## Planned model management

The [next roadmap tranche](../ROADMAP.md#next-model-selection-capabilities-and-recovery) adds Models settings for catalog and capability inspection, engine-scoped favourites, an Other models submenu and an Effort row that shows the selected preset. Diagnostic work will distinguish checkpoint loadability, request-style compatibility and per-response generation evidence. These controls are planned and are not available in Kid 0.1.1.

Compatibility will default to Automatic for each engine/model pairing, with an advanced override in model details. Switching models will resolve the new model's supported controls instead of inheriting another model family's settings from engine setup. The OpenAI-compatible API describes the connection protocol; the engine applies each model's actual chat template.
