import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import GoatLayout from './GoatLayout.vue'
import ReleaseBadge from './components/ReleaseBadge.vue'
import AdrList from './components/AdrList.vue'
import Mermaid from './components/Mermaid.vue'
import Term from '@/components/site/Term.vue'
import './goat.css'

/**
 * GOAT theme layer: the default theme with Caprine tokens (Light / Midnight), the
 * landing site's GPU aurora behind the page, and a little motion. Components
 * registered here are usable from any markdown page: <ReleaseBadge />, <AdrList />, and ```mermaid fences render through <Mermaid />.
 */
export default {
  extends: DefaultTheme,
  Layout: GoatLayout,
  enhanceApp({ app }) {
    app.component('ReleaseBadge', ReleaseBadge)
    app.component('AdrList', AdrList)
    app.component('Mermaid', Mermaid)
    app.component('Term', Term)
  },
} satisfies Theme
