import { WGSL, GLSL_VS, GLSL_FS } from './aurora-shaders.ts'
import { usesTouchInput } from './browser-input.ts'
import { auroraWorkers } from './aurora-worker-client.ts'
import type { AuroraFrame, AuroraMode, AuroraOptions } from './aurora-types.ts'

/** Owns graphics resources from asynchronous setup through disposal. */
export function createAuroraRenderer(options: () => AuroraOptions, reduced: boolean, onMode: (mode: AuroraMode) => void = () => {}) {
  // Uniform block, 80 bytes: res.xy time scroll | c0.xyz intensity | c1.xyz scale | c2.xyz speed | fade seed pad pad
  const uni = new Float32Array(20)
  let raf = 0
  let visible = true
  let stop: (() => void) | null = null
  let disposed = false
  const t0 = performance.now()
  let workerLease: ReturnType<typeof auroraWorkers.acquire> | undefined
  let refresh = () => {}

  async function initWorker(el: HTMLCanvasElement) {
    if (typeof Worker === 'undefined' || typeof el.transferControlToOffscreen !== 'function' || !navigator.gpu) return false
    try { workerLease = auroraWorkers.acquire(mode => { if (!disposed) onMode(mode) }) }
    catch { return false }
    if (!await workerLease.ready || disposed) {
      workerLease.release()
      workerLease = undefined
      return false
    }
    let canvas: OffscreenCanvas
    try { canvas = el.transferControlToOffscreen() }
    catch { workerLease.release(); workerLease = undefined; return false }

    // A transferred canvas cannot acquire a main-thread context. Later failures use CSS.
    const frame: AuroraFrame = {
      width: 2, height: 2, scroll: 0, visible: false, reduced, options: options(),
    }
    const measure = () => {
      const rect = el.getBoundingClientRect()
      const ratio = Math.min((window.devicePixelRatio || 1) * 0.5, 1, 1280 / Math.max(1, rect.width), 1280 / Math.max(1, rect.height))
      frame.width = Math.max(2, Math.round(rect.width * ratio))
      frame.height = Math.max(2, Math.round(rect.height * ratio))
    }
    const update = () => {
      frame.options = options()
      frame.visible = visible && !document.hidden
      frame.scroll = frame.options.fixed ? window.scrollY / Math.max(1, window.innerHeight) * frame.options.parallax : 0
      workerLease?.update(frame)
    }
    measure()
    frame.visible = visible && !document.hidden
    workerLease.attach(canvas, frame)
    const resize = new ResizeObserver(() => { measure(); update() })
    resize.observe(el)
    const scroll = () => { if (options().fixed) update() }
    window.addEventListener('scroll', scroll, { passive: true })
    document.addEventListener('visibilitychange', update)
    refresh = update
    stop = () => {
      resize.disconnect()
      window.removeEventListener('scroll', scroll)
      document.removeEventListener('visibilitychange', update)
      workerLease?.release()
      workerLease = undefined
      refresh = () => {}
    }
    return true
  }

  function fill(w: number, h: number) {
    const props = options()
    const [c0, c1, c2] = props.colors
    const scroll = props.fixed ? (window.scrollY / window.innerHeight) * props.parallax : 0
    uni.set([w, h, reduced ? 0 : (performance.now() - t0) / 1000, scroll])
    uni.set([...c0, props.intensity], 4)
    uni.set([...c1, props.scale], 8)
    uni.set([...c2, props.speed], 12)
    uni.set([props.fade ? 1 : 0, props.seed, props.stretch, props.sweep], 16)
  }

  function size(el: HTMLCanvasElement) {
    const r = el.getBoundingClientRect()
    const dpr = Math.min(window.devicePixelRatio || 1, 2) * 0.5
    const w = Math.max(2, Math.min(1280, Math.round(r.width * dpr)))
    const h = Math.max(2, Math.round(r.height * dpr))
    if (el.width !== w || el.height !== h) { el.width = w; el.height = h }
    return [w, h] as const
  }

  async function initWebGPU(el: HTMLCanvasElement): Promise<boolean> {
    if (disposed) return false
    const gpu = (navigator as Navigator & { gpu?: GPU }).gpu
    if (!gpu) return false
    const adapter = await gpu.requestAdapter()
    if (!adapter || disposed) return false
    const device = await adapter.requestDevice()
    if (disposed) { device.destroy(); return false }
    // Own the device before any operation that can throw.
    stop = () => { cancelAnimationFrame(raf); device.destroy() }
    const ctx = el.getContext('webgpu') as GPUCanvasContext | null
    if (!ctx) { stop(); stop = null; return false }
    const format = gpu.getPreferredCanvasFormat()
    ctx.configure({ device, format, alphaMode: 'premultiplied' })
    const module = device.createShaderModule({ code: WGSL })
    const pipeline = device.createRenderPipeline({
      layout: 'auto',
      vertex: { module, entryPoint: 'vs' },
      fragment: { module, entryPoint: 'fs', targets: [{ format }] },
      primitive: { topology: 'triangle-list' },
    })
    const buf = device.createBuffer({ size: 80, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST })
    const bind = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [{ binding: 0, resource: { buffer: buf } }] })

    const frame = () => {
      const [w, h] = size(el)
      fill(w, h)
      device.queue.writeBuffer(buf, 0, uni)
      const enc = device.createCommandEncoder()
      const pass = enc.beginRenderPass({ colorAttachments: [{ view: ctx.getCurrentTexture().createView(), clearValue: { r: 0, g: 0, b: 0, a: 0 }, loadOp: 'clear', storeOp: 'store' }] })
      pass.setPipeline(pipeline); pass.setBindGroup(0, bind); pass.draw(3); pass.end()
      device.queue.submit([enc.finish()])
    }
    loop(frame)
    return true
  }

  function initWebGL(el: HTMLCanvasElement): boolean {
    if (disposed) return false
    const gl = el.getContext('webgl2', { alpha: true, premultipliedAlpha: true, antialias: false, powerPreference: 'low-power' })
    if (!gl) return false
    stop = () => { cancelAnimationFrame(raf); gl.getExtension('WEBGL_lose_context')?.loseContext() }
    const sh = (type: number, src: string) => {
      const shader = gl.createShader(type)
      if (!shader) throw new Error('Unable to create aurora shader')
      gl.shaderSource(shader, src)
      gl.compileShader(shader)
      return shader
    }
    const prog = gl.createProgram()
    if (!prog) throw new Error('Unable to create aurora program')
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, GLSL_VS)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, GLSL_FS)); gl.linkProgram(prog)
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { stop(); stop = null; return false }
    gl.useProgram(prog)
    const ubo = gl.createBuffer()
    if (!ubo) throw new Error('Unable to create aurora uniform buffer')
    gl.bindBuffer(gl.UNIFORM_BUFFER, ubo); gl.bufferData(gl.UNIFORM_BUFFER, 80, gl.DYNAMIC_DRAW)
    gl.uniformBlockBinding(prog, gl.getUniformBlockIndex(prog, 'U'), 0); gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, ubo)
    const vao = gl.createVertexArray(); gl.bindVertexArray(vao)
    gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)

    const frame = () => {
      const [w, h] = size(el)
      fill(w, h)
      gl.viewport(0, 0, w, h)
      gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT)
      gl.bindBuffer(gl.UNIFORM_BUFFER, ubo); gl.bufferSubData(gl.UNIFORM_BUFFER, 0, uni)
      gl.drawArrays(gl.TRIANGLES, 0, 3)
    }
    loop(frame)
    return true
  }

  function loop(frame: () => void) {
    if (disposed) return
    if (reduced) { frame(); return }
    const tick = () => {
      if (disposed) return
      if (visible && !document.hidden) frame()
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
  }
  return {
    async start(el: HTMLCanvasElement): Promise<'webgpu' | 'webgl' | 'css'> {
      if (disposed) return 'css'
      // The worker reports WebGPU only after a surface has rendered its first frame.
      if (typeof Worker !== 'undefined' && typeof el.transferControlToOffscreen === 'function' && navigator.gpu) {
        if (await initWorker(el)) return 'css'
      }
      if (disposed) return 'css'
      // Keep touch fallback static when worker WebGPU is unavailable.
      if (usesTouchInput()) return 'css'
      try {
        if (await initWebGPU(el)) return 'webgpu'
      } catch {
        stop?.()
        stop = null
      }
      if (disposed) return 'css'
      try {
        if (initWebGL(el)) return 'webgl'
      } catch {
        stop?.()
        stop = null
      }
      return 'css'
    },
    refresh() { refresh() },
    setVisible(value: boolean) { visible = value; refresh() },
    dispose() {
      if (disposed) return
      disposed = true
      cancelAnimationFrame(raf)
      workerLease?.release()
      stop?.()
      stop = null
    },
  }
}
