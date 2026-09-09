<script setup lang="ts">
/** Every ADR in docs/adrs, generated at build time; drop <AdrList /> into any page. */
import { withBase } from 'vitepress'
import { adrs } from 'virtual:goat-data'
</script>

<template>
  <ol class="goat-adrs">
    <li v-for="a in adrs" :key="a.id">
      <a :href="withBase(`/adrs/${a.file.replace(/\.md$/, '')}`)">
        <span class="goat-adrs-id">{{ a.id }}</span>
        <span class="goat-adrs-title">{{ a.title }}</span>
      </a>
      <span class="goat-adrs-status" :data-status="a.status.split(/\s|·/)[0]?.toLowerCase()">{{ a.status }}</span>
    </li>
  </ol>
</template>
