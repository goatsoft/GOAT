import { fileURLToPath, URL } from 'node:url'
import { defineConfig, loadEnv } from 'vite'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'
import VueRouter from 'unplugin-vue-router/vite'
import { VueRouterAutoImports } from 'unplugin-vue-router'
import AutoImport from 'unplugin-auto-import/vite'
import Components from 'unplugin-vue-components/vite'
import Icons from 'unplugin-icons/vite'
import IconsResolver from 'unplugin-icons/resolver'
import MotionResolver from 'motion-v/resolver'
import { goatGlossary } from './docs/.vitepress/plugins/goat-glossary.ts'
import { goatDocs } from './plugins/goat-docs.ts'

export default defineConfig(({ mode }) => {
  // web/.env holds the public defaults; CI and .env.local override (VITE_BASE=/<repo>/ on Pages).
  const env = { ...loadEnv(mode, process.cwd(), 'VITE_'), ...process.env }
  return {
  base: env.VITE_BASE || '/',
  plugins: [
    // docs/GLOSSARY.md → virtual:goat-glossary, the definitions behind <Term> tooltips.
    goatGlossary({
      file: fileURLToPath(new URL('../docs/GLOSSARY.md', import.meta.url)),
      glossaryUrl: `${env.VITE_DOCS_URL || `${(env.VITE_BASE || '/').replace(/\/$/, '')}/docs/`}GLOSSARY`,
      docsUrl: env.VITE_DOCS_URL || `${(env.VITE_BASE || '/').replace(/\/$/, '')}/docs/`,
    }),
    // Repo Markdown rendered at build for the in-page legal dialogs.
    goatDocs({
      repo: env.VITE_REPO || 'goatsoft/GOAT',
      root: fileURLToPath(new URL('..', import.meta.url)),
      files: {
        'third-party-notices': fileURLToPath(new URL('../THIRD-PARTY-NOTICES.md', import.meta.url)),
        'license-art': fileURLToPath(new URL('../LICENSE-ART.md', import.meta.url)),
        license: fileURLToPath(new URL('../LICENSE', import.meta.url)),
        privacy: fileURLToPath(new URL('../docs/PRIVACY.md', import.meta.url)),
      },
    }),
    // Must run before vue(): file-based routes from src/pages.
    VueRouter({
      routesFolder: 'src/pages',
      dts: 'src/typed-router.d.ts',
    }),
    vue(),
    tailwindcss(),
    AutoImport({
      imports: ['vue', VueRouterAutoImports, { 'motion-v': ['useScroll', 'useTransform', 'useSpring', 'useMotionValue', 'useInView'] }],
      dirs: ['src/composables', 'src/lib'],
      dts: 'src/auto-imports.d.ts',
      vueTemplate: true,
    }),
    Components({
      dirs: ['src/components'],
      deep: true,
      dts: 'src/components.d.ts',
      resolvers: [IconsResolver({ prefix: 'i' }), MotionResolver()],
    }),
    Icons({
      compiler: 'vue3', autoInstall: false,
      // Hugeicons ships at a 1.5 stroke, baked into each glyph. Tag them so main.css can set
      // the weight once (CSS beats presentation attributes) instead of per usage.
      iconCustomizer(collection, _icon, props) {
        if (collection === 'hugeicons') props.class = [props.class, 'hg'].filter(Boolean).join(' ')
      },
    }),
  ],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  build: {
    target: 'es2022',
    cssMinify: 'lightningcss',
  },
  server: {
    // `npm run dev:all` runs VitePress on 5174; proxy it under /docs so both sites share 5173
    // with HMR, matching the deployed layout (<site>/docs/). Set VITE_DOCS_DEV_URL to override.
    proxy: {
      '/docs': { target: env.VITE_DOCS_DEV_URL || 'http://localhost:5174', changeOrigin: true, ws: true },
    },
  },
}
})
