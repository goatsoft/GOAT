<script setup lang="ts">
/**
 * Docs home hero: the landing page's hero, condensed. Masthead (the goat mark with
 * its sampled glow) on the left, copy on the right, the Midnight art and a local
 * aurora behind, all masked so it dissolves into the page instead of ending in a
 * line. Replaces VitePress's VPHero (frontmatter carries no `hero`).
 */
import { ref, onMounted, watchEffect } from 'vue'
import { useData, withBase } from 'vitepress'
import AuroraCanvas from '@/components/fx/AuroraCanvas.vue'
import Masthead from '@/components/site/Masthead.vue'
import { useSite } from '@/composables/useSite'

const site = useSite()
const { isDark } = useData()
// SSR renders dark; production hydration does not patch mismatched attributes, so
// anything keyed on the theme flips only after mount. Theme-only styling lives in CSS.
const dark = ref(true)
onMounted(() => watchEffect(() => { dark.value = isDark.value }))
const actions = [
  { theme: 'brand', text: 'Getting Started', link: '/Getting-Started' },
  { theme: 'alt', text: 'Understand GOAT', link: '/overview/GOAT' },
  { theme: 'alt', text: 'Reference', link: '/reference/' },
]
</script>

<template>
  <section class="goat-hero">
    <div class="goat-hero-bg" aria-hidden="true">
      <img :src="withBase('/img/midnight.webp')" alt="" class="goat-hero-art" fetchpriority="high" />
    </div>
    <div class="goat-hero-clouds" aria-hidden="true">
      <AuroraCanvas
        hue="aurora" fade
        :intensity="dark ? 0.3 : 0.35"
        :scale="1.1" :speed="0.09" :seed="3" :stretch="0.45"
        class="goat-aurora"
      />
    </div>

    <div class="goat-hero-inner">
      <div class="goat-hero-mark">
        <Masthead :src="withBase(dark ? '/img/goat-dark.webp' : '/img/goat-light.webp')" />
      </div>
      <div class="goat-hero-copy">
        <h1 class="goat-hero-title">Make local AI part of <span class="goat-hero-accent">your workflow.</span></h1>
        <p class="goat-hero-tagline">Set up GOAT, organise a project and work with models, tools and memory. Overviews first, practical guides next, exact reference when you need it.</p>
        <p v-if="!site.releaseAvailable" class="goat-hero-tagline"><a :href="withBase('/PUBLIC-PREVIEW')">{{ site.releaseLabel }} · Public source preview</a>. Build locally and help test the first release.</p>
        <div class="goat-hero-actions">
          <template v-for="a in actions" :key="a.link">
            <!-- The brand CTA wears the landing site's DownloadButton ring: rotating
                 blue→violet conic ring, blurred glow, shimmer sweep. CSS-only. -->
            <span v-if="a.theme === 'brand'" class="goat-ring-cta">
              <a :href="withBase(a.link)" class="goat-btn brand">{{ a.text }}<span class="goat-shimmer" aria-hidden="true" /></a>
            </span>
            <a v-else :href="withBase(a.link)" class="goat-btn" :class="a.theme">{{ a.text }}</a>
          </template>
        </div>
      </div>
    </div>
  </section>
</template>
