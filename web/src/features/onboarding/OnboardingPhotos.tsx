'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import './onboarding.css';
import { onboardingPhotoAdd, onboardingPhotoRemove, onboardingPhotoReplace, onboardingPhotoReview } from '@/server/actions/onboarding';
import type { Viewer } from './steps';

// The onboarding photos (r34, 0821): the ownership permit, the insurance slip and the lender's permission of each car.
// The owner, staff and an Admin replace or remove any of them (audited); staff and an Admin approve or reject one. A
// replaced photo waits for review again. Photos are re-encoded in the browser (which strips location data).
export interface PhotoRow { id: string; vehicle_id: string; vehicle_name: string; kind: string; label: string; mime: string | null; created_at: string;
  uploaded_by: 'owner' | 'carmacars' | null; review_status: 'waiting' | 'approved' | 'rejected'; reviewed_at: string | null; review_note: string | null; replaces: string | null }

const STATUS: Record<PhotoRow['review_status'], string> = { waiting: 'Waiting for the check', approved: 'Approved', rejected: 'Not accepted' };
const KINDS: Array<[string, string]> = [['ownership_permit', 'Ownership permit'], ['owner_insurance_proof', 'Insurance slip'], ['finance_party_permission', 'Lender or lessor permission']];
const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(iso));

async function prepare(file: File): Promise<Blob> {
  if (file.type === 'application/pdf') return file;
  const bmp = await createImageBitmap(file);
  const scale = Math.min(1, 2400 / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas');
  c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale);
  c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
  return new Promise((res, rej) => c.toBlob((b) => (b ? res(b) : rej(new Error('Could not read the image'))), 'image/jpeg', 0.9));
}

function Photo({ p, ownerId, viewer, refresh, view, say }: { p: PhotoRow; ownerId: string; viewer: Viewer; refresh: string[]; view: string; say: (text: string) => void }) {
  const id = useId().replace(/:/g, '');
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [mode, setMode] = useState<'remove' | 'reject' | null>(null);
  const [text, setText] = useState('');
  const staff = viewer !== 'owner';
  const done = (ok: boolean, t: string) => { setMsg({ ok, text: t }); if (ok) { setMode(null); setText(''); router.refresh(); } };
  const replace = (file: File | undefined) => {
    if (!file) return;
    start(async () => {
      try {
        const body = await prepare(file);
        const fd = new FormData();
        fd.set('document_id', p.id); fd.set('owner_id', ownerId); fd.set('paths', JSON.stringify(refresh));
        fd.set('file', new File([body], file.type === 'application/pdf' ? 'photo.pdf' : 'photo.jpg', { type: file.type === 'application/pdf' ? 'application/pdf' : 'image/jpeg' }));
        const r = await onboardingPhotoReplace(fd);
        // a replaced photo is a new row: this one leaves the list with the refresh, so the list says it (r38: the message went with it)
        if (r.ok) { say(r.data.back_to_review ? 'Replaced. It was approved, so it is checked again.' : 'Replaced. It waits for the check.'); router.refresh(); }
        else done(false, r.message);
      } catch (e) { done(false, e instanceof Error ? e.message : 'The upload did not finish. Try again.'); }
    });
  };
  return (
    <li className="ob-photo" data-testid="onboarding-photo" data-kind={p.kind} data-status={p.review_status}>
      <div className="ob-photo__head">
        <span><b>{p.label}</b> <span className="small muted">{p.vehicle_name} · added {day(p.created_at)}{p.uploaded_by === 'carmacars' ? ' by CarmaCars' : p.uploaded_by === 'owner' ? (staff ? ' by the owner' : ' by you') : ''}{p.replaces ? ' · replaces an earlier one' : ''}</span></span>
        <span className={`badge ${p.review_status === 'rejected' ? 'badge--red' : 'badge--outline'}`} data-testid="onboarding-photo-status">{STATUS[p.review_status]}</span>
      </div>
      {p.review_status === 'rejected' && p.review_note && <p className="small" role="note">Why: {p.review_note}</p>}
      <div className="ob-photo__acts">
        <a className="btn btn--quiet btn--sm" href={view} target="_blank" rel="noopener" data-testid="onboarding-photo-open">Open</a>
        <label className="btn btn--ghost btn--sm" htmlFor={`${id}-f`}>{pending ? 'Working' : 'Replace'}</label>
        <input id={`${id}-f`} type="file" accept="image/jpeg,image/png,application/pdf" disabled={pending} onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; replace(f); }}
          aria-label={`Replace the ${p.label.toLowerCase()} of the ${p.vehicle_name}`} data-testid="onboarding-photo-replace" />
        <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => { setMode(mode === 'remove' ? null : 'remove'); setText(''); }} data-testid="onboarding-photo-remove-open">Remove</button>
        {staff && p.review_status !== 'approved' && <button type="button" className="btn btn--primary btn--sm" disabled={pending} data-testid="onboarding-photo-approve"
          onClick={() => start(async () => { const r = await onboardingPhotoReview(p.id, 'approved', '', refresh); done(r.ok, r.ok ? 'Approved.' : r.message); })}>Approve</button>}
        {staff && p.review_status !== 'rejected' && <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => { setMode(mode === 'reject' ? null : 'reject'); setText(''); }} data-testid="onboarding-photo-reject-open">Not accepted</button>}
      </div>
      {mode && (
        <div className="field">
          <label className="label" htmlFor={`${id}-t`}>{mode === 'remove' ? (staff ? 'Why it is removed (kept in the history)' : 'Why (optional)') : 'What is wrong (the owner reads it)'}</label>
          <input className="input" id={`${id}-t`} value={text} onChange={(e) => setText(e.target.value)} data-testid="onboarding-photo-reason" />
          <div className="row" style={{ gap: 'var(--s-2)', marginTop: 'var(--s-2)' }}>
            <button type="button" className="btn btn--primary btn--sm" disabled={pending || (mode === 'reject' && !text.trim()) || (mode === 'remove' && staff && text.trim().length < 3)} data-testid="onboarding-photo-confirm"
              onClick={() => start(async () => {
                const r = mode === 'remove' ? await onboardingPhotoRemove(p.id, text, refresh) : await onboardingPhotoReview(p.id, 'rejected', text, refresh);
                done(r.ok, r.ok ? (mode === 'remove' ? 'Removed.' : 'Marked not accepted. The owner is asked for a new one.') : r.message);
              })}>{mode === 'remove' ? 'Remove the photo' : 'Not accepted'}</button>
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => setMode(null)}>Cancel</button>
          </div>
        </div>
      )}
      {msg && <p className={`small ${msg.ok ? '' : 'ad-err'}`} role={msg.ok ? 'status' : 'alert'} data-testid="onboarding-photo-msg">{msg.text}</p>}
    </li>
  );
}

function AddPhoto({ cars, refresh, ownerId }: { cars: Array<{ vehicle_id: string; name: string }>; refresh: string[]; ownerId: string }) {
  const id = useId().replace(/:/g, '');
  const router = useRouter();
  const [pending, start] = useTransition();
  const [car, setCar] = useState(cars[0]?.vehicle_id ?? '');
  const [kind, setKind] = useState('ownership_permit');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  if (!cars.length) return null;
  return (
    <details className="stack"><summary className="link small">Add a photo for the owner</summary>
      <div className="field-row">
        <div className="field"><label className="label" htmlFor={`${id}-c`}>Car</label>
          <select className="select" id={`${id}-c`} value={car} onChange={(e) => setCar(e.target.value)}>{cars.map((c) => <option key={c.vehicle_id} value={c.vehicle_id}>{c.name}</option>)}</select></div>
        <div className="field"><label className="label" htmlFor={`${id}-k`}>What it is</label>
          <select className="select" id={`${id}-k`} value={kind} onChange={(e) => setKind(e.target.value)}>{KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
        <div className="field"><label className="label" htmlFor={`${id}-f`}>Photo or PDF</label>
          <input className="input" id={`${id}-f`} type="file" accept="image/jpeg,image/png,application/pdf" disabled={pending} data-testid="onboarding-photo-add"
            onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (!f) return; start(async () => {
              try {
                const body = await prepare(f);
                const fd = new FormData(); fd.set('vehicle_id', car); fd.set('owner_id', ownerId); fd.set('kind', kind); fd.set('paths', JSON.stringify(refresh));
                fd.set('file', new File([body], f.type === 'application/pdf' ? 'photo.pdf' : 'photo.jpg', { type: f.type === 'application/pdf' ? 'application/pdf' : 'image/jpeg' }));
                const r = await onboardingPhotoAdd(fd);
                setMsg({ ok: r.ok, text: r.ok ? 'Added. It waits for the check.' : r.message }); if (r.ok) router.refresh();
              } catch (x) { setMsg({ ok: false, text: x instanceof Error ? x.message : 'The upload did not finish.' }); }
            }); }} /></div>
      </div>
      {msg && <p className={`small ${msg.ok ? '' : 'ad-err'}`} role={msg.ok ? 'status' : 'alert'}>{msg.text}</p>}
    </details>
  );
}

export function OnboardingPhotos({ photos, ownerId, viewer, refresh, cars = [], title = 'Onboarding photos', only }: {
  photos: PhotoRow[]; ownerId: string; viewer: Viewer; refresh: string[]; cars?: Array<{ vehicle_id: string; name: string }>; title?: string; only?: string }) {
  const list = photos.filter((p) => !only || p.vehicle_id === only);
  const [notice, setNotice] = useState<string | null>(null);
  const view = (p: PhotoRow) => viewer === 'owner' ? `/owner/documents/${p.id}` : viewer === 'admin' ? `/admin/documents/${p.id}` : `/staff/documents/${p.id}`;
  return (
    <section className="pt-card stack" id="photos" aria-labelledby="ob-photos-h" data-testid="onboarding-photos">
      <h2 className="d4" id="ob-photos-h">{title}</h2>
      <p className="small muted">{viewer === 'owner' ? 'The ownership permit, insurance and lender photos you or we added. A wrong one? Replace it or remove it: a new photo is checked again.'
        : 'The ownership permit, insurance and lender photos of the owner\'s cars. Replace or remove any of them (kept in the history); approve or mark one not accepted. A replaced photo is checked again.'}</p>
      {list.length ? <ul className="ob-photos">{list.map((p) => <Photo key={p.id} p={p} ownerId={ownerId} viewer={viewer} refresh={refresh} view={view(p)} say={setNotice} />)}</ul>
        : <p className="small muted" data-testid="onboarding-photos-none">No photo yet.</p>}
      {notice && <p className="small" role="status" data-testid="onboarding-photo-msg">{notice}</p>}
      {viewer !== 'owner' && <AddPhoto cars={cars.filter((c) => !only || c.vehicle_id === only)} refresh={refresh} ownerId={ownerId} />}
    </section>
  );
}
