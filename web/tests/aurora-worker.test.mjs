import assert from 'node:assert/strict'
import { test } from 'node:test'

const settle = async () => { for (let i = 0; i < 10; i++) await Promise.resolve() }

async function fixture(t) {
  const originals = new Map()
  const set = (name, value) => {
    originals.set(name, Object.getOwnPropertyDescriptor(globalThis, name))
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value })
  }
  t.after(() => { for (const [name, descriptor] of originals) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor)
    else delete globalThis[name]
  } })
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const messages = []
  let devices = 0, submissions = 0, contexts = 0, released = 0
  let finishBatch
  let loseDevice
  const device = {
    lost: new Promise(resolve => { loseDevice = resolve }),
    destroy() {}, addEventListener() {},
    createShaderModule() { return {} },
    async createRenderPipelineAsync() { return { getBindGroupLayout() { return {} } } },
    createBuffer() { return { destroy() { released++ } } },
    createBindGroup() { return {} },
    createCommandEncoder() { return {
      beginRenderPass() { return { setPipeline() {}, setBindGroup() {}, draw() {}, end() {} } },
      finish() { return {} },
    } },
    queue: {
      writeBuffer() {}, submit() { submissions++ },
      onSubmittedWorkDone() { return new Promise(resolve => { finishBatch = resolve }) },
    },
  }
  class Canvas {
    width = 2; height = 2
    getContext() {
      contexts++
      return { configure() {}, unconfigure() {}, getCurrentTexture() { return { createView() { return {} } } } }
    }
  }
  set('navigator', { gpu: {
    async requestAdapter() { return { async requestDevice() { devices++; return device } } },
    getPreferredCanvasFormat() { return 'bgra8unorm' },
  } })
  set('OffscreenCanvas', Canvas)
  set('GPUBufferUsage', { UNIFORM: 1, COPY_DST: 2 })
  set('postMessage', message => messages.push(message))
  set('onmessage', undefined)
  await import(`../src/lib/aurora-worker.ts?case=${Math.random()}`)
  const send = data => globalThis.onmessage({ data })
  send({ type: 'probe' })
  await settle()
  const frame = (overrides = {}) => ({
    width: 100, height: 100, scroll: 0, visible: true, reduced: false,
    options: { colors: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], intensity: 1, scale: 1, speed: 1, fade: false, seed: 0, stretch: 1, sweep: 0 },
    ...overrides,
  })
  return { send, frame, Canvas, messages,
    stats: () => ({ devices, submissions, contexts, released }),
    finish: async () => { finishBatch(); await settle() },
    lose: async () => { loseDevice(); await settle() },
    tick: async () => { t.mock.timers.tick(34); await settle() },
  }
}

test('one GPU batch serves visible surfaces and waits before drawing again', async t => {
  const f = await fixture(t)
  for (let id = 1; id <= 3; id++) f.send({ type: 'attach', id, canvas: new f.Canvas(), frame: f.frame({ visible: id < 3 }) })
  await f.tick()
  assert.deepEqual(f.stats(), { devices: 1, submissions: 1, contexts: 3, released: 0 })
  assert.equal(f.messages.filter(x => x.type === 'mode').length, 0)
  await f.tick()
  assert.equal(f.stats().submissions, 1)
  await f.finish()
  assert.equal(f.messages.filter(x => x.mode === 'webgpu').length, 2)
  for (let id = 1; id <= 3; id++) f.send({ type: 'update', id, frame: f.frame({ visible: false }) })
  await f.tick()
  assert.equal(f.stats().submissions, 1)
  for (let id = 1; id <= 3; id++) f.send({ type: 'detach', id })
  assert.equal(f.stats().released, 2)
})

test('reduced motion draws once and redraws only after a surface update', async t => {
  const f = await fixture(t)
  f.send({ type: 'attach', id: 1, canvas: new f.Canvas(), frame: f.frame({ reduced: true }) })
  await f.tick()
  await f.finish()
  await f.tick()
  assert.equal(f.stats().submissions, 1)
  f.send({ type: 'update', id: 1, frame: f.frame({ reduced: true, width: 200 }) })
  await f.tick()
  assert.equal(f.stats().submissions, 2)
  await f.finish()
  f.send({ type: 'detach', id: 1 })
})

test('device loss releases active buffers and cannot publish late success', async t => {
  const f = await fixture(t)
  f.send({ type: 'attach', id: 1, canvas: new f.Canvas(), frame: f.frame() })
  await f.tick()
  await f.lose()
  await f.finish()
  assert.equal(f.stats().released, 1)
  assert.deepEqual(f.messages.filter(x => x.type === 'mode'), [{ type: 'mode', id: 1, mode: 'css' }])
  await f.tick()
  assert.equal(f.stats().submissions, 1)
})
