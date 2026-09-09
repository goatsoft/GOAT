# Understand GOAT

GOAT is a native AI workspace for Apple Silicon Macs. It connects a model engine to conversations, project context and tools, while keeping access decisions visible in the app.

## The workspace around your model

An **engine** runs models and exposes an API. A **model** generates responses through that engine. GOAT provides the conversation interface, gathers the context needed for a request, coordinates available tools and presents the results. It does not include model weights or run inference in-process.

You can run an engine on your Mac to keep inference local. A configured service can also run on another machine. Its location and behavior determine where submitted context is processed. See [Models and engines](MODELS.md).

## Projects, actions and knowledge

A **Pen** groups related chats with project instructions and can bind a folder on your Mac. The folder provides a workspace for native file and command tools; binding it does not automatically send every file to the model.

**Tools** perform actions such as reading a file or running an approved command. **Skills** provide reusable instructions and resources. A skill can help a model choose its approach, but cannot approve actions or change your permissions.

**Memory** supplies reusable context. Local providers store Markdown on your Mac; optional Hindsight uses a separately configured service. Global chats and Pen chats have separate memory scopes.

The **Paddock** previews supported documents alongside a conversation. A displayed code block is output to inspect, not proof that a file was written or a command ran.

## Control and visibility

File permissions, command permissions, MCP tool approvals and JUDAS connection policies have different scopes. GOAT checks the authority relevant to each action. Expand grouped tool activity to inspect an action’s arguments and result. Use Lead to guide active work after its current action finishes.

GOAT has no built-in analytics, advertising or automatic update checks. Optional services and approved network activity still matter to your privacy. Read [Privacy](../PRIVACY.md) and [Tools and permissions](TOOLS.md) before connecting a sensitive project.

Next: [Getting started](../wiki/Getting-Started.md) or [create your first Pen](../how-to/CREATE-A-PEN.md).
