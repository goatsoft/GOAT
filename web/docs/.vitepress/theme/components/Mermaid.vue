<script setup lang="ts">
/**
 * Client-side Mermaid renderer for ```mermaid fences (see plugins/mermaid.ts).
 * Loads the bundled library lazily on first use, follows the site theme, and
 * re-renders when the user flips Light / Midnight. Strict security level: the
 * diagram source is data, never HTML. Diagrams wider than the column keep their
 * natural size and scroll; the expand control opens them at viewport width.
 */
import { onMounted, ref, watch } from 'vue'
import { useData } from 'vitepress'

const props = defineProps<{ code: string }>()
const { isDark } = useData()
const host = ref<HTMLElement | null>(null)
const dialog = ref<HTMLDialogElement | null>(null)
const svg = ref('')
const error = ref('')
const wide = ref(false)
let counter = 0

async function render() {
  const { default: mermaid } = await import('mermaid')
  const css = getComputedStyle(document.documentElement)
  const v = (name: string) => css.getPropertyValue(name).trim()
  const dark = isDark.value
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: 'base',
    fontFamily: 'var(--vp-font-family-base)',
    themeVariables: {
      darkMode: dark,
      background: 'transparent',
      primaryColor: dark ? '#1b1e33' : '#eef1fb',
      primaryTextColor: v('--goat-ink'),
      primaryBorderColor: v('--goat-accent'),
      secondaryColor: dark ? '#241a3d' : '#f1ebfb',
      tertiaryColor: dark ? '#151726' : '#f7f8fc',
      lineColor: v('--goat-muted'),
      textColor: v('--goat-ink'),
      clusterBkg: dark ? 'rgba(21,23,38,.55)' : 'rgba(255,255,255,.6)',
      clusterBorder: v('--goat-accent2'),
      edgeLabelBackground: v('--goat-surface'),
      actorBkg: dark ? '#1b1e33' : '#eef1fb',
      actorBorder: v('--goat-accent'),
      actorTextColor: v('--goat-ink'),
      signalColor: v('--goat-ink'),
      signalTextColor: v('--goat-ink'),
      labelBoxBkgColor: v('--goat-surface'),
      labelTextColor: v('--goat-ink'),
      loopTextColor: v('--goat-ink'),
      noteBkgColor: dark ? '#241a3d' : '#f1ebfb',
      noteTextColor: v('--goat-ink'),
    },
  })
  try {
    const id = `goat-mermaid-${++counter}-${Math.random().toString(36).slice(2)}`
    const out = await mermaid.render(id, props.code)
    // Mermaid pins `max-width` to the layout width; drop it so CSS decides the size.
    svg.value = out.svg.replace(/style="max-width:[^"]*"/, '')
    error.value = ''
    const width = Number(/viewBox="[\d.\-]+ [\d.\-]+ ([\d.]+)/.exec(out.svg)?.[1] ?? 0)
    wide.value = !!host.value && width > host.value.clientWidth * 1.15
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  }
}

onMounted(render)
watch(isDark, render)
</script>

<template>
  <figure class="goat-mermaid" :class="{ wide }">
    <button v-if="wide" class="goat-mermaid-expand" type="button" title="Expand diagram" @click="dialog?.showModal()">⤢</button>
    <div ref="host" class="goat-mermaid-svg" v-html="svg" />
    <pre v-if="error" class="goat-mermaid-error">{{ error }}</pre>
    <dialog ref="dialog" class="goat-mermaid-dialog" @click.self="dialog?.close()">
      <button class="goat-mermaid-close" type="button" title="Close" @click="dialog?.close()">✕</button>
      <div class="goat-mermaid-full" v-html="svg" />
    </dialog>
  </figure>
</template>

<style scoped>
.goat-mermaid {
  position: relative;
  margin: 1.25rem 0;
  padding: 1rem;
  overflow-x: auto;
  border: 1px solid var(--vp-c-divider);
  border-radius: 12px;
  background: var(--vp-c-bg-soft);
}
/* VitePress's doc line-height leaks into foreignObject labels and clips them; pin it. */
.goat-mermaid :deep(.nodeLabel),
.goat-mermaid :deep(.edgeLabel),
.goat-mermaid :deep(.cluster-label),
.goat-mermaid :deep(foreignObject div) {
  line-height: 1.25;
}
.goat-mermaid :deep(p) {
  margin: 0;
  line-height: 1.25;
}
.goat-mermaid-svg :deep(svg) {
  display: block;
  height: auto;
  margin: 0 auto;
  max-width: 100%;
}
/* Wide diagrams keep their natural width and scroll rather than shrinking to a smear. */
.goat-mermaid.wide .goat-mermaid-svg :deep(svg) {
  max-width: none;
  width: max(100%, 1100px);
}
.goat-mermaid-expand,
.goat-mermaid-close {
  position: absolute;
  top: 0.5rem;
  right: 0.5rem;
  z-index: 1;
  width: 2rem;
  height: 2rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  background: var(--vp-c-bg-elv);
  color: var(--vp-c-text-1);
  font-size: 1rem;
  line-height: 1;
  cursor: pointer;
}
.goat-mermaid-expand:hover,
.goat-mermaid-close:hover {
  border-color: var(--goat-accent);
}
.goat-mermaid-dialog {
  width: min(96vw, 1800px);
  max-width: none;
  max-height: 94vh;
  padding: 2.5rem 1rem 1rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 16px;
  background: var(--vp-c-bg);
  color: var(--vp-c-text-1);
  overflow: auto;
}
.goat-mermaid-dialog::backdrop {
  background: rgba(5, 6, 12, 0.7);
  backdrop-filter: blur(6px);
}
.goat-mermaid-full :deep(svg) {
  display: block;
  width: 100%;
  height: auto;
  margin: 0 auto;
}
.goat-mermaid-error {
  margin: 0;
  font-size: 0.8rem;
  color: var(--vp-c-danger-1);
  white-space: pre-wrap;
}
</style>
