<script setup lang="ts">
import { cn } from '@/lib/utils'
withDefaults(defineProps<{ title?: string; class?: string; sidebar?: boolean }>(), { title: 'GOAT', sidebar: true })
</script>

<template>
  <div :class="cn('app-glass', $props.class)">
    <div class="window-content">
      <aside v-if="sidebar" class="mock-sidebar" aria-label="Illustrated project sidebar">
        <div class="sidebar-window-controls"><div class="traffic-lights" aria-hidden="true"><span /><span /><span /></div></div>
        <div class="sidebar-search"><i-hugeicons-search-01 aria-hidden="true" /> Search chats</div>
        <div class="sidebar-action"><i-hugeicons-edit-02 aria-hidden="true" /> New chat</div>
        <div class="sidebar-action"><i-hugeicons-folder-management aria-hidden="true" /> Pens</div>
        <div class="sidebar-label">Your Pens <i-hugeicons-add-01 aria-hidden="true" /></div>
        <div class="sidebar-pen violet"><i-hugeicons-chevron-down aria-hidden="true" /><span>🐐</span> Goat Trails <i-hugeicons-add-01 class="pen-add" aria-hidden="true" /></div>
        <div class="sidebar-chat active"><span /> A trail worth taking</div>
        <div class="sidebar-chat"><span /> The summit checklist</div>
        <div class="sidebar-pen teal"><i-hugeicons-chevron-right aria-hidden="true" /><span>🌱</span> Pasture Notes</div>
        <div class="sidebar-pen amber"><i-hugeicons-chevron-right aria-hidden="true" /><span>🏔️</span> Summit Lab</div>
        <div class="sidebar-label">Chats <i-hugeicons-add-01 aria-hidden="true" /></div>
        <div class="plain-chat">A little mountain thinking</div>
        <div class="sidebar-engine"><div><span class="engine-dot" /><strong>Local engine</strong><span class="model-count">3 models</span><i-hugeicons-settings-01 aria-hidden="true" /></div><small>localhost</small></div>
      </aside>
      <div class="window-main">
    <div class="window-toolbar">
      <div class="traffic-lights" :class="{ 'narrow-only-controls': sidebar }" aria-hidden="true"><span /><span /><span /></div>
      <span class="toolbar-icon" aria-hidden="true"><i-hugeicons-sidebar-left /></span>
      <div class="window-title">{{ title }}</div>
      <span class="toolbar-icon" aria-hidden="true"><i-hugeicons-command-line /></span>
      <span class="toolbar-icon" aria-hidden="true"><i-hugeicons-sidebar-right /></span>
    </div>
        <slot />
      </div>
    </div>
  </div>
</template>

<style scoped>
.app-glass { position:relative; display:flex; flex-direction:column; overflow:hidden; border-radius:23px; padding:5px; color:#ececf6; border:1px solid #b8ceff40; background:linear-gradient(140deg,#b7d9ff24,#bab7e40c 42%,#d6b8ff20),#141625df; box-shadow:inset 0 1px 0 #ffffff38,inset 0 -1px 0 #ffffff10,0 35px 90px -25px #000b,0 0 35px #8577ff0b; backdrop-filter:blur(32px) saturate(145%); -webkit-backdrop-filter:blur(32px) saturate(145%); font-size:13px }
.window-toolbar { display:flex; align-items:center; gap:12px; height:44px; padding:0 11px 4px; flex-shrink:0 }
.traffic-lights { display:flex; gap:7px; margin-right:5px }
.traffic-lights span { width:10px; height:10px; border-radius:50%; background:#ff6058; box-shadow:inset 0 0 0 1px #0001 }
.traffic-lights span:nth-child(2) { background:#ffbd2e }.traffic-lights span:nth-child(3) { background:#28c840 }
.toolbar-icon { display:grid; place-items:center; width:25px; height:25px; flex-shrink:0; border:1px solid #e2e5ff14; border-radius:50%; background:#1416243d; color:#a5a9bf }.toolbar-icon svg { width:15px; height:15px }
.window-title { min-width:0; flex:1; text-align:center; overflow:hidden; white-space:nowrap; text-overflow:ellipsis; font-size:11px; font-weight:500; color:#c0bfd2 }
.window-content { display:flex; flex:1; min-height:0; border-radius:18px; overflow:hidden }
.window-main { display:flex; flex:1; flex-direction:column; min-width:0 }
.mock-sidebar { display:none; flex-direction:column; width:190px; flex-shrink:0; padding:0 9px 13px; border-radius:17px; border:1px solid #c8d5ff18; background:linear-gradient(160deg,#b0d7ff0d,#dac8ff0a); box-shadow:inset 0 1px 0 #ffffff08 }
.sidebar-window-controls { display:flex; align-items:center; height:43px; padding-left:4px; margin-bottom:13px; flex-shrink:0 }
.sidebar-search { display:flex; align-items:center; gap:7px; padding:9px; margin-bottom:12px; border:1px solid #b0b9d328; border-radius:9px; color:#a6aabc; font-size:11px; background:#0c122b50 }
.sidebar-action { display:flex; align-items:center; gap:10px; padding:9px; font-size:12px; font-weight:600 }.sidebar-action svg { color:#52b5ff; width:17px; height:17px }
.sidebar-label { display:flex; justify-content:space-between; align-items:center; margin:24px 7px 9px; font-size:10px; font-weight:600; color:#939aaf }
.sidebar-pen { --pen:#b191ff; display:flex; align-items:center; gap:6px; margin-bottom:5px; padding:4px 6px; line-height:14px; border-radius:6px; border:1px solid color-mix(in srgb,var(--pen) 38%,transparent); background:color-mix(in srgb,var(--pen) 15%,transparent); font-size:11px; font-weight:600 }
.sidebar-pen svg { color:var(--pen); width:12px; height:12px }.sidebar-pen>span { font-size:13px; line-height:14px }.sidebar-pen .pen-add { margin-left:auto }.sidebar-pen.teal { --pen:#38c9b7; margin-top:9px }.sidebar-pen.amber { --pen:#e5b75b; margin-top:4px }
.sidebar-chat { display:flex; align-items:center; gap:7px; padding:8px 5px; margin-left:7px; color:#c3bfd7; font-size:10px; border-radius:6px }.sidebar-chat span { width:5px; height:5px; border-radius:50%; background:#b08bf3; flex-shrink:0 }.sidebar-chat.active { background:#9d70e936; color:#eee2ff }
.plain-chat { padding:4px 7px; font-size:10px; color:#bec0d2 }
.sidebar-engine { margin-top:auto; padding-top:25px; font-size:9px }.sidebar-engine>div { display:flex; align-items:center; gap:5px; padding-top:12px; border-top:1px solid #d2d5ff12 }.sidebar-engine svg { margin-left:auto; width:15px; height:15px }.sidebar-engine small { display:block; margin:5px 0 0 11px; color:#949bb1; font-size:9px }.engine-dot { width:5px; height:5px; border-radius:50%; background:#37dd92 }.model-count { color:#65b7ff; background:#339dff13; padding:3px 5px; border-radius:20px }
@container(min-width:700px) { .mock-sidebar { display:flex }.narrow-only-controls { display:none } }
@container(max-width:380px) { .window-toolbar { gap:7px; padding-inline:8px }.toolbar-icon { width:22px; height:22px }.window-toolbar>.toolbar-icon:nth-last-child(2) { display:none }.app-glass { border-radius:20px } }
</style>
