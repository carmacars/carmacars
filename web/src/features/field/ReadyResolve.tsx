'use client';
import { useState, useTransition } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { fieldAct } from '@/server/actions/field';
import { fieldPaperScan } from '@/server/actions/field-paper';
import { staffLicenceUpload } from '@/server/actions/sign-now';
import { startCardRequest } from '@/server/actions/offers';
import { preparePhoto } from './queue';
import type { FieldJob, Resolve } from './types';

// The ready check resolved on the spot (0151): each line that is not ready says what field staff can do about it here,
// instead of only "Stop". The database decides every step again (app.field_resolve) and records who did what.
const money = (c: number) => new Intl.NumberFormat('en-CA', { style: 'currency', currency: 'CAD' }).format(c / 100);
const KINDS: Array<[string, string]> = [['licence_front', 'Licence, front'], ['licence_back', 'Licence, back'], ['selfie', 'Selfie with the licence']];

function useAct() {
  const router = useRouter();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const run = (f: () => Promise<{ ok: boolean; message?: string }>, done: string) => start(async () => {
    setMsg(null);
    const r = await f();
    if (!r.ok) { setMsg({ ok: false, text: r.message ?? 'Not saved.' }); return; }
    setMsg({ ok: true, text: done });
    router.refresh();
  });
  return { msg, pending, run, setMsg };
}
function Msg({ m }: { m: { ok: boolean; text: string } | null }) {
  return m ? <p className={`alert ${m.ok ? 'alert--ok' : 'alert--error'} small`} role={m.ok ? 'status' : 'alert'}><span>{m.text}</span></p> : null;
}

/** The agreement is not signed: sign on this phone, or scan the paper copy. */
export function ResolveSignature({ j, signNow }: { j: FieldJob; signNow: string }) {
  const { msg, pending, run } = useAct();
  const [pages, setPages] = useState<File[]>([]);
  const b = j.booking!;
  const send = () => run(async () => {
    const fd = new FormData(); fd.set('job', j.job.id); fd.set('booking', b.id); fd.set('signer_name', b.renter?.name ?? '');
    for (const p of pages) { const x = await preparePhoto(p).catch(() => null); fd.append('page', x ? new File([x.blob], 'page.jpg', { type: 'image/jpeg' }) : p); }
    const r = await fieldPaperScan(fd);
    if (r.ok) setPages([]);
    return r;
  }, 'The paper copy is recorded. The agreement counts as signed.');
  return (
    <div className="fd-fix stack" data-testid="fix-signature">
      <Link prefetch={false} className="btn btn--primary fd-wide" href={signNow} data-testid="fix-sign-now">Sign now on this device</Link>
      <details className="fd-fix__more">
        <summary>Signed on paper instead? Scan it</summary>
        <div className="stack">
          <p className="small">Photograph every page of the signed agreement, in order. They become one PDF on the booking.</p>
          <label className="btn btn--ghost fd-wide">{pages.length ? `Add a page (${pages.length} taken)` : 'Take a photo of page 1'}
            <input className="vh" type="file" accept="image/*,application/pdf" capture="environment" data-testid="fix-paper-page"
              onChange={(e) => { const f = e.target.files?.[0]; if (f) setPages((p) => [...p, f]); e.target.value = ''; }} /></label>
          {pages.length > 0 && <p className="small" data-testid="fix-paper-count">{pages.length} page{pages.length > 1 ? 's' : ''} ready. <button type="button" className="link" onClick={() => setPages([])}>Start again</button></p>}
          <button type="button" className="btn btn--primary fd-wide" disabled={pending || !pages.length} onClick={send} data-testid="fix-paper-send">{pending ? 'Sending' : 'Record the signed paper copy'}</button>
        </div>
      </details>
      <Msg m={msg} />
    </div>
  );
}

/** A driver's identity is not verified: photograph the licence and the person, confirm each check, done. */
export function ResolveIdentity({ j, r }: { j: FieldJob; r: Resolve }) {
  return (
    <div className="fd-fix stack" data-testid="fix-identity">
      {r.drivers.filter((d) => !d.verified).map((d) => <DriverCheck key={d.driver_id} j={j} r={r} d={d} />)}
    </div>
  );
}
function DriverCheck({ j, r, d }: { j: FieldJob; r: Resolve; d: Resolve['drivers'][number] }) {
  const { msg, pending, run, setMsg } = useAct();
  const router = useRouter();
  const [up, startUp] = useTransition();
  const [c, setC] = useState({ name: false, photo: false, expiry: false, class: false });
  const [num, setNum] = useState('');
  const [exp, setExp] = useState('');
  const l = d.licence as unknown as Record<string, string | null | undefined> & Resolve['drivers'][number]['licence'];
  const needExpiry = !l.expiry;
  const kinds = KINDS.filter(([k]) => k !== 'selfie' || r.selfie_required);
  const have = (k: string) => l[k] === 'submitted' || l[k] === 'approved';
  const allPhotos = kinds.every(([k]) => have(k));
  const photo = (kind: string, f: File | undefined) => {
    if (!f) return;
    startUp(async () => {
      setMsg(null);
      const p = await preparePhoto(f).catch(() => null);
      const fd = new FormData(); fd.set('booking', j.booking!.id); fd.set('driver', d.driver_id); fd.set('kind', kind);
      fd.set('file', p ? new File([p.blob], `${kind}.jpg`, { type: 'image/jpeg' }) : f);
      const x = await staffLicenceUpload(fd);
      if (!x.ok) { setMsg({ ok: false, text: x.message }); return; }
      router.refresh();
    });
  };
  const confirm = () => run(() => fieldAct('identity_in_person', { job: j.job.id, driver: d.driver_id, checks: c, licence_number: num || null, licence_expiry: exp || null }),
    `${d.name}'s licence is checked.`);
  return (
    <section className="fd-card stack" aria-label={`Licence of ${d.name}`} data-testid={`fix-driver-${d.role}`}>
      <p><b>{d.name}</b> <span className="small muted">{d.role.replace(/_/g, ' ')}</span></p>
      <ol className="fd-shots">{kinds.map(([k, t]) => (
        <li key={k} className={have(k) ? 'is-done' : undefined}>
          <span><b>{t}</b><span className="small">{have(k) ? ' taken' : l[k] === 'rejected' ? ' rejected: take it again' : ''}</span></span>
          <label className="btn btn--ghost btn--sm fd-cam">{up ? 'Sending' : have(k) ? 'Retake' : 'Take'}
            <input className="vh" type="file" accept="image/*" capture={k === 'selfie' ? 'user' : 'environment'} data-testid={`fix-photo-${d.role}-${k}`}
              onChange={(e) => { photo(k, e.target.files?.[0]); e.target.value = ''; }} /></label>
        </li>))}
      </ol>
      <fieldset className="stack" style={{ gap: 'var(--s-2)' }}>
        <legend className="label">Check the original licence in your hand</legend>
        <label className="check"><input type="checkbox" checked={c.name} onChange={(e) => setC({ ...c, name: e.target.checked })} data-testid={`fix-check-name-${d.role}`} /> <span>The name matches the booking ({d.name})</span></label>
        <label className="check"><input type="checkbox" checked={c.photo} onChange={(e) => setC({ ...c, photo: e.target.checked })} data-testid={`fix-check-photo-${d.role}`} /> <span>The photo on the licence is the person in front of me</span></label>
        <label className="check"><input type="checkbox" checked={c.expiry} onChange={(e) => setC({ ...c, expiry: e.target.checked })} data-testid={`fix-check-expiry-${d.role}`} /> <span>Valid past the return date{l.expiry ? ` (expires ${l.expiry})` : ''}</span></label>
        <label className="check"><input type="checkbox" checked={c.class} onChange={(e) => setC({ ...c, class: e.target.checked })} data-testid={`fix-check-class-${d.role}`} /> <span>Class G2 or G, and no sign of alteration</span></label>
      </fieldset>
      {needExpiry && <div className="stack">
        <label className="field"><span className="label">Licence number (from the card)</span><input className="input" autoCapitalize="characters" value={num} onChange={(e) => setNum(e.target.value)} data-testid={`fix-number-${d.role}`} /></label>
        <label className="field"><span className="label">Expiry date</span><input className="input" type="date" value={exp} onChange={(e) => setExp(e.target.value)} data-testid={`fix-expiry-${d.role}`} /></label>
      </div>}
      <button type="button" className="btn btn--primary fd-wide" disabled={pending || up || !allPhotos || !(c.name && c.photo && c.expiry && c.class) || (needExpiry && !exp)}
        onClick={confirm} data-testid={`fix-identity-confirm-${d.role}`}>{pending ? 'Saving' : 'The licence checks out'}</button>
      {!allPhotos && <p className="small muted">Take the {kinds.filter(([k]) => !have(k)).map(([, t]) => t.toLowerCase()).join(', ')} first.</p>}
      <Msg m={msg} />
    </section>
  );
}

/** The deposit is not taken: a card hold on the renter's phone, or e-Transfer or cash when allowed. */
export function ResolveDeposit({ j, r, back }: { j: FieldJob; r: Resolve; back: string }) {
  const router = useRouter();
  const { msg, pending, run } = useAct();
  const [card, startCard] = useTransition();
  const [ref, setRef] = useState('');
  const [cardErr, setCardErr] = useState<string | null>(null);
  const b = j.booking!;
  const long = (new Date(b.return_at).getTime() - new Date(b.pickup_at).getTime()) / 86_400_000 > 7;
  const hold = () => startCard(async () => {
    setCardErr(null);
    const x = await startCardRequest({ booking: b.booking_number, kind: long ? 'setup' : 'hold', channel: 'device', back });
    if (!x.ok) { setCardErr(x.message); return; }
    router.push(x.data.url);
  });
  return (
    <div className="fd-fix stack" data-testid="fix-deposit">
      <p className="small">Deposit {money(r.deposit_cents)}{j.ready?.deposit === 'declined' ? ': the card was declined. Ask for another credit card in the renter’s name.' : '.'}</p>
      <button type="button" className="btn btn--primary fd-wide" disabled={card} onClick={hold} data-testid="fix-deposit-card">
        {card ? 'Opening' : long ? 'Save the card on this phone (long rental)' : 'Card hold: hand this phone to the renter'}</button>
      {cardErr && <p className="alert alert--error small" role="alert"><span>{cardErr}</span></p>}
      {r.deposit_methods.includes('e_transfer') && (
        <details className="fd-fix__more" data-testid="fix-deposit-etransfer">
          <summary>Paid by e-Transfer</summary>
          <div className="stack">
            <p className="small">The renter sends {money(r.deposit_cents)}{r.e_transfer_email ? <> to <b>{r.e_transfer_email}</b></> : null} and shows you the confirmation with its reference number.</p>
            <label className="field"><span className="label">e-Transfer reference number</span><input className="input" value={ref} onChange={(e) => setRef(e.target.value)} autoCapitalize="characters" data-testid="fix-etransfer-ref" /></label>
            <button type="button" className="btn btn--primary fd-wide" disabled={pending || ref.trim().length < 3}
              onClick={() => run(() => fieldAct('deposit_offline', { job: j.job.id, method: 'e_transfer', reference: ref.trim() }), 'Deposit recorded as e-Transfer.')} data-testid="fix-etransfer-save">{pending ? 'Saving' : 'Record the e-Transfer'}</button>
          </div>
        </details>)}
      {r.deposit_methods.includes('cash') && (
        <details className="fd-fix__more" data-testid="fix-deposit-cash">
          <summary>Paid in cash</summary>
          <div className="stack">
            <p className="small">Count {money(r.deposit_cents)} in front of the renter, keep it apart, and bring it to the office: Finance gets a task to collect it from you.</p>
            <button type="button" className="btn btn--primary fd-wide" disabled={pending}
              onClick={() => run(() => fieldAct('deposit_offline', { job: j.job.id, method: 'cash' }), 'Cash deposit recorded. Hand it to Finance.')} data-testid="fix-cash-save">{pending ? 'Saving' : `I received ${money(r.deposit_cents)} in cash`}</button>
          </div>
        </details>)}
      <Msg m={msg} />
    </div>
  );
}

/** The tracker is not reporting: release with a reason, an Admin is told at once. */
export function TrackerOverride({ j, r }: { j: FieldJob; r: Resolve }) {
  const { msg, pending, run } = useAct();
  const [reason, setReason] = useState('');
  if (r.tracker_override) return <p className="fd-line is-ok" data-testid="tracker-overridden"><span aria-hidden="true">✓</span> Released without the tracker: {r.tracker_override.reason}. An Admin was told.</p>;
  if (!r.tracker_override_allowed) return null;
  return (
    <details className="fd-fix__more" data-testid="fix-tracker">
      <summary>The car has to go anyway?</summary>
      <div className="stack">
        <p className="small">Say why. The car is released with the tracker recorded as not reporting, and an Admin gets an urgent task right away.</p>
        <label className="field"><span className="label">Reason</span><textarea className="input" value={reason} onChange={(e) => setReason(e.target.value)} data-testid="fix-tracker-reason" placeholder="Underground parking, no signal; the office confirmed by phone" /></label>
        <button type="button" className="btn btn--primary fd-wide" disabled={pending || reason.trim().length < 10}
          onClick={() => run(() => fieldAct('tracker_override', { job: j.job.id, reason: reason.trim() }), 'Recorded. An Admin was told. Go on.')} data-testid="fix-tracker-save">{pending ? 'Saving' : 'Release without the tracker'}</button>
        <Msg m={msg} />
      </div>
    </details>
  );
}
