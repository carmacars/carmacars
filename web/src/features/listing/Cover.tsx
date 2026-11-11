'use client';
import { useCallback, useEffect, useState, useTransition } from 'react';
import { staffDo, staffRead } from '@/server/actions/staff-tools';
import { photoUrl } from '@/lib/photo';

// Release 36 (2100): the listing's first photo, chosen per listing and switchable any time, on the site and on Marketplace:
// the plain cover photo, the car-show photo with a model (the image model), or the flyer (the price, the offer, the call to
// action and the logo drawn on the cover). The words and the model's description are Program settings (Listings).
type Style = 'plain' | 'model' | 'flyer';
type Made = { style: 'model' | 'flyer'; status: 'queued' | 'made' | 'needs_gemini' | 'failed'; path: string | null; provider: string | null; note: string | null; current: boolean; at: string };
type Data = { style: Style; cover_photo: string | null; shown: string | null; covers: Made[]; flyer: { headline?: string; offer?: string; cta?: string; badge?: string } };
const STYLES: Array<[Style, string, string]> = [
  ['plain', 'Plain car', 'The cover photo as it is.'],
  ['model', 'With a model', 'A car-show photo: the image model adds a fully clothed adult model beside the car.'],
  ['flyer', 'Flyer', 'The cover with the price a day, the offer, the call to action and the logo.']
];
const STATUS: Record<Made['status'], string> = { queued: 'Being made', made: 'Made', needs_gemini: 'Needs the image model', failed: 'Failed' };

export function ListingCover({ vehicle }: { vehicle: string }) {
  const [d, setD] = useState<Data | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [tick, setTick] = useState(0);
  const load = useCallback(() => setTick((n) => n + 1), []);
  useEffect(() => { let on = true; void staffRead<Data>('listing_cover', { vehicle }).then((r) => { if (on && r.ok) setD(r.data); }); return () => { on = false; }; }, [vehicle, tick]);
  const mine = d?.covers.find((c) => c.style === d.style) ?? null;
  const busy = mine?.status === 'queued';
  useEffect(() => { if (!busy) return; const t = setInterval(load, 8000); return () => clearInterval(t); }, [busy, load]);
  if (!d) return null;
  const set = (style: Style, remake = false) => start(async () => {
    const r = await staffDo<Data>('listing_cover_set', { vehicle, style, remake }, ['/cars']);
    if (r.ok) { setD(r.data); setMsg({ ok: true, text: style === 'plain' ? 'The plain cover photo shows first.' : remake ? 'Being made again.' : 'Chosen. It shows first once it is made; the plain cover shows until then.' }); }
    else setMsg({ ok: false, text: r.message });
  });
  return (
    <section className="stack" data-testid="listing-cover" aria-labelledby={`lc-${vehicle}`}>
      <h3 className="d4" id={`lc-${vehicle}`}>First photo</h3>
      <p className="small muted">What shows first on the site and in the Marketplace kit. Switch any time; the other photos stay as they are.</p>
      <fieldset className="row" disabled={pending}>
        <legend className="sr-only">First photo</legend>
        {STYLES.map(([v, label, hint]) => (
          <label key={v} className="small" title={hint}>
            <input type="radio" name={`cover-${vehicle}`} value={v} checked={d.style === v} onChange={() => set(v)} data-testid={`listing-cover-${v}`} /> {label}
          </label>))}
      </fieldset>
      {d.style !== 'plain' && (
        <div className="row" data-testid="listing-cover-state" data-status={mine?.status ?? 'none'}>
          {/* eslint-disable-next-line @next/next/no-img-element -- made at the frame's size by the pipeline */}
          {d.shown ? <a href={photoUrl(d.shown)} target="_blank" rel="noreferrer"><img src={photoUrl(d.shown)} alt="The first photo as shown" width={240} height={160} loading="lazy" /></a> : null}
          <p className="small">
            {mine ? <><b>{STATUS[mine.status]}</b>{mine.status === 'made' && !mine.current ? ' (out of date: being made again with the new price or photo)' : ''}{mine.note && mine.status !== 'made' ? `: ${mine.note}` : ''}</> : 'Not made yet.'}
            {!d.shown && ' The plain cover shows until it is made.'}
          </p>
          {d.style === 'flyer' && <p className="small muted">{[d.flyer.headline, d.flyer.offer, d.flyer.cta, d.flyer.badge].filter(Boolean).join(' · ')}</p>}
          <button className="btn btn--ghost btn--sm" type="button" disabled={pending || busy} onClick={() => set(d.style, true)} data-testid="listing-cover-remake">{busy ? 'Being made…' : 'Make it again'}</button>
        </div>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </section>
  );
}
