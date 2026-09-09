/**
 * Domain-warped fbm aurora, written twice: WGSL for WebGPU, GLSL ES 3.0 for WebGL2.
 * Both read the same 80-byte uniform block (see AuroraCanvas.vue for the layout).
 */

export const WGSL = /* wgsl */ `
struct U {
  res: vec2f, time: f32, scroll: f32,
  c0: vec3f, intensity: f32,
  c1: vec3f, scale: f32,
  c2: vec3f, speed: f32,
  fade: f32, seed: f32, stretch: f32, sweep: f32,
};
@group(0) @binding(0) var<uniform> u: U;

struct VOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f };

@vertex fn vs(@builtin(vertex_index) i: u32) -> VOut {
  var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  var o: VOut;
  o.pos = vec4f(p[i], 0.0, 1.0);
  o.uv = p[i] * 0.5 + 0.5;
  return o;
}

fn hash(p: vec2f) -> f32 { return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453123); }
fn noise(p: vec2f) -> f32 {
  let i = floor(p); let f = fract(p); let w = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2f(1.0, 0.0)), w.x), mix(hash(i + vec2f(0.0, 1.0)), hash(i + vec2f(1.0, 1.0)), w.x), w.y);
}
fn fbm(p0: vec2f) -> f32 {
  var p = p0; var v = 0.0; var a = 0.5;
  let m = mat2x2f(0.8, 0.6, -0.6, 0.8);
  for (var k = 0; k < 4; k++) { v += a * noise(p); p = m * p * 2.02; a *= 0.5; }
  return v;
}

@fragment fn fs(in: VOut) -> @location(0) vec4f {
  var uv = vec2f(in.uv.x, 1.0 - in.uv.y);
  let aspect = u.res.x / u.res.y;
  let p = (vec2f(uv.x * aspect * u.stretch, (uv.y + u.scroll) * 1.35) + vec2f(u.seed)) * u.scale;
  let t = u.time * u.speed;
  let q = vec2f(fbm(p + vec2f(0.0, t * 0.35)), fbm(p + vec2f(5.2, 1.3) - t * 0.25));
  let r = vec2f(fbm(p + 2.2 * q + vec2f(1.7, 9.2) + t * 0.15), fbm(p + 2.2 * q + vec2f(8.3, 2.8) - t * 0.12));
  let f = fbm(p + 2.4 * r);
  let band = smoothstep(0.48, 0.66, f) * (1.0 - smoothstep(0.66, 0.9, f));
  let glow = pow(f, 4.0);
  let a = clamp(band * 0.7 + glow * 0.3, 0.0, 1.0) * u.intensity;
  var col = mix(mix(u.c0, u.c1, clamp(r.x * 1.4, 0.0, 1.0)), u.c2, clamp(q.y * 1.2, 0.0, 1.0));
  // sweep: force a left→right c0→c2 gradient across the canvas (one cloud, blue to violet)
  col = mix(col, mix(u.c0, u.c2, smoothstep(0.0, 1.0, uv.x)) * (0.85 + 0.3 * r.x), u.sweep);
  var m = 1.0;
  if (u.fade > 0.5) { m = smoothstep(0.0, 0.22, uv.y) * (1.0 - smoothstep(0.78, 1.0, uv.y)); }
  return vec4f(col * a * m, a * m);
}
`

export const GLSL_VS = /* glsl */ `#version 300 es
precision highp float;
out vec2 v_uv;
void main() {
  vec2 p[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
  gl_Position = vec4(p[gl_VertexID], 0.0, 1.0);
  v_uv = p[gl_VertexID] * 0.5 + 0.5;
}
`

export const GLSL_FS = /* glsl */ `#version 300 es
precision highp float;
in vec2 v_uv;
out vec4 o;
layout(std140) uniform U {
  vec2 res; float time; float scroll;
  vec3 c0; float intensity;
  vec3 c1; float scale;
  vec3 c2; float speed;
  float fade; float seed; float stretch; float sweep;
};
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
float noise(vec2 p) {
  vec2 i = floor(p); vec2 f = fract(p); vec2 w = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), w.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), w.x), w.y);
}
float fbm(vec2 p) {
  float v = 0.0; float a = 0.5; mat2 m = mat2(0.8, 0.6, -0.6, 0.8);
  for (int k = 0; k < 4; k++) { v += a * noise(p); p = m * p * 2.02; a *= 0.5; }
  return v;
}
void main() {
  vec2 uv = vec2(v_uv.x, 1.0 - v_uv.y);
  float aspect = res.x / res.y;
  vec2 p = (vec2(uv.x * aspect * stretch, (uv.y + scroll) * 1.35) + vec2(seed)) * scale;
  float t = time * speed;
  vec2 q = vec2(fbm(p + vec2(0.0, t * 0.35)), fbm(p + vec2(5.2, 1.3) - t * 0.25));
  vec2 r = vec2(fbm(p + 2.2 * q + vec2(1.7, 9.2) + t * 0.15), fbm(p + 2.2 * q + vec2(8.3, 2.8) - t * 0.12));
  float f = fbm(p + 2.4 * r);
  float band = smoothstep(0.48, 0.66, f) * (1.0 - smoothstep(0.66, 0.9, f));
  float glow = pow(f, 4.0);
  float a = clamp(band * 0.7 + glow * 0.3, 0.0, 1.0) * intensity;
  vec3 col = mix(mix(c0, c1, clamp(r.x * 1.4, 0.0, 1.0)), c2, clamp(q.y * 1.2, 0.0, 1.0));
  col = mix(col, mix(c0, c2, smoothstep(0.0, 1.0, uv.x)) * (0.85 + 0.3 * r.x), sweep);
  float m = 1.0;
  if (fade > 0.5) { m = smoothstep(0.0, 0.22, uv.y) * (1.0 - smoothstep(0.78, 1.0, uv.y)); }
  o = vec4(col * a * m, a * m);
}
`

export const PALETTES: Record<string, [number[], number[], number[]]> = {
  blue: [[0.23, 0.63, 1.0], [0.48, 0.82, 1.0], [0.48, 0.36, 1.0]],
  violet: [[0.71, 0.29, 1.0], [0.48, 0.36, 1.0], [0.88, 0.55, 1.0]],
  green: [[0.2, 0.83, 0.6], [0.23, 0.63, 1.0], [0.43, 0.91, 0.72]],
  indigo: [[0.48, 0.36, 1.0], [0.36, 0.62, 1.0], [0.66, 0.5, 1.0]],
  aurora: [[0.23, 0.63, 1.0], [0.48, 0.36, 1.0], [0.71, 0.29, 1.0]],
}
