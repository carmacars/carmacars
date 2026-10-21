'use client';
// Motion (src/styles/motion.css, src/components/Effects.tsx): every script that moves something asks this first.
export const motionOK = () => typeof window !== 'undefined' && !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
