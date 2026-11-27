'use client';
import { useEffect, useMemo, useState } from 'react';
import { PHOTO_ACCEPT } from '@/features/uploads/formats';
import { toStandardImage } from '@/features/uploads/standard-image';
import { groupByTime } from './group';
import { pickedTime, useUploads, type Kind } from './useUploads';
import { UploadList } from './UploadList';

// Add old photos, the pile (5185): pick every photo at once. They are grouped by the time they were taken (Program settings
// old_photos_group_minutes); the plate is read from up to two photos of each group (the vision chain, inside its daily
// allowance); the database suggests the check-in or check-out nearest in time, on that car when the plate matched. One tap
// confirms a group; Change picks another of the suggestions.
interface Pick { id: string; file: File; at: string | null; url: string }
interface Option { booking_id: string; booking_number: string; kind: Kind; at: string; car: string | null; plate: string | null; renter: string | null; minutes_off: number }
interface Suggestion { i: number; plate: string | null; plate_matched: boolean; options: Option[] }
type Status = 'reading' | 'ready' | 'sent';

const fmt = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso)) : 'No time on these photos');
const off = (m: number) => (m < 1 ? 'taken at that time' : m < 90 ? `${m} min apart` : `${Math.round(m / 60)} h apart`);
const word = (k: Kind) => (k === 'pickup' ? 'Check-in' : 'Check-out');

async function small(file: File): Promise<string | null> {
  try {
    const bmp = await createImageBitmap(await toStandardImage(file));
    const k = Math.min(1, 1024 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
    c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
    return c.toDataURL('image/jpeg', 0.8);
  } catch { return null; }
}
async function readPlate(file: File): Promise<string | null> {
  const image = await small(file);
  if (!image) return null;
  try {
    const r = await fetch('/api/old-photos/plate', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ image }) });
    const j = (await r.json().catch(() => null)) as { plate?: string | null } | null;
    return j?.plate ?? null;
  } catch { return null; }
}

export function Bulk({ gapMinutes }: { gapMinutes: number }) {
  const [picks, setPicks] = useState<Pick[]>([]);
  const [status, setStatus] = useState<Status | null>(null);
  const [sugg, setSugg] = useState<Record<number, Suggestion>>({});
  const [chosen, setChosen] = useState<Record<number, number>>({});
  const [sent, setSent] = useState<Record<number, boolean>>({});
  const [err, setErr] = useState<string | null>(null);
  const up = useUploads();
  const groups = useMemo(() => groupByTime(picks, gapMinutes), [picks, gapMinutes]);
  useEffect(() => () => picks.forEach((p) => URL.revokeObjectURL(p.url)), [picks]);

  async function choose(files: FileList | null) {
    if (!files?.length) return;
    setErr(null); setStatus('reading'); setSugg({}); setChosen({}); setSent({});
    const next = await Promise.all(Array.from(files).map(async (file) => ({ id: crypto.randomUUID(), file, at: await pickedTime(file), url: URL.createObjectURL(file) })));
    setPicks(next);
    const gs = groupByTime(next, gapMinutes);
    const plates = await Promise.all(gs.map(async (g) => {
      for (const p of [g.items[0], g.items[Math.floor(g.items.length / 2)]].filter((x, i, a) => x && a.indexOf(x) === i)) {
        const plate = await readPlate(p!.file);
        if (plate) return plate;
      }
      return null;
    }));
    try {
      const r = await fetch('/api/old-photos/suggest', { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ groups: gs.map((g, i) => ({ i: g.i, from: g.from, to: g.to, plate: plates[i] })) }) });
      const j = (await r.json().catch(() => null)) as { ok?: boolean; message?: string; groups?: Suggestion[] } | null;
      if (!j?.ok) throw new Error(j?.message ?? 'The suggestions did not load. Try again.');
      setSugg(Object.fromEntries((j.groups ?? []).map((s) => [s.i, s])));
    } catch (e) { setErr(e instanceof Error ? e.message : 'The suggestions did not load. Try again.'); }
    setStatus('ready');
  }

  function confirm(i: number) {
    const g = groups.find((x) => x.i === i);
    const o = sugg[i]?.options[chosen[i] ?? 0];
    if (!g || !o) return;
    up.add(g.items.map((p) => ({ file: p.file, at: p.at })), o.booking_id, o.kind);
    setSent((s) => ({ ...s, [i]: true }));
  }

  return (
    <div className="op-stack" data-testid="op-bulk">
      <label className="op-drop" data-testid="op-bulk-pick">
        <input type="file" accept={PHOTO_ACCEPT} multiple disabled={status === 'reading'} onChange={(e) => { void choose(e.target.files); e.target.value = ''; }} data-testid="op-bulk-input" />
        <b>{status === 'reading' ? 'Sorting your photos' : picks.length ? 'Choose another pile' : 'Choose all the photos'}</b>
        <span>Every check-in and check-out photo you still have, in one go. We group them by the time they were taken and find the booking of each group.</span>
      </label>
      {status === 'reading' && <p className="op-note" aria-live="polite" data-testid="op-bulk-reading">Reading the times and the plates of {picks.length || 'your'} photos.</p>}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      {status === 'ready' && groups.length > 0 && <ol className="op-groups" data-testid="op-groups">
        {groups.map((g) => {
          const s = sugg[g.i];
          const opts = s?.options ?? [];
          const o = opts[chosen[g.i] ?? 0];
          return (
            <li key={g.i} className={`op-group${sent[g.i] ? ' is-sent' : ''}`} data-testid="op-group">
              <div className="op-group__head">
                <p className="op-group__when">{fmt(g.from)}{g.to && g.to !== g.from ? ` to ${new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(g.to))}` : ''}</p>
                <p className="op-group__n">{g.items.length} photo{g.items.length === 1 ? '' : 's'}{s?.plate ? <> · plate read <span className="op-plate op-plate--sm">{s.plate}</span>{s.plate_matched ? '' : ' (no car with it)'}</> : ''}</p>
              </div>
              <ul className="op-thumbs" aria-hidden="true">
                {/* eslint-disable-next-line @next/next/no-img-element -- a local preview of the phone's own photo */}
                {g.items.slice(0, 6).map((p) => <li key={p.id}><img src={p.url} alt="" width={64} height={64} decoding="async" /></li>)}
                {g.items.length > 6 && <li className="op-thumbs__more">+{g.items.length - 6}</li>}
              </ul>
              {o ? <div className="op-suggest" data-testid="op-suggest">
                <p><b>{word(o.kind)} of {o.booking_number}</b>{o.plate ? <> <span className="op-plate op-plate--sm">{o.plate}</span></> : null}</p>
                <p className="op-sub">{[o.car, o.renter, `${fmt(o.at)}, ${off(o.minutes_off)}`].filter(Boolean).join(', ')}</p>
                {opts.length > 1 && !sent[g.i] && <label className="op-change">
                  <span>Not this one?</span>
                  <select className="select" value={chosen[g.i] ?? 0} onChange={(e) => setChosen((c) => ({ ...c, [g.i]: Number(e.target.value) }))} data-testid="op-change">
                    {opts.map((x, k) => <option key={`${x.booking_id}-${x.kind}`} value={k}>{word(x.kind)} of {x.booking_number}{x.plate ? `, ${x.plate}` : ''}, {off(x.minutes_off)}</option>)}
                  </select>
                </label>}
                {sent[g.i] ? <p className="op-ok" data-testid="op-group-sent">Confirmed: uploading below.</p>
                  : <button type="button" className="btn btn--primary btn--block" onClick={() => confirm(g.i)} data-testid="op-confirm">Add {g.items.length} photo{g.items.length === 1 ? '' : 's'} to {o.booking_number}</button>}
              </div> : <p className="op-note" data-testid="op-no-match">No check-in or check-out near the time of these photos. Find the booking under One booking and add them there.</p>}
            </li>);
        })}
      </ol>}
      <UploadList {...up} />
    </div>
  );
}
