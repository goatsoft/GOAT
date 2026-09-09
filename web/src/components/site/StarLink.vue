<script setup lang="ts">
/**
 * "Star on GitHub" link. On hover the star fills gold, pops, throws sparkles, then settles.
 * CSS-only, so the global reduced-motion rule quiets it.
 */
import { cn } from '@/lib/utils'
withDefaults(defineProps<{ href: string; label?: string; size?: 'sm' | 'lg'; class?: string }>(), { label: 'Star', size: 'sm' })
const sparks = [0, 60, 120, 180, 240, 300]
</script>

<template>
  <a
    :href="href" target="_blank" rel="noopener"
    :class="cn(
      'star group inline-flex items-center gap-2 rounded-full font-semibold text-foreground transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60',
      size === 'sm' ? 'h-9 px-3.5 text-sm text-muted-foreground hover:bg-white/5 hover:text-foreground' : 'h-14 border border-border px-8 text-lg hover:border-white/25 hover:bg-white/5',
      $props.class,
    )"
  >
    <span class="relative inline-grid place-items-center" :class="size === 'sm' ? 'size-4' : 'size-5'">
      <svg viewBox="0 0 24 24" class="star-icon size-full" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round">
        <path d="M12 2.5l2.9 6.2 6.8.8-5 4.7 1.3 6.7L12 17.6 5.9 20.9l1.3-6.7-5-4.7 6.8-.8z" />
      </svg>
      <span
        v-for="a in sparks" :key="a"
        class="spark pointer-events-none absolute left-1/2 top-1/2 size-1 rounded-full bg-amber-300"
        :style="{ '--a': a + 'deg' }"
      />
    </span>
    <span>{{ label }}</span>
  </a>
</template>

<style scoped>
.star-icon { transform-origin: 50% 55%; transition: fill .25s, stroke .25s, filter .25s; }
.star:hover .star-icon {
  fill: #fbbf24; stroke: #fbbf24;
  filter: drop-shadow(0 0 6px rgba(251, 191, 36, .8));
  animation: star-pop .7s cubic-bezier(.34, 1.56, .64, 1) both;
}
@keyframes star-pop {
  0% { transform: scale(1) rotate(0deg); }
  40% { transform: scale(1.55) rotate(-18deg); }
  70% { transform: scale(.92) rotate(6deg); }
  100% { transform: scale(1.08) rotate(0deg); }
}
.spark { opacity: 0; transform: translate(-50%, -50%) rotate(var(--a)) translateY(0) scale(0); }
.star:hover .spark { animation: spark-fly .8s ease-out .12s both; }
@keyframes spark-fly {
  0% { opacity: 0; transform: translate(-50%, -50%) rotate(var(--a)) translateY(-2px) scale(0); }
  25% { opacity: 1; transform: translate(-50%, -50%) rotate(var(--a)) translateY(-9px) scale(1.2); }
  100% { opacity: 0; transform: translate(-50%, -50%) rotate(var(--a)) translateY(-18px) scale(0); }
}
</style>
