import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createAuroraRenderer } from '../src/lib/aurora-renderer.ts'

const options = () => ({ colors: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], fixed: false, parallax: 0, intensity: 1, scale: 1, speed: 1, fade: false, seed: 0, stretch: 1, sweep: 0 })
const deferred = () => {
  let resolve
  let reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

function fixture(t, requestAdapter, context = null) {
  let frames = 0
  let contextRequests = 0
  t.mock.method(globalThis, 'cancelAnimationFrame', () => {}, { create: true })
  t.mock.method(globalThis, 'requestAnimationFrame', () => ++frames, { create: true })
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'navigator')
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { gpu: { requestAdapter, getPreferredCanvasFormat: () => 'bgra8unorm' } } })
  t.after(() => { if (previous) Object.defineProperty(globalThis, 'navigator', previous); else delete globalThis.navigator })
  const canvas = { getContext() { contextRequests++; return context } }
  return { canvas, frames: () => frames, contextRequests: () => contextRequests }
}

// Browser-only globals are restored after each test by the mock tracker.
if (!globalThis.cancelAnimationFrame) globalThis.cancelAnimationFrame = () => {}
if (!globalThis.requestAnimationFrame) globalThis.requestAnimationFrame = () => 0

test('unmount while waiting for the adapter prevents device creation and fallback', async t => {
  const adapter = deferred()
  let devices = 0
  const f = fixture(t, () => adapter.promise)
  const renderer = createAuroraRenderer(options, false)
  const result = renderer.start(f.canvas)
  renderer.dispose()
  adapter.resolve({ requestDevice() { devices++; return Promise.resolve({}) } })
  assert.equal(await result, 'css')
  assert.equal(devices, 0)
  assert.equal(f.contextRequests(), 0)
  assert.equal(f.frames(), 0)
})

test('a device returned after unmount is destroyed exactly once', async t => {
  const device = deferred()
  const entered = deferred()
  let destroyed = 0
  const f = fixture(t, async () => ({ requestDevice() { entered.resolve(); return device.promise } }))
  const renderer = createAuroraRenderer(options, false)
  const result = renderer.start(f.canvas)
  await entered.promise
  renderer.dispose()
  device.resolve({ destroy() { destroyed++ } })
  assert.equal(await result, 'css')
  renderer.dispose()
  assert.equal(destroyed, 1)
  assert.equal(f.contextRequests(), 0)
  assert.equal(f.frames(), 0)
})

test('rejected setup after unmount cannot start the fallback', async t => {
  const adapter = deferred()
  const f = fixture(t, () => adapter.promise)
  const renderer = createAuroraRenderer(options, false)
  const result = renderer.start(f.canvas)
  renderer.dispose()
  adapter.reject(new Error('adapter failed'))
  assert.equal(await result, 'css')
  assert.equal(f.contextRequests(), 0)
})

test('partial GPU setup releases its device before trying the fallback', async t => {
  let destroyed = 0
  const f = fixture(t, async () => ({ requestDevice: async () => ({ destroy() { destroyed++ } }) }))
  const renderer = createAuroraRenderer(options, false)
  assert.equal(await renderer.start(f.canvas), 'css')
  assert.equal(destroyed, 1)
  renderer.dispose()
  assert.equal(destroyed, 1)
  assert.equal(f.frames(), 0)
})

test('disposing a running renderer cancels frames and releases graphics resources', async t => {
  let destroyed = 0
  let cancelled = 0
  const device = {
    destroy() { destroyed++ }, createShaderModule() { return {} },
    createRenderPipeline() { return { getBindGroupLayout() { return {} } } },
    createBuffer() { return {} }, createBindGroup() { return {} },
  }
  const f = fixture(t, async () => ({ requestDevice: async () => device }), { configure() {} })
  t.mock.method(globalThis, 'cancelAnimationFrame', () => cancelled++)
  const previous = globalThis.GPUBufferUsage
  globalThis.GPUBufferUsage = { UNIFORM: 1, COPY_DST: 2 }
  t.after(() => { if (previous) globalThis.GPUBufferUsage = previous; else delete globalThis.GPUBufferUsage })
  const renderer = createAuroraRenderer(options, false)
  assert.equal(await renderer.start(f.canvas), 'webgpu')
  assert.equal(f.frames(), 1)
  renderer.dispose()
  renderer.dispose()
  assert.equal(destroyed, 1)
  assert.ok(cancelled > 0)
})

test('failed WebGL allocation releases the acquired context', async t => {
  let lost = 0
  const gl = {
    getExtension: () => ({ loseContext() { lost++ } }),
    createProgram: () => null,
  }
  const f = fixture(t, async () => null, gl)
  const renderer = createAuroraRenderer(options, false)
  assert.equal(await renderer.start(f.canvas), 'css')
  renderer.dispose()
  assert.equal(lost, 1)
  assert.equal(f.frames(), 0)
})

for (const query of ['(hover: none)', '(pointer: coarse)']) {
  test(`touch graphics fallback skips devices, contexts and animation frames: ${query}`, async t => {
    let adapters = 0
    const f = fixture(t, async () => { adapters++; return null })
    const previous = Object.getOwnPropertyDescriptor(globalThis, 'matchMedia')
    Object.defineProperty(globalThis, 'matchMedia', { configurable: true, value: value => ({ matches: value.split(', ').includes(query) }) })
    t.after(() => { if (previous) Object.defineProperty(globalThis, 'matchMedia', previous); else delete globalThis.matchMedia })
    const renderer = createAuroraRenderer(options, false)
    assert.equal(await renderer.start(f.canvas), 'css')
    assert.equal(adapters, 0)
    assert.equal(f.contextRequests(), 0)
    assert.equal(f.frames(), 0)
    renderer.dispose()
  })
}
