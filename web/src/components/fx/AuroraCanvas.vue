<script setup lang="ts">
/**
 * GPU aurora. WebGPU when the browser has it, WebGL2 otherwise, and a static CSS
 * gradient when neither is available. Reduced motion renders a single still frame.
 *
 * Renders at a capped internal resolution, pauses when off-screen or in a hidden tab, and never intercepts input.
 */
import { PALETTES } from '@/lib/aurora-shaders'
import { createAuroraRenderer } from '@/lib/aurora-renderer'

const props = withDefaults(defineProps<{
  hue?: 'blue' | 'violet' | 'green' | 'indigo' | 'aurora'
  intensity?: number
  /** Noise zoom: smaller = broader ribbons. */
  scale?: number
  speed?: number
  /** Fade the top and bottom edges out. */
  fade?: boolean
  /** Cover the viewport and follow scroll (page background mode). */
  fixed?: boolean
  /** Fraction of scroll the aurora follows in fixed mode (parallax). */
  parallax?: number
  seed?: number
  /** Horizontal stretch: smaller = longer, wispier ribbons. */
  stretch?: number
  /** Explicit palette (three rgb triplets, 0..1); overrides `hue`. */
  colors?: [number[], number[], number[]]
  /** 0..1: blend toward a fixed left→right c0→c2 gradient across the canvas. */
  sweep?: number
}>(), { sweep: 0, hue: 'aurora', intensity: 1, scale: 1.6, speed: 0.06, fade: false, fixed: false, parallax: 0.25, seed: 0, stretch: 0.55 })

const canvas = ref<HTMLCanvasElement | null>(null)
const mode = ref<'webgpu' | 'webgl' | 'css'>('css')
const reduced = typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches

const pal = computed(() => props.colors ?? PALETTES[props.hue]!)
const cssFallback = computed(() => {
  const [a, b, c] = pal.value.map(v => `rgb(${v.map(x => Math.round(x * 255)).join(' ')} / ${0.28 * props.intensity})`)
  return `radial-gradient(60% 40% at 20% 30%, ${a}, transparent 70%), radial-gradient(50% 45% at 75% 60%, ${b}, transparent 70%), radial-gradient(70% 35% at 50% 90%, ${c}, transparent 70%)`
})

const renderer = createAuroraRenderer(() => ({ ...props, colors: pal.value }), reduced)
let observer: IntersectionObserver | null = null
let disposed = false
onMounted(async () => {
  const el = canvas.value
  if (!el) return
  observer = new IntersectionObserver(([entry]) => renderer.setVisible(!!entry?.isIntersecting), { rootMargin: '20% 0px' })
  observer.observe(el)
  const result = await renderer.start(el)
  if (!disposed) mode.value = result
})
onUnmounted(() => {
  disposed = true
  observer?.disconnect()
  observer = null
  renderer.dispose()
})
</script>

<template>
  <div
    class="pointer-events-none overflow-hidden"
    :class="fixed ? 'fixed inset-0' : 'absolute inset-0'"
    aria-hidden="true"
    :data-aurora="mode"
  >
    <div v-if="mode === 'css'" class="absolute inset-0" :style="{ backgroundImage: cssFallback }" />
    <canvas ref="canvas" class="block size-full" :class="mode === 'css' ? 'hidden' : ''" />
  </div>
</template>
