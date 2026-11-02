'use client';
import Link from '@/components/Link';
import './quick-range.css';
import { QUICK_RANGES, activeRange, rangeFor, rangeHref } from '@/lib/nav/range';

/** The quick date range control (Release 27): Today · 7 days · 30 days · 90 days · Custom. The dates travel in the address
 * (links, so the page does not jump); Custom moves to the page's own From field (`customId`). On a phone it scrolls sideways. */
export function QuickRange({ base, keep = {}, from, to, today, customId, label = 'Dates', keys }: {
  base: string; keep?: Record<string, string | undefined>; from?: string | null; to?: string | null; today: string; customId?: string; label?: string;
  keys?: { from: string; to: string };
}) {
  const on = activeRange(from, to, today);
  return (
    <div className="qr" role="group" aria-label={label} data-testid="quick-range">
      {QUICK_RANGES.map((r) => (
        <Link key={r.key} prefetch={false} className={`qr__b${on === r.key ? ' is-on' : ''}`} href={rangeHref(base, keep, rangeFor(r.days, today), keys)}
          aria-current={on === r.key ? 'true' : undefined} data-testid={`qr-${r.key}`}>{r.label}</Link>
      ))}
      <button type="button" className={`qr__b${on === 'custom' ? ' is-on' : ''}`} aria-current={on === 'custom' ? 'true' : undefined} data-testid="qr-custom"
        onClick={() => { const el = customId ? document.getElementById(customId) : null; el?.focus(); }}>Custom</button>
    </div>
  );
}
