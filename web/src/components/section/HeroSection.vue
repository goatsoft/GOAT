<script setup lang="ts">
import { motion } from 'motion-v'
import { usesTouchInput } from '@/lib/browser-input'
const site = useSite()
const touch = usesTouchInput()
const scrollY = touch ? useMotionValue(0) : useScroll().scrollY
const bgY = useTransform(scrollY, [0, 900], [0, 180])
const goatY = useTransform(scrollY, [0, 900], [0, -60])
const fade = useTransform(scrollY, [0, 500], [1, 0])
const windowY = useTransform(scrollY, [0, 800], [0, -40])

const ease = [0.22, 1, 0.36, 1] as const
</script>

<template>
  <section class="hero-section relative isolate overflow-hidden pt-12 pb-12 sm:pb-16 sm:pt-28">
    <!-- Keep the mountain artwork behind the mark; mobile framing is set below. -->
    <motion.div class="hero-backdrop pointer-events-none absolute inset-x-0 -top-24 -z-20 h-[120vh]" :style="touch ? undefined : { y: bgY }">
      <img
        :src="asset('img/midnight.webp')" alt="" fetchpriority="high"
        class="size-full origin-center -translate-x-[7.6%] scale-[1.16] object-cover object-[50%_40%] opacity-75 [mask-image:linear-gradient(180deg,#000_30%,transparent_95%)]"
      />
    </motion.div>
    <div class="pointer-events-none absolute inset-0 -z-10 bg-[radial-gradient(70%_50%_at_50%_0%,rgba(10,11,20,0)_0%,rgba(10,11,20,.55)_60%,var(--goat-bg)_100%)]" />
    <!-- Static purple mist stays visible on touch devices without a graphics context. -->
    <div class="hero-mobile-haze pointer-events-none" aria-hidden="true" />
    <div class="pointer-events-none absolute inset-x-0 top-[52vh] -z-10 h-[85vh] [mask-image:linear-gradient(to_bottom,transparent,#000_25%,#000_65%,transparent)]" aria-hidden="true">
      <AuroraCanvas hue="aurora" fade :intensity="0.38" :scale="1.1" :speed="0.09" :seed="3" :stretch="0.45" />
    </div>
    <!-- Aurora ribbons -->
    <div class="pointer-events-none absolute left-1/2 top-24 -z-10 h-[520px] w-[900px] -translate-x-1/2 animate-aurora rounded-full bg-[radial-gradient(closest-side,rgba(58,160,255,.22),transparent)] blur-3xl" />
    <div class="pointer-events-none absolute left-1/2 top-40 -z-10 h-[420px] w-[700px] -translate-x-1/3 animate-aurora rounded-full bg-[radial-gradient(closest-side,rgba(180,75,255,.2),transparent)] blur-3xl [animation-delay:-9s]" />

    <div class="mx-auto max-w-6xl px-6 text-center">
      <!-- the art has ~25% transparent padding; pull the headline up so the visual gap reads right -->
      <motion.div :style="touch ? undefined : { y: goatY, opacity: fade }" class="mx-auto -mb-8 w-fit sm:-mb-12 md:-mb-16">
        <motion.div
          class="size-64 sm:size-80 md:size-[26rem]"
          :initial="touch ? false : { opacity: 0, scale: 0.6, filter: 'blur(12px)' }"
          :animate="{ opacity: 1, scale: 1, filter: 'blur(0px)' }"
          :transition="{ duration: 1.1, ease }"
        >
          <Masthead :src="asset('img/goat-dark.webp')" />
        </motion.div>
      </motion.div>

      <motion.h1
        class="mx-auto max-w-4xl text-balance text-5xl font-semibold leading-[1.02] tracking-[-0.03em] sm:text-7xl md:text-8xl [text-shadow:0_2px_30px_rgba(0,0,0,.5)]"
        :initial="touch ? false : { opacity: 0, y: 24, filter: 'blur(8px)' }" :animate="{ opacity: 1, y: 0, filter: 'blur(0px)' }"
        :transition="{ duration: 0.9, delay: 0.3, ease }"
      >
        Your private AI<br /><span class="text-aurora">workspace for Mac.</span>
      </motion.h1>

      <motion.p
        class="mx-auto mt-7 max-w-2xl text-pretty text-lg text-muted-foreground sm:text-xl"
        :initial="touch ? false : { opacity: 0, y: 16 }" :animate="{ opacity: 1, y: 0 }" :transition="{ duration: 0.8, delay: 0.5, ease }"
      >
        Put local models to work with project files, tools and memory in one native Mac app. Keep your work organised, guide the next step and choose what GOAT can access.
      </motion.p>

      <p class="mt-5 text-sm text-muted-foreground">No GOAT account. No built-in telemetry. Connections you configure and control.</p>
      <p v-if="!site.releaseAvailable" class="mt-3 text-sm text-muted-foreground"><a :href="site.doc('PUBLIC-PREVIEW')" class="text-primary hover:underline">{{ site.releaseLabel }} · Public source preview</a>. Build locally; Mac downloads are coming after release testing.</p>

      <motion.div :initial="touch ? false : { opacity: 0, y: 12 }" :animate="{ opacity: 1, y: 0 }" :transition="{ duration: 0.7, delay: 0.6, ease }" class="mt-9 flex justify-center">
        <HeroBadge />
      </motion.div>

      <motion.div
        class="mt-6 flex flex-col items-center justify-center gap-3 sm:flex-row"
        :initial="touch ? false : { opacity: 0, y: 16 }" :animate="{ opacity: 1, y: 0 }" :transition="{ duration: 0.8, delay: 0.7, ease }"
      >
        <DownloadButton :href="site.primaryHref" :label="site.primaryLabel" />
        <!-- Same metrics as StarLink size="lg" so the two secondary CTAs match. -->
        <a :href="site.docs" class="glass inline-flex h-14 items-center gap-2 rounded-full border-0 px-8 text-lg font-semibold text-foreground transition-colors hover:bg-white/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60">
          <i-hugeicons-book-open-01 class="size-5" /> Documentation
        </a>
        <StarLink :href="site.repo" label="Star on GitHub" size="lg" class="glass border-0 hover:bg-white/10" />
      </motion.div>
      <motion.p class="mt-4 font-mono text-xs text-muted-foreground/70" :initial="touch ? false : { opacity: 0 }" :animate="{ opacity: 1 }" :transition="{ delay: 1 }">
        Bring a compatible local engine. <a :href="site.omlx" class="text-primary hover:underline">oMLX</a> · <a :href="site.doc('Engines')" class="text-primary hover:underline">Engine setup</a>.
      </motion.p>
    </div>

    <!-- Hero window -->
    <motion.div
      class="mx-auto mt-10 max-w-5xl sm:mt-20 px-4 [perspective:1600px]"
      :style="touch ? undefined : { y: windowY }"
      :initial="touch ? false : { opacity: 0, y: 80, rotateX: 14, scale: 0.94 }"
      :animate="{ opacity: 1, y: 0, rotateX: 0, scale: 1 }"
      :transition="{ duration: 1.2, delay: 0.7, ease }"
    >
      <div class="relative">
        <div class="pointer-events-none absolute -inset-x-10 -top-10 -z-10 h-64 bg-[radial-gradient(60%_100%_at_50%_0%,rgba(122,92,255,.35),transparent_70%)] blur-2xl" />
        <ProductMock scene="hero" />
      </div>
    </motion.div>
  </section>
</template>

<style scoped>
.hero-mobile-haze { display:none }
@media (hover: none), (pointer: coarse) {
  .hero-backdrop { top:0; height:760px }
  .hero-backdrop img { transform:none; object-position:56% top; opacity:.85 }
  .hero-mobile-haze {
    display:block; position:absolute; z-index:-10; inset:300px -25% auto; height:850px;
    background:radial-gradient(ellipse at 50% 38%,#7a3edb59,transparent 62%),radial-gradient(ellipse at 75% 65%,#ad48dc33,transparent 60%);
    mask-image:linear-gradient(to bottom,transparent,#000 20%,#000 80%,transparent);
  }
  .hero-section .animate-aurora { animation:none }
  /* Radial gradients already have soft edges; extra blur stalls iOS compositing. */
  .hero-section .blur-3xl, .hero-section .blur-2xl { filter:none }
}
</style>
