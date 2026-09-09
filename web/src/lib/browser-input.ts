/** Use the lightweight presentation on phones and other touch-first devices. */
export function usesTouchInput(): boolean {
  return typeof matchMedia === 'function' && matchMedia('(hover: none), (pointer: coarse)').matches
}
