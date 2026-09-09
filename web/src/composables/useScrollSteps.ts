import { onMounted, onUnmounted, ref } from 'vue'

/**
 * Tracks the `[data-step]` element nearest the viewport's focal line so a sticky
 * illustration follows the visible copy.
 */
export function useScrollSteps(root: Ref<HTMLElement | null>, focal = 0.45) {
  const active = ref(0)
  let raf = 0

  const measure = () => {
    raf = 0
    const el = root.value
    if (!el || window.innerWidth < 1024) return
    const steps = Array.from(el.querySelectorAll<HTMLElement>('[data-step]'))
    const line = window.innerHeight * focal
    let best = 0
    let bestDist = Infinity
    steps.forEach((s, i) => {
      const r = s.getBoundingClientRect()
      const center = r.top + r.height / 2
      const d = Math.abs(center - line)
      if (d < bestDist) { bestDist = d; best = i }
    })
    active.value = best
  }

  const onScroll = () => { if (window.innerWidth >= 1024 && !raf) raf = requestAnimationFrame(measure) }

  onMounted(() => {
    measure()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
  })
  onUnmounted(() => {
    window.removeEventListener('scroll', onScroll)
    window.removeEventListener('resize', onScroll)
    cancelAnimationFrame(raf)
  })

  return { active }
}
