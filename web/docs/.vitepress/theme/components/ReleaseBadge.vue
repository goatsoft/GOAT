<script setup lang="ts">
import { release } from 'virtual:goat-data'
import publication from '../../../../publication.json'
const available = publication.releaseTag === `v${release.version}`
</script>

<template>
  <span class="goat-release">{{ release.label }}{{ available ? '' : ' · Source preview' }}</span>
</template>
