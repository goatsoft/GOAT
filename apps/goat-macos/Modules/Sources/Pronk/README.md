# Pronk

The offline, Pen-scoped fictional-goat extension example.

Public seams: `PronkExtension`.

Dependencies: GOATed, Herd, Tools.

Bundled example using public GOATed contracts; state stays in the selected Pen scope; no network or scripts.

Validation: PronkTests exercises offline persistence and Pen scope; examples/pronk documents usage. Run `make test MODULE=Pronk`.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
