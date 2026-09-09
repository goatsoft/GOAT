<script setup lang="ts">
/**
 * Primary CTA: the aurora Button wrapped in a rotating blue→violet ring with a soft outer
 * glow and a shimmer sweep. CSS-only; the global reduced-motion rule freezes it.
 */
import { cn } from '@/lib/utils'
withDefaults(defineProps<{ href: string; label?: string; class?: string }>(), { label: 'Download for Mac' })
</script>

<template>
  <span :class="cn('ring-cta relative inline-flex rounded-full p-px', $props.class)">
    <Button variant="aurora" size="xl" :as="'a'" :href="href" class="relative z-10 overflow-hidden">
      <i-hugeicons-download-01 v-if="label === 'Download for Mac'" class="!size-5" />
      <i-hugeicons-arrow-up-right-01 v-else class="!size-5" /> {{ label }}
      <span class="shimmer pointer-events-none absolute inset-0 rounded-full" />
    </Button>
  </span>
</template>

<style scoped>
.ring-cta::before {
  content: ""; position: absolute; inset: -2px; border-radius: 9999px;
  background: conic-gradient(from var(--a, 0deg), rgba(58,160,255,0) 0%, #7cc4ff 25%, #e08cff 50%, #7a5cff 65%, rgba(58,160,255,0) 100%);
  animation: ring-spin 4s linear infinite;
}
.ring-cta::after {
  content: ""; position: absolute; inset: 0; border-radius: inherit; pointer-events: none;
  box-shadow: -6px -3px 22px rgba(58,160,255,.4), 6px 3px 24px rgba(180,75,255,.4);
  animation: ring-glow 4s linear infinite;
}
@keyframes ring-glow {
  0%, 100% { box-shadow: -6px -3px 22px rgba(58,160,255,.4), 6px 3px 24px rgba(180,75,255,.4); }
  50% { box-shadow: -6px -3px 22px rgba(180,75,255,.4), 6px 3px 24px rgba(58,160,255,.4); }
}
@property --a { syntax: "<angle>"; inherits: false; initial-value: 0deg; }
@keyframes ring-spin { to { --a: 360deg; } }
.shimmer {
  background: linear-gradient(110deg, transparent 30%, rgba(255,255,255,.18) 50%, transparent 70%);
  background-size: 250% 100%;
  background-repeat: no-repeat;
  animation: shimmer 3.2s ease-in-out infinite;
}
@keyframes shimmer { from { background-position: 120% 0; } to { background-position: -120% 0; } }
</style>
