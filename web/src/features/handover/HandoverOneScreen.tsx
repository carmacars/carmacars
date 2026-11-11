'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { DateInput } from '@/components/DateInput';
import { PhotoPicker } from './PhotoPicker';
import { DashReading } from './DashReading';
import { emptyReading, readingPayload, readingPhotos, readingProblem, readingValues } from './reading';
import type { PickedPhoto } from './angles';
import { oneScreenHandover, selfPickup } from '@/server/actions/self-handover';

// One screen for a check-in or a check-out (migration 0545): the time (now unless changed), many photos at once with the
// suggested angles, a note; 0910: the odometer and fuel from a required dashboard photo (read, then confirmed or typed) and
// a selfie in front of the car taken live. Staff (Admin, Fleet, Sales, Customer service, field) on the
// booking page; the renter's own check-in at pickup with the same screen. The renter's photos join the same report.
function localNow(): string {
  const d = new Date(Date.now() - new Date().getTimezoneOffset() * 60_000);
  return d.toISOString().slice(0, 16);
}

export function HandoverOneScreen({ booking, number, kind, who, refresh = [], isAdmin = false }: {
  booking: string; number: string; kind: 'pickup' | 'return'; who: 'staff' | 'renter'; refresh?: string[]; isAdmin?: boolean;
}) {
  const router = useRouter();
  const [at, setAt] = useState(localNow());
  const [reading, setReading] = useState(emptyReading());
  const [readingBusy, setReadingBusy] = useState(false);
  const [note, setNote] = useState('');
  const [photos, setPhotos] = useState<PickedPhoto[]>([]);
  const [busy, setBusy] = useState(0);
  const [dep, setDep] = useState('');
  const [sig, setSig] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const pickup = kind === 'pickup';
  const go = () => start(async () => {
    setMsg(null);
    const problem = readingProblem(reading);
    if (problem) { setMsg({ ok: false, text: problem }); return; }
    const ph = [...photos.map(({ bucket, path, angle }) => ({ bucket, path, angle })), ...readingPhotos(reading)];
    const { odometer_km: km, fuel_pct: fuel } = readingValues(reading);
    const rd = readingPayload(reading);
    if (who === 'renter') {
      const r = await selfPickup({ number, at: at ? new Date(at).toISOString() : undefined, odometer_km: km, fuel_pct: fuel, note, photos: ph, reading: rd });
      setMsg(r.ok ? { ok: true, text: r.data.status === 'applied' ? 'You are checked in. Drive safely: your photos and readings are on the check-in report.' : `Thank you, we have your photos and readings. Not finished by itself yet${r.data.reason ? `: ${r.data.reason}` : ''}. A team member confirms the pickup with you shortly.` } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
      return;
    }
    const r = await oneScreenHandover({ booking, kind, at, odometer_km: km, fuel_pct: fuel, note, photos: ph, reading: rd, deposit_waiver_reason: dep, signature_override_reason: sig, refresh });
    setMsg(r.ok ? { ok: true, text: pickup ? 'Checked in: the rental has started.' : 'Checked out: the trip is completed; any extra km and fuel are charged from the rate sheet and shown on the return receipt.' } : { ok: false, text: r.message });
    if (r.ok) { setPhotos([]); setReading(emptyReading()); router.refresh(); }
  });
  return (
    <form className="stack" data-testid={`one-screen-${kind}`} onSubmit={(e) => { e.preventDefault(); go(); }}>
      <PhotoPicker scope={who === 'renter' ? 'self-pickup' : 'one-screen'} id={booking} photos={photos} onChange={setPhotos} onBusy={setBusy}
        label={who === 'renter' ? 'Photos of the car as you get it (all sides, inside, any damage)' : 'Photos (add to the renter\'s, if they took some)'} testId={`os-${kind}-photos`} />
      <div className="field-row">
        <div className="field"><label className="label" htmlFor={`os-${kind}-at`}>{pickup ? 'Picked up at' : 'Returned at'}</label>
          <DateInput className="input" id={`os-${kind}-at`} type="datetime-local" value={at} max={localNow()} onChange={(e) => setAt(e.target.value)} /></div>
      </div>
      <DashReading scope={who === 'renter' ? 'self-pickup' : 'one-screen'} id={booking} read={{ booking }} value={reading} onChange={setReading} onBusy={setReadingBusy} testId={`os-${kind}-reading`} />
      <div className="field"><label className="label" htmlFor={`os-${kind}-note`}>Note (optional)</label>
        <textarea className="textarea" id={`os-${kind}-note`} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} /></div>
      {who === 'staff' && pickup && isAdmin && <details><summary className="small link">Admin: without the deposit or the renter&apos;s signature</summary>
        <div className="field"><label className="label" htmlFor="os-dep">Deposit not taken: the reason it is waived</label><input className="input" id="os-dep" value={dep} onChange={(e) => setDep(e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor="os-sig">Without the renter&apos;s signature on the report: the reason</label><input className="input" id="os-sig" value={sig} onChange={(e) => setSig(e.target.value)} /></div></details>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={pending || busy > 0 || readingBusy} data-testid={`os-${kind}-go`}>{pending ? 'Saving' : who === 'renter' ? 'Check in' : pickup ? 'Check in on one screen' : 'Check out on one screen'}</button>
    </form>
  );
}
