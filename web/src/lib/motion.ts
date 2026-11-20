'use client';
// Motion (src/styles/motion.css, src/components/Effects.tsx): every script that moves something asks this first.
// r48 AN: and not paused by the pause control (html[data-motion="reduced"], src/portable/motion)
export const motionOK = () => typeof window !== 'undefined' && !window.matchMedia('(prefers-reduced-motion: reduce)').matches
  && document.documentElement.dataset.motion !== 'reduced';
