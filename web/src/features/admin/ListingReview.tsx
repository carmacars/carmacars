'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { photoUrl } from '@/lib/photo';
import { useDoor } from './door';

// Review a listing (09-listing-pipeline.md section 6): the copy draft (edit in place), every photo
// (approve, reject, use the original, choose the cover), the problems the database still sees, then
// approve and publish, or send it back with what to change.
type Photo = { id: string; shot_type: string; shot_label: string | null; processed_path: string | null; original_path: string | null; status: string; is_cover: boolean; alt_text: string | null };
export type L = { id: string; vehicle_id: string; state: string; reason: string | null; vehicle: { name: string; plate: string | null };
  listing: { status: string; slug: string | null; headline: string | null; description: string | null; features: string[] | null; faq: Array<{ question: string; answer: string }> | null; seo_title: string | null; seo_description: string | null } | null;
  draft: { id: string; headline: string | null; description: string | null; features: string[] | null; faq: Array<{ question: string; answer: string }> | null; seo_title: string | null; seo_description: string | null; lint_problems: string[] | null; proposed_classes: string[] | null } | null;
  photos: Photo[]; jobs: Array<Record<string, unknown>>; problems: { copy: string[] | null; photos: string[] | null; specs: string[] | null; missing_shots: string[] | null } };

export function ListingReview({ l }: { l: L }) {
  const { act: adminAct } = useDoor();
  const router = useRouter();
  const src = l.draft?.headline ? l.draft : l.listing;
  const [c, setC] = useState({ headline: src?.headline ?? '', description: src?.description ?? '', features: (src?.features ?? []).join('\n'), faq: (src?.faq ?? []).map((f) => `${f.question} | ${f.answer}`).join('\n'), seo_title: src?.seo_title ?? '', seo_description: src?.seo_description ?? '' });
  const [ph, setPh] = useState<Record<string, string>>({});
  const [cover, setCover] = useState<string | null>(l.photos.find((p) => p.is_cover)?.id ?? null);
  const [note, setNote] = useState('');
  const [res, setRes] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const reviewable = ['needs_review', 'approved'].includes(l.state);
  const edits = (publish: boolean) => ({
    listing: { headline: c.headline, description: c.description, features: c.features.split('\n').map((x) => x.trim()).filter(Boolean),
      faq: c.faq.split('\n').map((x) => x.split('|')).filter((x) => x[0]?.trim() && x[1]?.trim()).map(([q, a]) => ({ question: q!.trim(), answer: a!.trim() })), seo_title: c.seo_title, seo_description: c.seo_description },
    photos: l.photos.map((p) => ({ photo_id: p.id, decision: ph[p.id] ?? undefined, cover: cover === p.id })).filter((p) => p.decision || p.cover), publish });
  const go = (approve: boolean, publish = true) => start(async () => {
    const r = await adminAct<{ state?: string; slug?: string }>('listing_review', { intake: l.id, approve, edits: edits(publish), note: approve ? null : note }, [`/admin/listings/${l.id}`, '/admin/listings']);
    setRes(r.ok ? { ok: true, text: approve ? (publish ? 'Approved and published.' : 'Approved.') : 'Sent back with your note.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  const T = (k: keyof typeof c, label: string, rows = 1) => (
    <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`lr-${k}`}>{label}</label>
      {rows > 1 ? <textarea className="input ad-textarea" id={`lr-${k}`} rows={rows} value={c[k]} disabled={!reviewable} onChange={(e) => setC({ ...c, [k]: e.target.value })} />
        : <input className="input" id={`lr-${k}`} value={c[k]} disabled={!reviewable} onChange={(e) => setC({ ...c, [k]: e.target.value })} />}</div>);
  const problems = [...(l.problems.copy ?? []), ...(l.problems.photos ?? []), ...(l.problems.specs ?? []), ...(l.problems.missing_shots ?? []).map((s) => `missing photo: ${s.replace(/_/g, ' ')}`)];
  return (
    <div className="ad-cols ad-cols--main" data-testid="listing-review">
      <div className="stack">
        <section className="pt-card ad-card ad-form" aria-labelledby="lr-copy"><h2 className="d4" id="lr-copy">Copy</h2>
          <div className="ad-fields">{T('headline', 'Headline')}{T('description', 'Description', 6)}{T('features', 'Features (one a line)', 5)}{T('faq', 'Questions (question | answer, one a line)', 5)}{T('seo_title', 'Search title')}{T('seo_description', 'Search description', 2)}</div>
          {l.draft?.lint_problems?.length ? <p className="small muted">Draft notes: {l.draft.lint_problems.join('; ')}</p> : null}
        </section>
        <section className="pt-card ad-card" aria-labelledby="lr-ph"><h2 className="d4" id="lr-ph">Photos</h2>
          <ul className="ad-photos">{l.photos.map((p) => { const path = p.processed_path ?? p.original_path; return (
            <li key={p.id} className={`${cover === p.id ? 'is-cover' : ''}${(ph[p.id] ?? p.status) === 'reject' ? ' is-rejected' : ''}`}>
              {/* eslint-disable-next-line @next/next/no-img-element -- photos come pre-sized from the pipeline */}
              {path ? <img src={photoUrl(path)} alt={p.alt_text ?? p.shot_label ?? p.shot_type} loading="lazy" width={300} height={200} /> : <span className="muted">no file</span>}
              <span><b>{p.shot_label ?? p.shot_type}</b> · {p.status}</span>
              <label className="vh" htmlFor={`ph-${p.id}`}>Decision for {p.shot_label ?? p.shot_type}</label>
              <select className="select" id={`ph-${p.id}`} value={ph[p.id] ?? ''} disabled={!reviewable} onChange={(e) => setPh({ ...ph, [p.id]: e.target.value })}>
                <option value="">Keep as is</option><option value="approve">Approve</option><option value="use_original">Use the original</option><option value="reject">Reject</option></select>
              <label className="check"><input type="radio" name="cover" checked={cover === p.id} disabled={!reviewable} onChange={() => setCover(p.id)} /> <span>Cover</span></label>
            </li>); })}</ul>
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
          {l.state === 'approved' && l.listing?.status !== 'published' && <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => start(async () => { const r = await adminAct('listing_publish', { vehicle: l.vehicle_id }, [`/admin/listings/${l.id}`]); setRes(r.ok ? { ok: true, text: 'Published.' } : { ok: false, text: r.message }); if (r.ok) router.refresh(); })}>Publish now</button>}
          {res && <p className={`alert ${res.ok ? 'alert--ok' : 'alert--error'}`} role={res.ok ? 'status' : 'alert'}><span>{res.text}</span></p>}
          {l.listing?.status === 'published' && l.listing.slug && <a className="link small" href={`/cars/${l.listing.slug}`}>See the public page</a>}
        </section>
      </aside>
    </div>
  );
}
