<script setup lang="ts">
/**
 * The hero masthead: the goat mark with a layered drop shadow and an animated glow
 * whose colors are sampled from the artwork itself (left horn, right horn, center),
 * so the halo always matches the logo's own color profile. Falls back to the
 * Midnight accents until the image has loaded. The mark itself never moves.
 */
import { cn } from '@/lib/utils'
const props = withDefaults(defineProps<{ src: string; class?: string }>(), {})

const colors = ref({ left: 'rgb(58 160 255)', right: 'rgb(180 75 255)', mid: 'rgb(122 92 255)' })

function sample(img: HTMLImageElement) {
  const n = 96
  const c = document.createElement('canvas'); c.width = n; c.height = n
  const ctx = c.getContext('2d', { willReadFrequently: true })
  if (!ctx) return
  ctx.drawImage(img, 0, 0, n, n)
  const data = ctx.getImageData(0, 0, n, n).data
  const acc = { left: [0, 0, 0, 0], right: [0, 0, 0, 0], mid: [0, 0, 0, 0] }
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
    const i = (y * n + x) * 4
    const [r, g, b, a] = [data[i]!, data[i + 1]!, data[i + 2]!, data[i + 3]!]
    if (a < 128) continue
    const max = Math.max(r, g, b), min = Math.min(r, g, b)
    const sat = max === 0 ? 0 : (max - min) / max
    const w = sat * sat * (max / 255) // weight vivid, bright pixels
    if (w < 0.05) continue
    const bucket = x < n * 0.38 ? acc.left : x > n * 0.62 ? acc.right : acc.mid
    bucket[0] += r * w; bucket[1] += g * w; bucket[2] += b * w; bucket[3] += w
  }
  const rgb = (v: number[]) => v[3]! > 0 ? `rgb(${Math.round(v[0]! / v[3]!)} ${Math.round(v[1]! / v[3]!)} ${Math.round(v[2]! / v[3]!)})` : null
  colors.value = {
    left: rgb(acc.left) ?? colors.value.left,
    right: rgb(acc.right) ?? colors.value.right,
    mid: rgb(acc.mid) ?? colors.value.mid,
  }
}

const img = ref<HTMLImageElement | null>(null)
onMounted(() => {
  const el = img.value
  if (!el) return
  const go = () => { try { sample(el) } catch { /* cross-origin or decode issue: keep fallback */ } }
  el.complete && el.naturalWidth ? go() : el.addEventListener('load', go, { once: true })
})
</script>

<template>
  <div :class="cn('masthead relative grid place-items-center', $props.class)" :style="{ '--gl': colors.left, '--gr': colors.right, '--gm': colors.mid }">
    <!-- glow layers, behind the mark -->
    <span class="glow glow-l" aria-hidden="true" />
    <span class="glow glow-r" aria-hidden="true" />
    <span class="glow glow-m" aria-hidden="true" />
    <img ref="img" :src="src" alt="GOAT" class="mark relative size-full" />
  </div>
</template>

<style scoped>
.mark {
  filter:
    drop-shadow(0 30px 40px rgba(0, 0, 0, .75))
    drop-shadow(0 12px 18px rgba(0, 0, 0, .5))
    drop-shadow(0 0 30px color-mix(in oklab, var(--gm) 45%, transparent));
}
.glow {
  position: absolute; border-radius: 9999px; filter: blur(38px); pointer-events: none;
  mix-blend-mode: screen; will-change: transform, opacity;
}
.glow-l { left: -6%; top: 4%; width: 68%; height: 72%; background: radial-gradient(closest-side, var(--gl), transparent 72%); animation: breathe-l 7s ease-in-out infinite; }
.glow-r { right: -6%; top: 4%; width: 68%; height: 72%; background: radial-gradient(closest-side, var(--gr), transparent 72%); animation: breathe-r 7s ease-in-out infinite; animation-delay: -3.5s; }
.glow-m { left: 18%; top: 28%; width: 64%; height: 66%; background: radial-gradient(closest-side, var(--gm), transparent 70%); animation: breathe-m 9s ease-in-out infinite; animation-delay: -2s; }
@media (hover: none), (pointer: coarse) {
  .mark, .glow { filter:none }
}
@keyframes breathe-l {
  0%, 100% { opacity: .7; transform: translate(0, 0) scale(1); }
  50% { opacity: 1; transform: translate(-6%, 4%) scale(1.25); }
}
@keyframes breathe-r {
  0%, 100% { opacity: .7; transform: translate(0, 0) scale(1); }
  50% { opacity: 1; transform: translate(6%, 4%) scale(1.25); }
}
@keyframes breathe-m {
  0%, 100% { opacity: .35; transform: translate(0, 6%) scale(.9); }
  50% { opacity: .8; transform: translate(0, -4%) scale(1.15); }
}
</style>
