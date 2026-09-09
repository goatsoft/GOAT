<script setup lang="ts">
/**
 * Default layout plus the GOAT atmosphere: one fixed aurora behind everything
 * (the same WGSL/GLSL shader the landing page runs), the landing page's hero
 * condensed on the docs home, the release badge beside the wordmark, and a reveal when the page
 * content swaps on navigation. AuroraCanvas handles WebGPU → WebGL2 → CSS itself
 * and freezes under prefers-reduced-motion.
 */
import { nextTick, watch } from 'vue'
import { useData, useRoute } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import AuroraCanvas from '@/components/fx/AuroraCanvas.vue'
import ReleaseBadge from './components/ReleaseBadge.vue'
import GoatHero from './components/GoatHero.vue'

const { isDark } = useData()
const route = useRoute()

// Replay the content reveal on each navigation: a short-lived class on <html>
// that goat.css animates (.goat-entering .vp-doc). No-op under reduced motion.
let timer = 0
watch(() => route.path, async () => {
  await nextTick()
  const el = document.documentElement
  el.classList.remove('goat-entering'); void el.offsetWidth
  el.classList.add('goat-entering')
  clearTimeout(timer); timer = window.setTimeout(() => el.classList.remove('goat-entering'), 900)
})
</script>

<template>
  <DefaultTheme.Layout>
    <template #layout-top>
      <AuroraCanvas
        fixed hue="aurora"
        :intensity="isDark ? 0.22 : 0.10"
        :scale="1.0" :speed="0.04" :parallax="0.2"
        class="goat-aurora goat-aurora-page"
      />
    </template>

    <template #home-hero-before>
      <GoatHero />
    </template>

    <template #nav-bar-title-after>
      <ReleaseBadge />
    </template>
  </DefaultTheme.Layout>
</template>
