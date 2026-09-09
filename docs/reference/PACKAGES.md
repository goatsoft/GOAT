# GOATed package format

Kid accepts declarative `.goated` archives, not executable plugins. For installation, see [GOATed packages](../wiki/GOATed-Packages.md).

## Create a package

Start with the repository's `examples/vue-toolkit` folder or import the ready-made `examples/vue-toolkit.goated`. The example adds one Vue skill and one prompt, without connections.

```text
extension.json
prompts/vue.md
skills/vue/SKILL.md
skills/vue/references/checklist.md
```

The manifest requires all these fields, using empty arrays where appropriate:

```json
{
  "formatVersion": 1,
  "apiVersion": 1,
  "id": "example.vue-toolkit",
  "name": "Vue Toolkit",
  "version": "1.0.0",
  "author": "Your name",
  "description": "Vue and TypeScript guidance.",
  "permissions": ["skill-resources", "prompt-context"],
  "skills": ["vue"],
  "prompts": ["prompts/vue.md"],
  "mcp": []
}
```

Package IDs use lowercase letters, digits, hyphens and dot-separated segments. `goat.*` and `dev.leet.*` are reserved. Versions contain three numeric components. Unknown fields and unsupported format/API versions are rejected.

Each skill name corresponds to `skills/<name>/SKILL.md`. Use normal Agent Skills frontmatter (`name` matching the folder and a description). Other files under that skill are readable text resources. Prompt paths must be Markdown files under `prompts/`. They are added together to future turns. Resources, including source examples, are treated as text and never run.

Permissions must match the declared contributions exactly:

| Permission | Required when | Meaning |
|---|---|---|
| `skill-resources` | `skills` is nonempty | Load package instructions and bundled text resources. |
| `prompt-context` | `prompts` is nonempty | Add package instructions to turns in the chosen scope. |
| `mcp-setup` | `mcp` is nonempty | Offer a separately reviewed MCP configuration draft. |

An optional MCP suggestion is either `{"name":"example","command":"example-server","arguments":[]}` or `{"name":"example","url":"http://127.0.0.1:9000/mcp"}`. Do not include secrets, headers or environment variables in the package. The MCP editor applies its existing endpoint and transport validation before Test/Add. Executable entry points, declared host tools and lifecycle hooks are unsupported.

ZIP the **contents** of the folder, placing `extension.json` at the archive root. For example, from the repository root:

```sh
cd examples/vue-toolkit
zip -r ../vue-toolkit.goated extension.json prompts skills
```

Use regular, non-executable UTF-8 files. Paths may contain ASCII letters, digits, hyphens, underscores, dots and directory separators; hidden, absolute, traversal and duplicate paths are rejected. Remove Finder metadata before packaging. No files outside the declared skill folders, declared prompts and root manifest are accepted.

## Limits

Archives support ordinary stored or deflate ZIP compression, up to 8 MiB compressed and expanded, 1 MiB per file and 256 entries. Links, executable file modes, binary content, encryption, ZIP64 and multi-disk archives are rejected. A manifest is at most 64 KiB, with up to 16 skills, 16 prompt files totaling 16 KiB, and 8 MCP suggestions. GOAT permits 16 user packages with at most 32 MiB of archive bytes in total.

See the [extension API](../EXTENSIONS.md) for bundled Swift capabilities and [ADR-0062](../adrs/0062-declarative-goated-packages.md) for the package security and lifetime design. Third-party executable extension hosting remains separate work.
