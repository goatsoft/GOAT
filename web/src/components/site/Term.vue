<script setup lang="ts">
/**
 * A glossary term with a hover/focus definition. One component for both sites:
 * the landing page writes `<Term>Inference</Term>` by hand, the docs auto-link the
 * first occurrence of each term per page (docs/.vitepress/plugins/goat-glossary.ts).
 *
 * Definitions come from docs/GLOSSARY.md via `virtual:goat-glossary`, resolved at
 * build time: no fetch, nothing leaves the page. Styling is plain CSS on `--goat-*`
 * tokens so it looks the same without Tailwind (the docs theme has none).
 */
import { computed, onMounted, ref } from 'vue'
import { entries, glossaryUrl } from 'virtual:goat-glossary'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'

const props = defineProps<{ term?: string }>()

// Without an explicit `term`, the rendered text is the lookup key (read after mount so
// the slot can be anything: plain text, nested emphasis, an auto-linked docs word).
const el = ref<HTMLElement | null>(null)
const text = ref('')
onMounted(() => { text.value = el.value?.textContent?.trim() ?? '' })
const key = computed(() => (props.term ?? text.value).toLowerCase())
const entry = computed(() =>
  key.value
    ? entries.find(e => e.slug === key.value || e.term.toLowerCase() === key.value || e.aliases.some((a: string) => a.toLowerCase() === key.value))
    : undefined,
)
</script>

<template>
  <TooltipProvider :delay-duration="150">
    <Tooltip>
      <TooltipTrigger as-child>
        <!-- Focusable so keyboard and touch (tap focuses) reach the definition too. -->
        <span ref="el" :class="entry ? 'goat-term' : undefined" :tabindex="entry ? 0 : undefined"><slot>{{ term }}</slot></span>
      </TooltipTrigger>
      <TooltipContent v-if="entry" class="goat-term-tip" :side-offset="8" :collision-padding="12">
        <strong class="goat-term-tip-name">{{ entry.term }}</strong>
        <span class="goat-term-tip-def">{{ entry.definition }}</span>
        <a class="goat-term-tip-more" :href="`${glossaryUrl}#${entry.slug}`">Glossary ↗</a>
      </TooltipContent>
    </Tooltip>
  </TooltipProvider>
</template>

<style>
/* Unscoped on purpose: the tooltip content is portalled to <body>. Unlayered rules
   beat Tailwind's layered utilities, so both sites render this one look. */
.goat-term {
  cursor: help;
  text-decoration: underline dotted color-mix(in oklab, var(--goat-accent) 70%, transparent);
  text-decoration-thickness: 1.5px;
  text-underline-offset: 3px;
  border-radius: 3px;
  transition: color .2s, text-decoration-color .2s;
}
.goat-term:hover, .goat-term:focus-visible { color: var(--goat-accent); text-decoration-color: var(--goat-accent); outline: none; }
.goat-term:focus-visible { box-shadow: 0 0 0 2px color-mix(in oklab, var(--goat-accent) 45%, transparent); }
.goat-term-tip {
  display: grid; gap: 4px; z-index: 60; max-width: 22rem;
  padding: 10px 12px; border-radius: 12px;
  font-size: 13px; line-height: 1.45; text-align: left; font-weight: 400; letter-spacing: 0;
  color: var(--goat-ink);
  background: color-mix(in oklab, var(--goat-surface) 88%, transparent);
  border: 1px solid color-mix(in oklab, var(--goat-accent) 30%, transparent);
  box-shadow: 0 12px 40px -12px rgba(0, 0, 0, .6), 0 0 0 1px rgba(255, 255, 255, .04) inset;
  backdrop-filter: saturate(160%) blur(18px); -webkit-backdrop-filter: saturate(160%) blur(18px);
  animation: goat-term-in .16s ease-out;
}
.goat-term-tip[data-state="closed"] { animation: goat-term-out .12s ease-in forwards; }
.goat-term-tip-name { display: block; font-weight: 600; color: var(--goat-accent); }
.goat-term-tip-def { display: block; color: var(--goat-ink); opacity: .92; }
.goat-term-tip-more { font-size: 12px; color: var(--goat-muted); text-decoration: none; }
.goat-term-tip-more:hover { color: var(--goat-accent); }
@keyframes goat-term-in { from { opacity: 0; transform: translateY(4px) scale(.98); } to { opacity: 1; transform: none; } }
@keyframes goat-term-out { to { opacity: 0; transform: translateY(2px) scale(.98); } }
@media (prefers-reduced-motion: reduce) { .goat-term-tip { animation: none !important; } }
</style>
