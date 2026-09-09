import type { MotionProps } from 'motion-v'
import { usesTouchInput } from '../lib/browser-input.ts'

type RevealProps = Pick<MotionProps, 'initial' | 'whileInView' | 'inViewOptions' | 'transition'>

/**
 * Shared motion-v presets so every section reveals the same way.
 * Usage: <motion.div v-bind="reveal()" />, stagger(i) for lists, heading() for h2/h3.
 * motion-v honours prefers-reduced-motion via <MotionConfig reduced-motion="user"> in App.vue.
 */
export function useReveal() {
  if (usesTouchInput()) {
    const visible = (_delay?: number, _distance?: number): RevealProps => ({ initial: false })
    return { reveal: visible, stagger: visible, heading: visible }
  }
  const reveal = (delay = 0, y = 28): RevealProps => ({
    initial: { opacity: 0, y, filter: 'blur(6px)' },
    whileInView: { opacity: 1, y: 0, filter: 'blur(0px)' },
    inViewOptions: { once: true, margin: '-12% 0px -12% 0px' },
    transition: { duration: 0.8, delay, ease: [0.22, 1, 0.36, 1] },
  })

  const stagger = (i: number, step = 0.08) => reveal(i * step)

  /** Reveal headings with a slower scale and letter-spacing transition. */
  const heading = (delay = 0): RevealProps => ({
    initial: { opacity: 0, y: 18, scale: 0.97, letterSpacing: '-0.01em', filter: 'blur(8px)' },
    whileInView: { opacity: 1, y: 0, scale: 1, letterSpacing: '-0.03em', filter: 'blur(0px)' },
    inViewOptions: { once: true, margin: '-10% 0px -10% 0px' },
    transition: { duration: 1.1, delay, ease: [0.16, 1, 0.3, 1] },
  })

  return { reveal, stagger, heading }
}
