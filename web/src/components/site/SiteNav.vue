<script setup lang="ts">
import { motion } from 'motion-v'
import { RouterLink } from 'vue-router'
const site = useSite()
const scrolled = ref(false)
const open = ref(false)
const onScroll = () => (scrolled.value = window.scrollY > 24)
onMounted(() => { onScroll(); window.addEventListener('scroll', onScroll, { passive: true }) })
onUnmounted(() => window.removeEventListener('scroll', onScroll))

// Documentation has its own site, so navigation uses an ordinary link.
const links = [
  { label: 'Features', to: '/#features' },
  { label: 'Privacy', to: '/#privacy' },
  { label: 'Themes', to: '/#themes' },
  { label: 'Documentation', to: site.docs, external: true },
  { label: site.releaseAvailable ? 'Download' : 'Get started', to: '/#download' },
]
</script>

<template>
  <header
    class="fixed inset-x-0 top-0 z-50 transition-all duration-500"
    :class="scrolled ? 'py-2' : 'py-4'"
  >
    <div class="mx-auto max-w-6xl px-4">
      <nav
        class="flex items-center justify-between rounded-full px-4 py-2 transition-all duration-500"
        :class="scrolled ? 'glass shadow-[0_10px_40px_-20px_rgba(0,0,0,.8)]' : 'border border-transparent'"
      >
        <RouterLink to="/" class="flex items-center gap-2.5 font-semibold tracking-tight">
          <img :src="asset('img/goat-dark.webp')" alt="" class="size-9 drop-shadow-[0_4px_14px_rgba(122,92,255,.55)]" />
          <span class="text-brand text-lg font-bold tracking-tight">GOAT</span>
        </RouterLink>

        <div class="hidden items-center gap-7 text-sm text-muted-foreground md:flex">
          <component
            :is="l.external ? 'a' : RouterLink" v-for="l in links" :key="l.to"
            v-bind="l.external ? { href: l.to } : { to: l.to }"
            class="transition-colors hover:text-foreground"
          >{{ l.label }}</component>
        </div>

        <div class="flex items-center gap-2">
          <Button variant="ghost" size="icon" :as="'a'" :href="site.repo" target="_blank" rel="noopener" aria-label="GitHub" class="hidden md:inline-flex">
            <i-simple-icons-github />
          </Button>
          <Button size="sm" :as="'a'" :href="site.primaryHref" class="hidden sm:inline-flex">
            <i-hugeicons-arrow-up-right-01 /> {{ site.releaseAvailable ? 'Download' : 'Get started' }}
          </Button>
          <Button variant="ghost" size="icon" class="md:hidden" aria-label="Menu" :aria-expanded="open" @click="open = !open">
            <i-hugeicons-menu-01 v-if="!open" /><i-hugeicons-cancel-01 v-else />
          </Button>
        </div>
      </nav>

      <AnimatePresence>
        <motion.div
          v-if="open"
          :initial="{ opacity: 0, y: -8 }"
          :animate="{ opacity: 1, y: 0 }"
          :exit="{ opacity: 0, y: -8 }"
          class="glass mt-2 flex flex-col gap-1 rounded-2xl p-2 md:hidden"
        >
          <component
            :is="l.external ? 'a' : RouterLink" v-for="l in links" :key="l.to"
            v-bind="l.external ? { href: l.to } : { to: l.to }"
            class="rounded-xl px-4 py-3 text-sm hover:bg-white/5"
            @click="open = false"
          >{{ l.label }}</component>
        </motion.div>
      </AnimatePresence>
    </div>
  </header>
</template>
