'use client';
import { useMemo, useRef, useState, useTransition } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { SignaturePad } from '@/features/portal/SignaturePad';
import { fieldAct } from '@/server/actions/field';
import { CarDiagram, type Mark } from './CarDiagram';
import { preparePhoto, uploads, useUploads } from './queue';
import type { FieldJob } from './types';

// The handover and return checklists (06-field.md sections 4 and 5): one decision or one photo per screen,
// the primary button at the bottom within thumb reach. Answers autosave on the phone and on the server
// (save_condition_report); photos go through the queue; the database completes the handover or the
// return in one transaction and refuses anything missing.
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

export function Checklist({ j }: { j: FieldJob }) {
  const router = useRouter();
  const pickup = j.report_kind === 'pickup';
  const jobId = j.job.id;
  const key = `cc-field-${jobId}`;
  const [r, setR] = useState<Report>(() => {
    const server: Report = j.report ? { odometer_km: j.report.odometer_km ?? undefined, fuel_pct: j.report.fuel_pct ?? undefined, keys_count: j.report.keys_count ?? undefined, cleanliness: j.report.cleanliness ?? undefined } : {};
    try { return { ...server, ...(JSON.parse(localStorage.getItem(key) ?? '{}') as Report) }; } catch { return server; }
  });
  const [damages, setDamages] = useState<Damage[]>(() => (j.report?.damages ?? []).map((d) => ({ ...d, kind: d.kind ?? 'other', size_cm: d.size_cm ?? null, position: d.position ?? null, is_new: d.is_new ?? true })));
  const [step, setStep] = useState(0);
  const [stop, setStop] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const q = useUploads(jobId);
  const onServer = useMemo(() => new Set((j.report?.photos ?? []).map((p) => p.seq)), [j.report]);
  const has = (seq: number) => onServer.has(seq) || q.arrived(seq) || q.pending.some((x) => x.seq === seq && x.mode === 'photo');
  const set = (p: Partial<Report>) => setR((s) => { const n = { ...s, ...p }; try { localStorage.setItem(key, JSON.stringify(n)); } catch { /* private mode */ } return n; });
  const unattended = Boolean(j.booking?.unattended);
  const ready = j.ready;

  const save = (extra: Record<string, unknown> = {}) => fieldAct('save_report', { job: jobId, report: { ...strip(r), ...extra } });
  const next = () => { setMsg(null); start(async () => { const s = await save(); if (!s.ok) { setMsg(s.message); return; } setStep((n) => n + 1); window.scrollTo(0, 0); }); };
  const block = (reason: string) => start(async () => {
    const x = await fieldAct('block_handover', { job: jobId, reason });
    setStop(x.ok ? `${reason}. CarmaCars has an urgent task.` : `${reason}. ${x.message}`);
  });

  const photo = async (seq: number, shot: string, file: File | undefined, damage_label?: string) => {
    if (!file) return;
    const p = await preparePhoto(file);
    if (p.flags.some((f) => ['dark', 'blurry'].includes(f))) setMsg(`That photo looks ${p.flags.filter((f) => ['dark', 'blurry'].includes(f)).join(' and ')}. Take it again if you can; it is kept otherwise.`);
    await uploads.add({ job: jobId, seq, shot, mode: 'photo', damage_label: damage_label ?? null, blob: p.blob, taken_at: new Date().toISOString(), width: p.width, height: p.height, flags: p.flags });
  };
  const sign = async (who: 'renter' | 'staff', png: string) => {
    const k = await uploads.addAndWait({ job: jobId, seq: who === 'renter' ? 900 : 901, shot: `signature_${who}`, mode: 'raw', blob: await dataUrlBlob(png), taken_at: new Date().toISOString() });
    set(who === 'renter' ? { renter_signature_ref: k } : { staff_signature_ref: k });
  };

  // ---------------------------------------------------------------- the screens
  const required = j.shots;
  const shotsDone = required.filter((s) => has(s.seq)).length;
  const closeupsMissing = damages.filter((d) => d.is_new && !damageSeqs(damages).some(([l, s]) => l === d.label && has(s)));
  const queueEmpty = q.pending.length === 0;
  const oldMarks: Mark[] = (pickup ? j.baseline_damages : j.pickup?.damages ?? []).map((d) => ({ label: d.label, position: d.position ?? null, old: true }));
  const marks: Mark[] = [...oldMarks, ...damages.map((d) => ({ label: d.label, position: d.position }))];

  // the ready check: a rental added by hand also needs the renter's signature (0051), as a booking made online already has
  const readyOk = Boolean(ready && ready.signed !== false && ready.identity && ready.coverage && ready.drivers_accepted && ready.calendar && ['taken', 'waived', 'none'].includes(ready.deposit));
  const screens: Array<{ title: string; body: React.ReactNode; can?: boolean; primary?: string; onPrimary?: () => void }> = pickup ? [
    { title: 'Ready check', can: readyOk, body: (
      <ul className="fd-checks" data-testid="ready-check">
        <Line ok={ready ? ready.signed !== false : false}>{ready?.signed === false ? 'Awaiting signature: the renter has not signed the rental agreement' : 'Rental agreement signed'}</Line>
        <Line ok={ready?.identity}>Identity verified for every driver</Line>
        <Line ok={ready?.coverage}>Coverage confirmed</Line>
        <Line ok={ready?.drivers_accepted}>Additional drivers accepted</Line>
        <Line ok={ready?.calendar}>The booking holds the calendar</Line>
        <Line ok={ready ? ['taken', 'waived', 'none'].includes(ready.deposit) : false}>Deposit: {ready?.deposit === 'taken' ? 'taken' : ready?.deposit === 'waived' ? 'waived by an Admin' : ready?.deposit === 'declined' ? 'declined' : ready?.deposit === 'none' ? 'none on this booking' : 'not taken yet'}</Line>
        {ready && !readyOk &&
          <li><button className="btn btn--primary fd-stop" type="button" onClick={() => block('The ready check failed')}>Stop: do not release the car</button></li>}
      </ul>) },
    { title: 'Car ready', body: (
      <div className="stack">
        <YesNo label="Fuel full, or charge 80% or more" value={r.fuel_or_charge_ok} set={(v) => set({ fuel_or_charge_ok: v })} />
        {j.booking?.addons?.length ? <p className="small" data-testid="checklist-addons">Add-ons to put in the car: {j.booking.addons.map((a) => `${a.quantity > 1 ? `${a.quantity} x ` : ''}${a.name}`).join(', ')}{j.booking.prepaid_fuel ? '. Prepaid fuel: no fuel charge at the return.' : ''}</p>
          : j.booking?.extras?.length ? <p className="small">Extras ordered: {j.booking.extras.join(', ')}</p> : null}
        <label className="field"><span className="label">Note for Fleet (anything missing or not clean)</span><textarea className="input" value={r.notes ?? ''} onChange={(e) => set({ notes: e.target.value })} /></label>
      </div>) },
    ...(unattended ? [] : [
      { title: 'Is this the renter?', can: r.renter_present === true, body: (
        <div className="stack"><p className="fd-big">{j.booking?.renter?.name}</p>
          <YesNo label="The person in front of me is the renter named on the booking" value={r.renter_present} set={(v) => { set({ renter_present: v }); if (!v) block('The person is not the renter on the booking'); }} /></div>) },
      { title: 'Original licence', can: r.licence_seen === true, body: (
        <div className="stack">
          <p className="small">Name matches, the photo matches the person, not expired.</p>
          {(j.booking?.drivers ?? []).map((d) => <p key={d.name} className="small"><b>{d.name}</b> · licence {d.licence_number ?? ''} · class {d.licence_class ?? ''} · expires {d.licence_expiry ?? ''}</p>)}
          <YesNo label="I checked the original licence and it matches" value={r.licence_seen} set={(v) => { set({ licence_seen: v }); if (!v) block('The licence does not match or has expired'); }} />
          <button className="btn btn--ghost" type="button" onClick={() => block('The renter seems unfit to drive')}>The renter seems unfit to drive</button>
        </div>) },
      { title: 'Card on File', can: r.card_seen === true || j.booking?.booking_type === 'owner', body: (
        <YesNo label={`I have seen the physical card ending in ${j.booking?.card?.last4 ?? '----'} in the renter's name`} value={r.card_seen} set={(v) => { set({ card_seen: v }); if (!v) block('The Card on File was not shown'); }} />) }
    ]),
    { title: 'Odometer', can: (r.odometer_km ?? 0) > 0 && !((j.vehicle.odometer_km ?? 0) > (r.odometer_km ?? 0) && !r.odometer_confirmed), body: (
      <div className="stack">
        <label className="field"><span className="label">Odometer (km)</span><input className="input fd-num" inputMode="numeric" pattern="[0-9]*" data-testid="odometer" value={r.odometer_km ?? ''} onChange={(e) => set({ odometer_km: Number(e.target.value.replace(/\D/g, '')) || undefined })} /></label>
        {j.vehicle.odometer_km && (r.odometer_km ?? 0) > 0 && (r.odometer_km ?? 0) < j.vehicle.odometer_km ? <label className="check"><input type="checkbox" checked={Boolean(r.odometer_confirmed)} onChange={(e) => set({ odometer_confirmed: e.target.checked })} /> <span>Lower than the last reading ({j.vehicle.odometer_km} km). I checked it.</span></label> : null}
      </div>) },
    { title: 'Fuel or charge', can: r.fuel_pct !== undefined, body: <Fuel value={r.fuel_pct} set={(v) => set({ fuel_pct: v })} /> },
    { title: 'Keys', can: (r.keys_count ?? 0) >= 1, body: <Stepper label="Keys and fobs handed over" value={r.keys_count ?? 0} set={(v) => set({ keys_count: v })} /> },
    { title: 'Photo set', can: shotsDone === required.length, body: <Shots j={j} has={has} q={q} photo={photo} /> },
    { title: 'Damage', can: closeupsMissing.length === 0, body: <Damages j={j} marks={marks} damages={damages} setDamages={setDamages} save={save} has={has} photo={photo} oldLabel="Recorded before" /> },
    { title: 'Tracker', can: Boolean(j.tracker.reporting), body: (
      <div className="stack" data-testid="tracker">
        <Line ok={j.tracker.reporting}>{j.tracker.reporting ? 'Tracker in place and reporting' : j.tracker.installed ? 'Tracker not reporting' : 'No tracker installed'}</Line>
        <p className="small">Last reading: {j.tracker.reported_at ? new Date(j.tracker.reported_at).toLocaleTimeString('en-CA') : 'none'}</p>
        <button className="btn btn--ghost" type="button" onClick={() => router.refresh()}>Check again</button>
        {!j.tracker.reporting && <button className="btn btn--primary fd-stop" type="button" onClick={() => block('The Tracker is not reporting')}>Stop: do not release the car</button>}
      </div>) },
    { title: 'Renter reviews', body: <Summary r={r} damages={damages} old={oldMarks.length} shots={shotsDone} /> },
    { title: 'Signatures', can: Boolean((unattended || r.renter_signature_ref) && r.staff_signature_ref), body: (
      <div className="stack">
        {!unattended ? <Sign who="renter" label={`${j.booking?.renter?.name ?? 'Renter'} signs`} done={Boolean(r.renter_signature_ref)} sign={sign} /> : <p className="pt-note small">Unattended handover: the renter&apos;s own photo set stands in for their signature.</p>}
        <Sign who="staff" label="You sign" done={Boolean(r.staff_signature_ref)} sign={sign} />
      </div>) },
    { title: 'Hand over the keys', can: queueEmpty && shotsDone === required.length, primary: 'Hand over the keys', onPrimary: () => start(async () => {
      setMsg(null);
      const x = await fieldAct<{ booking_status: string }>('complete_handover', { job: jobId, report: { ...strip(r), unattended, renter_present: unattended ? false : r.renter_present } });
      if (!x.ok) { setMsg(x.message); return; }
      try { localStorage.removeItem(key); } catch { /* ignore */ }
      setDone('Handed over. The rental has started.');
    }), body: <Upload q={q} total={required.length} shotsDone={shotsDone} /> }
  ] : [
    { title: 'Car and keys received', can: r.renter_present !== undefined, body: (
      <div className="stack"><YesNo label="I have the car and all keys. The renter is here." value={r.renter_present} set={(v) => set({ renter_present: v })} />
        <p className="small muted">Check-in is the moment you complete this return; the server stamps the time.</p></div>) },
    { title: 'Odometer', can: (r.odometer_km ?? 0) > 0, body: (
      <div className="stack">
        <label className="field"><span className="label">Odometer (km)</span><input className="input fd-num" inputMode="numeric" pattern="[0-9]*" data-testid="odometer" value={r.odometer_km ?? ''} onChange={(e) => set({ odometer_km: Number(e.target.value.replace(/\D/g, '')) || undefined })} /></label>
        {j.pickup?.odometer_km && r.odometer_km ? <p className="small">Driven: {r.odometer_km - j.pickup.odometer_km} km{j.booking?.km_allowance_total ? ` of ${j.booking.km_allowance_total} km included` : ''}</p> : null}
      </div>) },
    { title: 'Fuel or charge', can: r.fuel_pct !== undefined, body: <><Fuel value={r.fuel_pct} set={(v) => set({ fuel_pct: v })} />{j.pickup?.fuel_pct !== undefined && r.fuel_pct !== undefined ? <p className="small">At pickup: {j.pickup.fuel_pct}%. Difference: {r.fuel_pct - (j.pickup.fuel_pct ?? 0)}%.</p> : null}</> },
    { title: 'Keys and extras', can: (r.keys_count ?? 0) >= 1, body: <Stepper label={`Keys returned${j.pickup?.keys_count ? ` (${j.pickup.keys_count} handed over)` : ''}`} value={r.keys_count ?? 0} set={(v) => set({ keys_count: v })} /> },
    { title: 'Cleanliness', can: Boolean(r.cleanliness), body: (
      <fieldset className="fd-choices"><legend className="label">How is the car?</legend>
        {CLEAN.map(([v, l]) => <label key={v} className="fd-choice"><input type="radio" name="clean" value={v} checked={r.cleanliness === v} onChange={() => set({ cleanliness: v, odour: v === 'heavy' || v === 'smoking' })} /> <span>{l}</span></label>)}
        {r.cleanliness && r.cleanliness !== 'clean' && <p className="small">Take photos of it in the photo set before any cleaning.</p>}
      </fieldset>) },
    { title: 'Photo set', can: shotsDone === required.length, body: <Shots j={j} has={has} q={q} photo={photo} /> },
    { title: 'Compare with pickup', can: closeupsMissing.length === 0, body: (
      <div className="stack">
        {(j.pickup?.damages ?? []).map((d) => (
          <fieldset key={d.label} className="fd-choices"><legend className="label">{d.label}: {d.location}, {d.description}</legend>
            {['unchanged', 'worse'].map((v) => <label key={v} className="fd-choice"><input type="radio" name={`cmp-${d.label}`} checked={(r.car_diagram?.[d.label] as string | undefined) === v} onChange={() => set({ car_diagram: { ...(r.car_diagram ?? {}), [d.label]: v } })} /> <span>{v === 'worse' ? 'Worse: add it as new damage below' : 'Unchanged'}</span></label>)}
          </fieldset>))}
        <Damages j={j} marks={marks} damages={damages} setDamages={setDamages} save={save} has={has} photo={photo} oldLabel="At pickup" />
      </div>) },
    { title: 'Belongings', body: <label className="field"><span className="label">Anything left in the car (bag and label it with {j.booking?.booking_number})</span><textarea className="input" value={r.belongings_found ?? ''} onChange={(e) => set({ belongings_found: e.target.value })} /></label> },
    { title: 'Renter reviews and signs', can: Boolean(r.renter_signature_ref || r.renter_declined_to_sign || r.renter_present === false), body: (
      <div className="stack">
        <Summary r={r} damages={damages} old={oldMarks.length} shots={shotsDone} />
        <label className="field"><span className="label">The renter&apos;s note, if they dispute a finding</span><textarea className="input" value={r.notes ?? ''} onChange={(e) => set({ notes: e.target.value })} /></label>
        {r.renter_present !== false && !r.renter_declined_to_sign && <Sign who="renter" label={`${j.booking?.renter?.name ?? 'Renter'} signs`} done={Boolean(r.renter_signature_ref)} sign={sign} />}
        <label className="check"><input type="checkbox" checked={Boolean(r.renter_declined_to_sign)} onChange={(e) => set({ renter_declined_to_sign: e.target.checked })} /> <span>The renter declined to sign</span></label>
        {r.renter_declined_to_sign && <label className="field"><span className="label">Their reason</span><input className="input" value={r.renter_decline_reason ?? ''} onChange={(e) => set({ renter_decline_reason: e.target.value })} /></label>}
      </div>) },
    { title: 'You sign and complete', can: Boolean(r.staff_signature_ref) && queueEmpty && shotsDone === required.length, primary: 'Complete the return', onPrimary: () => start(async () => {
      setMsg(null);
      const x = await fieldAct<{ booking_status: string; minutes_late?: number }>('complete_return', { job: jobId, report: strip(r) });
      if (!x.ok) { setMsg(x.message); return; }
      try { localStorage.removeItem(key); } catch { /* ignore */ }
      setDone('Return complete. Fleet reviews the photos and Finance the findings.');
    }), body: <><Sign who="staff" label="You sign" done={Boolean(r.staff_signature_ref)} sign={sign} /><Upload q={q} total={required.length} shotsDone={shotsDone} /></> }
  ];

  if (done) return <div className="fd-screen" role="status" data-testid="field-done"><h2 className="d3">{done}</h2><Link className="btn btn--primary fd-wide" href="/field">Back to my jobs</Link></div>;
  if (stop) return <div className="fd-screen fd-stopped" role="alert" data-testid="field-stop"><h2 className="d3">Do not release the car. Call CarmaCars.</h2><p>{stop}</p><Link className="btn btn--ghost fd-wide" href="/field">Back to my jobs</Link></div>;
  const s = screens[Math.min(step, screens.length - 1)]!;
  const last = step >= screens.length - 1;
  return (
    <div className="fd-screen" data-testid="checklist">
      <p className="pt-kicker">Step {step + 1} of {screens.length}</p>
      <h2 className="d3" data-testid="step-title">{s.title}</h2>
      {s.body}
      {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
      <div className="fd-bar">
        {step > 0 && <button className="btn btn--ghost" type="button" onClick={() => { setMsg(null); setStep((n) => n - 1); }}>Back</button>}
        {last
          ? <button className="btn btn--primary" type="button" disabled={pending || s.can === false} onClick={s.onPrimary} data-testid="complete">{pending ? 'Working' : s.primary}</button>
          : <button className="btn btn--primary" type="button" disabled={pending || s.can === false} onClick={next} data-testid="next">{pending ? 'Saving' : 'Next'}</button>}
      </div>
    </div>
  );
}

// what the server keeps from the answers (signatures and photos travel on their own)
function strip(r: Report): Record<string, unknown> {
  const out: Record<string, unknown> = { ...r };
  for (const k of Object.keys(out)) if (out[k] === undefined || out[k] === '') delete out[k];
  return out;
}
function damageSeqs(ds: Damage[]): Array<[string, number]> { return ds.filter((d) => d.is_new).map((d, i) => [d.label, 20 + i]); }

function Line({ ok, children }: { ok: boolean | undefined; children: React.ReactNode }) {
  return <li className={`fd-line ${ok ? 'is-ok' : 'is-bad'}`}><span aria-hidden="true">{ok ? '✓' : '✕'}</span><span>{children}</span><span className="vh">{ok ? 'yes' : 'no'}</span></li>;
}
function YesNo({ label, value, set }: { label: string; value: boolean | undefined; set: (v: boolean) => void }) {
  return (
    <fieldset className="fd-yesno"><legend className="label">{label}</legend>
      <div className="row"><button type="button" className={`btn ${value === true ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={value === true} onClick={() => set(true)}>Yes</button>
        <button type="button" className={`btn ${value === false ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={value === false} onClick={() => set(false)}>No</button></div>
    </fieldset>
  );
}
function Fuel({ value, set }: { value: number | undefined; set: (v: number) => void }) {
  const eighths = value === undefined ? 8 : Math.round(value / 12.5);
  return (
    <label className="field"><span className="label">Fuel or charge: <b className="fd-big" data-testid="fuel-value">{value === undefined ? 'not set' : `${eighths}/8 (${Math.round(eighths * 12.5)}%)`}</b></span>
      <input type="range" min={0} max={8} step={1} value={eighths} onChange={(e) => set(Math.round(Number(e.target.value) * 12.5))} onClick={() => set(Math.round(eighths * 12.5))} data-testid="fuel" className="fd-range" />
    </label>
  );
}
function Stepper({ label, value, set }: { label: string; value: number; set: (v: number) => void }) {
  return (
    <div className="field"><span className="label" id="st-l">{label}</span>
      <div className="row fd-stepper" role="group" aria-labelledby="st-l">
        <button type="button" className="btn btn--ghost" aria-label="One fewer" onClick={() => set(Math.max(0, value - 1))}>−</button>
        <output className="fd-big" data-testid="keys" aria-live="polite">{value}</output>
        <button type="button" className="btn btn--ghost" aria-label="One more" onClick={() => set(Math.min(9, value + 1))} data-testid="keys-more">+</button>
      </div>
    </div>
  );
}
function Upload({ q, total, shotsDone }: { q: ReturnType<typeof useUploads>; total: number; shotsDone: number }) {
  return (
    <div className="stack" aria-live="polite">
      <p className="small" data-testid="upload-count">{shotsDone} of {total} photos taken · {q.pending.length ? `${q.pending.length} still uploading` : 'all uploaded'}</p>
      {q.failed.length > 0 && <p className="alert alert--error small"><span>{q.failed[0]!.error}</span></p>}
    </div>
  );
}
function Shots({ j, has, q, photo }: { j: FieldJob; has: (seq: number) => boolean; q: ReturnType<typeof useUploads>; photo: (seq: number, shot: string, f: File | undefined) => Promise<void> }) {
  return (
    <div className="stack">
      <Upload q={q} total={j.shots.length} shotsDone={j.shots.filter((s) => has(s.seq)).length} />
      <p className="small">Landscape, whole car in frame. Confirm the plate is <b>{j.vehicle.plate}</b> in the first photo; a different car stops the job.</p>
      <ol className="fd-shots">{j.shots.map((s) => {
        const f = q.pending.find((x) => x.seq === s.seq && x.mode === 'photo');
        return (
          <li key={s.seq} className={has(s.seq) ? 'is-done' : undefined}>
            <span><b>{s.seq}. {shotName(s.shot)}</b>{s.guide ? <span className="small muted"> {s.guide}</span> : null}
              <span className="small">{f ? (f.state === 'failed' ? ` ${f.error}` : ' waiting to upload') : has(s.seq) ? ' uploaded' : ''}</span></span>
            <label className="btn btn--ghost btn--sm fd-cam">{has(s.seq) ? 'Retake' : 'Take photo'}
              <input className="vh" type="file" accept="image/*" capture="environment" data-testid={`shot-${s.seq}`} onChange={(e) => { void photo(s.seq, s.shot, e.target.files?.[0]); e.target.value = ''; }} /></label>
          </li>);
      })}</ol>
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
