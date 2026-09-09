<script setup lang="ts">
import { motion } from 'motion-v'
const { reveal, stagger, heading } = useReveal()
</script>

<template>
  <section class="mx-auto max-w-6xl px-6 py-24 sm:py-32">
    <motion.div v-bind="reveal()" class="mx-auto max-w-2xl text-center">
      <p class="font-mono text-xs uppercase tracking-[0.2em] text-primary">Built around your work</p>
      <motion.h2 v-bind="heading(0.1)" class="mt-3 text-balance text-4xl font-semibold tracking-[-0.03em] sm:text-5xl">
        Local intelligence. Native to Mac. Private by design.
      </motion.h2>
    </motion.div>

    <div class="mt-14 grid gap-4 md:grid-cols-3">
      <motion.div v-bind="stagger(0)">
        <Card variant="glass" padding="lg" class="group h-full overflow-hidden">
          <AuroraCanvas hue="blue" :intensity="0.6" :scale="1.5" :speed="0.06" :stretch="0.22" :seed="1" />
          <div class="pointer-events-none absolute inset-0 bg-[linear-gradient(180deg,transparent_20%,rgba(10,11,20,.55))]" />
          <div class="relative">
          <div class="mb-5 inline-flex size-11 items-center justify-center rounded-xl bg-primary/15 text-primary ring-1 ring-primary/30"><i-hugeicons-cpu class="size-6" /></div>
          <h3 class="text-xl font-semibold">Local models, useful work</h3>
          <p class="mt-2 text-pretty text-muted-foreground">
            Connect an engine running on your Mac and bring it into everyday project work. GOAT provides the workspace, context and tools around the model.
          </p>
          </div>
        </Card>
      </motion.div>
      <motion.div v-bind="stagger(1)">
        <Card variant="glass" padding="lg" class="group h-full overflow-hidden">
          <AuroraCanvas hue="violet" :intensity="0.6" :scale="1.5" :speed="0.06" :stretch="0.22" :seed="7" />
          <div class="pointer-events-none absolute inset-0 bg-[linear-gradient(180deg,transparent_20%,rgba(10,11,20,.55))]" />
          <div class="relative">
          <div class="mb-5 inline-flex size-11 items-center justify-center rounded-xl bg-goat-accent2/15 text-[#d9a3ff] ring-1 ring-goat-accent2/30"><i-hugeicons-laptop class="size-6" /></div>
          <h3 class="text-xl font-semibold">A native Mac workspace</h3>
          <p class="mt-2 text-pretty text-muted-foreground">
            Read conversations, browse project files and inspect previews in a focused desktop interface, with themes and reading preferences that suit you.
          </p>
          </div>
        </Card>
      </motion.div>
      <motion.div v-bind="stagger(2)">
        <Card variant="glass" padding="lg" class="group h-full overflow-hidden">
          <AuroraCanvas hue="indigo" :intensity="0.6" :scale="1.5" :speed="0.06" :stretch="0.22" :seed="13" />
          <div class="pointer-events-none absolute inset-0 bg-[linear-gradient(180deg,transparent_20%,rgba(10,11,20,.55))]" />
          <div class="relative">
          <div class="mb-5 inline-flex size-11 items-center justify-center rounded-xl bg-goat-glow/20 text-[#b9a7ff] ring-1 ring-goat-glow/40"><i-hugeicons-security-check class="size-6" /></div>
          <h3 class="text-xl font-semibold">Control at the point of access</h3>
          <p class="mt-2 text-pretty text-muted-foreground">
            Review tool permissions, choose connection policies and inspect activity. Configuring a service is a deliberate choice about where it runs and what it receives.
          </p>
          </div>
        </Card>
      </motion.div>
    </div>
  </section>
</template>
