import type { AuroraFrame, AuroraMode, AuroraRequest, AuroraResponse } from './aurora-types.ts'

type ModeListener = (mode: AuroraMode) => void
type WorkerFactory = () => Worker

/** A page owns one worker; each mounted decoration holds one lease. */
export function createAuroraWorkerPool(factory: WorkerFactory) {
  let current: ReturnType<typeof createHost> | undefined
  let nextId = 0

  function createHost() {
    const worker = factory()
    const listeners = new Map<number, ModeListener>()
    let failed = false
    let resolveReady: (ready: boolean) => void = () => {}
    const ready = new Promise<boolean>(resolve => { resolveReady = resolve })
    const timeout = setTimeout(fail, 4000)
    function fail() {
      if (failed) return
      failed = true
      clearTimeout(timeout)
      resolveReady(false)
      worker.terminate()
      for (const listener of listeners.values()) listener('css')
    }
    worker.onmessage = ({ data }: MessageEvent<AuroraResponse>) => {
      if (failed) return
      if (data.type === 'ready') {
        clearTimeout(timeout)
        if (data.available) resolveReady(true)
        else fail()
      } else if (data.mode === 'css') fail()
      else listeners.get(data.id)?.(data.mode)
    }
    worker.onerror = fail
    worker.onmessageerror = fail
    function send(message: AuroraRequest, transfer: Transferable[] = []) {
      if (failed) return false
      try { worker.postMessage(message, transfer); return true }
      catch { fail(); return false }
    }
    send({ type: 'probe' })
    return { ready, listeners, send, fail, get failed() { return failed } }
  }

  return {
    acquire(listener: ModeListener) {
      if (!current || current.failed) current = createHost()
      const host = current
      const id = ++nextId
      let released = false
      host.listeners.set(id, listener)
      return {
        ready: host.ready,
        attach(canvas: OffscreenCanvas, frame: AuroraFrame) {
          return !released && host.send({ type: 'attach', id, canvas, frame }, [canvas])
        },
        update(frame: AuroraFrame) {
          if (!released) host.send({ type: 'update', id, frame })
        },
        release() {
          if (released) return
          released = true
          host.listeners.delete(id)
          host.send({ type: 'detach', id })
          if (!host.listeners.size) {
            host.fail()
            if (current === host) current = undefined
          }
        },
      }
    },
  }
}

export const auroraWorkers = createAuroraWorkerPool(() =>
  new Worker(new URL('./aurora-worker.ts', import.meta.url), { type: 'module', name: 'Aurora' }),
)
