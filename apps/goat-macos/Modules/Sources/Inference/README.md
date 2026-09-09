# Inference

Engine contracts, capability discovery, prompt budgets and streaming.

Public seams: `InferenceEngine`, `OpenAICompatEngine`, `PromptBudgeter`, `EngineLifecycleController`.

Dependencies: Herd, JUDAS.

Configured endpoints through JUDAS; context is data, never permission; no in-process ML.

Validation: InferenceTests covers wire handling, budgets, capabilities and lifecycle ownership.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
