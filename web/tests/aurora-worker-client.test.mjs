import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createAuroraWorkerPool } from '../src/lib/aurora-worker-client.ts'

function fixture() {
  const workers = []
  const pool = createAuroraWorkerPool(() => {
    const worker = {
      messages: [], terminations: 0,
      postMessage(message, transfer) { this.messages.push({ message, transfer }) },
      terminate() { this.terminations++ },
      receive(data) { this.onmessage({ data }) },
    }
    workers.push(worker)
    return worker
  })
  return { pool, workers }
}

test('surfaces share one worker and release it only after the final unmount', async () => {
  const { pool, workers } = fixture()
  const a = pool.acquire(() => {})
  const b = pool.acquire(() => {})
  assert.equal(workers.length, 1)
  const worker = workers[0]
  assert.deepEqual(worker.messages.map(x => x.message.type), ['probe'])
  worker.receive({ type: 'ready', available: true })
  assert.equal(await a.ready, true)
  assert.equal(await b.ready, true)
  const canvas = {}
  a.attach(canvas, { visible: true })
  b.attach({}, { visible: false })
  assert.deepEqual(worker.messages[1].transfer, [canvas])
  assert.notEqual(worker.messages[1].message.id, worker.messages[2].message.id)
  a.release()
  a.release()
  assert.equal(worker.terminations, 0)
  b.release()
  assert.equal(worker.terminations, 1)
})

test('unmount during preflight settles readiness and prevents late attachment', async () => {
  const { pool, workers } = fixture()
  const lease = pool.acquire(() => {})
  lease.release()
  assert.equal(await lease.ready, false)
  workers[0].receive({ type: 'ready', available: true })
  assert.equal(lease.attach({}, {}), false)
  assert.equal(workers[0].messages.some(x => x.message.type === 'attach'), false)
})

test('worker failure restores every fallback and a later mount can retry', async () => {
  const { pool, workers } = fixture()
  const modes = []
  const a = pool.acquire(mode => modes.push(['a', mode]))
  const b = pool.acquire(mode => modes.push(['b', mode]))
  workers[0].onerror(new Error('device failed'))
  assert.equal(await a.ready, false)
  assert.equal(await b.ready, false)
  assert.deepEqual(modes, [['a', 'css'], ['b', 'css']])
  const c = pool.acquire(() => {})
  assert.equal(workers.length, 2)
  a.release()
  b.release()
  assert.equal(workers[1].terminations, 0)
  c.release()
})

test('a transfer failure terminates the worker and reports CSS once', async () => {
  const { pool, workers } = fixture()
  const modes = []
  const lease = pool.acquire(mode => modes.push(mode))
  workers[0].receive({ type: 'ready', available: true })
  assert.equal(await lease.ready, true)
  workers[0].postMessage = () => { throw new Error('transfer rejected') }
  assert.equal(lease.attach({}, {}), false)
  assert.deepEqual(modes, ['css'])
  lease.release()
  assert.equal(workers[0].terminations, 1)
})

test('preflight times out without ever transferring a canvas', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const { pool, workers } = fixture()
  const lease = pool.acquire(() => {})
  t.mock.timers.tick(4000)
  assert.equal(await lease.ready, false)
  assert.equal(workers[0].terminations, 1)
  assert.deepEqual(workers[0].messages.map(x => x.message.type), ['probe'])
  lease.release()
})
