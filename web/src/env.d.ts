/// <reference types="vite/client" />
interface ImportMetaEnv {
  /** GitHub "owner/repo"; every repo link derives from it. */
  readonly VITE_REPO: string
  /** Deploy base path, e.g. "/GOAT/" for a project site. */
  readonly VITE_BASE?: string
  readonly VITE_OMLX_URL?: string
  /** Absolute URL of the docs site when it lives on its own domain (https://goatherd.dev/). */
  readonly VITE_DOCS_URL?: string
  /** Set to "1" for single-file previews (hash router). */
  readonly VITE_HASH_ROUTER?: string
}
interface ImportMeta { readonly env: ImportMetaEnv }

declare module 'virtual:goat-glossary' {
  import type { GlossaryEntry } from '../docs/.vitepress/plugins/goat-glossary'
  export const entries: GlossaryEntry[]
  /** Absolute-from-root URL of the docs glossary page, e.g. "/docs/GLOSSARY". */
  export const glossaryUrl: string
  export const docsUrl: string
}

declare module 'virtual:goat-docs' {
  import type { GoatDoc } from '../plugins/goat-docs'
  export const docs: Record<'third-party-notices' | 'license-art' | 'license' | 'privacy', GoatDoc>
}
