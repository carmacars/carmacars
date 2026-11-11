'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { DateInput } from '@/components/DateInput';
import { FUEL_LEVELS } from '@/features/returns/claim';
import { PhotoPicker } from './PhotoPicker';
import type { PickedPhoto } from './angles';
import { oneScreenHandover, selfPickup } from '@/server/actions/self-handover';

// One screen for a check-in or a check-out (migration 0545): the time (now unless changed), km, fuel, many photos at once
// with the suggested angles, a note; optional fields optional. Staff (Admin, Fleet, Sales, Customer service, field) on the
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
  const [km, setKm] = useState('');
  const [fuel, setFuel] = useState('');
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
    const ph = photos.map(({ bucket, path, angle }) => ({ bucket, path, angle }));
    if (who === 'renter') {
      const r = await selfPickup({ number, at: at ? new Date(at).toISOString() : undefined, odometer_km: km, fuel_pct: fuel, note, photos: ph });
      setMsg(r.ok ? { ok: true, text: r.data.status === 'applied' ? 'You are checked in. Drive safely: your photos and readings are on the check-in report.' : `Thank you, we have your photos and readings. Not finished by itself yet${r.data.reason ? `: ${r.data.reason}` : ''}. A team member confirms the pickup with you shortly.` } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
      return;
    }
    const r = await oneScreenHandover({ booking, kind, at, odometer_km: km, fuel_pct: fuel, note, photos: ph, deposit_waiver_reason: dep, signature_override_reason: sig, refresh });
    setMsg(r.ok ? { ok: true, text: pickup ? 'Checked in: the rental has started.' : 'Checked out: the trip is completed; the charges follow on the statement.' } : { ok: false, text: r.message });
    if (r.ok) { setPhotos([]); router.refresh(); }
  });
  return (
    <form className="stack" data-testid={`one-screen-${kind}`} onSubmit={(e) => { e.preventDefault(); go(); }}>
      <PhotoPicker scope={who === 'renter' ? 'self-pickup' : 'one-screen'} id={booking} photos={photos} onChange={setPhotos} onBusy={setBusy}
        label={who === 'renter' ? 'Photos of the car as you get it (all sides, odometer, fuel, inside, any damage)' : 'Photos (add to the renter\'s, if they took some)'} testId={`os-${kind}-photos`} />
      <div className="field-row">
        <div className="field"><label className="label" htmlFor={`os-${kind}-at`}>{pickup ? 'Picked up at' : 'Returned at'}</label>
          <DateInput className="input" id={`os-${kind}-at`} type="datetime-local" value={at} max={localNow()} onChange={(e) => setAt(e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor={`os-${kind}-km`}>Odometer (km)</label>
          <input className="input" id={`os-${kind}-km`} inputMode="numeric" value={km} onChange={(e) => setKm(e.target.value)} data-testid={`os-${kind}-km`} /></div>
        <div className="field"><label className="label" htmlFor={`os-${kind}-fuel`}>Fuel</label>
          <select className="input" id={`os-${kind}-fuel`} value={fuel} onChange={(e) => setFuel(e.target.value)} data-testid={`os-${kind}-fuel`}>
            <option value="">Not given</option>{FUEL_LEVELS.map(([l, p]) => <option key={l} value={String(p)}>{l}</option>)}</select></div>
      </div>
      <div className="field"><label className="label" htmlFor={`os-${kind}-note`}>Note (optional)</label>
        <textarea className="textarea" id={`os-${kind}-note`} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} /></div>
      {who === 'staff' && pickup && isAdmin && <details><summary className="small link">Admin: without the deposit or the renter&apos;s signature</summary>
        <div className="field"><label className="label" htmlFor="os-dep">Deposit not taken: the reason it is waived</label><input className="input" id="os-dep" value={dep} onChange={(e) => setDep(e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor="os-sig">Without the renter&apos;s signature on the report: the reason</label><input className="input" id="os-sig" value={sig} onChange={(e) => setSig(e.target.value)} /></div></details>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={pending || busy > 0} data-testid={`os-${kind}-go`}>{pending ? 'Saving' : who === 'renter' ? 'Check in' : pickup ? 'Check in on one screen' : 'Check out on one screen'}</button>
    </form>
  );
}
