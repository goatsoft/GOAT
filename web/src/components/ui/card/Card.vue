<script setup lang="ts">
import type { HTMLAttributes } from 'vue'
import { cn } from '@/lib/utils'
import { cardVariants, type CardVariants } from '.'

const props = defineProps<{
  variant?: CardVariants['variant']
  padding?: CardVariants['padding']
  class?: HTMLAttributes['class']
}>()
</script>

<template>
  <div data-slot="card" :class="cn(cardVariants({ variant, padding }), props.class)">
    <slot />
  </div>
</template>
