'use client';
import { useEffect, useState } from 'react';
import { span } from './model';

// A countdown that moves every 30 seconds: "1h 28m left", then "12m over" in red once the time has passed. Starts from the
// page's own clock (at), so the first render matches the server's.
export function Countdown({ to, at, left = 'left', over = 'over', testId }: { to: string; at: number; left?: string; over?: string; testId?: string }) {
  const [now, setNow] = useState(at);
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 30_000); return () => clearInterval(t); }, []);
  const ms = new Date(to).getTime() - now;
  return <span className={`bn-cd${ms < 0 ? ' is-over' : ms < 30 * 60_000 ? ' is-near' : ''}`} data-testid={testId}>{span(ms)} {ms < 0 ? over : left}</span>;
}
