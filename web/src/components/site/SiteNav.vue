<script setup lang="ts">
import { RouterLink } from 'vue-router'
const site = useSite()
const scrolled = ref(false)
const open = ref(false)
const menuButton = ref<HTMLButtonElement | null>(null)
const router = useRouter()
function closeMenu() {
  open.value = false
  menuButton.value?.focus()
}
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
    class="fixed inset-x-0 top-0 z-50 py-3 md:transition-[padding] md:duration-500"
    :class="scrolled ? 'md:py-2' : 'md:py-4'"
  >
    <div class="relative mx-auto max-w-6xl px-4" @keydown.esc="closeMenu">
      <nav
        class="flex items-center justify-between rounded-full px-4 py-2 md:transition-all md:duration-500"
        :class="scrolled ? 'glass shadow-[0_10px_40px_-20px_rgba(0,0,0,.8)]' : 'border border-transparent'"
      >
        <RouterLink to="/" class="flex items-center gap-2.5 font-semibold tracking-tight">
          <img :src="asset('img/goat-dark.webp')" alt="" class="size-12 md:size-9 drop-shadow-[0_4px_14px_rgba(122,92,255,.55)]" />
          <span class="text-brand text-2xl md:text-lg font-bold tracking-tight">GOAT</span>
        </RouterLink>

        <div class="hidden items-center gap-7 text-sm md:flex" :class="scrolled ? 'text-muted-foreground' : 'text-foreground'">
          <component
            :is="l.external ? 'a' : RouterLink" v-for="l in links" :key="l.to"
            v-bind="l.external ? { href: l.to } : { to: l.to }"
            class="transition-colors hover:text-foreground"
          >{{ l.label }}</component>
        </div>

        <div class="flex items-center gap-2">
          <Button variant="ghost" size="icon" :as="'a'" :href="site.repo" target="_blank" rel="noopener" aria-label="GitHub" class="hidden md:inline-flex" :class="scrolled ? 'text-muted-foreground' : 'text-foreground'">
            <i-simple-icons-github />
          </Button>
          <Button size="sm" :as="'a'" :href="site.primaryHref" class="hidden sm:inline-flex">
            <i-hugeicons-arrow-up-right-01 /> {{ site.releaseAvailable ? 'Download' : 'Get started' }}
          </Button>
          <button
            ref="menuButton" type="button"
            class="inline-flex size-12 shrink-0 touch-manipulation items-center justify-center rounded-full border border-border bg-background/80 text-foreground focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring md:hidden [&_svg]:pointer-events-none [&_svg]:size-6"
            :aria-label="open ? 'Close menu' : 'Open menu'" :aria-expanded="open" aria-controls="mobile-navigation"
            @click="open = !open"
          >
            <i-hugeicons-menu-01 v-if="!open" aria-hidden="true" /><i-hugeicons-cancel-01 v-else aria-hidden="true" />
          </button>
        </div>
      </nav>

      <nav
        v-if="open" id="mobile-navigation" aria-label="Mobile navigation"
        class="absolute inset-x-4 top-full mt-2 flex max-h-[calc(100dvh-7rem)] flex-col gap-1 overflow-y-auto overscroll-contain rounded-2xl border border-border bg-popover p-2 shadow-xl md:hidden"
      >
        <a
          v-for="l in links" :key="l.to" :href="l.external ? l.to : router.resolve(l.to).href"
          class="flex min-h-12 touch-manipulation items-center rounded-xl px-4 py-3 text-base text-foreground focus-visible:outline-2 focus-visible:outline-ring active:bg-accent"
          @click="open = false"
        >{{ l.label }}</a>
      </nav>
    </div>
  </header>
</template>
