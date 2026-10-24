'use client';
import { useState, useTransition, type ReactNode } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import type { Consent } from '@/features/agreement/model';
import { SignatureInput, type SignatureValue } from '@/features/signing/SignatureInput';
import { signInPerson, staffLicenceUpload } from '@/server/actions/sign-now';
import type { Signer, SigningState } from './types';

// "Sign now on this device" (migration 0130). The staff view lists who still signs, with their licence on file; the
// staff member checks the name and the original licence (and can photograph it), then hands the device over. The
// signer's view shows the agreements (CarmaCars' and Blind Spot's), the statements and the signature; then "hand the
// device back", and the staff view again. The record says it was signed in person, collected by this staff member.
const KINDS: Array<[string, string]> = [['licence_front', 'Licence, front'], ['licence_back', 'Licence, back'], ['selfie', 'Selfie with the licence']];

export function SignNow({ s, base, agreement, consents, staffName }: { s: SigningState; base: string; agreement: ReactNode; consents: Consent[]; staffName: string }) {
  const router = useRouter();
  const [who, setWho] = useState<Signer | null>(null);
  const [mode, setMode] = useState<'staff' | 'signer' | 'done'>('staff');
  const [checks, setChecks] = useState<Record<string, { name: boolean; licence: boolean }>>({});
  const [doneMsg, setDoneMsg] = useState('');
  const open = s.agreement && (s.agreement.status === 'open' || s.agreement.status === 'signed');
  const waiting = s.signers.filter((x) => !x.signed_at);
  if (!open) return <p className="pt-empty" data-testid="sign-now-none">No rental agreement is waiting for a signature on this booking.{s.status === 'pending_payment' ? ' It opens when the renter\'s details are saved.' : ''}</p>;

  if (mode === 'signer' && who) return (
    <SignerView s={s} who={who} agreement={agreement} consents={who.role === 'renter' ? consents : consents.filter((c) => c.n <= 3)}
      identity={{ name_confirmed: !!checks[who.id]?.name, licence_seen: !!checks[who.id]?.licence }}
      onCancel={() => setMode('staff')}
      onSigned={(declined) => { setDoneMsg(declined ? `Signed. The card was not charged: ${declined}` : 'Signed.'); setMode('done'); }} />
  );
  if (mode === 'done' && who) return (
    <div className="pt-card hr-sign__handoff stack" role="status" data-testid="sign-now-done">
      <h2 className="d3">{doneMsg} Thank you, {who.name.split(' ')[0]}.</h2>
      <p className="lead">Please hand the device back to {staffName}.</p>
      <button className="btn btn--primary btn--lg" type="button" onClick={() => { setWho(null); setMode('staff'); router.refresh(); }} data-testid="sign-now-back">Back to the staff view</button>
    </div>
  );
  return (
    <div className="stack-lg" data-testid="sign-now-staff">
      {waiting.length === 0 && <p className="alert alert--ok" role="status" data-testid="sign-now-all-signed"><span className="alert__title">Everyone has signed</span><span><Link prefetch={false} className="link" href={base}>Back to the booking</Link></span></p>}
      {s.signers.map((g) => (
        <section key={g.id} className={`pt-card${g.signed_at ? '' : ' pt-card--next'}`} aria-labelledby={`sn-${g.id}`} data-testid={`sign-now-signer-${g.role}`}>
          <div className="pt-card__head"><h2 className="d4" id={`sn-${g.id}`}>{g.name}</h2><span className="badge badge--outline">{g.role === 'renter' ? 'Renter' : 'Additional driver'}</span></div>
          {g.signed_at ? <p className="fd-line is-ok"><span aria-hidden="true">✓</span> Signed{g.in_person ? ' in person' : ''}</p> : (
            <div className="stack">
              <Licence s={s} g={g} />
              <fieldset className="stack" style={{ gap: 'var(--s-2)' }}>
                <legend className="label">Before you hand over the device</legend>
                <label className="check"><input type="checkbox" checked={!!checks[g.id]?.name} onChange={(e) => setChecks((c) => ({ ...c, [g.id]: { name: e.target.checked, licence: !!c[g.id]?.licence } }))} data-testid="sn-name" /> <span>The person in front of me is {g.name}: the name matches their licence.</span></label>
                <label className="check"><input type="checkbox" checked={!!checks[g.id]?.licence} onChange={(e) => setChecks((c) => ({ ...c, [g.id]: { name: !!c[g.id]?.name, licence: e.target.checked } }))} data-testid="sn-licence" /> <span>I saw the original licence: the photo matches the person and it has not expired.</span></label>
              </fieldset>
              <button className="btn btn--primary" type="button" disabled={!checks[g.id]?.name || !checks[g.id]?.licence} onClick={() => { setWho(g); setMode('signer'); window.scrollTo(0, 0); }} data-testid={`sn-hand-${g.role}`}>
                Hand the device to {g.name.split(' ')[0]}</button>
            </div>
          )}
        </section>
      ))}
    </div>
  );
}

function Licence({ s, g }: { s: SigningState; g: Signer }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const l = g.licence;
  const up = (kind: string, f: File | undefined) => {
    if (!f || !g.driver_id) return;
    const fd = new FormData(); fd.set('booking', s.booking_id); fd.set('driver', g.driver_id); fd.set('kind', kind); fd.set('file', f);
    start(async () => { const r = await staffLicenceUpload(fd); setErr(r.ok ? null : r.message); if (r.ok) router.refresh(); });
  };
  return (
    <div className="stack" style={{ gap: 'var(--s-2)' }} data-testid="sn-licence-state">
      <p className="small">{l.complete ? <>Licence on file{l.verified ? ', verified' : ', in review'}{l.expiry ? `, expires ${l.expiry}` : ''}.</> : <>Licence still needed: {l.missing.join(', ')}.</>}</p>
      {!l.complete && g.driver_id && <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        {KINDS.filter(([k]) => !(l as unknown as Record<string, string | null>)[k] || (l as unknown as Record<string, string | null>)[k] === 'rejected').map(([k, t]) => (
          <label key={k} className="btn btn--ghost btn--sm">{pending ? 'Uploading' : `Photograph: ${t}`}
            <input className="vh" type="file" accept="image/*" capture={k === 'selfie' ? 'user' : 'environment'} data-testid={`sn-photo-${k}`} onChange={(e) => { up(k, e.target.files?.[0]); e.target.value = ''; }} /></label>
        ))}
      </div>}
      {err && <p className="error" role="alert">{err}</p>}
    </div>
  );
}

function SignerView({ s, who, agreement, consents, identity, onCancel, onSigned }: { s: SigningState; who: Signer; agreement: ReactNode; consents: Consent[]; identity: { name_confirmed: boolean; licence_seen: boolean };
  onCancel: () => void; onSigned: (declined: string | null) => void }) {
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const [sig, setSig] = useState<SignatureValue>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const all = consents.every((c) => ticked.has(c.code));
  const submit = () => {
    if (!all) { setErr(`Tick the ${consents.length === 4 ? 'four' : 'three'} statements.`); return; }
    if (!sig) { setErr('Sign in the box, or use your name.'); return; }
    setErr(null);
    start(async () => {
      const r = await signInPerson({ booking: s.booking_id, signer: who.id, sha: s.agreement!.document_sha256, companionSha: who.role === 'renter' && s.companion?.status === 'open' ? s.companion.document_sha256 : null,
        consents: [...ticked], typedName: sig.method === 'typed' ? sig.typedName : undefined, drawn: sig.method === 'drawn' ? sig.png : undefined,
        device: typeof navigator !== 'undefined' ? navigator.userAgent : undefined, identity });
      if (!r.ok) { setErr(r.message); return; }
      onSigned(r.data.declined);
    });
  };
  return (
    <div className="stack-lg hr-sign" data-testid="sign-now-signer">
      <header className="stack"><p className="pt-kicker">Booking {s.booking_number}</p><h1 className="d2">{who.name.split(' ')[0]}, please read and sign</h1>
        <p className="muted">{who.role === 'renter' ? 'Your rental agreement, filled in with your booking and your details.' : 'You are an additional driver on this booking. Read the agreement and accept it.'}</p></header>
      <details className="sg-docs" open><summary>Read the full rental agreement</summary>{agreement}</details>
      {who.role === 'renter' && s.companion && <p className="small" data-testid="sn-companion">We rent under Blind Spot Car Rental&apos;s insurance, so your rental also has their agreement, filled in with the same booking and details. Your one signature below signs both agreements.</p>}
      <fieldset className="pt-consents">
        <legend>Before you sign</legend>
        <label className="check pk-all"><input type="checkbox" checked={all} onChange={(e) => setTicked(e.target.checked ? new Set(consents.map((c) => c.code)) : new Set())} data-testid="sn-consents-all" />
          <span><b>All {consents.length === 4 ? 'four' : 'three'}</b>: I agree to each statement below</span></label>
        <div className="pk-statements">{consents.map((c) => (
          <label key={c.code} className="check"><input type="checkbox" checked={ticked.has(c.code)} onChange={(e) => { const n = new Set(ticked); if (e.target.checked) n.add(c.code); else n.delete(c.code); setTicked(n); }} />
            <span><b>{c.n}. {c.title}.</b> {c.text}</span></label>))}</div>
      </fieldset>
      <SignatureInput id="sn-sig" name={who.name} onChange={setSig} />
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <button className="btn btn--primary btn--lg" type="button" disabled={pending} onClick={submit} data-testid="sn-sign">{pending ? 'Signing' : who.role === 'renter' ? 'Sign the agreement' : 'Accept and sign'}</button>
        <button className="btn btn--ghost" type="button" disabled={pending} onClick={onCancel}>Give the device back without signing</button>
      </div>
      <p className="xs muted">We record the time, the device and that you signed in person with CarmaCars staff.</p>
    </div>
  );
}
