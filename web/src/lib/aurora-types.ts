export interface AuroraOptions {
  colors: [number[], number[], number[]]
  fixed: boolean
  parallax: number
  intensity: number
  scale: number
  speed: number
  fade: boolean
  seed: number
  stretch: number
  sweep: number
}

export interface AuroraFrame {
  width: number
  height: number
  scroll: number
  visible: boolean
  reduced: boolean
  options: AuroraOptions
}

export type AuroraMode = 'webgpu' | 'webgl' | 'css'

export type AuroraRequest =
  | { type: 'probe' }
  | { type: 'attach'; id: number; canvas: OffscreenCanvas; frame: AuroraFrame }
  | { type: 'update'; id: number; frame: AuroraFrame }
  | { type: 'detach'; id: number }

export type AuroraResponse =
  | { type: 'ready'; available: boolean }
  | { type: 'mode'; id: number; mode: AuroraMode }

export function fillAuroraUniforms(out: Float32Array, frame: AuroraFrame, time: number) {
  const p = frame.options
  out.set([frame.width, frame.height, frame.reduced ? 0 : time, frame.scroll])
  out.set([...p.colors[0], p.intensity], 4)
  out.set([...p.colors[1], p.scale], 8)
  out.set([...p.colors[2], p.speed], 12)
  out.set([p.fade ? 1 : 0, p.seed, p.stretch, p.sweep], 16)
}
