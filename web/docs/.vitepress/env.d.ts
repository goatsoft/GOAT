/// <reference types="vite/client" />
/// <reference types="@webgpu/types" />

declare module 'virtual:goat-data' {
  import type { Adr, Release } from './plugins/goat-data'
  export const adrs: Adr[]
  export const release: Release
  export const repo: string
}

declare module 'virtual:goat-glossary' {
  import type { GlossaryEntry } from './plugins/goat-glossary'
  export const entries: GlossaryEntry[]
  export const glossaryUrl: string
  export const docsUrl: string
}
