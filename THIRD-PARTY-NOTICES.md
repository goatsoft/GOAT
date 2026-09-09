# Third-party notices

GOAT uses open-source libraries and redistributes the upstream notices required for its bundled components. These components retain their own licences. GOAT’s code, documentation and examples use [MIT](LICENSE); GOAT branding and artwork have [separate terms](LICENSE-ART.md).

## Mac application and CLI

The [complete application notices](apps/goat-macos/App/Resources/Licenses/THIRD-PARTY-NOTICES.txt) include the resolved Swift dependencies and embedded JavaScript. They are shipped in the application’s `Contents/Resources/Licenses/` directory and in the disk image’s `Licenses/` folder alongside GOAT’s own terms.

| Component | Use | Upstream terms |
| --- | --- | --- |
| GRDB.swift | SQLite persistence | MIT |
| MCP Swift SDK and EventSource | MCP transport and events | MIT |
| MarkdownUI and NetworkImage | Markdown presentation | MIT |
| HighlightSwift and bundled Highlight.js | Syntax highlighting | MIT / BSD-3-Clause |
| Swift Atomics, Collections, Log, NIO and System | Runtime support | Apache-2.0 with Swift exceptions where supplied |
| swift-cmark | Markdown parsing | Its bundled COPYING notices, including BSD and MIT terms |
| Mermaid and its dependency tree | Offline Paddock diagram rendering | MIT and the respective dependency licences |
| Hindsight integration mark | Identify the optional Hindsight service | MIT, Vectorize AI, Inc. |

Version and source-revision records are in the [distribution manifest](third-party/distribution-manifest.json). The notice collection includes nested licence files for Highlight.js and NIO’s llhttp code. Mermaid’s dependency list is deliberately inclusive; it also contains type packages and does not imply that every listed package executes in the application.

## Website and documentation

The [complete website notices](web/public/third-party-licenses.txt) cover the locked JavaScript, CSS, icon and documentation dependencies, including build tools. The same file is served as `third-party-licenses.txt` on both sites. It is an inclusive attribution inventory, not a list of external services contacted by visitors.

The sites use Vue, Vue Router, VitePress, Vite, Tailwind CSS, Reka UI and Motion for Vue, with their supporting dependencies. Mermaid renders documentation diagrams. Hugeicons supplies interface icons under MIT; Simple Icons supplies brand marks under CC0-1.0. Brand names and trademarks remain with their owners.

Full upstream texts, copyright statements and exceptions are preserved in the collected notices. See [Distribution](docs/DISTRIBUTION.md) for the refresh and verification procedure. A dependency upgrade requires a new review; the current notices are not a blanket clearance for future versions or assets.
