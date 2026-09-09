<script setup lang="ts">
import type { HTMLAttributes } from 'vue'
import { computed } from 'vue'
import { DialogContent, type DialogContentEmits, type DialogContentProps, DialogOverlay, DialogPortal, useForwardPropsEmits } from 'reka-ui'
import { cn } from '@/lib/utils'

defineOptions({ inheritAttrs: false })

const props = defineProps<DialogContentProps & { class?: HTMLAttributes['class']; overlayClass?: HTMLAttributes['class'] }>()
const emits = defineEmits<DialogContentEmits>()
const delegated = computed(() => { const { class: _, overlayClass: _o, ...rest } = props; return rest })
const forwarded = useForwardPropsEmits(delegated, emits)
</script>

<template>
  <DialogPortal>
    <DialogOverlay
      :class="cn(
        'fixed inset-0 z-50 bg-black/60 backdrop-blur-sm',
        'data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=closed]:animate-out data-[state=closed]:fade-out-0',
        props.overlayClass,
      )"
    />
    <DialogContent
      v-bind="{ ...forwarded, ...$attrs }"
      :class="cn(
        'fixed left-1/2 top-1/2 z-50 -translate-x-1/2 -translate-y-1/2 outline-none',
        'data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=open]:zoom-in-95 data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-95',
        props.class,
      )"
    >
      <slot />
    </DialogContent>
  </DialogPortal>
</template>
