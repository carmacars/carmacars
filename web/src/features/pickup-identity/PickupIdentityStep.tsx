'use client';
import './pickup-identity.css';
import { useState, useTransition } from 'react';
import { DocView } from '@/features/docs-view/DocView';
import { pickupIdentityCheck, pickupIdentityLoad } from '@/server/actions/pickup-identity';
import { preparePhoto } from '@/features/field/queue';
import { WhyDisabled } from '@/components/WhyDisabled';
import { FLAG_TITLE, UPLOAD_LABEL, cardWords, outcomeWords, resultLines, type Answer, type CheckDone, type PickupView } from './model';

// The pickup identity check (r48 ops, 3292 and 3293): is the person taking the car the renter? One optional step, folded
// until opened, on the field checklist, on the one-screen check-in of the booking page and on the renter's own check-in.
// Staff photograph the licence the person is holding and see it beside the licence and selfie on file; they look at the
// card used to pay and answer for its last four digits and its name (the card is never photographed). A renter takes a
// photo of their licence and a selfie. The server reads and compares; a mismatch tells Fleet and Admin. Nothing here is
// required and nothing here stops the handover.
type Shot = 'front' | 'back' | 'selfie';
export function PickupIdentityStep({ booking, driver, who, call = 'ops_read', onChecked }: {
  booking: string; driver?: string; who: 'staff' | 'renter'; call?: 'ops_read' | 'va_read' | 'field_read'; onChecked?: (r: CheckDone) => void;
}) {
  const staff = who === 'staff';
  const [view, setView] = useState<PickupView | null>(null);
  const [shots, setShots] = useState<Partial<Record<Shot, Blob>>>({});
  const [last4, setLast4] = useState<Answer>('');
  const [cname, setCname] = useState<Answer>('');
  const [done, setDone] = useState<CheckDone | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const load = () => { if (!view) start(async () => { const r = await pickupIdentityLoad(booking); if (r.ok) setView(r.data); else setErr(r.message); }); };
  const pick = async (k: Shot, f?: File) => {
    if (!f) return;
    setDone(null); setErr(null);
    // a phone photo is several megabytes: sent smaller, as the checklist's photos are
    const blob = await preparePhoto(f).then((p) => p.blob).catch(() => f);
    setShots((s) => ({ ...s, [k]: blob }));
  };
  const person = view?.drivers.find((d) => (driver ? d.driver_id === driver : d.role === 'renter')) ?? null;
  const ready = Boolean(shots.front || shots.selfie || last4 || cname);
  const check = () => start(async () => {
    setErr(null);
    const form = new FormData();
    form.set('booking', booking); if (driver) form.set('driver', driver);
    for (const k of ['front', 'back', 'selfie'] as const) { const b = shots[k]; if (b) form.set(k, b, `${k}.jpg`); }
    if (staff) { form.set('card_last4', last4); form.set('card_name', cname); }
    const r = await pickupIdentityCheck(form);
    if (!r.ok) { setErr(r.message); return; }
    setDone(r.data); setShots({}); onChecked?.(r.data);
    const v = await pickupIdentityLoad(booking); if (v.ok) setView(v.data);
  });
  const file = (k: Shot, label: string, hint: string, selfie = false) => (
    <div className="pid__shot">
      <label className="label" htmlFor={`pid-${k}-${booking}`}>{label}</label>
      <input className="pid__file" id={`pid-${k}-${booking}`} type="file" accept="image/*" capture={selfie ? 'user' : 'environment'} disabled={pending}
        onChange={(e) => { void pick(k, e.target.files?.[0]); e.target.value = ''; }} data-testid={`pid-${k}`} />
      <p className="small muted" data-testid={`pid-${k}-state`}>{shots[k] ? 'Photo ready. Take it again to replace it.' : hint}</p>
    </div>
  );
  const ask = (legend: string, value: Answer, set: (a: Answer) => void, name: string) => (
    <fieldset className="pid__ask" data-testid={`pid-${name}`}>
      <legend>{legend}</legend>
      {(['yes', 'no'] as const).map((a) => <label key={a}><input type="radio" name={`pid-${name}-${booking}`} checked={value === a} onChange={() => { set(a); setDone(null); }} data-testid={`pid-${name}-${a}`} />{a === 'yes' ? 'Yes' : 'No'}</label>)}
      {value && <button className="btn btn--quiet btn--sm" type="button" onClick={() => set('')}>Clear</button>}
    </fieldset>
  );
  const shown = done ?? (view?.last ? { outcome: view.last.outcome, mismatches: view.last.mismatches, coverage_problem: view.last.coverage_problem, results: view.last.results } : null);
  return (
    <details className="pid" onToggle={(e) => { if (e.currentTarget.open) load(); }} data-testid="pickup-identity">
      <summary data-testid="pid-open">{staff ? 'Check it is the renter: photo of the licence they are holding' : 'Confirm it is you: a photo of your licence and a selfie'}<span className="pid__opt">Optional</span></summary>
      <div className="pid__body">
        <p className="small">{staff
          ? 'Take a photo of the physical licence the person in front of you is holding. It is compared with the licence and selfie on this booking. You can skip this step: it never stops the handover.'
          : 'Take a photo of your driver\'s licence and a selfie now. They are compared with the ones on your booking, to confirm the car goes to you. You can skip this step.'}</p>
        {staff && view?.marked && <div className="pid__flag" role="status" data-testid="pid-marked"><b>{FLAG_TITLE}</b><span className="small">This booking is marked. Fleet and Admin have a To do for it.</span></div>}
        <div className="pid__pair">
          {file('front', staff ? 'The licence they are holding (front)' : 'Your licence (front)', 'Whole card, sharp, no glare.')}
          {staff ? file('back', 'Back of the licence (optional)', 'The barcode on the back is read exactly.') : file('selfie', 'A selfie, now', 'Face the camera, in good light.', true)}
        </div>
        {staff && person && (person.on_file?.length || person.at_pickup?.length) ? (
          <div className="pid__pair" data-testid="pid-side-by-side">
            {[...(person.on_file ?? []), ...(person.at_pickup ?? [])].map((u) => (
              <div className="pid__shot" key={u.id}><b className="small">{UPLOAD_LABEL[u.kind] ?? u.kind.replace(/_/g, ' ')}</b>
                <DocView upload={u.id} call={call} label={UPLOAD_LABEL[u.kind] ?? u.kind} testId={`pid-view-${u.kind}`} /></div>))}
          </div>) : null}
        {staff && person && <p className="small" data-testid="pid-on-file">On file: <b>{person.name}</b>{person.licence_number ? ` · licence ${person.licence_number}` : ''}{person.licence_expiry ? ` · expires ${person.licence_expiry}` : ''}</p>}
        {staff && view && (
          <div className="pid__card" data-testid="pid-card">
            <b>Show the card used to pay</b>
            <p className="small">Card on file: <b data-testid="pid-card-on-file">{cardWords(view.card)}</b></p>
            <p className="small">Name on the booking: <b>{view.booking_name ?? person?.name ?? ''}</b></p>
            {view.coverage_card && <p className="small"><b>This rental is covered by the renter&apos;s credit card:</b> the card must be in the renter&apos;s own name.</p>}
            <p className="small muted">Look at the card. Do not photograph it and do not write its number down.</p>
            {view.card?.last4 && ask(`Does the card they showed end in ${view.card.last4}?`, last4, setLast4, 'last4')}
            {ask('Is the name on the card the name on the ID?', cname, setCname, 'cname')}
          </div>)}
        <button className="btn btn--primary pid__go" type="button" disabled={pending || !ready} onClick={check} data-testid="pid-check" aria-describedby={`pid-why-${booking}`}>{pending ? 'Checking' : 'Check now'}</button>
        <WhyDisabled id={`pid-why-${booking}`} why={!ready && (staff ? 'Take the photo of the licence first, or answer for the card.' : 'Take the photo of your licence or the selfie first.')} />
        {err && <p className="small alert alert--error" role="alert" data-testid="pid-error"><span>{err}</span></p>}
        {shown && (
          <div className="stack" role="status" data-testid="pid-result" data-outcome={shown.outcome}>
            {shown.outcome === 'mismatch' && staff
              ? <div className="pid__flag"><b>{FLAG_TITLE}</b><ul className="small">{shown.mismatches.map((m) => <li key={m}>{m}</li>)}</ul>
                  {shown.coverage_problem && <span className="small"><b>Coverage problem:</b> credit card coverage needs a card in the renter&apos;s own name.</span>}</div>
              : null}
            <p className="small"><b>{outcomeWords(shown.outcome, staff)}</b></p>
            <ul className="pid__res">{resultLines(shown.results, staff).map((l) => <li key={l.key}><span>{l.label}</span><b data-r={l.result} data-testid={`pid-r-${l.key}`}>{l.word}</b></li>)}</ul>
          </div>)}
      </div>
    </details>
  );
}
