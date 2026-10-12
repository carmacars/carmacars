'use client';
import { useEffect, useState } from 'react';

// "Offer held until ..." with the time left, updated every 30 seconds. The deadline text is the
// server's (Toronto time); only the remaining time is computed here.
export function Countdown({ until, label }: { until: string; label: string }) {
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => { const first = setTimeout(() => setNow(Date.now()), 0); const t = setInterval(() => setNow(Date.now()), 30_000); return () => { clearTimeout(first); clearInterval(t); }; }, []);
  const left = now === null ? null : new Date(until).getTime() - now;
  const text = left === null ? '' : left <= 0 ? 'Expired' : left < 3600e3 ? `${Math.max(1, Math.round(left / 60e3))} min left` : left < 48 * 3600e3 ? `${Math.floor(left / 3600e3)} h ${Math.floor((left % 3600e3) / 60e3)} min left` : `${Math.round(left / 86400e3)} days left`;
  return (
    <div className={`pt-timer${left !== null && left < 3 * 3600e3 ? ' pt-timer--late' : ''}`} data-testid="offer-countdown">
      <span>{label}</span>
      <b suppressHydrationWarning>{text}</b>
    </div>
  );
}
