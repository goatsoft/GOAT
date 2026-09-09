<script setup lang="ts">
/**
 * Page background: one GPU aurora pinned to the viewport, following scroll at a
 * quarter of the page speed. Sits behind everything; the hero paints over it.
 */
</script>

<template>
  <AuroraCanvas fixed hue="aurora" :intensity="0.18" :scale="1.0" :speed="0.04" :parallax="0.22" class="-z-10" />
</template>
