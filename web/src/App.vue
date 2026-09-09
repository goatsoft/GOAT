<script setup lang="ts">
</script>

<template>
  <!-- reduced-motion="user": motion-v drops transforms/blur for people who asked the OS for less motion. -->
  <MotionConfig reduced-motion="user">
    <div class="relative isolate min-h-dvh overflow-x-clip bg-background text-foreground">
      <AmbientGlow />
      <SiteNav />
      <RouterView />
      <SiteFooter />
    </div>
  </MotionConfig>
</template>
