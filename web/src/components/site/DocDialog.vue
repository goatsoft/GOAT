<script setup lang="ts">
/**
 * A repo document (rendered from Markdown at build, see plugins/goat-docs.ts) in a
 * dialog that looks like it belongs to the herd: a slow-spinning blue→violet ring, the
 * aurora clouds drifting behind a glass panel, gradient title, and prose set for
 * reading. Trigger is the default slot; `doc` picks the document.
 *
 *   <DocDialog doc="third-party-notices">Third-party notices</DocDialog>
 */
import { computed } from 'vue'
import { docs } from 'virtual:goat-docs'
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle, DialogTrigger } from '@/components/ui/dialog'

const props = defineProps<{ doc: keyof typeof docs; title?: string; hue?: 'aurora' | 'blue' | 'violet' | 'indigo' }>()
const d = computed(() => docs[props.doc])
const title = computed(() => props.title ?? d.value.title)
</script>

<template>
  <Dialog>
    <DialogTrigger as-child>
      <slot />
    </DialogTrigger>
    <DialogContent
      class="w-[min(92vw,44rem)] max-h-[88vh]"
      overlay-class="bg-[#05060c]/70 backdrop-blur-md"
      :aria-describedby="undefined"
    >
      <!-- Ring: the DownloadButton's conic sweep, slowed down for a big surface. -->
      <div class="doc-ring pointer-events-none absolute -inset-px rounded-[26px]" aria-hidden="true" />
      <div class="doc-glow pointer-events-none absolute inset-0 rounded-[26px]" aria-hidden="true" />

      <div class="relative isolate flex max-h-[88vh] flex-col overflow-hidden rounded-3xl bg-goat-bg/85 ring-hair backdrop-blur-2xl">
        <!-- Clouds live behind the header only, dissolving into the panel so the body stays readable. -->
        <div class="pointer-events-none absolute inset-x-0 top-0 -z-10 h-56 [mask-image:linear-gradient(180deg,#000_20%,transparent)]" aria-hidden="true">
          <AuroraCanvas :hue="hue ?? 'aurora'" fade :intensity="0.9" :scale="1.15" :speed="0.08" :stretch="0.5" :seed="21" class="absolute inset-0" />
          <div class="absolute inset-0 bg-[radial-gradient(60%_70%_at_50%_0%,rgba(122,92,255,.25),transparent)]" />
        </div>

        <header class="flex items-start justify-between gap-6 px-7 pb-5 pt-7 sm:px-9">
          <div class="min-w-0">
            <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-primary">GOAT</p>
            <DialogTitle class="mt-1.5 text-balance text-2xl font-semibold tracking-[-0.03em] sm:text-3xl">
              <span class="text-aurora">{{ title }}</span>
            </DialogTitle>
            <DialogDescription class="mt-2 text-sm text-muted-foreground">
              <a :href="d.source" target="_blank" rel="noopener" class="text-primary hover:underline">Read the full document ↗</a>
              <a v-if="doc === 'third-party-notices'" :href="asset('third-party-licenses.txt')" class="mt-1 block text-primary hover:underline">Full website licence texts ↗</a>
            </DialogDescription>
          </div>
          <DialogClose
            class="glass inline-flex size-9 shrink-0 items-center justify-center rounded-full text-muted-foreground transition hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
            aria-label="Close"
          >
            <i-hugeicons-cancel-01 class="size-4" />
          </DialogClose>
        </header>

        <div class="doc-prose min-h-0 overflow-y-auto px-7 pb-8 sm:px-9" v-html="d.html" />

        <!-- Fade the bottom edge so the scroll reads as a surface, not a cut. -->
        <div class="pointer-events-none absolute inset-x-0 bottom-0 h-10 bg-gradient-to-t from-goat-bg/90 to-transparent" aria-hidden="true" />
      </div>
    </DialogContent>
  </Dialog>
</template>

<style scoped>
@property --doc-a { syntax: "<angle>"; inherits: false; initial-value: 0deg; }
.doc-ring {
  background: conic-gradient(from var(--doc-a, 0deg), rgba(58,160,255,0) 0%, #7cc4ff 22%, #e08cff 48%, #7a5cff 66%, rgba(58,160,255,0) 100%);
  animation: doc-spin 9s linear infinite;
  -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
  mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
  -webkit-mask-composite: xor; mask-composite: exclude;
  padding: 1.5px;
}
.doc-glow {
  box-shadow: -12px -8px 48px -20px rgba(58,160,255,.3), 12px 16px 56px -20px rgba(180,75,255,.3);
  animation: doc-glow 9s linear infinite;
}
@keyframes doc-glow {
  0%, 100% { box-shadow: -12px -8px 48px -20px rgba(58,160,255,.3), 12px 16px 56px -20px rgba(180,75,255,.3); }
  50% { box-shadow: -12px -8px 48px -20px rgba(180,75,255,.3), 12px 16px 56px -20px rgba(58,160,255,.3); }
}
@keyframes doc-spin { to { --doc-a: 360deg; } }
@media (prefers-reduced-motion: reduce) { .doc-ring, .doc-glow { animation: none; } }

/* Prose for the rendered Markdown (no typography plugin on purpose: tokens only). */
.doc-prose { font-size: 14.5px; line-height: 1.65; color: color-mix(in oklab, var(--goat-ink) 88%, transparent); }
.doc-prose :deep(h2) { margin: 1.6em 0 .5em; font-size: 1.05rem; font-weight: 600; letter-spacing: -.01em; color: var(--goat-ink); }
.doc-prose :deep(h2)::before { content: ""; display: inline-block; width: 10px; height: 10px; margin-right: 10px; border-radius: 999px; vertical-align: 0; background: linear-gradient(120deg, var(--goat-accent), var(--goat-accent2)); box-shadow: 0 0 12px rgba(122,92,255,.6); }
.doc-prose :deep(h3) { margin: 1.3em 0 .4em; font-size: .95rem; font-weight: 600; color: var(--goat-ink); }
.doc-prose :deep(p) { margin: .7em 0; }
.doc-prose :deep(ul) { margin: .6em 0; padding-left: 1.2em; list-style: disc; }
.doc-prose :deep(ol) { margin: .6em 0; padding-left: 1.2em; list-style: decimal; }
.doc-prose :deep(li) { margin: .3em 0; }
.doc-prose :deep(li)::marker { color: var(--goat-accent); }
.doc-prose :deep(a) { color: var(--goat-accent); text-decoration: underline; text-decoration-color: color-mix(in oklab, var(--goat-accent) 40%, transparent); text-underline-offset: 3px; }
.doc-prose :deep(a:hover) { text-decoration-color: var(--goat-accent); }
.doc-prose :deep(strong) { color: var(--goat-ink); font-weight: 600; }
.doc-prose :deep(code) { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85em; padding: .1em .4em; border-radius: 6px; background: rgba(255,255,255,.06); box-shadow: inset 0 0 0 1px rgba(142,149,168,.18); }
.doc-prose :deep(blockquote) { margin: .9em 0; padding: .6em 1em; border-left: 2px solid transparent; border-image: linear-gradient(180deg, var(--goat-accent), var(--goat-accent2)) 1; background: rgba(255,255,255,.03); color: var(--goat-muted); font-size: .9em; }
.doc-prose :deep(hr) { border: 0; height: 1px; margin: 1.4em 0; background: linear-gradient(90deg, transparent, rgba(142,149,168,.35), transparent); }
</style>
