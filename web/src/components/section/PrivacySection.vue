<script setup lang="ts">
import { motion } from 'motion-v'
const site = useSite()
const { reveal, stagger, heading } = useReveal()
const rows = [
  { label: 'No built-in telemetry', body: 'GOAT does not send product analytics or usage reports home.' },
  { label: 'Local storage', body: 'Chats and local-provider memory are stored on your Mac.' },
  { label: 'Explicit connections', body: 'Configure engines, tools and memory services, with supported connections governed by JUDAS.' },
]
</script>

<template>
  <section id="privacy" class="relative scroll-mt-24 overflow-hidden py-12 sm:py-32">
    <div class="mx-auto grid max-w-6xl items-start gap-8 px-6 sm:gap-14 lg:grid-cols-2">
      <motion.div v-bind="reveal()">
        <p class="font-mono text-xs uppercase tracking-[0.2em] text-emerald-300">Privacy by design</p>
        <motion.h2 v-bind="heading(0.1)" class="mt-3 text-balance text-4xl font-semibold tracking-[-0.03em] sm:text-5xl">A clear boundary around your work.</motion.h2>
        <p class="mt-5 text-pretty text-lg text-muted-foreground">GOAT does not include analytics, advertising or automatic update checks. Chats and local-provider memory are stored on your Mac. When you connect an engine or service, the data needed for that work goes to the service you chose.</p>
        <p class="mt-6 text-sm leading-relaxed text-muted-foreground">Local engines can keep inference on your Mac. Remote engines, MCP servers, Hindsight, preview content and approved network-enabled commands can communicate beyond it. JUDAS is an application policy layer, not an OS firewall.</p>
        <div class="mt-7 flex flex-wrap gap-5 text-sm text-primary"><DocDialog doc="privacy"><button type="button" class="hover:underline">Read the privacy notice →</button></DocDialog><a :href="site.doc('JUDAS')" class="hover:underline">Review connection controls →</a></div>
      </motion.div>
      <motion.div v-bind="reveal(0.15)">
        <Card variant="glass" padding="none" class="overflow-hidden">
          <div class="flex items-center gap-2 border-b border-border px-5 py-4 text-xs text-muted-foreground"><i-hugeicons-security-check class="size-4" /> Privacy commitments</div>
          <ul class="divide-y divide-border"><motion.li v-for="(row, i) in rows" :key="row.label" v-bind="stagger(i, 0.06)" class="px-6 py-6"><h3 class="flex items-center gap-3 text-base font-semibold"><i-hugeicons-tick-02 class="size-4 text-emerald-300" />{{ row.label }}</h3><p class="mt-3 text-sm leading-relaxed text-muted-foreground">{{ row.body }}</p></motion.li></ul>
          <div class="border-t border-border bg-emerald-400/5 px-6 py-4 text-xs leading-relaxed text-muted-foreground">Understand the engine and services you configure. Their own data-handling policies also apply.</div>
        </Card>
      </motion.div>
    </div>
  </section>
</template>
