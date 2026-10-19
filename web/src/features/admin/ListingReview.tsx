'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { photoUrl } from '@/lib/photo';
import { staffDo } from '@/server/actions/staff-tools';
import { PlateEditor } from '@/features/listing/PlateEditor';
import { useDoor } from './door';
import { CarCopyPanel, type CarCopyData } from '@/features/seo/CarCopyPanel';

// Review a listing (09-listing-pipeline.md section 6): the copy, written by itself (0061: nothing to type), every photo
// (approve, reject, use the original, choose the cover), the problems the database still sees, then
// approve and publish, or send it back with what to change.
type Photo = { id: string; vehicle_id: string; shot_type: string; shot_label: string | null; processed_path: string | null; original_path: string | null; original_url?: string | null; status: string; is_cover: boolean; alt_text: string | null;
  plate_status: 'unchecked' | 'covered' | 'not_visible'; plate_boxes: Array<{ x: number; y: number; w: number; h: number }> | null; variants: Array<{ width: number }> | null };
export type Plates = { required: boolean; unchecked: string[]; private_shots: string[] };
const PLATE: Record<Photo['plate_status'], string> = { unchecked: 'Plate not checked', covered: 'Plate covered', not_visible: 'No plate visible' };
export type L = { id: string; vehicle_id: string; state: string; reason: string | null; vehicle: { name: string; plate: string | null };
  listing: { status: string; slug: string | null; headline: string | null; description: string | null; features: string[] | null; faq: Array<{ question: string; answer: string }> | null; seo_title: string | null; seo_description: string | null } | null;
  draft: { id: string; headline: string | null; description: string | null; features: string[] | null; faq: Array<{ question: string; answer: string }> | null; seo_title: string | null; seo_description: string | null; lint_problems: string[] | null; proposed_classes: string[] | null } | null;
  photos: Photo[]; jobs: Array<Record<string, unknown>>; problems: { copy: string[] | null; photos: string[] | null; specs: string[] | null; missing_shots: string[] | null } };

export function ListingReview({ l, plates, copy }: { l: L; plates?: Plates | null; copy?: CarCopyData | null }) {
  const { act: adminAct } = useDoor();
  const router = useRouter();
  const [ph, setPh] = useState<Record<string, string>>({});
  const [cover, setCover] = useState<string | null>(l.photos.find((p) => p.is_cover)?.id ?? null);
  const [note, setNote] = useState('');
  const [res, setRes] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [editing, setEditing] = useState<string | null>(null);
  const [sure, setSure] = useState(false);
  const plateCheck = (p: Photo) => !!plates && !plates.private_shots.includes(p.shot_type) && !!p.processed_path && ['processed', 'approved'].includes(p.status) && (ph[p.id] ?? '') !== 'reject';
  const toCheck = l.photos.filter((p) => plateCheck(p) && p.plate_status === 'unchecked');
  const reviewable = ['needs_review', 'approved'].includes(l.state);
  // the copy is written and published by the search job (0061); the review sends only the photo decisions
  const edits = (publish: boolean) => ({
    photos: l.photos.map((p) => ({ photo_id: p.id, decision: ph[p.id] ?? undefined, cover: cover === p.id })).filter((p) => p.decision || p.cover), publish });
  const go = (approve: boolean, publish = true) => start(async () => {
    const r = await adminAct<{ state?: string; slug?: string }>('listing_review', { intake: l.id, approve, edits: edits(publish), note: approve ? null : note }, [`/admin/listings/${l.id}`, '/admin/listings']);
    setRes(r.ok ? { ok: true, text: approve ? (publish ? 'Approved and published.' : 'Approved.') : 'Sent back with your note.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  const problems = [...(l.problems.copy ?? []), ...(l.problems.photos ?? []), ...(l.problems.specs ?? []), ...(l.problems.missing_shots ?? []).map((s) => `missing photo: ${s.replace(/_/g, ' ')}`),
    ...(plates?.required && toCheck.length ? [`licence plate not covered or marked "no plate visible": ${toCheck.map((p) => p.shot_label ?? p.shot_type).join(', ')}`] : [])];
  const noneVisible = () => start(async () => {
    for (const p of toCheck) { const r = await staffDo('photo_plate_record', { photo: p.id, status: 'not_visible' }); if (!r.ok) { setRes({ ok: false, text: r.message }); return; } }
    setRes({ ok: true, text: 'Marked: no plate visible.' }); router.refresh();
  });
  return (
    <div className="ad-cols ad-cols--main" data-testid="listing-review">
      <div className="stack">
        {copy ? <CarCopyPanel d={copy} slug={l.listing?.slug} />
          : <section className="pt-card ad-card" aria-labelledby="lr-copy"><h2 className="d4" id="lr-copy">Copy</h2><p className="small muted">Written automatically from the car&apos;s facts once the car is saved. Nothing to type.</p></section>}
        <section className="pt-card ad-card" aria-labelledby="lr-ph"><h2 className="d4" id="lr-ph">Photos</h2>
          {plates && <p className="small muted">Every photo that goes on the website needs its licence plate covered, or a check that no plate can be read{plates.required ? ' before the listing is published' : ''}. The photo as it was is kept privately.</p>}
          {plates && toCheck.length > 1 && <p className="row">{!sure
            ? <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="plates-none-visible" onClick={() => setSure(true)}>No plate visible on the {toCheck.length} photos left</button>
            : <><span className="small">No plate can be read on any of these {toCheck.length} photos?</span>
              <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="plates-none-visible-yes" onClick={() => { setSure(false); noneVisible(); }}>Yes, none visible</button>
              <button className="btn btn--ghost btn--sm" type="button" onClick={() => setSure(false)}>Cancel</button></>}</p>}
          {/* a shot kept as taken (the odometer, never published) stays in the private originals: shown through its signed link */}
          <ul className="ad-photos">{l.photos.map((p) => { const path = p.processed_path && p.processed_path !== p.original_path ? photoUrl(p.processed_path) : p.original_url ?? null; return (
            <li key={p.id} className={`${cover === p.id ? 'is-cover' : ''}${(ph[p.id] ?? p.status) === 'reject' ? ' is-rejected' : ''}`}>
              {/* eslint-disable-next-line @next/next/no-img-element -- photos come pre-sized from the pipeline */}
              {path ? <img src={path} alt={p.alt_text ?? p.shot_label ?? p.shot_type} loading="lazy" width={300} height={200} /> : <span className="muted">no file</span>}
              <span><b>{p.shot_label ?? p.shot_type}</b> · {p.status}</span>
              <label className="vh" htmlFor={`ph-${p.id}`}>Decision for {p.shot_label ?? p.shot_type}</label>
              <select className="select" id={`ph-${p.id}`} value={ph[p.id] ?? ''} disabled={!reviewable} onChange={(e) => setPh({ ...ph, [p.id]: e.target.value })}>
                <option value="">Keep as is</option><option value="approve">Approve</option><option value="use_original">Use the original</option><option value="reject">Reject</option></select>
              <label className="check"><input type="radio" name="cover" checked={cover === p.id} disabled={!reviewable} onChange={() => setCover(p.id)} /> <span>Cover</span></label>
              {plates && plateCheck(p) && <span className="lr-plate" data-testid={`plate-${p.shot_type}`} data-plate={p.plate_status}>
                <span className={`ad-b ${p.plate_status === 'unchecked' ? 'ad-b--amber' : 'ad-b--light'}`}>{PLATE[p.plate_status]}</span>
                <button className="btn btn--ghost btn--sm" type="button" onClick={() => setEditing(editing === p.id ? null : p.id)} aria-expanded={editing === p.id} data-testid={`plate-edit-${p.shot_type}`}>{p.plate_status === 'covered' ? 'Cover again' : 'Cover the plate'}</button>
                {p.plate_status === 'unchecked' && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`plate-none-${p.shot_type}`}
                  onClick={() => start(async () => { const r = await staffDo('photo_plate_record', { photo: p.id, status: 'not_visible' }); if (r.ok) router.refresh(); else setRes({ ok: false, text: r.message }); })}>No plate visible</button>}
              </span>}
            </li>); })}</ul>
          {editing && (() => { const p = l.photos.find((x) => x.id === editing); return p ? <PlateEditor key={p.id} photo={{ ...p, vehicle_id: l.vehicle_id }} onClose={() => setEditing(null)} /> : null; })()}
          {!l.photos.length && <p className="small muted">No photos uploaded yet.</p>}
        </section>
      </div>
      <aside className="stack">
        <section className="pt-card ad-card" aria-labelledby="lr-chk"><h2 className="d4" id="lr-chk">Before publishing</h2>
          {problems.length ? <ul className="small">{problems.map((p) => <li key={p}>{p}</li>)}</ul> : <p className="small">The database sees nothing missing.</p>}
          {reviewable ? <>
            <button className="btn btn--primary" type="button" disabled={pending} onClick={() => go(true, true)} data-testid="listing-approve">{pending ? 'Working' : 'Approve and publish'}</button>
            <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => go(true, false)}>Approve, publish later</button>
            <div className="field"><label className="label" htmlFor="lr-note">What needs to change</label><textarea className="input ad-textarea" id="lr-note" value={note} onChange={(e) => setNote(e.target.value)} /></div>
            <button className="btn btn--ghost btn--sm" type="button" disabled={pending || !note.trim()} onClick={() => go(false)}>Send back</button>
          </> : <p className="small muted">This listing is {l.state.replace(/_/g, ' ')}: nothing to review.</p>}
          {l.state === 'approved' && l.listing?.status !== 'published' && <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => start(async () => { const r = await adminAct('listing_publish', { vehicle: l.vehicle_id }, [`/admin/listings/${l.id}`]); setRes(r.ok ? { ok: true, text: 'Published.' } : { ok: false, text: /no rates are set/.test(r.message) ? `${r.message}. Set them on the car's Rates tab: the rates, kilometres and deposit save together in one step.` : r.message }); if (r.ok) router.refresh(); })}>Publish now</button>}
          {res && <p className={`alert ${res.ok ? 'alert--ok' : 'alert--error'}`} role={res.ok ? 'status' : 'alert'}><span>{res.text}</span></p>}
          {l.listing?.status === 'published' && l.listing.slug && <a className="link small" href={`/cars/${l.listing.slug}`}>See the public page</a>}
        </section>
      </aside>
    </div>
  );
}
