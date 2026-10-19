'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { sampleCars } from '@/server/actions/supply';

// "Show sample cars" / "Hide sample cars" (migration 0065), on Admin > Cars, Sample cars and Settings > Site. Show puts
// the 20 example cars of the original seed back on the site (recreated with their photos and rates when deleted); Hide
// takes them all off at once and is never refused. Sample cars stay out of search engines and the sitemap.
export function SampleCarsToggle({ publicCount, compact = false }: { publicCount: number; compact?: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const shown = publicCount > 0;
  const go = () => start(async () => {
    const r = await sampleCars(shown ? 'sample_cars_hide' : 'sample_cars_show');
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: shown ? `${r.data.hidden ?? 0} sample cars hidden from the site.`
      : `${r.data.state.public} sample cars on the site${r.data.added ? ` (${r.data.added} recreated)` : ''}. They are marked "Example car" and stay out of search engines.` });
    router.refresh();
  });
  return (
    <span className={compact ? 'row' : 'stack'} data-testid="sample-cars-toggle">
      <button className={`btn btn--sm ${shown ? 'btn--ghost' : 'btn--primary'}`} type="button" disabled={pending} onClick={go} data-testid={shown ? 'sample-cars-hide' : 'sample-cars-show'}>
        {pending ? (shown ? 'Hiding' : 'Showing') : shown ? `Hide sample cars (${publicCount})` : 'Show sample cars'}
      </button>
      {msg && <span className={`small ${msg.ok ? '' : 'ad-flag ad-flag--red'}`} role={msg.ok ? 'status' : 'alert'}>{msg.text}</span>}
    </span>
  );
}
