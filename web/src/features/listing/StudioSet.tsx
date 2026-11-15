'use client';
import { useCallback, useEffect, useState, useTransition } from 'react';
import { staffDo, staffRead } from '@/server/actions/staff-tools';
import { photoUrl } from '@/lib/photo';

// Release 48 (3030): a car's studio set (photo standard r48.2) beside the photos it was made from. One row per standard angle:
// the view Gemini made (marked AI-generated) and the car's own photos of that angle. Make one angle again, take a made view
// off the site or put it back, and choose the car's scene (the fleet's scene unless chosen here). Once the front
// three-quarter is made, the site shows only the made set, the same on the home page, the cards and the car page.
export type StudioAngle = { shot: string; label: string;
  generated: { id: string; path: string | null; state: string | null; public: boolean; why: string | null; reasons: string[] | null; tries: number | null;
    waiting: string | null; scene: string | null; hidden: boolean } | null;
  originals: Array<{ id: string; path: string | null; public: boolean; ai: boolean }> };
export type StudioSetData = { vehicle: string; name: string; spec: string; scene: string; own_scene: string | null; fleet_scene: string;
  scenes: Array<{ code: string; label: string }>; studio_cover: boolean; angles: StudioAngle[] };

/** The state of one made view in a few words. */
export function stateWords(g: StudioAngle['generated']): string {
  if (!g) return 'Not made yet';
  if (g.hidden) return 'Taken off the site';
  if (g.state === 'flagged') return 'Refused three times: not on the site';
  if (g.waiting === 'retry') return 'Waiting to try again';
  if (g.state === 'queued' || g.state === 'redo') return g.path ? 'On the site, a new version is being made' : 'Being made';
  return g.public ? 'On the site' : 'Made';
}

export function StudioSet({ vehicle }: { vehicle: string }) {
  const [d, setD] = useState<StudioSetData | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [tick, setTick] = useState(0);
  const load = useCallback(() => setTick((n) => n + 1), []);
  useEffect(() => {
    let on = true;
    void staffRead<StudioSetData>('photo_r48_set', { vehicle }).then((r) => { if (!on) return; if (r.ok) { setD(r.data); setErr(null); } else setErr(r.message); });
    return () => { on = false; };
  }, [vehicle, tick]);
  if (err) return null;
  if (!d) return null;
  const act = (p: Record<string, unknown>, text: string) => start(async () => {
    const r = await staffDo('photo_r48_angle', { vehicle, ...p });
    setMsg(r.ok ? { ok: true, text } : { ok: false, text: r.message }); if (r.ok) load();
  });
  const sceneLabel = (c: string) => d.scenes.find((s) => s.code === c)?.label ?? c.replace(/_/g, ' ');
  return (
    <section className="stack" data-testid="studio-set" aria-labelledby={`studio-${vehicle}`}>
      <h3 className="d4" id={`studio-${vehicle}`}>Studio photos</h3>
      <p className="small muted">Gemini makes every standard view of this car in the same angle and scene as every other car, from the car&apos;s own photos. {d.studio_cover
        ? 'The site shows only these views now, the same on the home page, the cards and the car page.'
        : 'Until the first view is made, the site shows the car\'s own photos.'}</p>
      <div className="field">
        <label className="label" htmlFor={`studio-scene-${vehicle}`}>Scene</label>
        {/* r48: the long first option ("Same as every car (...)") never widens the page on a phone: the box is as wide as its column at most */}
        <select className="select" id={`studio-scene-${vehicle}`} style={{ maxWidth: '100%' }} value={d.own_scene ?? ''} disabled={pending} data-testid="studio-scene" onChange={(e) => {
          const scene = e.target.value || null;
          start(async () => {
            const r = await staffDo<{ queued: number }>('photo_r48_scene', { vehicle, scene });
            setMsg(r.ok ? { ok: true, text: `Scene saved: ${r.data.queued} outside view${r.data.queued === 1 ? ' is' : 's are'} being made again. The views on the site stay until the new ones pass.` } : { ok: false, text: r.message });
            if (r.ok) load();
          });
        }}>
          <option value="">Same as every car ({sceneLabel(d.fleet_scene)})</option>
          {d.scenes.map((s) => <option key={s.code} value={s.code}>{s.label}</option>)}
        </select>
      </div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <div className="ad-table-wrap" tabIndex={0} role="region" aria-label="The studio views of this car (scrolls sideways)">
        <table className="ad-table" data-testid="studio-angles">
          <caption className="sr-only">Each standard view: the one Gemini made and the car&apos;s own photos</caption>
          <thead><tr><th scope="col">View</th><th scope="col">Made by Gemini (AI)</th><th scope="col">The car&apos;s own photos</th><th scope="col"><span className="sr-only">Actions</span></th></tr></thead>
          <tbody>
            {d.angles.map((a) => { const g = a.generated; return (
              <tr key={a.shot} data-testid={`studio-angle-${a.shot}`}>
                <td>{a.label}</td>
                <td>
                  {g?.path ? <a href={photoUrl(g.path)} target="_blank" rel="noreferrer">
                    {/* eslint-disable-next-line @next/next/no-img-element -- a made view, shown small */}
                    <img src={photoUrl(g.path)} alt={`${a.label}, made by Gemini`} width={150} height={100} loading="lazy" /></a> : null}
                  <p className="small"><span className="ad-b ad-b--light">AI</span> {stateWords(g)}</p>
                  {g?.state === 'flagged' && (g.reasons?.length || g.why) ? <p className="small muted">{(g.reasons ?? []).join(', ').replace(/_/g, ' ') || g.why}</p> : null}
                </td>
                <td>{a.originals.length ? <ul className="ad-photos">{a.originals.slice(0, 3).map((o) => <li key={o.id}>{o.path
                  ? <img src={photoUrl(o.path)} alt={`${a.label}, the car's own photo`} width={110} height={73} loading="lazy" /> /* eslint-disable-line @next/next/no-img-element */
                  : <span className="small muted">Not processed</span>}</li>)}</ul> : <span className="small muted">None: made from the car&apos;s other photos</span>}</td>
                <td className="row" style={{ flexWrap: 'wrap' }}>
                  <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`studio-redo-${a.shot}`}
                    onClick={() => act({ shot: a.shot, action: 'redo' }, `${a.label}: being made again.`)}>Make again</button>
                  {g?.path && !g.hidden && g.public ? <button className="btn btn--quiet btn--sm" type="button" disabled={pending} data-testid={`studio-hide-${a.shot}`}
                    onClick={() => act({ shot: a.shot, action: 'hide' }, `${a.label}: taken off the site.`)}>Take off the site</button> : null}
                  {g?.path && (g.hidden || !g.public) ? <button className="btn btn--quiet btn--sm" type="button" disabled={pending} data-testid={`studio-show-${a.shot}`}
                    onClick={() => act({ shot: a.shot, action: 'show' }, `${a.label}: on the site.`)}>Put on the site</button> : null}
                </td>
              </tr>); })}
          </tbody>
        </table>
      </div>
    </section>
  );
}
