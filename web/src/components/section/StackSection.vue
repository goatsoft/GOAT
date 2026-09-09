<script setup lang="ts">
import { motion } from 'motion-v'
const site = useSite()
const { reveal, heading } = useReveal()
const stack = [
  { name: 'Swift 6', note: 'Native application code with explicit ownership and concurrency.', href: 'https://www.swift.org' },
  { name: 'SwiftUI · macOS 26', note: 'A native interface for focused project work.', href: 'https://developer.apple.com/documentation/swiftui' },
  { name: 'Compatible engines', note: 'HTTP streaming connections to the model engine you choose.', href: site.doc('ENGINES') },
  { name: 'Local storage', note: 'SQLite chat storage through GRDB, with files in your home and workspaces.', href: site.doc('reference/STORAGE') },
  { name: 'MCP Swift SDK', note: 'Tools from configured stdio and HTTP servers.', href: 'https://github.com/modelcontextprotocol/swift-sdk' },
  { name: 'Documented dependencies', note: 'Open-source foundations with their licences and notices.', doc: 'third-party-notices' as const },
]
const capabilities = [
  'Streaming chat, syntax highlighting and engine-supplied statistics',
  'Capability-aware effort presets and context-use indicators',
  'Themes, local fonts and reading controls',
  'Saved conversations and local workspace organisation',
  'Activity history and a same-user local CLI/API',
  'Documented extension contracts and contributor examples',
]
const tileClass = 'group relative block w-full rounded-2xl p-6 text-left ring-hair transition-[transform,background-color] duration-500 hover:bg-white/[0.04]'

/**
 * One cloud behind the whole grid, blue on the left sweeping to violet on the right.
 * The tiles are windows onto it: an SVG mask of rounded rects (measured from the real
 * tile layout) clips the canvas so only the tiles show the cloud, never the gaps.
 */
const grid = ref<HTMLElement | null>(null)
const mask = ref('')
function measure() {
  const g = grid.value
  if (!g) return
  // offset* is layout geometry: unaffected by the entrance transforms motion-v applies.
  const rects = Array.from(g.querySelectorAll<HTMLElement>('[data-tile]')).map(
    (el) => `<rect x="${el.offsetLeft}" y="${el.offsetTop}" width="${el.offsetWidth}" height="${el.offsetHeight}" rx="16"/>`,
  )
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${g.offsetWidth}" height="${g.offsetHeight}">${rects.join('')}</svg>`
  mask.value = `url("data:image/svg+xml,${encodeURIComponent(svg)}")`
}
onMounted(() => {
  measure()
  const ro = new ResizeObserver(measure)
  if (grid.value) ro.observe(grid.value)
  onUnmounted(() => ro.disconnect())
})
</script>

<template>
  <section class="mx-auto max-w-6xl px-6 py-12 sm:py-24">
    <motion.div v-bind="reveal()" class="flex flex-col items-start justify-between gap-6 md:flex-row md:items-end">
      <div>
        <p class="font-mono text-xs uppercase tracking-[0.2em] text-primary">Under the hood</p>
        <motion.h2 v-bind="heading(0.1)" class="mt-3 text-balance text-3xl font-semibold tracking-[-0.03em] sm:text-4xl">Built for the Mac. Open to contribution.</motion.h2>
      </div>
      <p class="max-w-md text-pretty text-muted-foreground">
        A native interface, local chat storage and a modular tool runtime. The architecture is documented so contributors can understand how the pieces fit together.
      </p>
    </motion.div>

    <div ref="grid" class="relative isolate mt-8 sm:mt-10">
      <!-- the one cloud, clipped to the tiles -->
      <div class="pointer-events-none absolute inset-0 -z-10 bg-card" :style="{ maskImage: mask, WebkitMaskImage: mask }">
        <div class="absolute inset-0 bg-[linear-gradient(100deg,rgba(58,160,255,.16),rgba(122,92,255,.12)_50%,rgba(180,75,255,.18))]" />
        <AuroraCanvas hue="aurora" :sweep="1" :intensity="1.2" :scale="0.7" :speed="0.05" :stretch="0.4" :seed="3" />
      </div>
      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <template v-for="s in stack" :key="s.name">
          <!-- The notices tile opens the in-page dialog; the rest link out. -->
          <DocDialog v-if="'doc' in s && s.doc" :doc="s.doc" hue="blue">
            <button type="button" data-tile :class="tileClass">
              <div class="flex items-center justify-between gap-2">
                <span class="text-lg font-semibold">{{ s.name }}</span>
                <i-hugeicons-book-open-01 class="size-4 shrink-0 text-goat-ink/60 opacity-0 transition-opacity group-hover:opacity-100" />
              </div>
              <p class="mt-2 text-pretty text-sm text-goat-ink/70">{{ s.note }}</p>
            </button>
          </DocDialog>
          <a v-else :href="s.href" target="_blank" rel="noopener" data-tile :class="tileClass">
            <div class="flex items-center justify-between gap-2">
              <span class="text-lg font-semibold">{{ s.name }}</span>
              <i-hugeicons-arrow-up-right-01 class="size-4 shrink-0 text-goat-ink/60 opacity-0 transition-opacity group-hover:opacity-100" />
            </div>
            <p class="mt-2 text-pretty text-sm text-goat-ink/70">{{ s.note }}</p>
          </a>
        </template>
      </div>
    </div>
    <div class="mt-8 border-t sm:mt-12 border-white/10 pt-8">
      <h3 class="text-xl font-semibold">More for your everyday work</h3>
      <ul class="mt-6 grid gap-x-10 gap-y-4 text-sm text-muted-foreground sm:grid-cols-2">
        <li v-for="item in capabilities" :key="item" class="flex gap-3"><span aria-hidden="true" class="text-primary">•</span>{{ item }}</li>
      </ul>
      <p class="mt-7 flex flex-wrap gap-6 text-sm"><a :href="site.doc('Architecture')" class="text-primary hover:underline">Explore the architecture →</a><a :href="site.doc('MODULES')" class="text-primary hover:underline">Module reference →</a></p>
    </div>
  </section>
</template>
