'use client';
import { useEffect, useRef, useState } from 'react';
import { span } from './time';

// The portals' live pieces (portal-ui): a countdown that ticks and a number that counts up once when it comes into view.
// Both render their final text on the server, so nothing is missing without JavaScript, and neither moves under
// prefers-reduced-motion.

/** "Pickup in 2 days 4 h", updated every 30 seconds; once the time has passed, `after` (with the time since, if it has {t}). */
export function LiveCountdown({ until, before, after, initial, testId }: { until: string; before: string; after: string; initial: string; testId?: string }) {
  const [text, setText] = useState(initial);
  useEffect(() => {
    const at = new Date(until).getTime();
    const run = () => {
      const left = at - Date.now();
      setText(left > 0 ? `${before} ${span(left)}` : after.replace('{t}', span(left)));
    };
    const first = setTimeout(run, 0);
    const t = setInterval(run, 30_000);
    return () => { clearTimeout(first); clearInterval(t); };
  }, [until, before, after]);
  // a new text remounts the inner span, so it settles in (portal-ui.css, pu-tick)
  return <span className="pu-count" data-testid={testId}><span key={text} className="pu-count__text" suppressHydrationWarning>{text}</span></span>;
}

/** A money or count value that counts up from zero the first time it scrolls into view. `text` is the final text. */
export function CountUp({ cents, text, format = 'money' }: { cents: number; text: string; format?: 'money' | 'number' }) {
  const ref = useRef<HTMLSpanElement>(null);
  const [shown, setShown] = useState(text);
  useEffect(() => {
    const el = ref.current;
    if (!el || cents === 0 || matchMedia('(prefers-reduced-motion: reduce)').matches || !('IntersectionObserver' in window)) return;
    let raf = 0;
    const d = text.includes('.') ? 2 : 0;
    // the same shape as money() of src/lib/format.ts
    const fmt = (v: number) => (format === 'money' ? `$${(v / 100).toLocaleString('en-CA', { minimumFractionDigits: d, maximumFractionDigits: d })}` : String(Math.round(v)));
    const io = new IntersectionObserver(([e]) => {
      if (!e?.isIntersecting) return;
      io.disconnect();
      const t0 = performance.now(), dur = 700;
      const step = (now: number) => {
        const p = Math.min(1, (now - t0) / dur), eased = 1 - Math.pow(1 - p, 3);
        setShown(p >= 1 ? text : fmt(cents * eased));
        if (p < 1) raf = requestAnimationFrame(step);
      };
      raf = requestAnimationFrame(step);
    }, { threshold: 0.6 });
    io.observe(el);
    return () => { io.disconnect(); cancelAnimationFrame(raf); };
  }, [cents, text, format]);
  return <span ref={ref} className="pu-num" suppressHydrationWarning>{shown}</span>;
}
