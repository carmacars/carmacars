'use client';
import { useEffect, useRef, useState, useTransition } from 'react';
import { staffDo, staffRead, uploadR48Plate } from '@/server/actions/staff-tools';
import { photoUrl } from '@/lib/photo';

// Release 47 (2900): the showroom background plates of the generated listing views (Settings > Program, Admin). One empty
// showroom per angle family: front (front three-quarter and front), side, rear (rear three-quarter and rear). Made once by
// Gemini and checked as a real photo; an Admin can replace them with a real photo of a showroom. Inside views use none.
export type Plate = { family: 'front' | 'side' | 'rear'; path: string; source: 'gemini' | 'admin'; made_at: string; issues?: string[] | null };
export const FAMILY_LABEL: Record<Plate['family'], string> = { front: 'Front three-quarter and front', side: 'Side profile', rear: 'Rear three-quarter and rear' };

export function ShowroomPlates() {
  const [plates, setPlates] = useState<Plate[] | null>(null);
  const [family, setFamily] = useState('all');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [tick, setTick] = useState(0);
  const file = useRef<HTMLInputElement>(null);
  useEffect(() => { let on = true; void staffRead<{ plates: Plate[] }>('photo_r48_plates').then((r) => { if (on && r.ok) setPlates(r.data.plates); }); return () => { on = false; }; }, [tick]);
  const done = (r: { ok: boolean; message?: string }, text: string) => { setMsg(r.ok ? { ok: true, text } : { ok: false, text: r.message ?? 'Not saved.' }); if (r.ok) setTick((n) => n + 1); };
  if (!plates) return <p className="small muted">Loading the background plates.</p>;
  return (
    <div className="stack" data-testid="r48-plates">
      <p className="small">The room every generated outside view of a car stands in. Gemini made these once and a second check confirmed each looks like a real photo. A real photo of a showroom works best: upload one (an empty floor in the middle, no people, cars, signs or logos, landscape). New views use it; press <b>Redo every car</b> on Listings, Photo standard to make the whole fleet again with it. Inside views use no background.</p>
      <ul className="ad-photos">{(['front', 'side', 'rear'] as const).map((f) => { const p = plates.find((x) => x.family === f); return (
        <li key={f} data-testid={`r48-plate-${f}`}>
          {p ? (<>
            {/* eslint-disable-next-line @next/next/no-img-element -- a stored plate, shown small */}
            <img src={photoUrl(p.path)} alt={`Background plate: ${FAMILY_LABEL[f].toLowerCase()}`} width={180} height={120} loading="lazy" />
          </>) : <span className="small muted">Not made yet: Gemini makes it with the first view of these angles.</span>}
          <p className="small"><b>{FAMILY_LABEL[f]}</b>{p ? ` (${p.source === 'admin' ? 'uploaded' : 'made by Gemini'})` : ''}</p>
          {p && <button className="btn btn--sm btn--quiet" type="button" disabled={pending} onClick={() => start(async () => done(await staffDo('photo_r48_plate', { family: f, clear: true }), 'Taken off: Gemini makes a new one with the next view.'))}>Make a new one</button>}
        </li>); })}</ul>
      <p className="row">
        <label className="small">For <select value={family} onChange={(e) => setFamily(e.target.value)} aria-label="Which views the photo is for">
          <option value="all">every outside view</option><option value="front">front three-quarter and front</option><option value="side">side profile</option><option value="rear">rear three-quarter and rear</option></select></label>
        <input ref={file} type="file" accept="image/jpeg,image/png" aria-label="A real photo of a showroom" />
        <button className="btn btn--sm btn--primary" type="button" disabled={pending} data-testid="r48-plate-upload" onClick={() => start(async () => {
          const f = file.current?.files?.[0]; if (!f) { setMsg({ ok: false, text: 'Choose the photo.' }); return; }
          const fd = new FormData(); fd.set('family', family); fd.set('file', f);
          done(await uploadR48Plate(fd), 'Background photo uploaded: new views use it.'); })}>Upload</button>
      </p>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
