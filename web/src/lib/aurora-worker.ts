import { WGSL } from './aurora-shaders.ts'
import { fillAuroraUniforms } from './aurora-types.ts'
import type { AuroraFrame, AuroraRequest, AuroraResponse } from './aurora-types.ts'

interface Surface {
  canvas: OffscreenCanvas
  frame: AuroraFrame
  context?: GPUCanvasContext
  buffer?: GPUBuffer
  bind?: GPUBindGroup
  dirty: boolean
}

const scope = globalThis as unknown as {
  onmessage: (event: MessageEvent<AuroraRequest>) => void
  postMessage: (message: AuroraResponse) => void
}
const surfaces = new Map<number, Surface>()
const uniforms = new Float32Array(20)
const started = performance.now()
let device: GPUDevice | undefined
let pipeline: GPURenderPipeline | undefined
let format: GPUTextureFormat = 'bgra8unorm'
let timer: ReturnType<typeof setTimeout> | undefined
let drawing = false
let failed = false

function release(surface: Surface) {
  // Contexts may already be gone after device loss; still release every buffer.
  try { surface.context?.unconfigure() } catch { /* Already unavailable. */ }
  surface.buffer?.destroy()
}

function fail() {
  if (failed) return
  failed = true
  clearTimeout(timer)
  timer = undefined
  for (const [id, surface] of surfaces) {
    release(surface)
    scope.postMessage({ type: 'mode', id, mode: 'css' })
  }
  surfaces.clear()
  device?.destroy()
  device = undefined
}

async function probe() {
  try {
    const gpu = navigator.gpu
    if (!gpu || !new OffscreenCanvas(2, 2).getContext('webgpu')) throw new Error('Worker WebGPU unavailable')
    const adapter = await gpu.requestAdapter({ powerPreference: 'low-power' })
    if (!adapter) throw new Error('No GPU adapter')
    device = await adapter.requestDevice()
    void device.lost.then(fail)
    device.addEventListener('uncapturederror', fail)
    format = gpu.getPreferredCanvasFormat()
    const module = device.createShaderModule({ code: WGSL })
    pipeline = await device.createRenderPipelineAsync({
      layout: 'auto',
      vertex: { module, entryPoint: 'vs' },
      fragment: { module, entryPoint: 'fs', targets: [{ format }] },
      primitive: { topology: 'triangle-list' },
    })
    scope.postMessage({ type: 'ready', available: !failed })
  } catch {
    fail()
    scope.postMessage({ type: 'ready', available: false })
  }
}

function needsFrame(surface: Surface) {
  return surface.frame.visible && (!surface.frame.reduced || surface.dirty)
}

function schedule() {
  if (failed || drawing || timer !== undefined || ![...surfaces.values()].some(needsFrame)) return
  // Decorative surfaces share a 30fps budget and never queue a second GPU batch.
  timer = setTimeout(() => { timer = undefined; void draw() }, 1000 / 30)
}

async function draw() {
  if (!device || !pipeline || failed) return
  drawing = true
  try {
    const encoder = device.createCommandEncoder()
    let submitted = false
    const rendered: number[] = []
    for (const [id, surface] of surfaces) {
      if (!needsFrame(surface)) continue
      const { canvas, frame } = surface
      if (canvas.width !== frame.width) canvas.width = frame.width
      if (canvas.height !== frame.height) canvas.height = frame.height
      if (!surface.context) {
        const context = canvas.getContext('webgpu')
        if (!context) throw new Error('Surface WebGPU unavailable')
        surface.context = context
        context.configure({ device, format, alphaMode: 'premultiplied' })
        surface.buffer = device.createBuffer({ size: 80, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST })
        surface.bind = device.createBindGroup({
          layout: pipeline.getBindGroupLayout(0),
          entries: [{ binding: 0, resource: { buffer: surface.buffer } }],
        })
      }
      if (!surface.buffer || !surface.bind) continue
      fillAuroraUniforms(uniforms, frame, (performance.now() - started) / 1000)
      device.queue.writeBuffer(surface.buffer, 0, uniforms)
      const pass = encoder.beginRenderPass({ colorAttachments: [{
        view: surface.context.getCurrentTexture().createView(),
        clearValue: { r: 0, g: 0, b: 0, a: 0 }, loadOp: 'clear', storeOp: 'store',
      }] })
      pass.setPipeline(pipeline)
      pass.setBindGroup(0, surface.bind)
      pass.draw(3)
      pass.end()
      if (surface.dirty) rendered.push(id)
      surface.dirty = false
      submitted = true
    }
    if (submitted) {
      device.queue.submit([encoder.finish()])
      await device.queue.onSubmittedWorkDone()
      if (!failed) for (const id of rendered) {
        if (surfaces.has(id)) scope.postMessage({ type: 'mode', id, mode: 'webgpu' })
      }
    }
  } catch {
    fail()
  } finally {
    drawing = false
    schedule()
  }
}

scope.onmessage = ({ data }) => {
  if (data.type === 'probe') { void probe(); return }
  if (data.type === 'detach') {
    const surface = surfaces.get(data.id)
    if (surface) release(surface)
    surfaces.delete(data.id)
    return
  }
  if (failed) { scope.postMessage({ type: 'mode', id: data.id, mode: 'css' }); return }
  if (data.type === 'attach') {
    surfaces.set(data.id, { canvas: data.canvas, frame: data.frame, dirty: true })
  } else {
    const surface = surfaces.get(data.id)
    if (surface) { surface.frame = data.frame; surface.dirty = true }
  }
  schedule()
}
