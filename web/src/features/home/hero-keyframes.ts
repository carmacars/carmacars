// The hero's cross-fade (release 28, B5; HeroSlides.tsx): 6 seconds a car, a 1-second fade. Pure, for the unit test.
export const STEP = 6, FADE = 1;

export function heroKeyframes(n: number): string {
  if (n < 2) return '';
  const cycle = n * STEP;
  const pct = (s: number) => `${((s / cycle) * 100).toFixed(3)}%`;
  return `@keyframes hero-slides-${n}{0%{opacity:0}${pct(FADE)}{opacity:1}${pct(STEP)}{opacity:1}${pct(STEP + FADE)}{opacity:0}100%{opacity:0}}`;
}
