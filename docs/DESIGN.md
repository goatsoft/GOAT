# Caprine: the GOAT design language

*Caprine (adj.): of or relating to goats. Also: this design system.*

GOAT uses native Mac conventions with a restrained default appearance. Every default surface is honest macOS 26 material (real Liquid Glass, real vibrancy, real toolbars), with restrained palette, type rhythm, and motion. The 1337 experience can spend the personality budget after the user deliberately unlocks it.

## 1. Principles

1. **Material honesty.** Use system materials (`glassEffect`, `Material.bar`, vibrancy); never fake glass with alpha rectangles. When Liquid Glass morphing is available, use it (toolbar transitions, palette pop).
2. **Content is the interface.** Chrome recedes; the transcript is the app. No decorative borders, no gratuitous cards.
3. **Personality budget.** The default is deadpan professional. About may hint at personality; GOAT 1337 may use it in empty states, chat decoration, bylines, and easter eggs. Error and security paths never participate.
4. **Responsive interaction.** Smooth streaming is a design target that requires measurement. Motion respects Reduce Motion.

## 2. Themes and experiences: professional first

GOAT is a professional local AI workspace by default. The standard light and dark app icons set the tone: precise geometry, restrained contrast, macOS-native materials, and no mascot decoration in routine work. Windows use honest Liquid Glass, but content and system symbols lead. Theme = token set; all colours are semantic tokens, never hardcoded at call sites.

System is the first-run default. Light, Pasture, Midnight, and community GTF themes remain available in Appearance, plus a **Transparency slider** (0.5 = each theme's own default `bgOpacity`; the scale multiplies it). The GOAT 1337 option is absent until its About-scoped unlock succeeds. A theme supplies visual tokens; the trusted 1337 `ExperiencePack` may additionally select bundled icons, decorations, motion, and non-critical copy under ADR-0030.

### System
Follows macOS light/dark by adopting the restrained Light or Midnight token set. Materials are pure Tahoe, accents are quiet, and the professional light/dark icon family remains active.

### Light

| Token | Value |
|---|---|
| bg / surface | `#F5F6FA` cool paper / white 65% |
| ink / muted | `#1A1C26` / `#646B7E` |
| accent → accent2 | `#2E7CF6` → `#8B5CF6` (AA on paper) |
| glow / wash | `#8B5CF6` / 0.08 |

### Pasture (light, the deliberate exception)

No neon here: warm paper, moss, and saddle leather. An actual pasture.

| Token | Value |
|---|---|
| bg / surface | `#F6F3EC` warm paper / white 65% |
| ink / muted | `#2A2419` dark brown / `#80735C` |
| accent → accent2 | `#5E8C3A` moss → `#9C6B3C` saddle |
| glow / wash / selection | `#7FA650` / 0.10 / moss |

### Midnight (dark)

| Token | Value |
|---|---|
| bg / surface | `#0A0B14` deep navy / `#151726` 70% |
| ink / muted | `#E9ECF5` / `#8E95A8` |
| accent → accent2 | `#3AA0FF` → `#B44BFF` (the icon ring, verbatim) |
| glow / wash | `#7A5CFF` / 0.14 |

### 1337 (unlockable)

Open About GOAT, press Option-Command-G, then type `1337` within ten seconds. A single local confirmation unlocks the hidden GOAT 1337 experience. Once unlocked it stays in Appearance and can be turned off like any other selection. The exact chord may move if macOS reserves it; the About-only sequence is the invariant.

Goaties appear only while the 1337 theme is selected. Switching to any other theme disables its decorations without losing the unlock. Assistant goaties wave after a completed reply, think while busy, and show the warning pose on failure; error text stays direct. Standard themes use the bundled light or dark horn masthead, rendered in its original colours with transparent margins reduced. Its visible artwork matches the height of the two-line thinking status. The 1337 mascot remains 60 points with its thinking bubble and existing layout.

Chat mastheads use two shared 128-pixel thumbnails prepared with Core Graphics. Directly shrinking the 1254-pixel source aliases in the live macOS window renderer, including with high-quality interpolation, although off-screen previews appear smooth. Keep the full-resolution source for larger artwork and verify compact image changes in an actual window.

While a reply is running, elapsed time sits directly below the thinking label with the same leading edge. The thinking label has no brain icon. Both lines stay in the disclosure header when reasoning is expanded, including the transition from seconds to minutes or hours. Standard themes align the horn masthead with this two-line status. The 1337 theme retains its 60-point goatie and speech bubble with animated waves, with the status inset vertically to align beside the mascot.

| Token | Value |
|---|---|
| bg / surface | `#05060D` near-black navy / `#0B0D1A` 75% |
| ink / muted | `#D9E4FF` ice / `#5F6C9E` |
| accent → accent2 | `#35B4FF` → `#C44BFF` neon, glow `#8F4BFF` |
| wash | 0.20 (the most saturated backdrop) |
| type | SF Mono, everywhere, including the sidebar |

Keep decorative effects restrained. The pack activates alternate app icons, chat glyphs and emoji, bounded mascot animations, optional sound, bylines, empty-state copy, and playful labels such as **Knots** and **Let loose**. It never changes persisted text, engine requests, permissions, errors, destructive confirmations, layout, or feature availability.

### Action hierarchy

Primary actions (create, save, send) and selected controls use the theme accent. Routine secondary actions such as Edit, Open Folder, Refresh, Change, and Add Files use `SecondaryChipButtonStyle`: neutral ink, a faint rounded surface and border, and theme colour on hover, press or keyboard focus. Disabled actions are muted and cannot highlight. Destructive actions use semantic red on interaction. Increased Contrast strengthens the resting border, and transitions respect Reduce Motion and the app animation setting.

Use this shared style for standalone utility buttons and links that act as navigation buttons, including Open in Hindsight. Keep actual links inside documents and chat text as links. Apply the style at the action, not to a whole page: toggles, selected tabs, primary actions, menus and clickable content rows have their own hierarchy. Pens, Pen details, memory navigation and existing secondary actions in Settings share this treatment. Compact actions have a minimum 28-point hit area; icon-only actions must have an accessible name or help text.

### Connection settings

JUDAS uses native grouped settings and descriptive radio choices, Caprine semantic colours, and shared secondary buttons. Its service-access summary shows local and internet access separately. Paddock’s Off-grid control lives beside its effective policy and keeps the saved preference when a stricter connection mode overrides it. macOS permission guidance is separate from GOAT policy and never invents a permission status. Security copy remains direct and unchanged by the 1337 experience.

### Feature names

Use **GOAT** for the app, **GOATed** for the extension system, and **JUDAS** for connection policy. Use **Herd**, **Pen / Pens**, **Paddock**, **Hitch**, **Pronk**, and **Hindsight** in ordinary interface text. **GOAT 1337** names the unlockable experience; **Stats** names the inference charts. Reserve **HERD** for branding lines such as “Nothing leaves the HERD” and “JUDAS is watching the HERD.” Internal identifiers, stored paths and API names do not follow display capitalization.

## 3. Type & font size

- UI: SF Pro (system text styles, dynamic where possible). Chat body default **14pt**, line height 1.45.
- Code: system monospace at 13pt by default, independently configurable, in a recessed block with header row (language chip + copy button).
- **Fonts:** compact searchable local font popover, compact live preview, point-size entry and stepper in Appearance. Chat/composer uses 11–28pt (default 14); code uses 10–24pt (default 13) and fixed-pitch fonts only. Explicit choices override themes; Theme default follows optional GTF v1 fonts. Missing fonts fall back to the system font with a manual installation hint. Interface controls keep native typography. See ADR-0053.
- Ramp (at 14 base): chat body 14 · thinking 13 muted italic · timestamp/meta 11 · sidebar row 13 · title 15 semibold.

## 4. Layout & spacing

- 4pt grid. Radii: bubbles 14, cards 10, palette 16, thumbnails 8.
- Transcript max measure 68ch, centered in wide windows; user bubbles ≤ 75% width, right-aligned; assistant messages full-measure with a 44-point light/dark masthead. GOAT 1337 substitutes its 60-point goat set.
- Transcript rows have stable message-ID targets and intrinsic vertical sizing within a fully measured 40-message window. Earlier/Later controls overlap by 20 messages; Latest returns to the live end. All history remains available. Font and width changes preserve reading position through native scroll anchoring; scrolling up suspends stream following. Row insertion and lazy reappearance never fade or offset the content. See ADR-0058.
- Consecutive assistant tool rounds share a collapsed activity group, identified by its first message. The full header expands the list; individual actions expose arguments/results. Current actions, failed/denied counts and host errors remain visible. Lead messages and final replies stay separate. Grouping follows the existing window boundaries (ADR-0074).
- Sidebar 240pt default (200–320 resizable). Inspector 280pt, toggled, glass sheet edge.
- Density: sidebar rows 30pt ("comfortable") / 24pt ("tight"), Appearance setting.
- Left navigation remains Pens and chats in every workspace. Pen icon and OKLCH colour identify the Pen; nested chat groups inherit the accent subtly without using colour as the only grouping cue.
- The centre exposes Chat, Image, and Video. There is no global Edit mode. Editing is an Image or Video operation seeded from an existing result.
- Tether occupies the right inspector only for Image and Video. Chat never displays or constructs it. The Activity log remains independently collapsible at the bottom (ADR-0029).

## 5. Components

- **Message, assistant:** plain on bg with the light/dark horn masthead; GOAT 1337 replaces it with the current goatie pose. Hover reveals actions (copy, regenerate, remember-this) in a floating mini-bar. Streaming caret: 2pt accent bar with a soft 1.2s pulse.
- **Message, user:** tinted glass bubble, hover: copy + edit.
- **Thinking:** collapsed disclosure `Thought for 12s ▸`, muted italic when open, streams live if expanded. While running, duration sits below the thinking label without a brain icon.
- **Tool call card:** 10pt-radius card, status dot (pending amber → ok green → error red), `server · tool`, args in collapsed mono, result expandable. Denied = struck through, muted.
- **Composer:** glass field, grows 1→10 lines. Left: attach (+) with image chips row above; right: send button (accent, disabled-dim when empty), swaps to stop-square while streaming.
- **Model + effort capsule (composer, bottom-right):** `● Qwen3-30B-A3B Trot`, engine dot (green healthy / amber auth / gray offline), model name medium-weight, effort label secondary. Click → menu: the server's models (tick on active), Effort submenu with named levels and monochrome symbols, then "Manage Models in oMLX…" / refresh. GOAT 1337 may substitute its emoji set. The Claude Desktop convention; ⌘1–4 still set effort from the keyboard.
- **Command palette (⌘K):** centered glass panel, 8pt-blur pop (spring, 0.98→1.0 scale), fuzzy match over chats/projects/models/actions, ↑↓⏎, section headers.
- **Tether (Image and Video only):** contextual right-inspector controls built from the selected model's capability contract. Source roles, mask, dimensions, duration, guidance, seed, motion, and advanced controls live here. Prompt text stays in the centre composer. Missing required inputs disable Generate with an exact explanation.
- **Context meter (inspector):** thin bar `▓▓▓░░ 41% of 32k`. It appears at 60% pressure, turns amber above 75%, and red above 90%, with a trim notice. Estimated usage and a fallback window are marked independently.
- **Loading and empty states:** startup shows explicit local-restore and service-connection progress. Initial empty arrays are never presented as real emptiness. After restoration, the professional catalog says *“No conversations yet. Create a chat to begin.”* Engine offline says *“No local engine connected. Open oMLX →”* (button launches it). GOAT 1337 may substitute pasture and goat copy. Persistence failure is blocking and offers Retry rather than an unsaved chat.
- **Async media states:** attachment and theme thumbnails decode away from the UI executor. Their fixed-size placeholder occupies the final layout immediately, then resolves to the image or a quiet failure glyph without shifting the transcript.

## 6. Motion

- Springs: `response 0.28, damping 0.86` (standard) · palette pop `0.22, 0.8`.
- **Standard liveness:** a restrained semantic progress treatment with no decorative loop. The send button uses the current theme's primary token and dims when disabled.
- **1337 liveness:** the Neon Ring and alternate mascot motion may replace standard liveness. Reduce Motion uses static 1337 art. At most one prominent mascot loop runs per window, and hidden or inactive views pause.
- Transcript insertion and regrouping have no rise, fade or offset animation. Token streaming has **no per-token animation**; text appends raw and the active experience owns one bounded liveness indicator.
- Sidebar move-to-project: drag uses system lift; drop flashes the project row accent once.
- Liquid Glass morph on toolbar state changes where the OS provides it. Reduce Motion: springs → 120ms fades.

## 7. App icons

The canonical Finder icon and first-run Dock icon use the professional light/dark family. They are crisp at small sizes, carry no joke text, and remain correct if runtime icon switching is unavailable. GOAT 1337 unlocks the bundled expressive icon family for the Dock, About, and in-app identity where macOS permits it. Returning to System restores the professional family.

The 1337 family may use the geometric goat head: a charcoal-to-black squircle with seven angular acid-green strokes, long horns, and nodes at the vertices.

```
      ↑  ↑
     /| ∧ |\        seven strokes:
    / |/ \| \       2 horns · 2 ears
      | ○ |         2 jaw lines · 1 muzzle
       \_/          nodes at vertices
```

## 8. Sound

One optional sound: a soft marimba blip on generation complete when the window is unfocused. Off by default. There is no goat bleat. (There is one goat bleat. It plays if you click the About-box goat five times.)

## 9. Voice & copy

The default catalog is deadpan, dry, and terse. Errors are honest and actionable: *“Model ran out of memory. Close something, or try the 4-bit build.”* Errors, permission requests, and destructive confirmations are never themed. GOAT 1337 may decorate chat roles, bylines, empty states, completion copy, and non-critical labels at render time. Those decorations never enter stored messages or exports.

## 10. Accessibility

AA contrast in every shipped theme and experience. Full VoiceOver labels on message roles, tool cards, stats, Tether fields, and media results. Decorative goats are ignored by accessibility APIs. All actions are keyboard-reachable. Focus rings are never suppressed. Reduce Transparency swaps glass for opaque surfaces via the token layer; Reduce Motion removes non-essential 1337 animation.
