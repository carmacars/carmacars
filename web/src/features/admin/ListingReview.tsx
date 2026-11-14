'use client';
import { Fragment, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { photoUrl } from '@/lib/photo';
import { staffDo } from '@/server/actions/staff-tools';
import { PlateEditor } from '@/features/listing/PlateEditor';
import { PlateAutoSuggest } from '@/features/listing/PlateAutoSuggest';
import { suggestedBoxes } from '@/features/listing/plate-cover';
import { normalizePlateBoxes } from '@/features/tolls/vision-schema';
import { useDoor } from './door';
import { CarCopyPanel, type CarCopyData } from '@/features/seo/CarCopyPanel';
import { CutoutEditor } from '@/features/listing/CutoutEditor';
import { ExtraOrder } from '@/features/listing/ExtraOrder';
import { PlateCarry } from '@/features/listing/PlateCarry';
import { isExtra } from '@/features/listing/extra-order';
import { GeminiRedoCar, ShowroomCar, ShowroomPhoto } from '@/features/listing/Showroom';
import { MarketingPhotos } from '@/features/listing/Marketing';
import { ListingCover } from '@/features/listing/Cover';
import { MissingAngles } from '@/features/listing/MissingAngle';
import { ShortVideo } from '@/features/social/ShortVideo';
import { autoShown, autoText, type AutoPlate } from '@/features/listing/plate-auto-view';
import { WideRow } from '@/features/listing/WideRow';

// Review a listing (09-listing-pipeline.md section 6): the copy, written by itself (0061: nothing to type), every photo
// (approve, reject, use the original, choose the cover), the problems the database still sees, then
// approve and publish, or send it back with what to change.
type Photo = { id: string; vehicle_id: string; shot_type: string; shot_label: string | null; processed_path: string | null; original_path: string | null; original_url?: string | null; status: string; is_cover: boolean; alt_text: string | null;
  plate_status: 'unchecked' | 'covered' | 'not_visible'; plate_boxes: Array<{ x: number; y: number; w: number; h: number }> | null; variants: Array<{ width: number }> | null; plate_suggestion?: unknown;
  /** 0568: the touch-up values used (null: none) and the photo's "Use original colours" */
  enhance?: Record<string, unknown> | null; enhance_off?: boolean;
  /** 0700: the plate cover carried over an edit that did not move the car; how many times the cut-out was edited */
  plate_carry?: { boxes?: Array<{ x: number; y: number; w: number; h: number }>; style?: 'cover' | 'pixelate' | 'blur' } | null; edit_version?: number;
  /** 0990: the scene (showroom or the black studio) and how the showroom photo was made */
  scene?: string | null; preset_version?: string | null; showroom?: { provider?: string; model?: string | null; note?: string | null } | null;
  /** r41 (2530): the automatic plate check's decision, and who checked the plate (null: nobody, or the check by itself) */
  plate_auto?: AutoPlate | null; plate_checked_by?: string | null;
  /** r45 (2840): a view Gemini generated (the car was never photographed at this angle), and how the photo stands to the standard */
  ai_generated?: boolean; r45?: { state?: string; spec?: string; tries?: number; why?: string | null } | null };
export type Plates = { required: boolean; unchecked: string[]; private_shots: string[]; detect?: boolean; auto?: boolean; auto_waiting?: number };
const PLATE: Record<Photo['plate_status'], string> = { unchecked: 'Plate not checked', covered: 'Plate covered', not_visible: 'No plate visible' };
export type L = { id: string; vehicle_id: string; state: string; reason: string | null; vehicle: { name: string; plate: string | null };
  listing: { status: string; slug: string | null; headline: string | null; description: string | null; features: string[] | null; faq: Array<{ question: string; answer: string }> | null; seo_title: string | null; seo_description: string | null } | null;
  draft: { id: string; headline: string | null; description: string | null; features: string[] | null; faq: Array<{ question: string; answer: string }> | null; seo_title: string | null; seo_description: string | null; lint_problems: string[] | null; proposed_classes: string[] | null } | null;
  photos: Photo[]; jobs: Array<Record<string, unknown>>; problems: { copy: string[] | null; photos: string[] | null; specs: string[] | null; missing_shots: string[] | null } };

export function ListingReview({ l, plates, copy, exterior = [] }: { l: L; plates?: Plates | null; copy?: CarCopyData | null; exterior?: string[] }) {
  const { act: adminAct } = useDoor();
  const router = useRouter();
  const [ph, setPh] = useState<Record<string, string>>({});
  const [cover, setCover] = useState<string | null>(l.photos.find((p) => p.is_cover)?.id ?? null);
  const [note, setNote] = useState('');
  const [res, setRes] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [editing, setEditing] = useState<string | null>(null);
  const [sure, setSure] = useState(false);
  const [reframe, setReframe] = useState(false);
  const [cutting, setCutting] = useState<string | null>(null);
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
  // r41 (2530): an automatic decision undone (a cover: the photo as it was is put back by the save route)
  const undoAuto = (p: Photo, to: 'unchecked' | 'not_visible') => start(async () => {
    const fd = new FormData(); fd.set('photo', p.id); fd.set('undo', to);
    const r = await fetch('/api/listing/plate', { method: 'POST', body: fd }).catch(() => null);
    const j = (r ? await r.json().catch(() => null) : null) as { ok?: boolean; message?: string } | null;
    if (!j?.ok) { setRes({ ok: false, text: j?.message ?? 'The decision could not be undone.' }); return; }
    setRes({ ok: true, text: to === 'not_visible' ? 'The cover is off and the photo is marked "No plate visible".' : 'Undone: the plate is not checked. Cover it or mark it "No plate visible".' });
    router.refresh();
  });
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
          {plates && <PlateCarry photos={l.photos} />}
          {/* r41 (2530): the plates are checked by itself on the server; the browser's box suggestion only when that is off */}
          {plates?.auto && (plates.auto_waiting ?? 0) > 0 && <p className="small muted" role="status" data-testid="plate-auto-waiting">The plates are being checked automatically: {plates.auto_waiting} photo{plates.auto_waiting === 1 ? '' : 's'} waiting. A plate found is covered, a photo with none is marked &quot;No plate visible&quot;, and a photo the check is not sure of stays for you.</p>}
          {plates && <PlateAutoSuggest photos={l.photos.filter((p) => plateCheck(p)).map((p) => ({ ...p, vehicle_id: l.vehicle_id }))} exterior={exterior} on={plates.detect !== false && !plates.auto} />}
          {plates && toCheck.length > 1 && <p className="row">{!sure
            ? <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="plates-none-visible" onClick={() => setSure(true)}>No plate visible on the {toCheck.length} photos left</button>
            : <><span className="small">No plate can be read on any of these {toCheck.length} photos?</span>
              <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="plates-none-visible-yes" onClick={() => { setSure(false); noneVisible(); }}>Yes, none visible</button>
              <button className="btn btn--ghost btn--sm" type="button" onClick={() => setSure(false)}>Cancel</button></>}</p>}
          {/* r31 (0660): photos made before the studio_v4 framing (the car small and floating) are framed again on request */}
          {l.photos.some((p) => exterior.includes(p.shot_type) && p.processed_path && p.processed_path !== p.original_path) && <p className="row">{!reframe
            ? <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="photos-reframe" onClick={() => setReframe(true)}>Frame the outside photos again</button>
            : <><span className="small">Make the outside photos again with the newest framing (the model&apos;s name behind the car on the cover and the main outside views)? They leave the site until their plates are checked again.</span>
              <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="photos-reframe-yes" onClick={() => { setReframe(false); start(async () => {
                const r = await staffDo<{ queued: number }>('listing_photos_reframe', { intake: l.id });
                setRes(r.ok ? { ok: true, text: r.data.queued ? `${r.data.queued} outside photo${r.data.queued === 1 ? ' is' : 's are'} being made again. When ready, check the plate on each: on a listing that is on the site, each goes back on by itself once its plate is checked.` : 'Every outside photo already has the newest framing.' } : { ok: false, text: r.message });
                if (r.ok && r.data.queued) router.refresh(); }); }}>Yes, frame again</button>
              <button className="btn btn--ghost btn--sm" type="button" onClick={() => setReframe(false)}>Cancel</button></>}</p>}
          {/* r35 (0990): the car's outside photos into the dark showroom */}
          <ShowroomCar vehicle={l.vehicle_id} studio={l.photos.filter((p) => exterior.includes(p.shot_type) && p.processed_path && p.processed_path !== p.original_path && p.status !== 'rejected' && p.scene !== 'showroom').length} />
          {/* r43 (2690): the car's outside photos again with Gemini only */}
          <GeminiRedoCar vehicle={l.vehicle_id} />
          {/* r35 S2 (1053): marketing copies in other scenes (never the website's photos) */}
          <MarketingPhotos vehicle={l.vehicle_id} />
          {/* r36 (2100): the first photo on the site and Marketplace: plain, with a model, or the flyer */}
          <ListingCover vehicle={l.vehicle_id} />
          {/* r36b (2200): the missing angle, made by the image model and approved before it shows (never the cover) */}
          <MissingAngles vehicle={l.vehicle_id} />
          {/* r36b (2210): the short video for Reels, TikTok and Stories */}
          <ShortVideo vehicle={l.vehicle_id} />
          {/* a shot kept as taken (the odometer, never published) stays in the private originals: shown through its signed link */}
          <ul className="ad-photos">{l.photos.map((p) => { const path = p.processed_path && p.processed_path !== p.original_path ? photoUrl(p.processed_path) : p.original_url ?? null; return (
            <Fragment key={p.id}>
            <li className={`${cover === p.id ? 'is-cover' : ''}${(ph[p.id] ?? p.status) === 'reject' ? ' is-rejected' : ''}`}>
              {/* eslint-disable-next-line @next/next/no-img-element -- photos come pre-sized from the pipeline */}
              {path ? <img src={path} alt={p.alt_text ?? p.shot_label ?? p.shot_type} loading="lazy" width={300} height={200} /> : <span className="muted">no file</span>}
              <span><b>{p.shot_label ?? p.shot_type}</b> · {p.status}</span>
              <label className="vh" htmlFor={`ph-${p.id}`}>Decision for {p.shot_label ?? p.shot_type}</label>
              <select className="select" id={`ph-${p.id}`} value={ph[p.id] ?? ''} disabled={!reviewable} onChange={(e) => setPh({ ...ph, [p.id]: e.target.value })}>
                <option value="">Keep as is</option><option value="approve">Approve</option><option value="use_original">Use the original</option><option value="reject">Reject</option></select>
              <label className="check"><input type="radio" name="cover" checked={cover === p.id} disabled={!reviewable} onChange={() => setCover(p.id)} /> <span>Cover</span></label>
              {/* 0568: the light touch-up; switching it makes the photo again (approve it again, and check an outside photo's plate) */}
              {p.processed_path && p.processed_path !== p.original_path && <label className="check" title={p.enhance ? 'Touched up: exposure, levels, a little contrast and colour, mild sharpening' : 'Not touched up'}>
                <input type="checkbox" checked={!!p.enhance_off} disabled={pending} data-testid={`enhance-off-${p.id}`}
                  onChange={(e) => { const off = e.target.checked; start(async () => { const r = await staffDo('photo_enhance_set', { photo: p.id, off }); if (r.ok) { setRes({ ok: true, text: 'The photo is being made again. Approve it again when it is ready.' }); router.refresh(); } else setRes({ ok: false, text: r.message }); }); }} />
                <span>Use original colours{p.enhance && !p.enhance_off ? ' (touched up now)' : ''}</span></label>}
              {/* 0700: the cut-out editor (move and size the car, erase or restore, reset); a new version is saved */}
              {exterior.includes(p.shot_type) && p.processed_path && p.processed_path !== p.original_path && p.status !== 'rejected' &&
                <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setEditing(null); setCutting(cutting === p.id ? null : p.id); }} aria-expanded={cutting === p.id} data-testid={`cutout-edit-${p.shot_type}`}>Edit the cut-out{p.edit_version ? ` (edited ${p.edit_version}x)` : ''}</button>}
              {exterior.includes(p.shot_type) && p.processed_path && p.status !== 'rejected' && <ShowroomPhoto photo={p} />}
              {/* r45 (2840): the AI mark (staff only) and the photo standard */}
              {p.ai_generated && <span className="ad-b ad-b--dark" data-testid={`ai-generated-${p.id}`} title="Generated by Gemini from this car's own photos: the car was never photographed at this angle">AI generated</span>}
              {p.r45?.state === 'flagged' && <span className="ad-b ad-b--red" data-testid={`r45-flagged-${p.id}`} title={p.r45.why ?? undefined}>Flagged: off the site</span>}
              {p.r45?.state === 'queued' && <span className="ad-b ad-b--wait">Being made with Gemini</span>}
              {plates && plateCheck(p) && <span className="lr-plate" data-testid={`plate-${p.shot_type}`} data-plate={p.plate_status}>
                <span className={`ad-b ${p.plate_status === 'unchecked' ? 'ad-b--amber' : 'ad-b--light'}`}>{PLATE[p.plate_status]}</span>
                {p.plate_status === 'unchecked' && suggestedBoxes(p.plate_suggestion, normalizePlateBoxes).length > 0 && <span className="ad-b ad-b--light" data-testid={`plate-suggested-${p.shot_type}`}>Box suggested</span>}
                <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setCutting(null); setEditing(editing === p.id ? null : p.id); }} aria-expanded={editing === p.id} data-testid={`plate-edit-${p.shot_type}`}>{p.plate_status === 'covered' ? 'Cover again' : 'Cover the plate'}</button>
                {p.plate_status === 'unchecked' && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`plate-none-${p.shot_type}`}
                  onClick={() => start(async () => { const r = await staffDo('photo_plate_record', { photo: p.id, status: 'not_visible' }); if (r.ok) router.refresh(); else setRes({ ok: false, text: r.message }); })}>No plate visible</button>}
                {/* r41 (2530): a decision made by itself: shown, and undone in one click */}
                {autoText(p.plate_auto) && (autoShown(p) || p.plate_auto?.decision === 'unsure' && p.plate_status === 'unchecked') && <span className="ad-b ad-b--light" data-testid={`plate-auto-${p.shot_type}`} data-auto={p.plate_auto?.decision}>{autoText(p.plate_auto)}</span>}
                {autoShown(p) && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`plate-auto-undo-${p.shot_type}`}
                  onClick={() => undoAuto(p, 'unchecked')}>Undo</button>}
                {autoShown(p) && p.plate_status === 'covered' && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`plate-auto-none-${p.shot_type}`}
                  onClick={() => undoAuto(p, 'not_visible')}>Not a plate: no plate visible</button>}
              </span>}
            </li>
            {editing === p.id && <WideRow label={`Plate on the ${p.shot_label ?? p.shot_type} photo`}><PlateEditor key={p.id} photo={{ ...p, vehicle_id: l.vehicle_id }} onClose={() => setEditing(null)} /></WideRow>}
            {cutting === p.id && <WideRow label={`Cut-out of the ${p.shot_label ?? p.shot_type} photo`}><CutoutEditor key={p.id} photo={p} onClose={() => setCutting(null)} /></WideRow>}
            </Fragment>); })}</ul>
          <ExtraOrder key={l.photos.filter((p) => isExtra(p.shot_type)).map((p) => p.id).join()} vehicle={l.vehicle_id}
            photos={l.photos.filter((p) => isExtra(p.shot_type) && p.status !== 'rejected')} />
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
