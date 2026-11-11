'use client';
import { useCallback, useEffect, useState, useTransition } from 'react';
import { staffDo, staffRead } from '@/server/actions/staff-tools';
import { photoUrl } from '@/lib/photo';

// Release 36b (2200): "Make the missing angle". For a required angle the car has no photo of, the image model makes the view
// from the car's other approved photos (free daily use only, the same gate as the showroom). Each view is marked generated
// and waits for a person to approve it; the site shows it after the real photos with "AI view", never as the cover, and it
// is never used as damage or condition evidence. A real photo of the angle always replaces it.
type Made = { id: string; shot: string; label: string; status: 'queued' | 'made' | 'needs_gemini' | 'failed' | 'approved' | 'rejected'; path: string | null; note: string | null; taken: boolean };
type Data = { ai_on: boolean; sources: number; missing: Array<{ shot: string; label: string }>; made: Made[] };
const STATUS: Record<Made['status'], string> = { queued: 'Being made', made: 'Waiting for approval', needs_gemini: 'Needs the image model', failed: 'Failed', approved: 'Approved: on the site', rejected: 'Rejected' };

export function MissingAngles({ vehicle }: { vehicle: string }) {
  const [d, setD] = useState<Data | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [tick, setTick] = useState(0);
  const load = useCallback(() => setTick((n) => n + 1), []);
  useEffect(() => { let on = true; void staffRead<Data>('listing_angles', { vehicle }).then((r) => { if (on && r.ok) setD(r.data); }); return () => { on = false; }; }, [vehicle, tick]);
  const busy = d?.made.some((m) => m.status === 'queued') ?? false;
  useEffect(() => { if (!busy) return; const t = setInterval(load, 8000); return () => clearInterval(t); }, [busy, load]);
  if (!d) return null;
  const open = new Set(d.made.filter((m) => ['queued', 'made', 'approved'].includes(m.status)).map((m) => m.shot));
  const todo = d.missing.filter((m) => !open.has(m.shot));
  const act = (name: 'listing_angle_make' | 'listing_angle_decide', p: Record<string, unknown>, ok: string) => start(async () => {
    const r = await staffDo<Data>(name, { vehicle, ...p }, ['/cars']);
    if (r.ok) { setD(r.data); setMsg({ ok: true, text: ok }); } else setMsg({ ok: false, text: r.message });
  });
  return (
    <section className="stack" data-testid="missing-angles" aria-labelledby={`ma-${vehicle}`}>
      <h3 className="d4" id={`ma-${vehicle}`}>Make the missing angle</h3>
      <p className="small muted">An AI view of an angle never photographed, made from this car&apos;s photos. You approve it before it shows; it shows after the real photos as &ldquo;AI view&rdquo;, never as the cover, and is never used for damage or condition records. A real photo always replaces it.</p>
      {!d.ai_on && <p className="small" data-testid="missing-angles-off">The image model is off (Program settings &gt; Listings &gt; Showroom image model). It only uses the free daily allowance.</p>}
      {d.ai_on && d.sources === 0 && <p className="small">Approve at least one photo of the car first.</p>}
      {todo.length === 0 && d.made.length === 0 ? <p className="small">Every required angle has a photo.</p> : null}
      {d.ai_on && d.sources > 0 && todo.length > 0 && (
        <p className="row" style={{ flexWrap: 'wrap', gap: '0.5rem' }}>
          {todo.map((m) => <button key={m.shot} className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`angle-make-${m.shot}`}
            onClick={() => act('listing_angle_make', { shot: m.shot }, `${m.label}: being made. It waits for your approval.`)}>Make {m.label}</button>)}
        </p>)}
      {d.made.length > 0 && <ul className="ad-photos">{d.made.filter((m) => m.status !== 'rejected').map((m) => (
        <li key={m.id} data-testid={`angle-${m.shot}`} data-status={m.status}>
          {/* eslint-disable-next-line @next/next/no-img-element -- made at its size by the image model */}
          {m.path ? <img src={photoUrl(m.path)} alt={`${m.label}, AI view`} loading="lazy" width={300} height={200} /> : <span className="muted">{STATUS[m.status]}</span>}
          <p className="small"><b>{m.label}</b> · AI view · {STATUS[m.status]}{m.taken ? ' (a real photo is used now)' : ''}{m.note && m.status !== 'approved' ? `: ${m.note}` : ''}</p>
          <p className="row" style={{ gap: '0.5rem' }}>
            {m.status === 'made' && !m.taken && <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid={`angle-approve-${m.shot}`}
              onClick={() => act('listing_angle_decide', { id: m.id, action: 'approve' }, `${m.label}: approved, on the site after the real photos.`)}>Approve</button>}
            {m.status !== 'queued' && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`angle-reject-${m.shot}`}
              onClick={() => act('listing_angle_decide', { id: m.id, action: 'reject' }, `${m.label}: rejected. You can make it again.`)}>{m.status === 'approved' ? 'Take it off' : 'Reject'}</button>}
          </p>
        </li>))}</ul>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </section>
  );
}
