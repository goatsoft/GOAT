<script setup lang="ts">
import { motion } from 'motion-v'
const site = useSite()
const { reveal, stagger, heading } = useReveal()

/**
 * Ken Burns on hover: a slow, looping zoom-and-pan through a few waypoints (screensaver
 * style). On leave we freeze the current frame and glide back, so nothing snaps.
 */
function enter(e: PointerEvent) {
  const img = (e.currentTarget as HTMLElement).querySelector<HTMLElement>('.pan-img')
  if (!img) return
  img.style.transform = ''
  img.classList.add('live')
}
function leave(e: PointerEvent) {
  const img = (e.currentTarget as HTMLElement).querySelector<HTMLElement>('.pan-img')
  if (!img) return
  const now = getComputedStyle(img).transform
  img.classList.remove('live')
  img.style.transform = now === 'none' ? '' : now
  void img.offsetWidth // commit the frozen frame, then let the transition carry it home
  img.style.transform = ''
}

const themes = [
  { id: 'system', name: 'System', img: asset('img/theme-system.webp'), pos: '68% 50%', desc: 'Follows your Mac’s appearance.', tokens: ['#000000', '#3AA0FF', '#A855F7'] },
  { id: 'light', name: 'Light', img: asset('img/theme-light.webp'), pos: '84% 50%', desc: 'A clear, bright workspace.', tokens: ['#F5F6FA', '#2563C8', '#7542CB'] },
  { id: 'pasture', name: 'Pasture', img: asset('img/theme-pasture.webp'), pos: '50% 50%', desc: 'Warm paper, meadow greens.', tokens: ['#F6F3EC', '#496F2B', '#83582F'] },
  { id: 'midnight', name: 'Midnight', img: asset('img/theme-midnight.webp'), pos: '45% 50%', desc: 'Aurora over the ridge.', tokens: ['#0A0B14', '#3AA0FF', '#B44BFF'] },
]
</script>

<template>
  <section id="themes" class="mx-auto max-w-6xl scroll-mt-24 px-6 py-12 sm:py-32">
    <motion.div v-bind="reveal()" class="mx-auto max-w-2xl text-center">
      <p class="font-mono text-xs uppercase tracking-[0.2em] text-primary">Themes and appearance</p>
      <motion.h2 v-bind="heading(0.1)" class="mt-3 text-balance text-4xl font-semibold tracking-[-0.03em] sm:text-5xl">Make the workspace yours.</motion.h2>
      <p class="mt-2 text-pretty text-lg text-muted-foreground sm:mt-4">
        Follow your Mac’s appearance or choose a built-in theme. Adjust reading fonts and sizes, and import a custom theme when you want a different view of your workspace.
      </p>
    </motion.div>

    <div class="mt-8 grid sm:mt-14 gap-4 sm:grid-cols-2 lg:grid-cols-4">
      <motion.div v-for="(t, i) in themes" :key="t.id" v-bind="stagger(i)">
        <a
          :href="site.doc('Appearance')"
          class="pan group relative block overflow-hidden rounded-2xl ring-hair"
          :class="i % 2 ? 'pan-r' : 'pan-l'"
          @pointerenter="enter" @pointerleave="leave"
        >
          <img
            :src="t.img" :alt="`${t.name} theme`" loading="lazy"
            class="pan-img aspect-[12/5] w-full object-cover sm:aspect-[4/5]"
            :style="{ objectPosition: t.pos }"
          />
          <div class="absolute inset-0 bg-[linear-gradient(180deg,transparent_45%,rgba(10,11,20,.92))]" />
          <div class="absolute inset-x-0 bottom-0 grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 gap-y-0.5 p-5 sm:gap-y-1">
            <span class="col-span-2 text-lg font-semibold sm:col-span-1">{{ t.name }}</span>
            <span class="col-start-2 row-start-2 flex gap-1 sm:row-start-1">
              <span v-for="c in t.tokens" :key="c" class="size-3.5 rounded-full ring-1 ring-white/20" :style="{ background: c }" />
            </span>
            <p class="col-start-1 row-start-2 text-sm text-goat-muted sm:col-span-2">{{ t.desc }}</p>
          </div>
        </a>
      </motion.div>
    </div>
  </section>
</template>

<style scoped>
.pan-img {
  transform: scale(1) translate(0, 0);
  transform-origin: 50% 50%;
  transition: transform 1.2s cubic-bezier(.22, 1, .36, 1);
  will-change: transform;
}
/* Waypoints drift diagonally through the scene; alternate cards mirror the path. */
.pan-l .pan-img.live { animation: burns-l 12s ease-in-out infinite alternate; }
.pan-r .pan-img.live { animation: burns-r 12s ease-in-out infinite alternate; }
@keyframes burns-l {
  0%   { transform: scale(1.02) translate(0, 0); }
  30%  { transform: scale(1.14) translate(3%, -2%); }
  60%  { transform: scale(1.22) translate(-1%, 3%); }
  100% { transform: scale(1.3) translate(-4%, -3%); }
}
@keyframes burns-r {
  0%   { transform: scale(1.02) translate(0, 0); }
  30%  { transform: scale(1.14) translate(-3%, -2%); }
  60%  { transform: scale(1.22) translate(1%, 3%); }
  100% { transform: scale(1.3) translate(4%, -3%); }
}
</style>
