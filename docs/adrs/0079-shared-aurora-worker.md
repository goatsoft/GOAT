# ADR-0079: Shared Aurora rendering worker

Status: Accepted · Refines [ADR-0041](0041-website-as-vite-vue-spa.md) and [ADR-0077](0077-host-coordination-and-resource-lifetimes.md)

## Context

The website and documentation reuse Aurora backgrounds across page, panel and tile surfaces. Each canvas previously acquired its own graphics device and ran its drawing loop on the main thread. Mobile navigation must remain responsive while decorative rendering runs. Local network HTTP previews cannot exercise browser capabilities that require a secure context.

## Decision

Use one dedicated module worker per page with one WebGPU device and pipeline. Each mounted decoration owns a lease and transfers its canvas only after the worker confirms that it can create a pipeline. The Vue component owns its intersection observer; the browser adapter owns resize, scroll and document visibility listeners. The worker owns graphics resources and scheduling.

The worker submits one batch for visible surfaces, at up to 30 frames per second, and waits for completion before scheduling another. Canvas dimensions are capped at 1280 pixels per axis while preserving aspect ratio. Reduced motion renders once per input change. Uniforms, messages and rendering code have no Vue dependency.

Unsupported desktop browsers retain main-thread WebGPU, WebGL2 and CSS fallback paths. Unsupported touch browsers use CSS. Failure after canvas transfer restores CSS; it does not attempt to reuse a transferred canvas on the main thread. Device loss, setup failure and worker errors release resources. The final lease release terminates the worker, including pending initialization.

Provide an explicit HTTPS development command. Website and docs share one secure public origin, while the proxied docs backend stays on loopback. Certificate paths are supplied by the developer and private keys stay outside the repository. Existing servers are never stopped to claim a port.

## Consequences

Drawing orchestration no longer competes with input handling on browsers with worker WebGPU. GPU work and browser compositing still share device resources, so a worker does not fix expensive CSS effects. The mobile filter fixes remain in place, and physical-device acceptance remains necessary.

No runtime dependency or external request is added. Tests cover shared ownership, pending setup disposal, transfer failure, device loss, bounded submissions, visibility suspension and reduced motion. Website and docs builds verify both consumers.

## Alternatives considered

One worker per canvas would keep duplicated devices and scheduling overhead. Keeping all drawing on the main thread would preserve contention as more surfaces are added. Disabling animation on every touch device would discard capable hardware; capability checks with a static fallback retain the effect where supported.
