<script setup lang="ts">
import { motion } from 'motion-v'
const site = useSite()
const { reveal, stagger, heading } = useReveal()
const steps = [
  { n: '01', title: 'Set up an engine', body: 'Run a supported model with your chosen compatible engine.', link: { label: 'Engine setup', href: site.doc('Engines') } },
  { n: '02', title: site.releaseAvailable ? 'Install GOAT' : 'Build GOAT', body: site.releaseAvailable ? 'Follow the installation instructions for the published Mac build.' : 'Build the source preview with Xcode and XcodeGen. No Apple Developer membership is required.', link: { label: 'Getting started', href: site.doc('Getting-Started') } },
  { n: '03', title: 'Create a Pen', body: 'Add project instructions, choose a workspace and start a chat.', link: { label: 'Your first Pen', href: site.doc('how-to/CREATE-A-PEN') } },
]

// Blue → indigo → violet across the three steps, matching Under the hood.
const blue = [[0.23, 0.63, 1.0], [0.48, 0.82, 1.0], [0.48, 0.36, 1.0]]
const violet = [[0.71, 0.29, 1.0], [0.48, 0.36, 1.0], [0.88, 0.55, 1.0]]
const lerp = (a: number[], b: number[], t: number) => a.map((v, k) => v + (b[k]! - v) * t)
const palette = (i: number) => {
  const t = i / (steps.length - 1)
  return [lerp(blue[0]!, violet[0]!, t), lerp(blue[1]!, violet[1]!, t), lerp(blue[2]!, violet[2]!, t)] as [number[], number[], number[]]
}
</script>

<template>
  <section id="download" class="relative scroll-mt-24 overflow-hidden py-24 sm:py-32">
    <div class="pointer-events-none absolute left-1/2 top-1/2 -z-10 h-[700px] w-[1100px] -translate-x-1/2 -translate-y-1/2 rounded-full bg-[radial-gradient(closest-side,rgba(122,92,255,.22),transparent)] blur-3xl" />
    <div class="mx-auto max-w-6xl px-6">
      <motion.div v-bind="reveal()" class="mx-auto max-w-2xl text-center">
        <img :src="asset('img/goat-dark.webp')" alt="" class="logo-shadow mx-auto mb-6 size-28" />
        <motion.h2 v-bind="heading(0.1)" class="text-balance text-4xl font-semibold tracking-[-0.03em] sm:text-6xl">{{ site.releaseAvailable ? 'Put your local model to work.' : 'Help shape Kid.' }}</motion.h2>
        <p class="mt-4 text-pretty text-lg text-muted-foreground">{{ site.releaseAvailable ? 'Install GOAT, connect an engine and create your first Pen.' : 'Explore the source preview, try it with your local models and tell us what works. A packaged Mac download will follow once release testing is complete.' }}</p>
        <div class="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <DownloadButton :href="site.primaryHref" :label="site.primaryLabel" />
          <StarLink :href="site.repo" label="View source" size="lg" />
        </div>
      </motion.div>

      <p class="mt-5 text-center text-xs text-muted-foreground">{{ site.requirements }} · Code, docs and examples: MIT. Artwork has separate terms.</p>

      <!-- Same cloud language as the rest of the page, but softer and top-lit: the cloud
           sits behind the step number and fades out before the copy. -->
      <div class="mt-16 grid gap-4 md:grid-cols-3">
        <motion.div v-for="(s, i) in steps" :key="s.n" v-bind="stagger(i)">
          <Card variant="glass" padding="lg" class="group relative isolate h-full overflow-hidden">
            <AuroraCanvas
              :colors="palette(i)" :intensity="0.9" :scale="1.2" :speed="0.045" :stretch="0.9" :seed="i * 7 + 11"
              class="-z-10 [mask-image:linear-gradient(180deg,#000_10%,rgba(0,0,0,.35)_55%,transparent_90%)]"
            />
            <div class="font-mono text-5xl font-semibold tracking-tight text-white/90 [text-shadow:0_2px_24px_rgba(0,0,0,.5)]">{{ s.n }}</div>
            <h3 class="mt-4 text-lg font-semibold">
              {{ s.title }}
            </h3>
            <p class="mt-2 text-pretty text-sm text-goat-ink/70">{{ s.body }}</p>
            <a :href="s.link.href" class="mt-4 inline-flex items-center gap-1 text-sm text-primary hover:underline">{{ s.link.label }} <i-hugeicons-arrow-up-right-01 class="size-3.5" /></a>
          </Card>
        </motion.div>
      </div>
    </div>
  </section>
</template>
