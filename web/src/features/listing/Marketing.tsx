'use client';
import { useCallback, useEffect, useRef, useState, useTransition } from 'react';
import { staffDo, staffRead, uploadSceneReference } from '@/server/actions/staff-tools';
import { photoUrl } from '@/lib/photo';

// Release 35, part S2 (1053): marketing copies of a car's outside photos in a chosen scene, for Marketplace and social posts.
// The website keeps its photos (the dark showroom); a marketing set never replaces them. On a listing: choose a scene (or Mix:
// the scenes in turn across the photos), Make the marketing set, see each copy and download them as a ZIP (also from the
// Marketplace kit). On Settings > Program: each scene's photo of the real place (Choose the reference photo).
type Scene = { code: string; label: string; made: 'local' | 'photo' };
type Copy = { id: string; scene: string; status: 'queued' | 'made' | 'needs_gemini' | 'failed'; path: string | null; provider: string | null; note: string | null; shot: string };
type Set = { set: string | null; scenes: Scene[]; photos: Copy[] };
const STATUS: Record<Copy['status'], string> = { queued: 'Being made', made: 'Made', needs_gemini: 'Needs the image model', failed: 'Failed' };

export function MarketingPhotos({ vehicle }: { vehicle: string }) {
  const [data, setData] = useState<Set | null>(null);
  const [scene, setScene] = useState('mix');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [tick, setTick] = useState(0);
  const load = useCallback(() => setTick((n) => n + 1), []);
  useEffect(() => { let on = true; void staffRead<Set>('marketing_photos', { vehicle }).then((r) => { if (on && r.ok) setData(r.data); }); return () => { on = false; }; }, [vehicle, tick]);
  const busy = data?.photos.some((p) => p.status === 'queued') ?? false;
  useEffect(() => { if (!busy) return; const t = setInterval(load, 8000); return () => clearInterval(t); }, [busy, load]);
  if (!data) return null;
  const label = (c: string) => data.scenes.find((s) => s.code === c)?.label ?? c.replace(/_/g, ' ');
  const made = data.photos.filter((p) => p.status === 'made');
  return (
    <section className="stack" data-testid="marketing-photos" aria-labelledby={`mk-${vehicle}`}>
      <h3 className="d4" id={`mk-${vehicle}`}>Marketing photos</h3>
      <p className="small muted">Copies of the outside photos in another scene, for Marketplace and social posts. The website keeps its own photos.</p>
      <p className="row">
        <label className="small">Scene <select value={scene} onChange={(e) => setScene(e.target.value)} data-testid="marketing-scene">
          <option value="mix">Mix: a different scene on each photo</option>
          {data.scenes.map((s) => <option key={s.code} value={s.code}>{s.label}{s.made === 'photo' ? ' (image model)' : ''}</option>)}
        </select></label>
        <button className="btn btn--primary btn--sm" type="button" disabled={pending || busy} data-testid="marketing-make" onClick={() => start(async () => {
          const r = await staffDo<{ queued: number }>('marketing_set', { vehicle, scene });
          setMsg(r.ok ? { ok: true, text: `${r.data.queued} marketing photo${r.data.queued === 1 ? ' is' : 's are'} being made.` } : { ok: false, text: r.message });
          if (r.ok) load(); })}>{busy ? 'Being made…' : 'Make the marketing set'}</button>
        {made.length > 0 && <a className="btn btn--ghost btn--sm" href={`/api/marketing-photos/${vehicle}`} download data-testid="marketing-zip">Download ({made.length}, ZIP)</a>}
      </p>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      {data.photos.length > 0 && <ul className="ad-photos" data-testid="marketing-set">{data.photos.map((p) => (
        <li key={p.id} data-testid="marketing-copy" data-status={p.status}>
          {/* eslint-disable-next-line @next/next/no-img-element -- made at the frame's size by the pipeline */}
          {p.path ? <a href={photoUrl(p.path)} target="_blank" rel="noreferrer"><img src={photoUrl(p.path)} alt={`${label(p.scene)}, ${p.shot.replace(/_/g, ' ')}`} loading="lazy" /></a> : null}
          <p className="small"><b>{label(p.scene)}</b>: {STATUS[p.status]}{p.provider === 'ai' ? ' (image model)' : p.provider === 'local' ? ' (made by the site)' : ''}</p>
          {p.note && p.status !== 'made' && <p className="small muted">{p.note}</p>}
        </li>))}</ul>}
    </section>
  );
}

type RefScene = { code: string; label: string; made: string; needs_reference: boolean; reference: { photo?: string; path?: string } | null; ready: boolean;
  /** picked by itself (the widest outside photo as taken of a shareholder's own car), until an Admin chooses another */
  auto?: boolean; auto_photo?: string | null };
type Refs = { scenes: RefScene[]; photos: Array<{ id: string; vehicle: string; owner: string; shareholder: boolean; shot: string }> };

/** Settings > Program: each scene, and the photo of the real place a scene is made in (the shareholders' cars first). */
export function SceneReferences() {
  const [d, setD] = useState<Refs | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const file = useRef<HTMLInputElement>(null);
  const [tick, setTick] = useState(0);
  const load = useCallback(() => setTick((n) => n + 1), []);
  useEffect(() => { let on = true; void staffRead<Refs>('marketing_scene_refs').then((r) => { if (on && r.ok) setD(r.data); }); return () => { on = false; }; }, [tick]);
  if (!d) return null;
  const done = (r: { ok: boolean; message?: string }, text: string) => { setMsg(r.ok ? { ok: true, text } : { ok: false, text: r.message ?? 'Not saved.' }); if (r.ok) { setOpen(null); load(); } };
  return (
    <div className="stack" data-testid="scene-refs">
      <p className="small">The scenes staff choose from for marketing photos (Marketplace and social). Their words are in <b>Marketing scenes</b> below. A scene can be made in a real place: choose a photo of it, and the image model puts the car in that same place.</p>
      <ul className="stack">{d.scenes.map((s) => (
        <li key={s.code} data-testid={`scene-${s.code}`}>
          <p className="row"><b>{s.label}</b><span className="small muted">{s.made === 'local' ? 'made by the site when the image model is not there' : 'needs the image model'}</span>
            {s.auto ? <span className="small" data-testid="scene-auto-ref">Reference photo picked by itself: the widest outside photo of the shareholders&apos; own cars, as taken. Change it if it is not the place.</span>
              : s.ready ? <span className="small">Reference photo chosen.</span> : s.needs_reference ? <span className="ad-flag ad-flag--red" data-testid="scene-needs-ref">Choose the reference photo: this scene is not used until you do</span> : null}</p>
          <p className="row">
            <button className="btn btn--sm btn--ghost" type="button" onClick={() => setOpen(open === s.code ? null : s.code)} data-testid={`scene-pick-${s.code}`}>{s.ready ? 'Change the reference photo' : 'Choose the reference photo'}</button>
            {s.reference && <button className="btn btn--sm btn--quiet" type="button" disabled={pending} onClick={() => start(async () => done(await staffDo('marketing_scene_reference', { code: s.code, clear: true }), 'Reference taken off.'))}>Take it off</button>}
          </p>
          {open === s.code && <div className="stack">
            <p className="small">Pick a photo of the place (the shareholders&apos; cars first), or upload one.</p>
            <ul className="ad-photos" data-testid="scene-photos">{d.photos.map((p) => (
              <li key={p.id}><button type="button" className="btn btn--quiet" disabled={pending} aria-label={`${p.vehicle}, ${p.shot.replace(/_/g, ' ')}`} data-testid="scene-photo"
                onClick={() => start(async () => done(await staffDo('marketing_scene_reference', { code: s.code, photo: p.id }), `${s.label}: reference photo chosen.`))}>
                {/* eslint-disable-next-line @next/next/no-img-element -- the photo as taken, through the signed route */}
                <img src={`/api/listing/cutout?photo=${p.id}&part=original`} alt="" loading="lazy" width={160} height={107} /></button>
                <p className="small">{p.vehicle}{p.owner ? `, ${p.owner}` : ''}</p></li>))}</ul>
            <p className="row"><input ref={file} type="file" accept="image/jpeg,image/png" aria-label="Upload a photo of the place" />
              <button className="btn btn--sm btn--primary" type="button" disabled={pending} onClick={() => start(async () => {
                const f = file.current?.files?.[0]; if (!f) { setMsg({ ok: false, text: 'Choose the photo.' }); return; }
                const fd = new FormData(); fd.set('code', s.code); fd.set('file', f);
                done(await uploadSceneReference(fd), `${s.label}: reference photo uploaded.`); })}>Upload</button></p>
          </div>}
        </li>))}</ul>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
