'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { vaAct } from '@/server/actions/va';

// The photo review side by side (05-va.md section 3.3): the pickup and the return set in the fixed order,
// one row per shot, a tap enlarges; a missing shot is listed at the top with "Ask for a re-shoot", which
// gives a field job for the chosen shots to whoever took the set (or someone else).
export interface Shot { seq: number; shot: string; guide: string | null }
export interface Side { id: string; completed_at: string | null; performed_by_name: string | null; missing: string[]; photos: Array<{ seq: number; shot: string; src: string | null }>;
  reshoots: Array<{ id: string; status: string; shots: string[]; scheduled_at: string; assignee: string | null }> }
const nice = (s: string) => s.replace(/_/g, ' ');

export function PhotoReview({ booking, shots, pickup, ret, staff }: { booking: string; shots: Shot[]; pickup: Side | null; ret: Side | null; staff: Array<{ id: string; name: string }> }) {
  const router = useRouter();
  const [zoom, setZoom] = useState<{ src: string; alt: string } | null>(null);
  const [which, setWhich] = useState<'pickup' | 'return'>(ret ? 'return' : 'pickup');
  const side = which === 'return' ? ret : pickup;
  const [chosen, setChosen] = useState<string[]>(() => (ret ?? pickup)?.missing ?? []);
  const [to, setTo] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const photo = (s: Side | null, shot: string) => s?.photos.filter((p) => p.shot === shot).at(-1) ?? null;
  return (
    <div className="stack">
      {[['Pickup', pickup], ['Return', ret]].map(([l, s]) => {
        const x = s as Side | null;
        return x && x.missing.length ? <p key={l as string} className="alert alert--warn" role="status" data-testid={`missing-${String(l).toLowerCase()}`}><span className="alert__title">{l as string}: missing</span><span>{x.missing.map(nice).join(', ')}</span></p> : null;
      })}
      <div className="ad-pr" data-testid="photo-review">
        {shots.map((s) => (
          <section key={s.shot} className="ad-pr__row" aria-label={nice(s.shot)}>
            <h3>{s.seq}. {nice(s.shot)}</h3>
            {[['Pickup', pickup], ['Return', ret]].map(([l, side2]) => {
              const p = photo(side2 as Side | null, s.shot);
              return p?.src ? (
                <figure key={l as string} className="ad-pr__cell" style={{ margin: 0 }}>
                  <button type="button" className="btn btn--quiet" style={{ padding: 0 }} onClick={() => setZoom({ src: p.src!, alt: `${l as string}: ${nice(s.shot)}` })} aria-label={`Enlarge the ${String(l).toLowerCase()} photo of the ${nice(s.shot)}`}>
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={p.src} alt={`${l as string}: ${nice(s.shot)}`} loading="lazy" />
                  </button>
                  <figcaption className="xs muted">{l as string}</figcaption>
                </figure>
              ) : <div key={l as string} className="ad-pr__cell is-missing">{side2 ? `${l as string}: missing` : `${l as string}: no report yet`}</div>;
            })}
          </section>
        ))}
      </div>
      {(pickup || ret) && (
        <form className="ad-form" data-testid="reshoot" onSubmit={(e) => { e.preventDefault(); start(async () => {
          const r = await vaAct('request_reshoot', { booking, which, shots: chosen, to: to || null });
          setMsg(r.ok ? { ok: true, text: 'Re-shoot asked for: the field job is on the board.' } : { ok: false, text: r.message });
          if (r.ok) router.refresh();
        }); }}>
          <h2 className="d4">Ask for a re-shoot</h2>
          <div className="field"><label className="label" htmlFor="rs-which">Which set</label>
            <select className="select" id="rs-which" value={which} onChange={(e) => { const w = e.target.value as 'pickup' | 'return'; setWhich(w); setChosen((w === 'return' ? ret : pickup)?.missing ?? []); }}>
              {pickup && <option value="pickup">Pickup</option>}{ret && <option value="return">Return</option>}</select></div>
          <fieldset className="field"><legend className="label">Shots to take again</legend>
            <div className="ad-check__choice">{shots.map((s) => (
              <label key={s.shot} className="check"><input type="checkbox" checked={chosen.includes(s.shot)} onChange={(e) => setChosen((c) => e.target.checked ? [...c, s.shot] : c.filter((x) => x !== s.shot))} /> <span>{nice(s.shot)}</span></label>))}</div></fieldset>
          <div className="field"><label className="label" htmlFor="rs-to">Field staff</label>
            <select className="select" id="rs-to" value={to} onChange={(e) => setTo(e.target.value)}><option value="">Whoever took the set</option>{staff.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></div>
          {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending || !chosen.length} data-testid="reshoot-send">{pending ? 'Sending' : 'Ask for a re-shoot'}</button>
          {side?.reshoots.length ? <ul className="small">{side.reshoots.map((j) => <li key={j.id}>{j.shots.map(nice).join(', ')}: {j.status.replace(/_/g, ' ')}{j.assignee ? `, ${j.assignee}` : ''}</li>)}</ul> : null}
        </form>
      )}
      {zoom && (
        <button type="button" className="ad-pr__zoom" onClick={() => setZoom(null)} onKeyDown={(e) => { if (e.key === 'Escape') setZoom(null); }} aria-label="Close the enlarged photo" autoFocus>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={zoom.src} alt={zoom.alt} />
        </button>
      )}
    </div>
  );
}
