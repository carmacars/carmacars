'use client';
import { useEffect, useState } from 'react';
import { span } from './time';

// The portals' live countdown (portal-ui): it renders its text on the server, so nothing is missing without JavaScript,
// and its tick only settles in under prefers-reduced-motion: no-preference. Figures that count up: AnimatedNumber.

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
