<script setup lang="ts">
/** The "open source" pill under the masthead. Static: the motion lives on the Download button. */
</script>

<template>
  <span class="inline-flex items-center gap-2.5 rounded-full border border-white/10 bg-[#0c0e1c]/80 px-4 py-1.5 text-xs font-medium tracking-wide text-goat-ink backdrop-blur-md">
    <span class="inline-flex items-center gap-1.5"><i-simple-icons-github class="size-4 opacity-90" /> Open source</span>
    <span class="h-3 w-px bg-white/15" />
    <span class="inline-flex items-center gap-1.5"><i-hugeicons-laptop class="size-4 opacity-90" /> macOS 26</span>
    <span class="h-3 w-px bg-white/15" />
    <span class="inline-flex items-center gap-1.5"><i-hugeicons-cpu class="size-4 opacity-90" /> Apple Silicon</span>
  </span>
</template>
