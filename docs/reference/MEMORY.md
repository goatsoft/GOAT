# Memory providers and browser reference

Global memory belongs to chats outside a Pen. Each enabled Pen has its own memory store or
Hindsight bank. Settings → Memory shows up to **20 recent global records**. It does not browse
Pen memory.

## Pen context and local providers

Select a Pen and use the tabs below the chat composer:

- **Workspace:** project folder and Git status, Instructions, Additional Files, then Skills.
  Instructions are included in that Pen's chats. Additional files remain references and are not
  automatically added to chat context.
- The Pen brief and agent guide are app-managed metadata, supplied together in chat context.
  Their stored names, `README.md` and `AGENTS.md`, do not mean those files exist in the workspace.
  Herder can work with an empty bound workspace. File actions follow the Pen’s approval policy;
  builds and other commands require a separate command permission. Binding the workspace alone
  grants neither file writes nor command execution.
- **Memory:** the Pen's memory switch, provider, and up to **20 recent records**. Record previews
  show more text; select one to read its full contents. Recent records have their own bounded
  scroll area, showing roughly four typical previews at once.

Markdown and LLM Wiki memories remain on your Mac. Open Memory Folder opens the Pen's files.
LLM Wiki also provides Map and Connections views of its linked pages and sources.

## Hindsight

The Memory tab identifies the Pen's bank and offers **Records** and **Map**. Hindsight records are
extracted memories from conversations and other retained material, not necessarily complete chat
transcripts. Recent records follow the server's newest-updated ordering.

The map uses Hindsight's own memory relationships. **Click inside the map to activate it**.
Until then, scrolling moves the page normally. An active indicator appears; moving the pointer
outside the map releases it immediately. While active, drag to pan, scroll or pinch to zoom, and
right-drag to rotate. The toolbar provides zoom, fit, display options, and an expanded map. Records and Map accept
clicks across the entire segment, including the space beside the label.
Search finds nodes in the loaded map; press Return for the first match or choose one from the
results menu. Click a node to pin its connections, then choose **Open** to read it. The display menu
can isolate its neighborhood or hide labels. With the map focused, **+ / -** zoom and **0** fits
the map. Labels avoid overlapping, and wiki maps use arrowheads to show focused link direction. GOAT shows at most 60 memories plus 20 knowledge pages and 480 connections, with a partial-map indicator
when more data exists. These connections are not presented as wiki source citations. The server
controls which memories are included in its graph preview.

Choose **Open in Hindsight** for the full bank history, graph, and management tools. The link opens
your configured server's hostname on **port 9999**, through JUDAS. It contains no API token; the
Hindsight UI handles its own login. The API and UI are separate ports. If you use an SSH tunnel,
forward 9999 as well as your API port. A custom UI port or reverse-proxy address must currently be
opened manually in your browser.

## Keeping scopes separate

Choose a dedicated bank such as `goat-global` for Global memory. Enabling a Pen provisions or
reuses its own bank. GOAT rejects selecting a known Pen bank as Global memory, including when
editing an existing connection.

Changing a bank selects a destination for future reads and writes. It does not move or delete
existing memories. If an older configuration shared a bank, its existing records remain there;
GOAT does not guess which ones should move. Select a separate Global bank to restore isolation.

## 3D map and legend

The map has a spatial layout. After clicking to activate it, **right-drag horizontally or vertically
to orbit in 3D**. Left-drag pans; scroll/pinch and **− / +** zoom. Zoom ranges from **20% to 2000%**,
with gradual wheel input anchored under the pointer. Fit resets the camera. Nearer nodes
appear larger and in front of distant nodes. Depth helps exploration; it does not mean a memory is
more important, more certain, or more recent.

The compact legend shows shapes, colours and counts for the loaded preview. Hover any node type
or the **Links / Citations** line samples for an immediate explanation above the legend. Click an
entry, or activate it with the keyboard, to show the same explanation. VoiceOver exposes the
same explanations. The node types are:

- **World:** facts about the user, other people, preferences, constraints, and external events.
- **Experience:** actions performed or lessons learned by the assistant. A human's experience or
  preference can still be a world fact in Hindsight's terminology.
- **Observation:** consolidated insights derived by Hindsight from retained facts.
- **Opinion:** opinion records, when supplied by the server.
- **Knowledge:** Hindsight mental models, shown as hexagons. These curated pages are separate from
  observations. Select one and choose Open to read it.

The map loads up to 60 memories plus 20 knowledge pages. Knowledge citations connect to their
actual supporting records when those records are in the preview. Dotted lines are citations;
ordinary lines are memory relationships. A partial-map notice means there are more records or
links elsewhere. If knowledge cannot load, a notice appears while the memory map remains usable.

A zero in the legend means none of that type is in this preview. It does not indicate a disabled
feature. Hindsight classifies records when they are retained; GOAT preserves those classifications.
Future GOAT transcript submissions explicitly identify the User and Assistant sections to help
Hindsight distinguish user facts from assistant actions. Existing records are not automatically
rewritten or re-ingested.

Selected records appear in a floating bordered card over the bottom of the canvas, separate from
the legend. Selecting or clearing a node does not resize the canvas or move its nodes. Use **Open**
to read the selected record. While the map is active, hover or select a node to animate only its
connections. With neither hovered nor selected, the map stays still. Hover temporarily previews another node, then returns
to the pinned selection. These illustrate recorded relationships, not live data transfer.
Turn them off with **Animate connections** in the display menu. They also stop when you leave the
map, switch away from GOAT, enable Reduce Motion, or disable interface animations.

### Connector colours and direction

Dots keep the theme colour of the node they travel **from**. Hovered or selected connections stand
out; other connections are softly tinted while the map is active.

- **Semantic, shared entity, and temporal links:** dots travel both ways, and the connector blends
  the endpoint colours. These mean similar meaning, a shared entity, or proximity in time. A
  temporal link does not imply which event happened first.
- **Causal links:** dots travel from cause to effect. Hindsight's `caused_by` records are stored
  effect-first, so GOAT reverses their display motion. Older causes/enables/prevents links follow
  the recorded source to target.
- **Citations and wiki links:** dots travel from the citing page to its evidence or linked page,
  using the citing node's colour. This is a reference direction, not a claim that the page created
  its evidence.
- **Unknown link types:** remain muted and static rather than guessing a direction.

GOAT preserves distinct relationship types and merges duplicate reciprocal associations. It shows
at most 24 moving dots, keeping two-way pairs together; several relationship types may share a
curve. For the complete graph, use **Open in Hindsight**. See Hindsight's
[connection definitions](https://hindsight.vectorize.io/developer/retain#building-connections).
