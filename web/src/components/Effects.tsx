'use client';
import { usePathname } from 'next/navigation';
import { useEffect, useRef } from 'react';

// Scroll effects fallback (prototype app.js): browsers without scroll-driven animations get an
// IntersectionObserver that adds .is-in once. Nothing animates under prefers-reduced-motion.
// The motion layer (styles/motion.css): html.motion for a person's browser with motion allowed (never an automated
// one), a soft entry on each client navigation, and sections below the fold that rise in once they scroll into view.
const REVEAL = 'main section, main .car-card, main .hub-card, main .pt-card, main .ad-card';
export function Effects() {
  const path = usePathname();
  const first = useRef(true);
  useEffect(() => {
    const root = document.documentElement;
    root.classList.add('js');
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const motion = !reduce && !navigator.webdriver && 'IntersectionObserver' in window;
    root.classList.toggle('motion', motion);
    let t: ReturnType<typeof setTimeout> | undefined;
    if (motion && !first.current) {
      root.classList.remove('route-in'); void root.offsetWidth; root.classList.add('route-in');
      t = setTimeout(() => root.classList.remove('route-in'), 600);
    }
    first.current = false;
    const els = Array.from(document.querySelectorAll('.fx-wipe, .fx-line, .fx-grow-y'));
    const native = CSS.supports?.('animation-timeline: view()');
    let io: IntersectionObserver | undefined;
    if (native || reduce || !('IntersectionObserver' in window)) els.forEach((e) => e.classList.add('is-in'));
    else {
      io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('is-in'); io!.unobserve(e.target); } }), { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });
      els.forEach((e) => io!.observe(e));
    }
    let ro: IntersectionObserver | undefined;
    if (motion) {
      // only what starts below the fold: nothing already on screen is hidden, so nothing flashes or shifts
      const fold = window.innerHeight;
      ro = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('is-in'); ro!.unobserve(e.target); } }), { rootMargin: '0px 0px -8% 0px', threshold: 0.05 });
      let n = 0;
      for (const e of Array.from(document.querySelectorAll<HTMLElement>(REVEAL))) {
        if (n >= 60) break;
        if (e.hasAttribute('data-reveal') || e.parentElement?.closest('[data-reveal]') || e.getBoundingClientRect().top <= fold) continue;
        e.setAttribute('data-reveal', ''); ro.observe(e); n++;
      }
    }
    return () => { io?.disconnect(); ro?.disconnect(); if (t) clearTimeout(t); };
  }, [path]);
  return null;
}
