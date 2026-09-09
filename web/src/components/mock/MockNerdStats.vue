<script setup lang="ts">
// Match the native ThroughputDial's 240-degree sweep and 25 tick intervals.
const point = (fraction: number, radius: number) => {
  const angle = (150 + fraction * 240) * Math.PI / 180
  return { x: 120 + Math.cos(angle) * radius, y: 88 + Math.sin(angle) * radius }
}
const ticks = Array.from({ length: 26 }, (_, i) => ({
  start: point(i / 25, i % 5 === 0 ? 67 : 72), end: point(i / 25, 79),
  label: point(i / 25, 52), major: i % 5 === 0, value: i * 4,
}))
const needle = point(.684, 67)
</script>

<template>
  <section class="nerd-stats" aria-label="Nerd Stats with illustrative sample readings">
    <div class="stats-heading"><strong><i-hugeicons-activity-03 aria-hidden="true" /> Stats</strong><span>Sample</span></div>
    <svg class="throughput-dial" viewBox="0 0 240 158" role="img" aria-label="Sample generation speed: 68.4 tokens per second, scale zero to 100">
      <path d="M50.72 128 A80 80 0 1 1 189.28 128" fill="none" stroke="#aaa9cb38" stroke-width="7" stroke-linecap="round" />
      <g v-for="(tick, i) in ticks" :key="i"><line :x1="tick.start.x" :y1="tick.start.y" :x2="tick.end.x" :y2="tick.end.y" :stroke="tick.major ? '#e1ddef' : '#9795b4'" :stroke-width="tick.major ? 2 : 1.2" /><text v-if="tick.major" :x="tick.label.x" :y="tick.label.y" text-anchor="middle" dominant-baseline="central" fill="#d6d1e7" font-size="9">{{ tick.value }}</text></g>
      <line x1="120" y1="88" :x2="needle.x" :y2="needle.y" stroke="#65b5ff" stroke-width="3.5" stroke-linecap="round" /><circle cx="120" cy="88" r="5" fill="#65b5ff" />
      <text x="120" y="138" text-anchor="middle" fill="#f2edff" font-size="23" font-weight="700">68.4</text><text x="120" y="152" text-anchor="middle" fill="#a4a0bc" font-size="9">tok/s</text>
    </svg>
    <p class="stats-caption">Latest measured response</p>
    <div class="stats-metrics"><div><span>First token</span><strong>0.42s</strong></div><div><span>Output</span><strong>684</strong></div><div><span>Duration</span><strong>10.4s</strong></div></div>
    <div class="context-pressure"><div class="context-ring"><strong>24%</strong><small>context</small></div><div><strong>Context pressure</strong><p>7.9k / 32.8k</p><small>Engine reported</small></div></div>
    <div class="history-heading"><strong>Recent responses</strong><span>tok/s</span></div>
    <div class="history-bars" role="img" aria-label="Illustrative recent response speeds, newest on the right"><span v-for="(height, i) in [63, 76, 69, 81, 74, 86, 79, 82]" :key="i" :style="{ height: `${height}%` }" /></div>
    <div class="history-legend"><span class="reported" /> Reported <span class="derived" /> Derived</div>
  </section>
</template>

<style scoped>
.nerd-stats { border:1px solid #94b8ff25; border-radius:15px; background:#0d102450; padding:15px; font-size:10px; color:#dfdded; box-shadow:inset 0 1px 0 #ffffff08 }
.stats-heading,.stats-heading strong { display:flex; align-items:center; gap:6px }.stats-heading { justify-content:space-between }.stats-heading strong { font-size:12px }.stats-heading svg { color:#c4bfff; width:16px; height:16px }.stats-heading>span { font-size:9px; color:#a5a0bc }
.throughput-dial { display:block; width:100%; margin-top:12px; overflow:visible }.stats-caption { margin:6px 0 13px!important; color:#a7a3bc; font-size:9px; text-align:center }.stats-metrics { display:flex; justify-content:space-between; gap:5px }.stats-metrics span { display:block; color:#a7a3bc; font-size:8px }.stats-metrics strong { display:block; margin-top:3px; font-size:11px; font-variant-numeric:tabular-nums }
.context-pressure { display:flex; align-items:center; gap:10px; margin-top:16px; padding-top:14px; border-top:1px solid #c6bded20 }.context-ring { display:flex; flex-direction:column; align-items:center; justify-content:center; position:relative; width:58px; height:58px; flex-shrink:0; border-radius:50%; background:conic-gradient(#62b0ff 0% 24%,#bbb6d51a 24%); isolation:isolate }.context-ring:before { content:''; position:absolute; inset:5px; border-radius:50%; background:#1b1c30; z-index:-1 }.context-ring strong { font-size:13px }.context-ring small { font-size:7px!important }.context-pressure p { margin:4px 0!important; font-size:11px }.context-pressure small { color:#a7a3bc; font-size:8px }.context-pressure>div>strong { font-size:9px }
.history-heading { display:flex; justify-content:space-between; margin-top:17px; padding-top:13px; border-top:1px solid #c6bded20; font-size:9px }.history-heading>span { color:#a7a3bc }.history-bars { display:flex; align-items:flex-end; justify-content:space-around; gap:7px; height:55px; margin-top:8px; padding:0 5px; border-bottom:1px solid #aea6cf33; background:repeating-linear-gradient(to top,transparent 0 24px,#bbb6d512 24px 25px) }.history-bars span { flex:1; max-width:14px; border-radius:3px 3px 0 0; background:linear-gradient(#ce85ff,#9956f4) }.history-bars span:last-child { background:linear-gradient(#83caff,#3597ef) }.history-legend { display:flex; align-items:center; gap:5px; font-size:8px; color:#a7a3bc; margin-top:8px }.history-legend span { width:5px; height:5px; border-radius:50% }.reported { background:#5fb4ff }.derived { background:#b66cff; margin-left:5px }
</style>
