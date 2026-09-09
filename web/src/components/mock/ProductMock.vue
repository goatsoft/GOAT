<script setup lang="ts">
import { DialogRoot, DialogTrigger, DialogPortal, DialogOverlay, DialogContent, DialogTitle, DialogDescription, DialogClose } from 'reka-ui'
type ProductScene = 'hero' | 'coding' | 'pens' | 'memory' | 'previews' | 'extensions' | 'connections'
defineProps<{ scene: ProductScene }>()
const source = ref(false)
const editingPen = ref(false)
const penName = ref('Goat Trails')
const penTone = ref({ l: .74, c: .15, h: 295 })
const draftName = ref(penName.value)
const draftTone = ref({ ...penTone.value })
const colourCSS = (tone: { l: number; c: number; h: number }) => `oklch(${tone.l} ${tone.c} ${tone.h})`
const penColour = computed(() => colourCSS(penTone.value))
const draftColour = computed(() => colourCSS(draftTone.value))
const penColours = [
  { name: 'Violet', l: .74, c: .15, h: 295 }, { name: 'Ocean', l: .74, c: .13, h: 235 },
  { name: 'Meadow', l: .74, c: .12, h: 180 }, { name: 'Golden hour', l: .8, c: .12, h: 85 },
]
function preparePenDialog(open: boolean) {
  if (!open) return
  draftName.value = penName.value
  draftTone.value = { ...penTone.value }
}
function savePen() {
  if (!draftName.value.trim()) return
  penName.value = draftName.value.trim()
  penTone.value = { ...draftTone.value }
  editingPen.value = false
}
const memoryPage = ref('Writing style')
const titles: Record<ProductScene, string> = {
  hero: 'A trail worth taking · Goat Trails', coding: 'Build the trail guide · Goat Trails',
  pens: 'Goat Trails', memory: 'Goat Trails · Memory', previews: 'Paddock · Goat Trails',
  extensions: 'GOATed · Extensions', connections: 'JUDAS',
}
const pages = ['Writing style', 'Project decisions', 'Release checklist']
const memoryText: Record<string, string> = {
  'Writing style': 'Use concise Australian English. Explain the user benefit before implementation details. Keep instructions direct and specific.',
  'Project decisions': 'Build a trail guide for curious walkers. Use a midnight palette, clear route summaries and original mountain illustrations.',
  'Release checklist': 'Check each trail description, verify route links and inspect the site build before publishing Goat Trails.',
}
</script>

<template>
  <figure class="product-illustration" :data-scene="scene" :aria-label="`${titles[scene]}. Illustrative GOAT interface using fictional project content.`">
    <AppWindow :title="titles[scene]" :sidebar="scene === 'hero'">
      <div v-if="scene === 'hero'" class="mock-body hero-body">
        <div class="hero-chat">
          <p class="user-message">Give Goat Trails a stronger introduction and a preview.</p>
          <div class="assistant-mark"><img :src="asset('img/goat-dark.webp')" alt="" /> GOAT</div>
          <p class="reply">A little less desk. A little more mountain. Here’s a new direction for the trail guide.</p>
          <details class="tool-group"><summary><span><i-hugeicons-check-list aria-hidden="true" /> Used tools · 2 actions</span><i-hugeicons-chevron-right aria-hidden="true" /></summary><div class="tool-lines"><p><i-hugeicons-file-02 aria-hidden="true" /> Read docs/trail-guide.md <i-hugeicons-tick-02 class="tool-done" aria-hidden="true" /></p><p><i-hugeicons-code aria-hidden="true" /> Create goat-trails.html <i-hugeicons-tick-02 class="tool-done" aria-hidden="true" /></p></div></details>
          <div class="hero-artifact"><div class="artifact-label"><i-hugeicons-file-code aria-hidden="true" /> HTML <span class="artifact-actions" aria-hidden="true"><i-hugeicons-copy-01 /><i-hugeicons-download-01 /><i-hugeicons-sidebar-right /></span></div><div class="segments" aria-label="Illustrated chat artifact display"><button type="button" :class="{ selected: !source }" :aria-pressed="!source" @click="source = false">Preview</button><button type="button" :class="{ selected: source }" :aria-pressed="source" @click="source = true">Source</button></div><pre v-if="source" class="hero-source"><code>&lt;main class="goat-trails"&gt;
  &lt;h1&gt;Take the goat path.&lt;/h1&gt;
  &lt;p&gt;Quiet trails. Big views.&lt;/p&gt;
&lt;/main&gt;</code></pre><GoatTrailPreview v-else compact /></div>
          <div class="composer"><p>Baa…</p><div class="composer-actions"><span><i-hugeicons-add-01 aria-hidden="true" /> <span class="permission-chip"><i-hugeicons-shield-01 aria-hidden="true" /> Ask for approval</span></span><span class="send-icon" aria-hidden="true"><i-hugeicons-arrow-up-02 /></span></div></div>
          <details class="mobile-nerd-stats"><summary><i-hugeicons-activity-03 aria-hidden="true" /><span>Nerd Stats</span><span>68.4 tok/s</span><i-hugeicons-chevron-down aria-hidden="true" /></summary><MockNerdStats /></details>
          <div class="model-line"><span class="composer-stat">68.4 tok/s</span> Qwen3 · 8B <span>Trot <i-hugeicons-chevron-down aria-hidden="true" /></span></div>
        </div>
        <aside class="hero-inspector" aria-label="Illustrated Nerd Stats inspector"><MockNerdStats /><div class="inspector-engine"><i-hugeicons-cpu aria-hidden="true" /><div><strong>Local engine</strong><span>Qwen3 · 8B · 4-bit</span></div><span class="status-dot" /></div></aside>
      </div>

      <div v-else-if="scene === 'coding'" class="mock-body">
        <p class="user-message">Build the Goat Trails landing page and check it runs.</p>
        <div class="assistant-mark"><img :src="asset('img/goat-dark.webp')" alt="" /> GOAT</div>
        <p class="reply">I’ll update the trail guide, keep the mountain artwork and check the build.</p>
        <details class="tool-group" open><summary><span><i-hugeicons-check-list aria-hidden="true" /> Using tools · 3 actions</span><i-hugeicons-chevron-right aria-hidden="true" /></summary><div class="tool-lines"><p><i-hugeicons-file-02 aria-hidden="true" /> Read docs/trail-guide.md <i-hugeicons-tick-02 class="tool-done" aria-hidden="true" /></p><p><i-hugeicons-file-edit aria-hidden="true" /> Edit src/TrailGuide.vue <i-hugeicons-tick-02 class="tool-done" aria-hidden="true" /></p><p class="current-action"><i-hugeicons-command-line aria-hidden="true" /> Run command <code>npm run build</code><span class="status-dot" /></p></div></details>
        <p class="queued-note"><i-hugeicons-arrow-turn-forward aria-hidden="true" /> Lead queued · Keep the goat. Make the headline bolder.</p>
        <div class="composer"><p>Guide the next step…</p><div class="composer-actions"><span><i-hugeicons-add-01 aria-hidden="true" /> <span class="permission-chip"><i-hugeicons-shield-01 aria-hidden="true" /> Allow for this chat</span></span><span class="mock-action">Lead <i-hugeicons-arrow-up-02 aria-hidden="true" /></span></div></div>
        <div class="model-line"><span class="composer-stat"><i-hugeicons-activity-03 aria-hidden="true" /> Tool work</span> Local coder model <span>Trot <i-hugeicons-chevron-down aria-hidden="true" /></span></div>
      </div>

      <div v-else-if="scene === 'pens'" class="mock-body settings-body pen-body" :style="{ '--pen-colour': penColour }">
        <div class="pen-heading"><span class="pen-icon" aria-hidden="true">🐐</span><div><h3>{{ penName }}</h3><p>A field guide for curious walkers</p></div>
          <DialogRoot v-model:open="editingPen" @update:open="preparePenDialog">
            <DialogTrigger as-child><button type="button" class="mock-action edit-pen"><i-hugeicons-edit-02 aria-hidden="true" /> Edit Pen</button></DialogTrigger>
            <DialogPortal disabled>
              <DialogOverlay class="pen-dialog-overlay" />
              <DialogContent class="pen-dialog" :style="{ '--draft-colour': draftColour }">
                <DialogTitle class="pen-dialog-title">Edit Pen</DialogTitle>
                <DialogDescription class="sr-only">Edit the illustrated Pen. Changes apply when you choose Save.</DialogDescription>
                <form @submit.prevent="savePen">
                  <div class="pen-name-field"><span class="dialog-emoji" aria-label="Goat emoji">🐐</span><input v-model="draftName" aria-label="Pen name" autocomplete="off" /></div>
                  <div class="pen-colour-picker"><span>Colour</span><div class="pen-palette"><span class="current-swatch" :style="{ background: draftColour }" /><button v-for="colour in penColours" :key="colour.name" type="button" :aria-label="`${colour.name} Pen colour`" :aria-pressed="draftTone.l === colour.l && draftTone.c === colour.c && draftTone.h === colour.h" :style="{ background: colourCSS(colour) }" @click="draftTone = { l: colour.l, c: colour.c, h: colour.h }"><i-hugeicons-tick-02 v-if="draftTone.l === colour.l && draftTone.c === colour.c && draftTone.h === colour.h" aria-hidden="true" /></button></div></div>
                  <label class="colour-slider">Lightness<input v-model.number="draftTone.l" type="range" min="0.35" max="0.92" step="0.01" /></label>
                  <label class="colour-slider">Chroma<input v-model.number="draftTone.c" type="range" min="0" max="0.30" step="0.01" /></label>
                  <label class="colour-slider">Hue<input v-model.number="draftTone.h" type="range" min="0" max="360" step="1" /></label>
                  <div class="colour-preview"><i-hugeicons-chevron-right aria-hidden="true" /> 🐐 {{ draftName.trim() || 'Pen name' }}</div>
                  <div class="pen-dialog-actions"><DialogClose as-child><button type="button" class="mock-action">Cancel</button></DialogClose><button type="submit" class="mock-action save-pen" :disabled="!draftName.trim()">Save</button></div>
                </form>
              </DialogContent>
            </DialogPortal>
          </DialogRoot>
        </div>
        <div class="composer compact"><p>Start a chat in {{ penName }}…</p><div class="composer-actions"><span><i-hugeicons-add-01 aria-hidden="true" /> <span class="permission-chip"><i-hugeicons-shield-01 aria-hidden="true" /> Ask for approval</span></span><span class="send-icon" aria-hidden="true"><i-hugeicons-arrow-up-02 /></span></div></div>
        <div class="segments"><span class="selected">Workspace</span><span>Memory</span></div>
        <div class="settings-card"><div class="setting-row"><strong><i-hugeicons-folder-management aria-hidden="true" /> Project folder</strong><span class="muted icon-label">Open <i-hugeicons-arrow-up-right-01 aria-hidden="true" /></span></div><p class="muted">~/Projects/goat-trails</p><div class="setting-row"><span class="icon-label"><i-hugeicons-git-branch aria-hidden="true" /> Git</span><span class="muted">main · Clean</span></div></div>
        <div class="settings-card"><div class="setting-row"><strong><i-hugeicons-file-text aria-hidden="true" /> Instructions</strong><span class="muted">Edit</span></div><p>Use Australian English. Keep route descriptions practical and the mountain illustrations original.</p></div>
        <div class="setting-row small-row"><strong><i-hugeicons-file-security aria-hidden="true" /> File permissions</strong><span class="permission-chip">Ask for approval</span></div>
        <div class="setting-row small-row"><strong><i-hugeicons-command-line aria-hidden="true" /> Command permissions</strong><span class="muted">Add tool…</span></div>
      </div>

      <div v-else-if="scene === 'memory'" class="mock-body settings-body">
        <div class="pen-heading"><span class="pen-icon" aria-hidden="true">🐐</span><div><h3>Goat Trails</h3><p>Memory</p></div></div>
        <div class="segments"><span>Workspace</span><span class="selected">Memory</span></div>
        <div class="setting-row"><strong><i-hugeicons-brain aria-hidden="true" /> Memory</strong><span class="muted">LLM Wiki <span class="toggle on" aria-label="Enabled" /></span></div>
        <div class="segments compact-tabs"><span class="selected">Pages</span><span>Map</span><span>Connections</span></div>
        <div class="memory-reader"><nav aria-label="Illustrated memory pages"><button v-for="page in pages" :key="page" type="button" :class="{ 'active-page': memoryPage === page }" :aria-pressed="memoryPage === page" @click="memoryPage = page"><i-hugeicons-file-text aria-hidden="true" /> {{ page }}</button></nav><article><small>PEN MEMORY</small><h3>{{ memoryPage }}</h3><p>{{ memoryText[memoryPage] }}</p><p class="memory-reference">Goat Trails · Local page</p></article></div>
        <p class="pane-note">Project knowledge you can open and inspect.</p>
      </div>

      <div v-else-if="scene === 'previews'" class="mock-body preview-body">
        <div class="pane-label"><span class="artifact-title"><i-hugeicons-file-code aria-hidden="true" /> HTML</span><span class="artifact-actions muted" aria-hidden="true"><i-hugeicons-copy-01 /><i-hugeicons-arrow-reload-horizontal /><i-hugeicons-download-01 /></span></div>
        <div class="segments" aria-label="Illustrated document view"><button type="button" :class="{ selected: !source }" :aria-pressed="!source" @click="source = false"><i-hugeicons-view aria-hidden="true" /> Preview</button><button type="button" :class="{ selected: source }" :aria-pressed="source" @click="source = true"><i-hugeicons-code aria-hidden="true" /> Source</button></div>
        <pre v-if="source" class="source-document"><code>&lt;main class="goat-trails"&gt;
  &lt;p&gt;GOAT TRAILS&lt;/p&gt;
  &lt;h1&gt;Take the goat path.&lt;/h1&gt;
  &lt;p&gt;Quiet trails. Big views.
     A field guide for the curious.&lt;/p&gt;
  &lt;a href="/trails"&gt;
    Find your next climb
  &lt;/a&gt;
&lt;/main&gt;</code></pre>
        <GoatTrailPreview v-else />
      </div>

      <div v-else-if="scene === 'extensions'" class="mock-body settings-body">
        <h3 class="settings-heading"><i-hugeicons-folder-management aria-hidden="true" /> Extensions</h3>
        <div class="segments"><span class="selected">Built-in</span><span>User</span></div>
        <div class="settings-card"><div class="setting-row"><strong><i-hugeicons-chevron-right aria-hidden="true" /><i-hugeicons-book-open-01 aria-hidden="true" /> Skills</strong><small class="muted">Required core</small></div></div>
        <div class="settings-card"><div class="setting-row"><strong><i-hugeicons-chevron-down aria-hidden="true" /><i-hugeicons-command-line aria-hidden="true" /> Herder</strong><span class="muted">On <span class="toggle on" aria-label="Enabled" /></span></div><p class="muted">Native file and command tools for a Pen’s workspace.</p><div class="setting-row"><span>File creation and edits</span><span class="toggle on" aria-label="Enabled" /></div><div class="setting-row"><span>Shell commands</span><span class="toggle on" aria-label="Enabled" /></div><div class="setting-row"><span>Default command timeout</span><span class="field-value">120 seconds</span></div><p class="footnote">File and command permissions are managed on each Pen.</p></div>
        <div class="settings-card"><div class="setting-row"><strong><i-hugeicons-chevron-right aria-hidden="true" /><i-hugeicons-brain aria-hidden="true" /> Hindsight Memory</strong><span class="muted">On</span></div></div>
        <div class="settings-card"><div class="setting-row"><strong><i-hugeicons-chevron-right aria-hidden="true" /><i-hugeicons-link-01 aria-hidden="true" /> Hitch</strong><span class="muted">Off</span></div></div>
      </div>

      <div v-else class="mock-body settings-body">
        <h3 class="settings-heading"><i-hugeicons-shield-01 aria-hidden="true" /> Connection policy</h3>
        <div class="settings-card policy-options"><div><span class="radio" /><p><strong>Configured connections</strong><small>Use the services you choose.</small></p></div><div><span class="radio checked" /><p><strong>Local networks only</strong><small>This Mac, private LAN and Thunderbolt services.</small></p></div><div><span class="radio" /><p><strong>Block connections</strong><small>Stop managed connections, including local services.</small></p></div></div>
        <h4 class="section-label">Service access</h4>
        <div class="settings-card"><div class="setting-row"><span class="icon-label"><i-hugeicons-wifi-01 aria-hidden="true" /> This Mac, LAN &amp; Thunderbolt</span><span class="allowed">Allowed</span></div><div class="setting-row"><span class="icon-label"><i-hugeicons-globe-02 aria-hidden="true" /> Internet services</span><span class="muted">Blocked</span></div><div class="setting-row"><span class="icon-label"><i-hugeicons-command-line aria-hidden="true" /> MCP processes</span><span class="muted">Blocked</span></div></div>
        <div class="settings-card"><div class="setting-row"><strong><i-hugeicons-globe-off aria-hidden="true" /> Off-grid previews</strong><span class="toggle" aria-label="Overridden by policy" /></div><p class="footnote">The connection policy overrides this control.</p></div>
        <p class="pane-note">Changes disconnect active integrations. Reconnect when ready.</p>
      </div>
    </AppWindow>
    <figcaption>Illustrative interface · {{ scene === 'hero' ? 'Sample stats and fictional project' : 'Fictional project content' }}</figcaption>
  </figure>
</template>

<style scoped>
.product-illustration { margin:0; container-type:inline-size; color:#ececf2; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
.product-illustration figcaption { margin-top:12px; text-align:center; font-size:11px; letter-spacing:.015em; color:var(--goat-muted)}
.mock-body { display:flex; flex-direction:column; gap:16px; padding:24px; min-height:470px; font-size:13px; line-height:1.5; background:radial-gradient(ellipse at 0 0,#1457812b,transparent 65%),linear-gradient(140deg,#101726d9,#20132ecc)}
.mock-body h3,.mock-body p,.mock-body h4 { margin:0}
.mock-body h3 { font-weight:600}
.user-message { align-self:flex-end; max-width:90%; border-radius:14px; border:1px solid #8f91db32; background:linear-gradient(120deg,#2d82bd22,#a04fbe24); padding:12px 15px; font-weight:500}
.assistant-mark { display:flex; align-items:center; gap:8px; font-size:11px; font-weight:600; color:#aaaabc}
.assistant-mark img { width:25px; height:25px; object-fit:contain}
.reply { line-height:1.7}
.tool-group { font-size:11px; color:#b8b7cb}
.tool-group summary { padding:9px 0; cursor:pointer; list-style:none; display:flex; justify-content:space-between}
.tool-group summary>span { display:flex; align-items:center; gap:7px }.tool-group[open] summary>svg { transform:rotate(90deg) }.tool-group summary::-webkit-details-marker { display:none }
.tool-lines { padding:2px 0 9px 21px; display:grid; gap:10px}
.tool-lines code { font-size:10px; color:#9e9db3}
.current-action { display:flex; align-items:center; gap:7px}
.status-dot { width:6px; height:6px; background:#a493d7; border-radius:50%; display:inline-block}
.composer { margin-top:auto; border:1px solid #768dca77; border-radius:18px; padding:15px 16px 11px; background:linear-gradient(120deg,#bdcaff0d,#dcc8ff0d); box-shadow:inset 0 1px 0 #ffffff0d,0 0 20px #5a9fff0a; color:#d6d5df}
.composer p { font-size:13px; color:#aaa8b7}
.composer-actions { display:flex; align-items:center; justify-content:space-between; margin-top:17px}
.composer-actions>span:first-child { display:flex; gap:10px; align-items:center}
.permission-chip { border-radius:6px; background:#333043; padding:3px 7px; font-size:10px; color:#c5bbdc; font-weight:400}
.send-icon { display:inline-grid; place-content:center; border-radius:50%; width:28px; height:28px; background:linear-gradient(135deg,#528dd5,#9463c6); color:#e3d6fd}
.model-line { display:flex; justify-content:flex-end; gap:9px; font-size:10px; color:#b4b2c4; margin-top:-8px}
.model-line span { color:#9290a4}
.hero-body { padding:0; gap:0; flex-direction:row; min-height:550px}
.hero-chat { flex:1; min-width:0; padding:24px; display:flex; flex-direction:column; gap:16px}
.hero-inspector { display:none; width:244px; flex-shrink:0; padding:14px; background:linear-gradient(150deg,#c1cfff0a,#d4b9ff10); border:1px solid #c1cfff16; border-radius:17px; margin-left:1px }
.pane-label { display:flex; justify-content:space-between; font-size:12px; font-weight:600}
.pane-label span { font-weight:400; font-size:10px}
.pane-note { font-size:10px; color:#9c9aac; margin-top:10px!important; line-height:1.5}
.queued-note { border-left:2px solid #8f7bb9; padding-left:11px; color:#c4b5df; font-size:11px}
.mock-action { border:1px solid #555061; background:#36313e; border-radius:7px; padding:4px 10px; font-size:11px; color:#e2dae9}
.settings-body { gap:12px; padding:22px}
.pen-heading { display:flex; align-items:center; gap:12px; margin-bottom:5px}
.pen-heading h3 { font-size:19px}
.pen-heading p { font-size:11px; color:#aaa8b9}
.pen-heading>.mock-action { margin-left:auto}
.pen-icon { display:grid; place-content:center; width:38px; height:38px; border-radius:10px; background:color-mix(in srgb,var(--pen-colour,#b191ff) 22%,transparent); border:1px solid color-mix(in srgb,var(--pen-colour,#b191ff) 35%,transparent); color:#e8d6ff; font-size:23px}
.compact { margin:0; padding:12px}
.compact .composer-actions { margin-top:12px}
.segments { display:flex; border-radius:22px; padding:3px; background:#d4d2ff0c; border:1px solid #363541; font-size:11px; gap:3px; align-self:stretch}
.segments>* { flex:1; text-align:center; padding:5px 10px; color:#aaa8ba; border-radius:20px}
.segments button { cursor:pointer}
.segments .selected { background:#c1bfd327; color:#f5f2fb; box-shadow:0 1px 3px #0005}
.settings-card { padding:13px 15px; border-radius:10px; border:1px solid #393744; background:#c7c7ec08; box-shadow:inset 0 1px 0 #ffffff08; display:grid; gap:9px}
.settings-card p { font-size:11px}
.setting-row { display:flex; justify-content:space-between; align-items:center; gap:10px; font-size:11px}
.setting-row strong { font-weight:600}
.muted { color:#aaa7b8}
.small-row { padding:6px 3px}
.memory-reader { display:flex; min-height:225px; border:1px solid #3a3747; border-radius:10px; overflow:hidden; background:#11132666}
.memory-reader nav { width:145px; flex-shrink:0; padding:8px; background:#a4a8d00b; border-right:1px solid #3b3847}
.memory-reader button { display:block; width:100%; border-radius:6px; padding:9px 7px; text-align:left; font-size:11px; color:#b8b3c7; cursor:pointer}
.memory-reader .active-page { background:#494054; color:#ece0ff}
.memory-reader article { padding:20px 16px; min-width:0}
.memory-reader small { font-size:8px; letter-spacing:.14em; color:#a19bad}
.memory-reader h3 { font-size:17px; margin:12px 0}
.memory-reader p { font-size:12px; line-height:1.75}
.memory-reference { color:#9d92b0; margin-top:24px!important; font-size:10px!important}
.preview-body { padding:18px; gap:12px}
.source-document { margin:0; flex:1; min-height:310px; padding:28px 15px; overflow:auto; border:1px solid #3d384a; border-radius:8px; background:#14131e; color:#c6b5e0; line-height:2; font-size:12px}
.preview-footer { font-size:10px; padding:2px 4px}
.settings-heading { font-size:17px; margin-bottom:3px!important}
.toggle { display:inline-block; width:25px; height:14px; border-radius:15px; background:#504956; vertical-align:middle; position:relative; margin-left:7px}
.toggle:after { content:''; position:absolute; top:2px; left:2px; width:10px; height:10px; border-radius:50%; background:#c5c0ca}
.toggle.on { background:#728fdb}
.toggle.on:after { left:13px; background:#fff}
.field-value { border:1px solid #4d4759; padding:2px 7px; border-radius:5px; color:#c8bed5}
.footnote { color:#a5a0b2; font-size:10px!important; line-height:1.55}
.policy-options>div { display:flex; gap:10px; align-items:flex-start; padding:4px 0}
.policy-options strong { font-size:11px; font-weight:500}
.policy-options small { display:block; color:#a5a0b1; font-size:10px; margin-top:2px}
.radio { flex-shrink:0; width:12px; height:12px; border:1px solid #86808e; border-radius:50%; margin-top:3px}
.radio.checked { border:4px solid #729deb; background:#f8f1ff}
.section-label { font-size:11px; font-weight:600; color:#c6bfce; padding:3px 3px 0}
.allowed { color:#6dd5bb; font-size:10px}
button:focus-visible,summary:focus-visible { outline:2px solid #c4a8ed; outline-offset:3px}
@container(min-width:700px) { .hero-inspector { display:block}
}
@container(max-width:380px) { .mock-body,.settings-body { padding:17px; gap:12px}
.hero-body { padding:0}
.hero-chat { padding:17px}
.memory-reader { flex-direction:column}
.memory-reader nav { width:auto; border-right:0; border-bottom:1px solid #3b3847; display:flex; gap:3px}
.memory-reader button { font-size:10px; padding:6px}
.memory-reader article { padding:16px}
.memory-reader p { font-size:11px}
.setting-row { font-size:10px}
.permission-chip { font-size:9px}
.user-message { max-width:100%}
.settings-card { padding:11px}
.current-action { flex-wrap:wrap}
}

.mock-body svg { flex-shrink:0; width:14px; height:14px; vertical-align:middle }
.tool-lines p,.setting-row strong,.icon-label,.settings-heading,.queued-note,.mock-action { display:flex; align-items:center; gap:7px }
.tool-lines p { min-width:0; overflow-wrap:anywhere }.tool-lines .tool-done { margin-left:auto; color:#69cfb6; width:12px; height:12px }.tool-lines>p>svg:first-child { color:#8baded }
.permission-chip { display:inline-flex; align-items:center; gap:4px }.permission-chip svg { width:10px; height:10px }.send-icon svg { width:17px; height:17px }.model-line>span { display:inline-flex; align-items:center; gap:3px }.model-line .composer-stat { margin-right:auto; color:#a1a8c6; gap:4px }
.hero-artifact { margin-bottom:3px; border:1px solid #c5bde826; border-radius:11px; overflow:hidden; background:#b8b6dc06; padding:10px }.hero-artifact .segments { margin-bottom:9px }.hero-artifact .trail-preview { border:0; border-radius:7px }.hero-source { margin:0; min-height:170px; padding:15px 10px; font-size:10px; line-height:1.8; color:#c3b6df; white-space:pre; overflow:auto }.artifact-actions { display:flex; gap:12px; align-items:center }.artifact-actions svg { width:12px; height:12px }.artifact-label { display:flex; align-items:center; gap:5px; margin-bottom:7px; font-size:9px; color:#aaa9c2 }.artifact-label>span { margin-left:auto; font-size:8px; color:#9695b0 }
.inspector-engine { display:flex; align-items:center; gap:9px; margin-top:13px; padding:11px 5px; font-size:9px; color:#c0bdd3 }.inspector-engine>svg { width:19px; height:19px; color:#8bbaed }.inspector-engine strong { display:block; font-size:10px }.inspector-engine div>span { display:block; margin-top:3px; color:#9c98b3; font-size:9px }.inspector-engine>.status-dot { margin-left:auto; background:#56c8a0 }
.pen-body { position:relative; background:radial-gradient(ellipse at 0 0,color-mix(in srgb,var(--pen-colour) 16%,transparent),transparent 65%),linear-gradient(140deg,#101726d9,#20132ecc) }.pen-body .composer { border-color:color-mix(in srgb,var(--pen-colour) 50%,transparent) }.edit-pen { cursor:pointer; white-space:nowrap }.edit-pen svg { width:11px; height:11px }
.pen-dialog-overlay { position:absolute; inset:0; z-index:2; border-radius:15px; background:#090a1a99; backdrop-filter:blur(4px) }
.pen-dialog { position:absolute; z-index:3; width:calc(100% - 36px); max-width:360px; left:50%; top:50%; transform:translate(-50%,-50%); padding:20px; border:1px solid #c4c5f04f; border-radius:20px; background:linear-gradient(140deg,#303749f5,#282039fa); box-shadow:inset 0 1px 0 #ffffff26,0 15px 45px #0008; outline:none; color:#eeecf6 }
.pen-dialog-title { font-size:15px!important; margin:0 0 17px!important }.pen-name-field { display:flex; gap:9px; align-items:center; margin-bottom:17px }.dialog-emoji { display:grid; place-items:center; width:36px; height:36px; border:1px solid #c5c2e52e; border-radius:9px; background:#d8d7ee0d; font-size:21px; flex-shrink:0 }.pen-name-field input { min-width:0; width:100%; border:1px solid #c5c2e532; border-radius:8px; padding:8px 10px; font-size:12px; background:#0e14244d; color:#eeecf6 }
.pen-colour-picker { display:grid; gap:8px; margin-bottom:13px; font-size:10px; color:#c2bfd3 }.pen-palette { display:flex; align-items:center; gap:9px }.current-swatch { width:35px; height:25px; border:1px solid #ffffff33; border-radius:6px; margin-right:4px; box-shadow:0 0 12px color-mix(in srgb,var(--draft-colour) 25%,transparent) }.pen-palette button { display:grid; place-items:center; width:18px; height:18px; border-radius:50%; cursor:pointer; color:#171b2d }.pen-palette button[aria-pressed=true] { outline:1px solid #f0e6ff; outline-offset:2px }.pen-palette button svg { width:11px; height:11px }
.colour-slider { display:grid; grid-template-columns:58px minmax(0,1fr); align-items:center; gap:9px; margin-top:9px; font-size:10px; color:#c2bfd3 }.colour-slider input { width:100%; min-width:0; height:14px; accent-color:#91a9ff; cursor:pointer }.colour-preview { display:flex; align-items:center; gap:5px; width:fit-content; max-width:100%; overflow-wrap:anywhere; border-radius:20px; margin-top:17px; padding:4px 9px; background:color-mix(in srgb,var(--draft-colour) 16%,transparent); border:1px solid color-mix(in srgb,var(--draft-colour) 35%,transparent); font-size:11px }.colour-preview svg { color:var(--draft-colour); width:10px; height:10px }.pen-dialog-actions { display:flex; justify-content:flex-end; gap:8px; margin-top:20px }.pen-dialog-actions button { cursor:pointer; padding:5px 15px }.save-pen { background:#7385c6; border-color:#a9b3e94d; color:white }.save-pen:disabled { opacity:.4; cursor:default }.pen-dialog input:focus-visible { outline:2px solid #c4a8ed; outline-offset:3px }

.memory-reader button { display:flex; align-items:center; gap:5px }.memory-reader button svg { width:12px; height:12px }.preview-body>.trail-preview { flex:1 }.artifact-title { display:flex; align-items:center; gap:7px; font-size:12px!important; font-weight:600!important }.preview-file-actions { display:flex; gap:14px }.segments button { display:flex; align-items:center; justify-content:center; gap:5px }.segments button svg { width:12px; height:12px }
@container(max-width:380px) { .pen-heading { gap:8px }.pen-heading h3 { font-size:17px }.pen-heading p { max-width:140px; font-size:10px }.edit-pen { font-size:9px; padding:4px 6px }.hero-chat { gap:13px }.artifact-label { font-size:8px }.hero-body { min-height:570px }.memory-reader nav button { flex:1; flex-direction:column; align-items:flex-start }.preview-footer { flex-wrap:wrap }.source-document { font-size:10px }.policy-options small { font-size:9px } }
.mobile-nerd-stats { font-size:10px; border:1px solid #b9b2ef25; border-radius:12px; background:#b8b5ef08 }.mobile-nerd-stats summary { display:flex; align-items:center; gap:7px; cursor:pointer; list-style:none; padding:11px }.mobile-nerd-stats summary::-webkit-details-marker { display:none }.mobile-nerd-stats summary>span:nth-last-child(2) { margin-left:auto; color:#b9b1dd }.mobile-nerd-stats[open] summary>svg:last-child { transform:rotate(180deg) }.mobile-nerd-stats .nerd-stats { margin:0 9px 9px }
@container(min-width:700px) { .mobile-nerd-stats { display:none } }
</style>
