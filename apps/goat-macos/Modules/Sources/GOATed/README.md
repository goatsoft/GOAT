# GOATed

Scoped extension capabilities, registration lifetimes, skills and declarative .goated packages.

Public seams: `ExtensionRuntime`, `Extension`, `ExtensionPackage`, `ToolHandle`, `SkillProvider`.

Dependencies: Tools.

Bundled native code remains trusted; handles are scoped, revocable and bounded. User archives are validated in memory without extraction or execution.

Validation: GOATedTests (including package admission and scope), AppToolRouterTests and UserExtensionTests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
