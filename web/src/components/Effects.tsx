'use client';
import { usePathname } from 'next/navigation';
import { useEffect } from 'react';

// Scroll effects fallback (prototype app.js): browsers without scroll-driven animations get an
// IntersectionObserver that adds .is-in once. Nothing animates under prefers-reduced-motion.
export function Effects() {
  const path = usePathname();
  useEffect(() => {
    document.documentElement.classList.add('js');
    const els = Array.from(document.querySelectorAll('.fx-wipe, .fx-line, .fx-grow-y'));
    const native = CSS.supports?.('animation-timeline: view()');
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (native || reduce || !('IntersectionObserver' in window)) { els.forEach((e) => e.classList.add('is-in')); return; }
    const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('is-in'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });
    els.forEach((e) => io.observe(e));
    return () => io.disconnect();
  }, [path]);
  return null;
}
