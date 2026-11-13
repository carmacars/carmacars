'use client';
import { useEffect, useMemo, useRef, useState, useTransition } from 'react';
import Link from '@/components/Link';
import { useRouter } from 'next/navigation';
import { SignaturePad } from '@/features/portal/SignaturePad';
import { fieldAct } from '@/server/actions/field';
import { CarDiagram, type Mark } from './CarDiagram';
import { ResolveDeposit, ResolveIdentity, ResolveSignature, TrackerOverride } from './ReadyResolve';
import { preparePhoto, uploads, useUploads } from './queue';
import { FdIcon } from './icons';
import { Plate } from './Plate';
import type { FieldJob } from './types';
import { depositAutoText } from '@/features/money/deposit-auto-text';
import { money } from '@/lib/format';
import { mergeAnswers, prefill, sourceHint, stillNeeded, type Part } from './one-screen';
import { LateReturnChoice } from '@/features/handover/LateReturnChoice';
import { NO_CHOICE, afterReturnText, choicePayload, choiceProblem, decisionText, type LateChoice } from '@/features/handover/late-return';

// The handover and return checklists (06-field.md sections 4 and 5) on one screen (release 42, migration 2660): every
// part of the handover is on the page in the order it is done, with a tick once it is complete; what can be known is
// filled in already (the odometer and fuel from the Tracker or the last report, the keys, the cleanliness); what is
// optional is folded away; the one button at the bottom, within thumb reach, says what is still needed and takes you to
// it. Nothing the handover requires was dropped: the database completes the handover or the return in one transaction
// and refuses anything missing, as before. Answers save as they are given, on the phone and on the server
// (save_condition_report); photos go through the queue: an interrupted handover opens where it was left.
type Report = {
  odometer_km?: number; fuel_pct?: number; keys_count?: number; licence_seen?: boolean; card_seen?: boolean; renter_present?: boolean; unattended?: boolean;
  cleanliness?: string; odour?: boolean; belongings_found?: string; notes?: string; renter_signature_ref?: string; staff_signature_ref?: string;
  renter_declined_to_sign?: boolean; renter_decline_reason?: string; car_diagram?: Record<string, unknown>; fuel_or_charge_ok?: boolean; odometer_confirmed?: boolean;
};
type Damage = { label: string; location: string; description: string; kind: string; size_cm: number | null; position: { x: number; y: number } | null; is_new: boolean };
const LOCATIONS = ['front bumper', 'hood', 'windshield', 'roof', 'left front door', 'left rear door', 'left side', 'right front door', 'right rear door', 'right side', 'rear bumper', 'trunk', 'wheel or tire', 'mirror', 'interior', 'other'];
const KINDS = ['scratch', 'dent', 'chip', 'crack', 'scuff', 'stain', 'tear', 'other'];
const CLEAN: Array<[string, string]> = [['clean', 'Standard'], ['needs_cleaning', 'Needs cleaning'], ['heavy', 'Heavy soiling or odour'], ['pet_hair', 'Pet hair'], ['smoking', 'Smoking evidence']];
const shotName = (s: string) => s.replace(/_/g, ' ');
// the content security policy blocks fetch() of a data URL: decode it by hand
const dataUrlBlob = async (u: string) => {
  const [head, b64 = ''] = u.split(','); const bin = atob(b64); const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return new Blob([out], { type: /data:([^;]+)/.exec(head ?? '')?.[1] ?? 'image/png' });
};

export function Checklist({ j, back = '/staff/field', backLabel = 'Back to my jobs', here }: { j: FieldJob; back?: string; backLabel?: string;
  /** 0151: where this checklist runs (the field job, or the booking's check-in for staff): its sign-now page and the page the card form returns to */
  here?: { signNow: string; self: string } }) {
  const router = useRouter();
  // where each photo is taken, when the phone allows it (0130): asked once, never in the way
  const where = useRef<{ latitude: number; longitude: number } | null>(null);
  useEffect(() => {
    try {
      navigator.geolocation?.getCurrentPosition((p) => { where.current = { latitude: Math.round(p.coords.latitude * 1e6) / 1e6, longitude: Math.round(p.coords.longitude * 1e6) / 1e6 }; },
        () => undefined, { maximumAge: 120_000, timeout: 10_000, enableHighAccuracy: false });
    } catch { /* no location on this device */ }
  }, []);
  const pickup = j.report_kind === 'pickup';
  const jobId = j.job.id;
  const key = `cc-field-${jobId}`;
  // 0195: a pickup or return recorded with the details later: the photos, readings and staff signature only
  const later = Boolean(j.details_later);
  const unattended = Boolean(j.booking?.unattended) || later;
  // 2660: the screen starts with what is known (the Tracker, the last report, the pickup); then what the server has; then
  // what this phone kept
  const [r, setR] = useState<Report>(() => {
    const pre: Report = prefill(j.defaults, pickup ? 'pickup' : 'return', !unattended);
    const server: Report = j.report ? { odometer_km: j.report.odometer_km ?? undefined, fuel_pct: j.report.fuel_pct ?? undefined, keys_count: j.report.keys_count ?? undefined, cleanliness: j.report.cleanliness ?? undefined } : {};
    let local: Report = {};
    try { local = JSON.parse(localStorage.getItem(key) ?? '{}') as Report; } catch { local = {}; }
    return { ...mergeAnswers<Report>(pre, server), ...local };
  });
  const [damages, setDamages] = useState<Damage[]>(() => (j.report?.damages ?? []).map((d) => ({ ...d, kind: d.kind ?? 'other', size_cm: d.size_cm ?? null, position: d.position ?? null, is_new: d.is_new ?? true })));
  const [stop, setStop] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [lateChoice, setLateChoice] = useState<LateChoice>(NO_CHOICE);
  const [pending, start] = useTransition();
  // the answers' save state (2026-10-25): saved on the server, or kept on this phone while there is no signal and sent
  // again as soon as there is
  const [saved, setSaved] = useState<'idle' | 'saving' | 'saved' | 'phone'>('idle');
  const q = useUploads(jobId);
  const onServer = useMemo(() => new Set((j.report?.photos ?? []).map((p) => p.seq)), [j.report]);
  const has = (seq: number) => onServer.has(seq) || q.arrived(seq) || q.pending.some((x) => x.seq === seq && x.mode === 'photo');
  const set = (p: Partial<Report>) => setR((s) => { const n = { ...s, ...p }; try { localStorage.setItem(key, JSON.stringify(n)); } catch { /* private mode */ } return n; });
  const ready = j.ready;
  const res = j.resolve ?? null;
  const at = here ?? { signNow: `/staff/field/jobs/${jobId}/sign-now`, self: `/staff/field/jobs/${jobId}` };

  const save = (extra: Record<string, unknown> = {}) => fieldAct('save_report', { job: jobId, report: { ...strip(r), ...extra } });
  // the answers go to the server a moment after the last change (no Next button to press); with no signal they stay on
  // the phone and are sent again when it is back; the completion sends every answer once more
  const [saveMsg, setSaveMsg] = useState<string | null>(null);
  const first = useRef(true);
  const send = (answers: Report) => { setSaved('saving'); void fieldAct('save_report', { job: jobId, report: strip(answers) }).then((s) => { setSaved(s.ok ? 'saved' : 'idle'); setSaveMsg(s.ok ? null : s.message); }).catch(() => setSaved('phone')); };
  const resend = () => send(r);
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    const t = setTimeout(() => send(r), 1200);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the answers are the only thing that starts a save
  }, [r]);
  useEffect(() => {
    if (saved !== 'phone') return;
    const on = () => send(r);
    window.addEventListener('online', on);
    return () => window.removeEventListener('online', on);
  });
  const block = (reason: string) => start(async () => {
    try {
      const x = await fieldAct('block_handover', { job: jobId, reason });
      setStop(x.ok ? `${reason}. CarmaCars has an urgent task.` : `${reason}. ${x.message}`);
    } catch { setStop(`${reason}. No connection: the office was not told yet.`); }
  });

  const photo = async (seq: number, shot: string, file: File | undefined, damage_label?: string) => {
    if (!file) return;
    const p = await preparePhoto(file);
    if (p.flags.some((f) => ['dark', 'blurry'].includes(f))) setMsg(`That photo looks ${p.flags.filter((f) => ['dark', 'blurry'].includes(f)).join(' and ')}. Take it again if you can; it is kept otherwise.`);
    await uploads.add({ job: jobId, seq, shot, mode: 'photo', damage_label: damage_label ?? null, blob: p.blob, taken_at: new Date().toISOString(), width: p.width, height: p.height, flags: p.flags, ...(where.current ?? {}) });
  };
  const sign = async (who: 'renter' | 'staff', png: string) => {
    const k = await uploads.addAndWait({ job: jobId, seq: who === 'renter' ? 900 : 901, shot: `signature_${who}`, mode: 'raw', blob: await dataUrlBlob(png), taken_at: new Date().toISOString() });
    set(who === 'renter' ? { renter_signature_ref: k } : { staff_signature_ref: k });
  };

  // ---------------------------------------------------------------- the parts of the screen
  const required = j.shots;
  const shotsDone = required.filter((s) => has(s.seq)).length;
  const closeupsMissing = damages.filter((d) => d.is_new && !damageSeqs(damages).some(([l, s]) => l === d.label && has(s)));
  const queueEmpty = q.pending.length === 0;
  const oldMarks: Mark[] = (pickup ? j.baseline_damages : j.pickup?.damages ?? []).map((d) => ({ label: d.label, position: d.position ?? null, old: true }));
  const marks: Mark[] = [...oldMarks, ...damages.map((d) => ({ label: d.label, position: d.position }))];
  const newDamage = damages.some((d) => d.is_new);
  const late = !pickup && !later && j.late?.late ? j.late : null;
  const lateProblem = late ? choiceProblem(lateChoice, late) : null;

  // the ready check: a rental added by hand also needs the renter's signature (0051), as a booking made online already has
  const depositOk = Boolean(ready && ['taken', 'waived', 'none'].includes(ready.deposit));
  const readyOk = Boolean(ready && ready.signed !== false && ready.identity && ready.coverage && ready.drivers_accepted && ready.calendar && depositOk);
  const odoLow = pickup && (j.vehicle.odometer_km ?? 0) > (r.odometer_km ?? 0) && (r.odometer_km ?? 0) > 0;
  const odoOk = (r.odometer_km ?? 0) > 0 && !(odoLow && !r.odometer_confirmed);
  const readingsOk = odoOk && r.fuel_pct !== undefined && (r.keys_count ?? 0) >= 1 && (pickup || Boolean(r.cleanliness));
  const atCarOk = r.renter_present === true && r.licence_seen === true && (r.card_seen === true || j.booking?.booking_type === 'owner');
  const signOk = pickup ? Boolean((unattended || r.renter_signature_ref) && r.staff_signature_ref)
    : Boolean(r.staff_signature_ref) && (later || Boolean(r.renter_signature_ref || (r.renter_declined_to_sign && (r.renter_decline_reason ?? '').trim()) || r.renter_present === false));
  const trackerOk = Boolean(j.tracker.reporting || j.tracker.override);
  const renterToSign = pickup ? !unattended && !r.renter_signature_ref
    : !later && !(r.renter_signature_ref || (r.renter_declined_to_sign && (r.renter_decline_reason ?? '').trim()) || r.renter_present === false);

  const go = (id: string) => { document.getElementById(`hs-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' }); };
  const complete = () => start(async () => {
    setMsg(null);
    if (lateProblem) { setMsg(lateProblem); go('late'); return; }
    try {
      if (pickup) {
        const x = await fieldAct<{ booking_status: string }>('complete_handover', { job: jobId, report: { ...strip(r), fuel_or_charge_ok: r.fuel_or_charge_ok ?? (r.fuel_pct ?? 0) >= 80, unattended, renter_present: unattended ? false : r.renter_present } });
        if (!x.ok) { setMsg(x.message); return; }
        setDone(later ? 'Check-in details saved. The task is closed.' : 'Checked in. The rental has started; the renter gets the photo report by email.');
      } else {
        const choice = late ? choicePayload(lateChoice, late) : null;
        const x = await fieldAct<{ booking_status: string; minutes_late?: number; late?: { status?: string; problem?: string } | null }>('complete_return', { job: jobId, report: { ...strip(r), ...(choice ? { late_choice: choice } : {}) } });
        if (!x.ok) { setMsg(x.message); return; }
        setDone(later ? 'Check-out details saved. The kilometre and fuel charges follow the readings; Fleet reviews the photos.'
          : `Checked out. The kilometre and fuel charges are on the return statement; Fleet reviews the photos.${afterReturnText(x.data.late)} The deposit is not given back today: Finance settles it once tolls and tickets have had time to come in (about 7 days), and any damage you marked keeps it held.`);
      }
      try { localStorage.removeItem(key); } catch { /* ignore */ }
    } catch { setMsg(OFFLINE); }
  });

  const parts: Array<Part & { body: React.ReactNode; skip?: boolean; fold?: string }> = [
    { id: 'ready', title: 'Ready check', ok: readyOk, need: 'Ready check', skip: !pickup || later, body: (
      <div className="stack">
      <ReadySum items={ready ? [ready.signed !== false, ready.identity, ready.coverage, ready.drivers_accepted, ready.calendar, depositOk] : []} />
      {/* ready: one green line; the six lines open only when something is to fix */}
      <details className="fd-more" open={!readyOk || undefined}><summary data-testid="ready-open">The six checks</summary>
      <ul className="fd-checks" data-testid="ready-check">
        {/* 0151: what is not ready is fixed here, under its line; Stop stays for what cannot be */}
        <Row ok={ready ? ready.signed !== false : false} text={ready?.signed === false ? 'Awaiting signature: the renter has not signed the rental agreement' : 'Rental agreement signed'}>
          {ready?.signed === false && res && <ResolveSignature j={j} signNow={at.signNow} />}</Row>
        <Row ok={ready?.identity} text="Identity verified for every driver">
          {ready && !ready.identity && res && <ResolveIdentity j={j} r={res} />}</Row>
        <Row ok={ready?.coverage} text="Coverage confirmed">
          {ready && !ready.coverage && <p className="fd-office small">Coverage is confirmed by the office. Call CarmaCars; it shows here as soon as it is done.</p>}</Row>
        <Row ok={ready?.drivers_accepted} text="Additional drivers accepted">
          {ready && !ready.drivers_accepted && <Link prefetch={false} className="btn btn--ghost fd-wide" href={at.signNow} data-testid="fix-driver-sign">Sign now on this device (additional driver)</Link>}</Row>
        <Row ok={ready?.calendar} text="The booking holds the calendar">
          {ready && !ready.calendar && <p className="fd-office small">The office turns the calendar on for this booking. Call CarmaCars.</p>}</Row>
        <Row ok={depositOk} text={`Deposit: ${ready?.deposit === 'taken' ? 'taken' : ready?.deposit === 'waived' ? 'waived by an Admin' : ready?.deposit === 'declined' ? 'declined' : ready?.deposit === 'none' ? 'none on this booking' : 'not taken yet'}`}>
          {ready && !depositOk && <strong className="small" data-testid="ready-deposit-missing">{' '}No deposit yet: take it now.</strong>}
          {ready && ready.deposit_auto && depositAutoText(ready.deposit_auto, linkWhen, (c) => money(c)) && <span className="small muted" data-testid="ready-deposit-auto">{' '}{depositAutoText(ready.deposit_auto, linkWhen, (c) => money(c))}</span>}
          {ready && !depositOk && ready.deposit_link && <span className="small muted" data-testid="ready-deposit-link">{' '}{ready.deposit_link.texted_at
            ? `The deposit link was texted ${linkWhen(ready.deposit_link.texted_at)}${ready.deposit_link.opened_at ? ` and opened ${linkWhen(ready.deposit_link.opened_at)}` : ', not opened yet'}.`
            : ready.deposit_link.error ? `The deposit link was not sent: ${ready.deposit_link.error}.` : ''}</span>}
          {ready && !depositOk && res && j.job.status === 'in_progress' && <ResolveDeposit j={j} r={res} back={at.self} />}</Row>
        <li><button className="btn btn--ghost fd-wide" type="button" onClick={() => router.refresh()} data-testid="ready-refresh"><FdIcon name="retry" />Check again</button></li>
        {ready && !readyOk &&
          <li><button className="btn btn--primary fd-stop" type="button" onClick={() => block('The ready check failed')}>Stop: do not release the car</button></li>}
      </ul></details></div>) },
    { id: 'person', title: 'Renter, licence and card', ok: atCarOk, need: 'Renter, licence and card', skip: !pickup || unattended, body: (
      <div className="stack">
        <p className="fd-who">{j.booking?.renter?.name}</p>
        <Tick label="This is the renter named on the booking" on={r.renter_present === true} set={(v) => set({ renter_present: v })} testId="tick-renter" />
        <Tick label="I checked the original licence: the name and photo match, and it is not expired" on={r.licence_seen === true} set={(v) => set({ licence_seen: v })} testId="tick-licence" />
        {(j.booking?.drivers ?? []).map((d) => <p key={d.name} className="small"><b>{d.name}</b> · licence {d.licence_number ?? ''} · class {d.licence_class ?? ''} · expires {d.licence_expiry ?? ''}</p>)}
        {j.booking?.booking_type !== 'owner' && <Tick label={`I have seen the physical card ending in ${j.booking?.card?.last4 ?? '----'} in the renter's name`} on={r.card_seen === true} set={(v) => set({ card_seen: v })} testId="tick-card" />}
        <details className="fd-more"><summary data-testid="person-wrong">Something is wrong</summary><div className="stack">
          <p className="small">Each of these stops the handover and tells the office at once.</p>
          <button className="btn btn--ghost fd-wide" type="button" onClick={() => block('The person is not the renter on the booking')}>This is not the renter</button>
          <button className="btn btn--ghost fd-wide" type="button" onClick={() => block('The licence does not match or has expired')}>The licence does not match or has expired</button>
          {j.booking?.booking_type !== 'owner' && <button className="btn btn--ghost fd-wide" type="button" onClick={() => block('The Card on File was not shown')}>The card was not shown</button>}
          <button className="btn btn--ghost fd-wide" type="button" onClick={() => block('The renter seems unfit to drive')}>The renter seems unfit to drive</button>
        </div></details>
      </div>) },
    { id: 'readings', title: pickup ? 'Odometer, fuel and keys' : 'Odometer, fuel, keys and cleanliness', ok: readingsOk,
      need: !odoOk ? 'Odometer' : r.fuel_pct === undefined ? 'Fuel or charge' : (r.keys_count ?? 0) < 1 ? 'Keys' : 'Cleanliness', body: (
      <div className="stack">
        <Odo value={r.odometer_km} set={(v) => set({ odometer_km: v })}
          hint={sourceHint('odometer', j.defaults, r.odometer_km) ?? (pickup ? (j.vehicle.odometer_km ? `Last reading: ${j.vehicle.odometer_km.toLocaleString('en-CA')} km` : null) : (j.pickup?.odometer_km ? `At pickup: ${j.pickup.odometer_km.toLocaleString('en-CA')} km` : null))} />
        {odoLow ? <label className="check"><input type="checkbox" checked={Boolean(r.odometer_confirmed)} onChange={(e) => set({ odometer_confirmed: e.target.checked })} /> <span>Lower than the last reading ({j.vehicle.odometer_km} km). I checked it.</span></label> : null}
        {!pickup && j.pickup?.odometer_km && r.odometer_km ? <p className="fd-delta">Driven: {r.odometer_km - j.pickup.odometer_km} km{j.booking?.km_allowance_total ? ` of ${j.booking.km_allowance_total} km included` : ''}</p> : null}
        <Fuel value={r.fuel_pct} set={(v) => set({ fuel_pct: v })} />
        {sourceHint('fuel', j.defaults, r.fuel_pct) && <p className="small muted" data-testid="fuel-hint">{sourceHint('fuel', j.defaults, r.fuel_pct)}</p>}
        {!pickup && j.pickup?.fuel_pct !== undefined && j.pickup?.fuel_pct !== null && r.fuel_pct !== undefined ? <p className="fd-delta">At pickup: {j.pickup.fuel_pct}%. Difference: {r.fuel_pct - (j.pickup.fuel_pct ?? 0)}%.</p> : null}
        <Stepper label={pickup ? 'Keys and fobs handed over' : `Keys returned${j.pickup?.keys_count ? ` (${j.pickup.keys_count} handed over)` : ''}`} value={r.keys_count ?? 0} set={(v) => set({ keys_count: v })} />
        {sourceHint('keys', j.defaults, r.keys_count) && <p className="small muted">{sourceHint('keys', j.defaults, r.keys_count)}</p>}
        {!pickup && <fieldset className="fd-choices"><legend className="label">How is the car?</legend>
          {CLEAN.map(([v, l]) => <label key={v} className="fd-choice"><input type="radio" name="clean" value={v} checked={r.cleanliness === v} onChange={() => set({ cleanliness: v, odour: v === 'heavy' || v === 'smoking' })} /> <span>{l}</span></label>)}
          {r.cleanliness && r.cleanliness !== 'clean' && <p className="small">Take photos of it in the photo set before any cleaning.</p>}
        </fieldset>}
        {pickup && (j.booking?.addons?.length ? <p className="small" data-testid="checklist-addons">Add-ons to put in the car: {j.booking.addons.map((a) => `${a.quantity > 1 ? `${a.quantity} x ` : ''}${a.name}`).join(', ')}{j.booking.prepaid_fuel ? '. Prepaid fuel: no fuel charge at the return.' : ''}</p>
          : j.booking?.extras?.length ? <p className="small">Extras ordered: {j.booking.extras.join(', ')}</p> : null)}
      </div>) },
    { id: 'photos', title: 'Photos', ok: shotsDone === required.length, need: `Photos (${required.length - shotsDone} left)`, body: <Shots j={j} has={has} q={q} photo={photo} /> },
    { id: 'damage', title: pickup ? 'Damage' : 'Damage, compared with pickup', ok: closeupsMissing.length === 0, need: 'Damage close-up', body: (
      <details className="fd-more" open={newDamage || (!pickup && (j.pickup?.damages ?? []).length > 0) || undefined}>
        <summary data-testid="damage-open">{newDamage ? `New damage: ${damages.filter((d) => d.is_new).length}` : 'No new damage. Found some? Add it here'}</summary>
        <div className="stack">
          {!pickup && (j.pickup?.damages ?? []).map((d) => (
            <fieldset key={d.label} className="fd-choices"><legend className="label">{d.label}: {d.location}, {d.description}</legend>
              {['unchanged', 'worse'].map((v) => <label key={v} className="fd-choice"><input type="radio" name={`cmp-${d.label}`} checked={((r.car_diagram?.[d.label] as string | undefined) ?? 'unchanged') === v} onChange={() => set({ car_diagram: { ...(r.car_diagram ?? {}), [d.label]: v } })} /> <span>{v === 'worse' ? 'Worse: add it as new damage below' : 'Unchanged'}</span></label>)}
            </fieldset>))}
          <Damages j={j} marks={marks} damages={damages} setDamages={setDamages} save={save} has={has} photo={photo} oldLabel={pickup ? 'Recorded before' : 'At pickup'} />
        </div>
      </details>) },
    { id: 'tracker', title: 'Tracker', ok: trackerOk, need: 'Tracker', skip: !pickup || later, body: (
      <div className="stack" data-testid="tracker">
        <ul className="fd-checks"><Line ok={j.tracker.reporting}>{j.tracker.reporting ? 'Tracker in place and reporting' : j.tracker.installed ? 'Tracker not reporting' : 'No tracker installed'}</Line></ul>
        {!j.tracker.reporting && <>
          <p className="small">Last reading: {j.tracker.reported_at ? new Date(j.tracker.reported_at).toLocaleTimeString('en-CA') : 'none'}</p>
          <button className="btn btn--ghost fd-wide" type="button" onClick={() => router.refresh()}><FdIcon name="retry" />Check again</button>
          {res && <TrackerOverride j={j} r={res} />}
          {!j.tracker.override && <button className="btn btn--primary fd-stop" type="button" onClick={() => block('The Tracker is not reporting')}>Stop: do not release the car</button>}
        </>}
      </div>) },
    { id: 'late', title: `Late return: late by ${late?.late_text ?? ''}`, ok: !lateProblem, need: 'Late return choice', skip: !late, body: late ? (
      late.decision && late.decision.status !== 'pending' ? <p className="small">{decisionText(late.decision)}</p>
        : late.may.decide ? <><p className="small">The car is back after the return time. A late return is not charged by itself: choose now, or leave it to the office. The amounts are as of now; the charge follows the time you complete the return.</p>
            <LateReturnChoice late={late} value={lateChoice} onChange={setLateChoice} later /></>
        : <p className="small">The office chooses the late return charge on the booking.</p>) : null },
    { id: 'notes', title: 'Notes and belongings', ok: true, optional: true, body: (
      <details className="fd-more" open={Boolean(r.notes || r.belongings_found) || undefined}><summary data-testid="notes-open">{pickup ? 'Add a note for Fleet (optional)' : 'Belongings left in the car, or a note (optional)'}</summary><div className="stack">
        {!pickup && <label className="field"><span className="label">Anything left in the car (bag and label it with {j.booking?.booking_number})</span><textarea className="input" value={r.belongings_found ?? ''} onChange={(e) => set({ belongings_found: e.target.value })} /></label>}
        <label className="field"><span className="label">{pickup ? 'Note for Fleet (anything missing or not clean)' : 'The renter\'s note, if they dispute a finding'}</span><textarea className="input" value={r.notes ?? ''} onChange={(e) => set({ notes: e.target.value })} /></label>
      </div></details>) },
    { id: 'sign', title: 'Review and sign', ok: signOk, need: renterToSign ? 'The renter\'s signature' : 'Your signature', body: (
      <div className="stack">
        <Summary r={r} damages={damages} old={oldMarks.length} shots={shotsDone} />
        {pickup ? (!unattended ? <Sign who="renter" label={`${j.booking?.renter?.name ?? 'Renter'} signs`} done={Boolean(r.renter_signature_ref)} sign={sign} />
            : <p className="pt-note small">{later ? 'Recorded with the details later: the renter does not sign here.' : 'Unattended handover: the renter\'s own photo set stands in for their signature.'}</p>)
          : later ? <p className="pt-note small">Recorded with the details later: the renter does not sign here.</p> : <>
            {r.renter_present !== false && !r.renter_declined_to_sign && <Sign who="renter" label={`${j.booking?.renter?.name ?? 'Renter'} signs`} done={Boolean(r.renter_signature_ref)} sign={sign} />}
            <details className="fd-more" open={r.renter_present === false || r.renter_declined_to_sign || undefined}><summary data-testid="sign-other">The renter is not here, or will not sign</summary><div className="stack">
              <label className="check"><input type="checkbox" checked={r.renter_present === false} onChange={(e) => set({ renter_present: !e.target.checked })} data-testid="renter-absent" /> <span>The renter is not here: I have the car and the keys</span></label>
              <label className="check"><input type="checkbox" checked={Boolean(r.renter_declined_to_sign)} onChange={(e) => set({ renter_declined_to_sign: e.target.checked })} /> <span>The renter declined to sign</span></label>
              {r.renter_declined_to_sign && <label className="field"><span className="label">Their reason</span><input className="input" value={r.renter_decline_reason ?? ''} onChange={(e) => set({ renter_decline_reason: e.target.value })} /></label>}
            </div></details></>}
        <Sign who="staff" label="You sign" done={Boolean(r.staff_signature_ref)} sign={sign} />
        {!pickup && <p className="small muted">Check-out is the moment you complete this return; the server stamps the time.</p>}
      </div>) }
  ];

  const shown = parts.filter((x) => !x.skip);
  const needed = stillNeeded(shown);
  const uploadsLeft = !queueEmpty;
  const can = needed.length === 0 && !uploadsLeft;
  const primary = pickup ? (later ? 'Save the details' : 'Hand over the keys') : later ? 'Save the details' : 'Complete the return';
  if (done) return <div className="fd-screen fd-finish" role="status" data-testid="field-done"><span className="fd-finish__mark" aria-hidden="true"><FdIcon name="check" /></span><h2 className="d3">{done}</h2><Link className="btn btn--primary fd-wide" href={back} data-testid="checklist-back">{backLabel}</Link></div>;
  if (stop) return <div className="fd-screen fd-stopped" role="alert" data-testid="field-stop"><span className="fd-finish__mark" aria-hidden="true"><FdIcon name="cross" /></span><h2 className="d3">Do not release the car. Call CarmaCars.</h2><p>{stop}</p><Link className="btn btn--ghost fd-wide" href={back}>{backLabel}</Link></div>;
  const doneCount = shown.filter((x) => x.ok && !x.optional).length;
  const mustCount = shown.filter((x) => !x.optional).length;
  return (
    <div className="fd-screen fd-flow fd-one" data-testid="checklist">
      <div className="fd-flow__head">
        <p className="fd-stepcount" data-testid="step-count">{doneCount} of {mustCount} done<span className="fd-stepcount__job">{pickup ? 'Check in' : 'Check out'}{j.vehicle.plate ? <>, <Plate plate={j.vehicle.plate} small /></> : null}</span></p>
        <div className="fd-progress" role="progressbar" aria-label="Checklist progress" aria-valuemin={0} aria-valuemax={mustCount} aria-valuenow={doneCount} aria-valuetext={`${doneCount} of ${mustCount} done`}>
          {shown.filter((x) => !x.optional).map((x) => <span key={x.id} className={x.ok ? 'is-done' : needed[0]?.id === x.id ? 'is-now' : undefined} />)}
        </div>
        <SaveState state={saved} pending={q.pending.length} resend={resend} />
      </div>
      {shown.map((x) => (
        <section key={x.id} id={`hs-${x.id}`} className={`fd-sec${x.optional ? ' is-optional' : x.ok ? ' is-ok' : ' is-todo'}`} aria-labelledby={`hs-${x.id}-t`} data-testid={`part-${x.id}`} data-ok={x.ok ? 'yes' : 'no'}>
          {!x.optional && <h2 className="fd-sec__h" id={`hs-${x.id}-t`}><span className="fd-sec__mark" aria-hidden="true">{x.ok ? <FdIcon name="check" /> : null}</span><span>{x.title}</span><span className="vh">{x.ok ? ': done' : ': to do'}</span></h2>}
          {x.optional && <h2 className="vh" id={`hs-${x.id}-t`}>{x.title}</h2>}
          {x.body}
        </section>
      ))}
      {(msg ?? saveMsg) && <p className="alert alert--error" role="alert" data-testid="checklist-message"><span>{msg ?? saveMsg}</span></p>}
      <div className="fd-bar fd-bar--one">
        {!can && <button className="btn btn--ghost fd-bar__need" type="button" onClick={() => go(needed[0]?.id ?? 'photos')} data-testid="still-needed">
          {needed.length ? <>Next: {needed[0]!.label}{needed.length > 1 ? <span className="fd-bar__more"> and {needed.length - 1} more</span> : null}</> : <>Photos still uploading</>}</button>}
        <button className="btn btn--primary" type="button" disabled={pending || !can} onClick={complete} data-testid="complete">{pending ? 'Working' : primary}</button>
      </div>
    </div>
  );
}

// one tap ticks it; a second tap unticks. Big enough for a thumb.
function Tick({ label, on, set, testId }: { label: string; on: boolean; set: (v: boolean) => void; testId: string }) {
  return (
    <button type="button" className={`fd-tick${on ? ' is-on' : ''}`} aria-pressed={on} onClick={() => set(!on)} data-testid={testId}>
      <span className="fd-tick__box" aria-hidden="true">{on ? <FdIcon name="check" /> : null}</span><span>{label}</span>
    </button>
  );
}

// what the server keeps from the answers (signatures and photos travel on their own)
function strip(r: Report): Record<string, unknown> {
  const out: Record<string, unknown> = { ...r };
  for (const k of Object.keys(out)) if (out[k] === undefined || out[k] === '') delete out[k];
  return out;
}
const OFFLINE = 'Not sent: no connection, or the server did not answer. Your answers are kept on this phone: press again.';
function damageSeqs(ds: Damage[]): Array<[string, number]> { return ds.filter((d) => d.is_new).map((d, i) => [d.label, 20 + i]); }

function Line({ ok, children }: { ok: boolean | undefined; children: React.ReactNode }) {
  return <li className={`fd-line ${ok ? 'is-ok' : 'is-bad'}`}><span className="fd-line__mark" aria-hidden="true"><FdIcon name={ok ? 'check' : 'cross'} /></span><span>{children}</span><span className="vh">{ok ? 'yes' : 'no'}</span></li>;
}
// a ready check line with what fixes it under it (0151)
function Row({ ok, text, children }: { ok: boolean | undefined; text: string; children?: React.ReactNode }) {
  return (
    <li className={`fd-fixrow ${ok ? 'is-ok' : 'is-bad'}`}>
      <span className={`fd-line ${ok ? 'is-ok' : 'is-bad'}`}><span className="fd-line__mark" aria-hidden="true"><FdIcon name={ok ? 'check' : 'cross'} /></span><span>{text}</span><span className="vh">{ok ? 'yes' : 'no'}</span></span>
      {children}
    </li>
  );
}
// the ready check at a glance: green when the car may go, red with how many lines are left to fix
function ReadySum({ items }: { items: Array<boolean | undefined> }) {
  const left = items.filter((x) => !x).length;
  const ok = items.length > 0 && left === 0;
  return (
    <div className={`fd-readysum ${ok ? 'is-ok' : 'is-bad'}`}>
      <span className="fd-line__mark" aria-hidden="true"><FdIcon name={ok ? 'check' : 'cross'} /></span>
      <p><b>{ok ? 'Ready: the car may be released' : items.length ? `${left} of ${items.length} to fix before the car is released` : 'The ready check could not be read'}</b>
        {!ok && <span className="small"> Fix each red line below, then press Check again.</span>}</p>
    </div>
  );
}
// where the answers are: on the server, being sent, or kept on this phone until there is signal
function SaveState({ state, pending, resend }: { state: 'idle' | 'saving' | 'saved' | 'phone'; pending: number; resend: () => void }) {
  return (
    <div className={`fd-savestate is-${state}`} role="status" aria-live="polite" data-testid="save-state">
      {state === 'phone' ? <><FdIcon name="offline" /><span>No signal. Answers kept on this phone.</span><button type="button" className="fd-savestate__retry" onClick={resend}>Try again</button></>
        : state === 'saving' ? <><FdIcon name="cloud" /><span>Saving</span></>
        : state === 'saved' ? <><FdIcon name="check" /><span>Saved</span></>
        : <><FdIcon name="cloud" /><span>Answers save as you go</span></>}
      {pending > 0 && <span className="fd-savestate__photos">{pending} photo{pending > 1 ? 's' : ''} sending</span>}
    </div>
  );
}
function Odo({ value, set, hint }: { value: number | undefined; set: (v: number | undefined) => void; hint: string | null }) {
  return (
    <label className="field fd-odo"><span className="label">Odometer (km)</span>
      <span className="fd-odo__box"><input className="input fd-num" inputMode="numeric" pattern="[0-9]*" autoComplete="off" enterKeyHint="done" data-testid="odometer" value={value ?? ''} onChange={(e) => set(Number(e.target.value.replace(/\D/g, '')) || undefined)} /><span className="fd-odo__unit" aria-hidden="true">km</span></span>
      {hint && <span className="small muted">{hint}</span>}
    </label>
  );
}
// fuel or charge in eighths (2026-10-25): eight segments to tap, as the gauge in the car reads; the slider under them is
// the same value for the keyboard and screen readers
const FUEL_MARKS: Record<number, string> = { 0: 'E', 2: '1/4', 4: '1/2', 6: '3/4', 8: 'F' };
function Fuel({ value, set }: { value: number | undefined; set: (v: number) => void }) {
  const eighths = value === undefined ? 8 : Math.round(value / 12.5);
  const pick = (n: number) => set(Math.round(n * 12.5));
  return (
    <div className="field fd-fuel">
      <span className="label" id="fuel-l">Fuel or charge</span>
      <p className="fd-fuel__read" data-testid="fuel-value">{value === undefined ? 'Tap the level' : <>{eighths === 8 ? 'Full' : eighths === 0 ? 'Empty' : `${eighths}/8`}<span>{Math.round(eighths * 12.5)}%</span></>}</p>
      <div className={`fd-fuel__gauge${value === undefined ? ' is-unset' : ''}`} aria-hidden="true">
        <span className={`fd-fuel__e${value !== undefined && eighths === 0 ? ' is-on' : ''}`} onClick={() => pick(0)}>E</span>
        {[1, 2, 3, 4, 5, 6, 7, 8].map((n) => <span key={n} className={`fd-fuel__seg${value !== undefined && n <= eighths ? ' is-on' : ''}`} onClick={() => pick(n)} />)}
      </div>
      <div className="fd-fuel__marks" aria-hidden="true">{[0, 2, 4, 6, 8].map((n) => <span key={n}>{FUEL_MARKS[n]}</span>)}</div>
      <input type="range" min={0} max={8} step={1} value={eighths} aria-labelledby="fuel-l" aria-valuetext={value === undefined ? 'not set' : `${eighths} eighths, ${Math.round(eighths * 12.5)}%`}
        onChange={(e) => pick(Number(e.target.value))} onClick={() => pick(eighths)} data-testid="fuel" className="fd-range" />
    </div>
  );
}
function Stepper({ label, value, set }: { label: string; value: number; set: (v: number) => void }) {
  return (
    <div className="field"><span className="label" id="st-l">{label}</span>
      <div className="fd-stepper" role="group" aria-labelledby="st-l">
        <button type="button" className="btn btn--ghost" aria-label="One fewer" onClick={() => set(Math.max(0, value - 1))}>−</button>
        <output className="fd-stepper__n" data-testid="keys" aria-live="polite"><FdIcon name="key" />{value}</output>
        <button type="button" className="btn btn--ghost" aria-label="One more" onClick={() => set(Math.min(9, value + 1))} data-testid="keys-more">+</button>
      </div>
    </div>
  );
}
function Upload({ q, total, shotsDone }: { q: ReturnType<typeof useUploads>; total: number; shotsDone: number }) {
  const all = shotsDone === total && !q.pending.length;
  return (
    <div className="fd-upload" aria-live="polite">
      <div className="fd-meter" aria-hidden="true"><span style={{ width: `${total ? Math.round((shotsDone / total) * 100) : 0}%` }} /></div>
      <p className={`fd-upload__line${all ? ' is-ok' : ''}`} data-testid="upload-count">{shotsDone} of {total} photos taken · {q.pending.length ? `${q.pending.length} still uploading` : 'all uploaded'}</p>
      {q.failed.length > 0 && <div className="alert alert--error small"><span>{q.failed[0]!.error} <button type="button" className="link" onClick={() => void uploads.run()}>Send again now</button></span></div>}
    </div>
  );
}
// the photo set, camera first (2026-10-25): the next photo to take is the big button at the top, with what to frame;
// every shot of the list stays one tap away below, done ones ticked
function Shots({ j, has, q, photo }: { j: FieldJob; has: (seq: number) => boolean; q: ReturnType<typeof useUploads>; photo: (seq: number, shot: string, f: File | undefined) => Promise<void> }) {
  const todo = j.shots.find((s) => !has(s.seq));
  const done = j.shots.filter((s) => has(s.seq)).length;
  return (
    <div className="stack">
      <Upload q={q} total={j.shots.length} shotsDone={done} />
      {todo ? (
        <label className="fd-shoot">
          <span className="fd-shoot__n">Photo {done + 1} of {j.shots.length}</span>
          <span className="fd-shoot__name">{shotName(todo.shot)}</span>
          {todo.guide && <span className="fd-shoot__guide">{todo.guide}</span>}
          <span className="fd-shoot__btn"><FdIcon name="camera" />Take this photo</span>
          <input className="vh" type="file" accept="image/*" capture="environment" data-testid="next-shot" onChange={(e) => { void photo(todo.seq, todo.shot, e.target.files?.[0]); e.target.value = ''; }} />
        </label>
      ) : <p className="fd-line is-ok"><span className="fd-line__mark" aria-hidden="true"><FdIcon name="check" /></span><span>Every photo taken</span></p>}
      <p className="small">Landscape, whole car in frame. Confirm the plate is <b>{j.vehicle.plate}</b> in the first photo; a different car stops the job.</p>
      <details className="fd-more" open={!todo || undefined}><summary data-testid="shots-all">All {j.shots.length} photos: see or retake one</summary>
      <ol className="fd-shotgrid">{j.shots.map((s) => {
        const f = q.pending.find((x) => x.seq === s.seq && x.mode === 'photo');
        const ok = has(s.seq);
        return (
          <li key={s.seq} className={`${ok ? 'is-done' : ''}${f?.state === 'failed' ? ' is-failed' : ''}`}>
            <label className="fd-shot">
              <span className="fd-shot__top"><span className="fd-shot__n">{s.seq}</span>{ok && <span className="fd-shot__ok" aria-hidden="true"><FdIcon name="check" /></span>}</span>
              <span className="fd-shot__name">{shotName(s.shot)}</span>
              {s.guide ? <span className="fd-shot__guide">{s.guide}</span> : null}
              <span className="fd-shot__state">{f ? (f.state === 'failed' ? f.error : 'waiting to upload') : ok ? 'uploaded' : ''}</span>
              <span className="fd-shot__do"><FdIcon name="camera" />{ok ? 'Retake' : 'Take photo'}</span>
              <input className="vh" type="file" accept="image/*" capture="environment" data-testid={`shot-${s.seq}`} onChange={(e) => { void photo(s.seq, s.shot, e.target.files?.[0]); e.target.value = ''; }} />
            </label>
          </li>);
      })}</ol></details>
    </div>
  );
}
function Damages({ j, marks, damages, setDamages, save, has, photo, oldLabel }: { j: FieldJob; marks: Mark[]; damages: Damage[]; setDamages: (d: Damage[]) => void; save: (extra: Record<string, unknown>) => Promise<{ ok: boolean; message?: string } | { ok: true }>;
  has: (seq: number) => boolean; photo: (seq: number, shot: string, f: File | undefined, label?: string) => Promise<void>; oldLabel: string }) {
  const [pos, setPos] = useState<{ x: number; y: number } | null>(null);
  const [f, setF] = useState({ location: LOCATIONS[0]!, kind: KINDS[0]!, size: '', description: '' });
  const [err, setErr] = useState<string | null>(null);
  const old = j.report_kind === 'pickup' ? j.baseline_damages : j.pickup?.damages ?? [];
  const ref = useRef<HTMLDivElement>(null);
  const add = async () => {
    setErr(null);
    if (f.description.trim().length < 3) { setErr('Describe the damage.'); return; }
    const d: Damage = { label: `D${damages.filter((x) => x.is_new).length + 1}`, location: f.location, kind: f.kind, size_cm: f.size ? Number(f.size) : null, description: f.description.trim(), position: pos, is_new: true };
    const r = await save({ damages: [d] });
    if (!r.ok) { setErr('message' in r && r.message ? r.message : 'Not saved.'); return; }
    setDamages([...damages, d]); setPos(null); setF({ ...f, size: '', description: '' });
  };
  return (
    <div className="stack" ref={ref}>
      <CarDiagram marks={marks} picked={pos} onPick={setPos} />
      <p className="small muted">Tap the diagram where the damage is. Open circles are {oldLabel.toLowerCase()}.</p>
      {old.length > 0 && <ul className="small">{old.map((d) => <li key={d.label}>{oldLabel}: <b>{d.label}</b> {d.location}, {d.description}</li>)}</ul>}
      {damages.filter((d) => d.is_new).map((d, i) => (
        <div key={d.label} className="fd-damage" data-testid={`damage-${d.label}`}>
          <p><b>{d.label}</b> {d.location}, {d.kind}{d.size_cm ? `, ${d.size_cm} cm` : ''}: {d.description}</p>
          <label className="btn btn--ghost btn--sm fd-cam">{has(20 + i) ? 'Close-up taken: retake' : 'Take the close-up'}
            <input className="vh" type="file" accept="image/*" capture="environment" data-testid={`closeup-${d.label}`} onChange={(e) => { void photo(20 + i, 'damage_closeup', e.target.files?.[0], d.label); e.target.value = ''; }} /></label>
        </div>))}
      <fieldset className="fd-form"><legend className="label">Add new damage</legend>
        <label className="field"><span className="label">Where</span><select className="select" value={f.location} onChange={(e) => setF({ ...f, location: e.target.value })} data-testid="damage-location">{LOCATIONS.map((x) => <option key={x}>{x}</option>)}</select></label>
        <label className="field"><span className="label">Type</span><select className="select" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}>{KINDS.map((x) => <option key={x}>{x}</option>)}</select></label>
        <label className="field"><span className="label">Size (cm)</span><input className="input" inputMode="decimal" value={f.size} onChange={(e) => setF({ ...f, size: e.target.value.replace(/[^\d.]/g, '') })} /></label>
        <label className="field"><span className="label">What it is</span><input className="input" value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} data-testid="damage-description" /></label>
        <button className="btn btn--ghost" type="button" onClick={() => void add()} data-testid="damage-add">Add the damage</button>
        {err && <p className="error" role="alert">{err}</p>}
      </fieldset>
    </div>
  );
}
function Summary({ r, damages, old, shots }: { r: Report; damages: Damage[]; old: number; shots: number }) {
  return (
    <dl className="pt-dl" data-testid="summary">
      <div><dt>Odometer</dt><dd>{r.odometer_km ?? ''} km</dd></div>
      <div><dt>Fuel or charge</dt><dd>{r.fuel_pct ?? ''}%</dd></div>
      <div><dt>Keys</dt><dd>{r.keys_count ?? 0}</dd></div>
      <div><dt>Photos</dt><dd>{shots}</dd></div>
      <div><dt>Damage</dt><dd>{old} recorded before{damages.filter((d) => d.is_new).length ? `; new: ${damages.filter((d) => d.is_new).map((d) => `${d.label} ${d.location}`).join(', ')}` : '; nothing new'}</dd></div>
      {r.cleanliness && <div><dt>Cleanliness</dt><dd>{r.cleanliness.replace(/_/g, ' ')}</dd></div>}
    </dl>
  );
}
function Sign({ who, label, done, sign }: { who: 'renter' | 'staff'; label: string; done: boolean; sign: (who: 'renter' | 'staff', png: string) => Promise<void> }) {
  const [png, setPng] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (done) return <p className="fd-line is-ok" data-testid={`signed-${who}`}><span aria-hidden="true">✓</span> {label}: signed</p>;
  return (
    <div className="field" data-testid={`sign-${who}`}>
      <span className="label" id={`sg-${who}-l`}>{label}</span>
      <SignaturePad id={`sg-${who}`} onChange={setPng} describedBy={`sg-${who}-l`} />
      <button className="btn btn--ghost" type="button" disabled={!png || busy} data-testid={`use-${who}`} onClick={async () => { if (!png) return; setBusy(true); setErr(null); try { await sign(who, png); } catch (e) { setErr(e instanceof Error ? e.message : 'Not saved.'); } finally { setBusy(false); } }}>{busy ? 'Saving' : 'Use this signature'}</button>
      {err && <p className="error" role="alert">{err}</p>}
    </div>
  );
}

// 0213: when the deposit link was texted or opened, in Toronto time
function linkWhen(iso: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
}
