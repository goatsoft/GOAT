<script setup lang="ts">
defineProps<{ compact?: boolean }>()
</script>

<template>
  <div class="trail-preview" :class="{ compact }">
    <div class="trail-brand"><span>🐐</span> GOAT TRAILS <span class="trail-edition">FIELD GUIDE / 01</span></div>
    <div class="trail-copy"><small>LESS SCROLL. MORE SUMMIT.</small><h3>Take the<br /><em>goat path.</em></h3><p>Quiet trails. Big views.<br />A field guide for the curious.</p><span class="trail-cta">Find your next climb <i-hugeicons-arrow-up-right-01 aria-hidden="true" /></span></div>
    <svg class="trail-mountains" viewBox="0 0 500 320" preserveAspectRatio="xMidYMax slice" aria-hidden="true"><circle cx="377" cy="82" r="43" fill="#b4afff" opacity=".18" /><path d="M70 320 264 100 306 149 357 57 500 245V320Z" fill="#5644a0"/><path d="m357 57 32 87-29-14-16 20-38-1Z" fill="#c7bdff" opacity=".65"/><path d="m0 320 212-148 56 61 56-44 176 103v28Z" fill="#342b70"/><path d="m0 320 117-72 78 45 101-32 112 59Z" fill="#201e49"/><path d="M302 320c-83-27 72-46 14-76s-38-32-29-47" fill="none" stroke="#d0abff" stroke-width="3" stroke-dasharray="5 7" opacity=".8"/></svg>
    <div v-if="!compact" class="trail-footer"><span><i-hugeicons-folder-open aria-hidden="true" /> The trail collection</span><span>Made for wandering <i-hugeicons-arrow-right-02 aria-hidden="true" /></span></div>
  </div>
</template>

<style scoped>
.trail-preview { position:relative; isolation:isolate; overflow:hidden; min-height:325px; border-radius:11px; padding:22px 26px; border:1px solid #c1b3ff38; background:radial-gradient(ellipse at 95% 0,#7142ba55,transparent 60%),linear-gradient(135deg,#172c49,#221c43 65%); color:#f0eaff; display:flex; flex-direction:column }
.trail-brand { display:flex; align-items:center; gap:7px; font-size:9px; font-weight:750; letter-spacing:.16em }.trail-brand>span:first-child { font-size:19px }.trail-edition { margin-left:auto; font-size:7px; color:#c3b8e0; letter-spacing:.08em }
.trail-copy { position:relative; z-index:1; margin:25px 0 24px; max-width:230px }.trail-copy>small { font-size:7px; letter-spacing:.19em; color:#b6b8ef }.trail-copy h3 { margin:12px 0!important; font-size:39px!important; line-height:1.02; letter-spacing:-.045em; font-weight:650!important }.trail-copy em { color:#bdabff; font-style:normal }.trail-copy p { font-size:11px!important; line-height:1.6; color:#c8c8e2; margin:0 }
.trail-cta { display:inline-flex; align-items:center; gap:14px; padding:9px 12px; margin-top:17px; border:1px solid #ccbfff62; border-radius:30px; background:linear-gradient(125deg,#baa2ff30,#9cc4ff15); box-shadow:inset 0 1px 0 #ffffff21; backdrop-filter:blur(12px); font-size:9px; font-weight:600 }.trail-cta svg { width:13px; height:13px }
.trail-mountains { position:absolute; bottom:0; right:-20%; width:105%; height:85%; z-index:-1 }.trail-footer { margin-top:auto; display:flex; justify-content:space-between; gap:8px; border-top:1px solid #c0b6ff26; padding-top:12px; font-size:8px; color:#c5beda }.trail-footer span { display:flex; align-items:center; gap:5px }
.compact { min-height:170px; padding:15px 18px }.compact .trail-edition { display:none }.compact .trail-brand { font-size:8px }.compact .trail-brand>span:first-child { font-size:16px }.compact .trail-copy { margin:10px 0 0 }.compact .trail-copy>small,.compact .trail-copy p { display:none }.compact .trail-copy h3 { font-size:29px!important; margin:8px 0!important }.compact .trail-cta { margin-top:3px; padding:6px 10px; font-size:8px }.compact .trail-mountains { right:-12%; width:85%; height:100% }
@container(max-width:380px) { .trail-preview:not(.compact) { padding:20px }.trail-edition { display:none }.trail-copy h3 { font-size:35px!important }.trail-mountains { right:-35%; width:125%; opacity:.7 }.trail-footer { font-size:7px } }
</style>
