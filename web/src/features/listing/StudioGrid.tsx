'use client';
import { useEffect, useState } from 'react';
import { staffRead } from '@/server/actions/staff-tools';
import { photoUrl } from '@/lib/photo';

// Release 50 (3701): the studio grid. Every published car's studio views (5080: the eight sample angles) side by side, in the site's order, each with
// the gate's verdict, so a background, a floor, a car size or an angle that drifts from the others shows at a glance.
// Admin and Fleet (Photo standard on the Listings pages). Only a view marked "Live" is ever on the public site.
export type GridView = { shot: string; path: string | null; live: boolean; state: string | null; tries: number | null;
  gate: { pass?: boolean; reasons?: string[]; measures?: Record<string, unknown> } | null; why: string | null; reasons: string[] | null };
export type GridCar = { vehicle: string; name: string; fleet_number: string | null; live: number; views: GridView[] };
export type GridData = { spec: string; order: string[]; total: number; cars: GridCar[] };

const LABEL: Record<string, string> = { left: 'Side', front_left: 'Front 3/4', front: 'Front', rear_left: 'Rear 3/4', rear: 'Rear', dashboard: 'Dashboard',
  front_seats: 'Front seats', rear_seats: 'Rear seats', trunk: 'Trunk', wheel: 'Wheel' };

/** One view's state in a few words. */
export function viewWords(v: GridView): string {
  if (v.live) return 'Live';
  if (v.state === 'flagged') return `Flagged: ${(v.gate?.reasons?.length ? v.gate.reasons : v.reasons ?? []).join(', ').replace(/gate_|_/g, ' ').trim() || v.why || 'refused three times'}`;
  if (v.gate && v.gate.pass === false) return `Gate refused: ${(v.gate.reasons ?? []).join(', ').replace(/gate_|_/g, ' ').trim()}`;
  if (v.state === 'queued' || v.state === 'redo') return 'Being made';
  return v.path ? 'Not live' : 'Not made yet';
}

export function StudioGrid() {
  const [d, setD] = useState<GridData | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [page, setPage] = useState(0);
  const per = 20;
  useEffect(() => {
    let on = true;
    void staffRead<GridData>('photo_r48_grid', { limit: per, offset: page * per }).then((r) => { if (!on) return; if (r.ok) { setD(r.data); setErr(null); } else setErr(r.message); });
    return () => { on = false; };
  }, [page]);
  if (err) return <p className="alert alert--error" role="alert"><span>{err}</span></p>;
  if (!d) return <p className="small muted">Loading the studio grid</p>;
  const pages = Math.max(1, Math.ceil(d.total / per));
  return (
    <section className="stack" data-testid="studio-grid" aria-labelledby="studio-grid-h">
      <h3 className="d4" id="studio-grid-h">Studio grid</h3>
      <p className="small muted">Each car&apos;s nine views side by side (standard {d.spec}). Every row should look the same: the same room, floor, car size and angle in each column. Only views marked Live are on the site.</p>
      <div className="ad-table-wrap" tabIndex={0} role="region" aria-label="The studio views of every car (scrolls sideways)">
        <table className="ad-table studio-grid" data-testid="studio-grid-table">
          <caption className="sr-only">Every car&apos;s nine studio views</caption>
          <thead><tr><th scope="col">Car</th>{d.order.map((s) => <th scope="col" key={s}>{LABEL[s] ?? s}</th>)}</tr></thead>
          <tbody>
            {d.cars.map((c) => (
              <tr key={c.vehicle} data-testid={`studio-grid-${c.vehicle}`}>
                <th scope="row" className="small">{c.name}{c.fleet_number ? ` (${c.fleet_number})` : ''}<br /><span className="muted">{c.live} of {d.order.length} live</span></th>
                {c.views.map((v) => (
                  <td key={v.shot} className="studio-grid__cell" data-live={v.live ? '' : undefined}>
                    {v.path
                      ? <img src={photoUrl(v.path)} alt={`${c.name}, ${LABEL[v.shot] ?? v.shot}`} width={120} height={80} loading="lazy" decoding="async" /> /* eslint-disable-line @next/next/no-img-element */
                      : <span className="studio-grid__empty" aria-hidden="true" />}
                    <span className={`small${v.live ? '' : ' muted'}`}>{viewWords(v)}</span>
                  </td>))}
              </tr>))}
          </tbody>
        </table>
      </div>
      {pages > 1 && (
        <p className="row">
          <button className="btn btn--ghost btn--sm" type="button" disabled={page === 0} title={page === 0 ? 'This is the first page' : undefined} onClick={() => setPage((p) => p - 1)}>Previous</button>
          <span className="small">Page {page + 1} of {pages}</span>
          <button className="btn btn--ghost btn--sm" type="button" disabled={page + 1 >= pages} title={page + 1 >= pages ? 'This is the last page' : undefined} onClick={() => setPage((p) => p + 1)}>Next</button>
        </p>)}
    </section>
  );
}
