<script setup lang="ts">
import { motion } from 'motion-v'
const root = ref<HTMLElement | null>(null)
const { active } = useScrollSteps(root, 0.5)
const { reveal, heading } = useReveal()

const site = useSite()
const steps = [
  {
    "key": "coding",
    "eyebrow": "Coding tools",
    "title": "Work on code. Stay in control.",
    "body": "Ask your model to inspect files, make targeted edits and run approved commands inside a Pen. Expand grouped tool activity to see what happened, or use Lead to guide the next step while a chat is active.",
    "points": [
      "Scoped file and command permissions",
      "Non-interactive jobs with visible results",
      "Lead guidance after the current action"
    ],
    "guide": "how-to/WORK-ON-CODE",
    "link": "Work with coding tools"
  },
  {
    "key": "pens",
    "eyebrow": "Pens",
    "title": "Give each project a home.",
    "body": "A Pen brings related chats, project instructions and a workspace folder together. Set permissions for one chat or the Pen, then return to the same project context when you need it.",
    "points": [
      "Project instructions and linked files",
      "Individual Pen colours and emoji",
      "Access you can review and change"
    ],
    "guide": "how-to/CREATE-A-PEN",
    "link": "Create your first Pen"
  },
  {
    "key": "memory",
    "eyebrow": "Memory",
    "title": "Keep useful knowledge close.",
    "body": "Save and inspect reusable context with local memory providers, or connect a Hindsight service you manage. Global and Pen memory have separate scopes, so you can choose the context used for each workspace.",
    "points": [
      "Local Markdown and LLM Wiki providers",
      "Provider-specific browsing and maps",
      "Optional Hindsight integration"
    ],
    "guide": "Memory-and-Pens",
    "link": "Choose a memory provider"
  },
  {
    "key": "previews",
    "eyebrow": "Paddock previews",
    "title": "See what the model creates.",
    "body": "Open supported HTML, SVG, Markdown and Mermaid output in the Paddock. Compare the preview with its source, then save or open the result. Preview networking follows the connection policy you choose.",
    "points": [
      "Document previews alongside your work",
      "Bundled Mermaid rendering",
      "Controls for preview network access"
    ],
    "guide": "how-to/PREVIEWS",
    "link": "Use previews"
  },
  {
    "key": "extensions",
    "eyebrow": "Extensions and skills",
    "title": "Bring the right tools to the task.",
    "body": "Manage built-in extensions, connect MCP servers and add reusable skills. GOATed packages distribute declarative content, while tools follow the permissions and capabilities provided by GOAT or your configured services.",
    "points": [
      "Optional built-ins and their settings",
      "MCP servers over stdio or HTTP",
      "Reusable instructions and packages"
    ],
    "guide": "Extensions",
    "link": "Explore extensions and skills"
  },
  {
    "key": "connections",
    "eyebrow": "Connection controls",
    "title": "Choose what can connect.",
    "body": "Use JUDAS to allow configured connections, restrict supported connections to local networks or block them. Review activity alongside those settings. External tools and services have their own data-handling behavior.",
    "points": [
      "Configured, local-network and blocked modes",
      "Policy for supported app connections",
      "Activity history for inspection"
    ],
    "guide": "JUDAS",
    "link": "Understand connection policies"
  }
] as const

</script>

<template>
  <section id="features" class="relative mx-auto max-w-6xl scroll-mt-24 px-6 py-12 sm:py-24">
    <motion.div v-bind="reveal()" class="mx-auto mb-8 max-w-2xl text-center sm:mb-24">
      <p class="font-mono text-xs uppercase tracking-[0.2em] text-primary">Features</p>
      <motion.h2 v-bind="heading(0.1)" class="mt-3 text-balance text-4xl font-semibold tracking-[-0.03em] sm:text-5xl">
        From conversation to project work.
      </motion.h2>
    </motion.div>

    <div ref="root" class="grid gap-10 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:gap-16">
      <!-- Copy column -->
      <div class="order-2 space-y-12 sm:space-y-0 lg:order-1">
        <div
          v-for="(s, i) in steps" :key="s.key" :data-step="i" :id="`feature-${s.key}`"
          class="scroll-mt-24 flex flex-col justify-center transition-opacity duration-500 sm:min-h-[70vh] sm:py-10 lg:min-h-[80vh] lg:justify-start lg:pt-0"
          :class="active === i ? 'opacity-100' : 'lg:opacity-30'"
        >
          <p class="font-mono text-xs uppercase tracking-[0.2em] text-primary">{{ s.eyebrow }}</p>
          <h3 class="mt-3 text-balance text-3xl font-semibold tracking-[-0.02em] sm:text-4xl">{{ s.title }}</h3>
          <p class="mt-4 text-pretty text-lg text-muted-foreground">{{ s.body }}</p>
          <ul class="mt-6 space-y-2">
            <li v-for="p in s.points" :key="p" class="flex items-center gap-2.5 text-sm">
              <i-hugeicons-tick-02 class="size-4 text-emerald-300" /> {{ p }}
            </li>
          </ul>
          <a :href="site.doc(s.guide)" class="mt-5 inline-flex items-center gap-2 text-sm font-medium text-primary hover:underline">{{ s.link }} <span aria-hidden="true">→</span></a>
          <!-- On small screens the visual travels with its copy. -->
          <div class="mt-8 lg:hidden">
            <ProductMock :scene="s.key" />
          </div>
        </div>
      </div>

      <!-- Sticky visual column -->
      <div class="order-1 hidden lg:order-2 lg:block">
        <div class="sticky top-28">
          <div class="relative [perspective:1600px]">
            <div class="pointer-events-none absolute -inset-10 -z-10 rounded-full bg-[radial-gradient(closest-side,rgba(122,92,255,.28),transparent)] blur-3xl" />
            <AnimatePresence mode="wait">
              <motion.div
                :key="active"
                :initial="{ opacity: 0, y: 30, rotateX: 8, scale: 0.97 }"
                :animate="{ opacity: 1, y: 0, rotateX: 0, scale: 1 }"
                :exit="{ opacity: 0, y: -24, rotateX: -6, scale: 0.98 }"
                :transition="{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }"
              >
                <ProductMock :scene="steps[active]!.key" />
              </motion.div>
            </AnimatePresence>
          </div>
          <div class="mt-5 flex justify-center gap-2">
            <span v-for="(s, i) in steps" :key="s.key" class="h-1 rounded-full transition-all duration-500" :class="active === i ? 'w-8 bg-primary' : 'w-3 bg-white/15'" />
          </div>
        </div>
      </div>
    </div>
  </section>
</template>
