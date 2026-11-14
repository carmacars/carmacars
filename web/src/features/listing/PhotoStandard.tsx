'use client';
import { useEffect, useState, useTransition } from 'react';
import { staffDo, staffRead } from '@/server/actions/staff-tools';

// Release 45 (2842): the photo standard of every car (Admin and fleet, the Listings page): per car its photos made to the
// standard out of all, the angles Gemini generated, the photos flagged (off the site after three refusals), when it was last
// worked on, "Redo this car now"; "Redo every car" for the whole fleet. Read again every 30 seconds while open.
export type R45Car = { id: string; name: string; fleet_number: string | null; total: number; at_standard: number; generated: number; flagged: number; queued: number;
  missing: number; last_run: string | null; primary: string; done: boolean };
export type R45Fleet = { spec: string; auto: boolean; daily: number; reserve: number; left_today: number; waiting: number; cars: R45Car[] };

/** The fleet's progress in one line. */
export function fleetLine(f: Pick<R45Fleet, 'cars' | 'waiting' | 'left_today' | 'spec'>): string {
  const done = f.cars.filter((c) => c.done).length;
  const photos = f.cars.reduce((a, c) => a + c.at_standard, 0), total = f.cars.reduce((a, c) => a + c.total, 0);
  return `${done} of ${f.cars.length} car${f.cars.length === 1 ? '' : 's'} at ${f.spec}, ${photos} of ${total} photos. ${f.waiting} waiting for Gemini, ${f.left_today} Gemini calls left today.`;
}
const when = (s: string | null) => (s ? new Date(s).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : 'Never');

export function PhotoStandard() {
  const [f, setF] = useState<R45Fleet | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [sure, setSure] = useState(false);
  const [pending, start] = useTransition();
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let gone = false;
    const load = async () => { const r = await staffRead<R45Fleet>('photo_r45_fleet'); if (gone) return; if (r.ok) { setF(r.data); setErr(null); } else setErr(r.message); };
    void load();
    const t = setInterval(() => void load(), 30_000);
    return () => { gone = true; clearInterval(t); };
  }, [tick]);
  const redo = (p: Record<string, unknown>, done: (d: Record<string, number>) => string) => start(async () => {
    const r = await staffDo<Record<string, number>>('photo_r45_redo', p);
    setNote(r.ok ? done(r.data) : r.message); if (r.ok) setTick((n) => n + 1);
  });
  if (err) return <p className="alert alert--error" role="alert"><span>{err}</span></p>;
  if (!f) return <p className="small muted">Loading the photo standard.</p>;
  return (
    <div className="stack" data-testid="photo-standard">
      <p className="small">Every listing photo is made by Gemini from the original photo: outside photos in the CarmaCars showroom, inside photos cleaned up and sharp, every plate blurred. A missing angle is generated from the car&apos;s own photos (marked AI). A photo the check refuses three times stays off the site and is counted as flagged. {f.auto ? 'Runs by itself every 5 minutes until every car is done, newest listed cars first.' : 'The automatic run is off in Program settings.'}</p>
      <p className="small" data-testid="photo-standard-line">{fleetLine(f)}</p>
      <p className="row">
        {!sure ? <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="r45-all" onClick={() => setSure(true)}>Redo every car</button>
          : <><span className="small">Make every photo of every car again from its original, also those done already? The versions before are kept.</span>
            <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="r45-all-yes" onClick={() => { setSure(false); redo({ all: true }, (d) => `${d.waiting ?? 0} photos will be made again, newest listed cars first. ${d.queued ?? 0} are queued now.`); }}>Yes, every car</button>
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => setSure(false)}>Cancel</button></>}
      </p>
      {note && <p className="alert alert--ok" role="status"><span>{note}</span></p>}
      <div className="ad-table-wrap" tabIndex={0} role="region" aria-label="The photo standard of each car (scrolls sideways)">
        <table className="ad-table" data-testid="photo-standard-cars">
          <caption className="sr-only">The photo standard of each car</caption>
          <thead><tr><th scope="col">Car</th><th scope="col">At standard</th><th scope="col">AI angles</th><th scope="col">Flagged</th><th scope="col">Last run</th><th scope="col"><span className="sr-only">Redo</span></th></tr></thead>
          <tbody>
            {f.cars.map((c) => (
              <tr key={c.id} data-testid={`r45-car-${c.id}`}>
                <td>{c.name}{c.fleet_number ? ` (${c.fleet_number})` : ''}{c.primary === 'not_exterior' ? <span className="ad-b ad-b--amber"> Inside photo first</span> : null}</td>
                <td>{c.at_standard} / {c.total}{c.queued ? <span className="small muted"> ({c.queued} being made)</span> : null}{c.done ? <span className="ad-b ad-b--light"> Done</span> : null}</td>
                <td>{c.generated}{c.missing ? <span className="small muted"> ({c.missing} to make)</span> : null}</td>
                <td>{c.flagged || ''}</td>
                <td>{when(c.last_run)}</td>
                <td><button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`r45-redo-${c.id}`}
                  onClick={() => redo({ vehicle: c.id }, (d) => `${c.name}: ${d.queued ?? 0} photos made again now, ${d.generating ?? 0} angles generated.`)}>Redo this car now</button></td>
              </tr>))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
