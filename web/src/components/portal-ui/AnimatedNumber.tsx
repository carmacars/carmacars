'use client';
import { useEffect, useRef, useState } from 'react';
import { money } from '@/lib/format';
import { motionOK } from '@/lib/motion';

export type NumberFormat = 'money' | 'cents' | 'int' | 'pct1' | 'x';
/** The one formatter of portal-ui figures: money is integer cents, as the database stores it. */
export function formatNumber(v: number, f: NumberFormat): string {
  switch (f) {
    case 'money': return money(Math.round(v));
    case 'cents': return money(Math.round(v), { cents: true });
    case 'pct1': return `${(Math.round(v * 10) / 10).toLocaleString('en-CA')}%`;
    case 'x': return `${(Math.round(v * 10) / 10).toLocaleString('en-CA', { minimumFractionDigits: 1 })}x`;
    default: return Math.round(v).toLocaleString('en-CA');
  }
}

// A figure that counts up once when it first comes into view. The server renders the final value (no script, a test or
// reduced motion: it never moves); the count runs only where motion is allowed, from 0 to the value in about a second.
export function AnimatedNumber({ value, format = 'int', testId, className }: { value: number; format?: NumberFormat; testId?: string; className?: string }) {
  const final = formatNumber(value, format);
  // the figure while it counts; null at rest, when the final value shows
  const [text, setText] = useState<string | null>(null);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || !motionOK() || !value || typeof IntersectionObserver === 'undefined') return;
    let raf = 0;
    const io = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      const t0 = performance.now();
      const dur = 1100;
      const step = (t: number) => {
        const p = Math.min(1, (t - t0) / dur);
        const eased = 1 - Math.pow(1 - p, 4);
        setText(p >= 1 ? null : formatNumber(value * eased, format));
        if (p < 1) raf = requestAnimationFrame(step);
      };
      raf = requestAnimationFrame(step);
    }, { threshold: 0.4 });
    io.observe(el);
    return () => { io.disconnect(); cancelAnimationFrame(raf); };
  }, [value, format]);
  return <span ref={ref} className={className} data-testid={testId}>{text ?? final}</span>;
}
