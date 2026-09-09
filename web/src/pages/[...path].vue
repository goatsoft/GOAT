<script setup lang="ts">
</script>

<template>
  <main class="flex min-h-dvh flex-col items-center justify-center px-6 text-center">
    <img :src="asset('img/goat-dark.webp')" alt="" class="mb-6 size-28 opacity-60" />
    <p class="font-mono text-xs uppercase tracking-[0.2em] text-primary">404</p>
    <h1 class="mt-3 text-4xl font-semibold tracking-tight">Wandered off the pasture.</h1>
    <p class="mt-3 text-muted-foreground">That page does not exist.</p>
    <Button class="mt-8" as-child><RouterLink to="/">Back home</RouterLink></Button>
  </main>
</template>
