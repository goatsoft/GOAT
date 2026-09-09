import { createApp } from 'vue'
import { createRouter, createWebHashHistory, createWebHistory } from 'vue-router'
import { routes } from 'vue-router/auto-routes'
import App from './App.vue'
import './assets/main.css'
import { usesTouchInput } from './lib/browser-input'

const router = createRouter({
  // Hash history only for single-file previews (VITE_HASH_ROUTER=1); Pages gets clean URLs.
  history: import.meta.env.VITE_HASH_ROUTER === '1' ? createWebHashHistory() : createWebHistory(import.meta.env.BASE_URL),
  routes,
  scrollBehavior(to, _from, saved) {
    if (saved) return saved
    if (to.hash) {
      const touch = usesTouchInput()
      return { el: to.hash, behavior: touch ? 'instant' : 'smooth', top: touch ? 96 : 72 }
    }
    return { top: 0 }
  },
})

// The docs moved to their own domain. Old /docs/* links on this origin forward there,
// path preserved (Pages serves index.html for unknown paths, so this runs for them).
const docsUrl = import.meta.env.VITE_DOCS_URL
if (docsUrl) {
  const base = import.meta.env.BASE_URL.replace(/\/$/, '')
  const m = location.pathname.match(new RegExp(`^${base}/docs(?:/(.*))?$`))
  if (m) location.replace(`${docsUrl}${m[1] ?? ''}${location.search}${location.hash}`)
}

const app = createApp(App).use(router)
// Wait for the initial page so the footer cannot appear before the hero.
router.isReady().then(() => app.mount('#app'))
