'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { DateInput } from '@/components/DateInput';
import { staffDo } from '@/server/actions/staff-tools';
import { FUEL_LEVELS } from '@/features/returns/claim';
import { PhotoPicker } from './PhotoPicker';
import type { PickedPhoto } from './angles';

function localNow(): string {
  const d = new Date(Date.now() - new Date().getTimezoneOffset() * 60_000);
  return d.toISOString().slice(0, 16);
}

/** A new pickup from or return to the owner, or (addTo) more photos onto one. */
export function OwnerHandoffForm({ vehicleId, addTo, refresh = [] }: { vehicleId: string; addTo?: string; refresh?: string[] }) {
  const router = useRouter();
  const [kind, setKind] = useState<'pickup_from_owner' | 'return_to_owner'>('pickup_from_owner');
  const [at, setAt] = useState(localNow());
  const [km, setKm] = useState('');
  const [fuel, setFuel] = useState('');
  const [notes, setNotes] = useState('');
  const [photos, setPhotos] = useState<PickedPhoto[]>([]);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const save = () => start(async () => {
    const ph = photos.map(({ bucket, path, angle }) => ({ bucket, path, angle }));
    const r = await staffDo('owner_handoff_save', addTo ? { vehicle: vehicleId, id: addTo, photos: ph, notes }
      : { vehicle: vehicleId, kind, at: at ? new Date(at).toISOString() : null, odometer_km: km.replace(/[\s,]/g, '') || null, fuel_pct: fuel || null, notes, photos: ph }, refresh);
    setMsg(r.ok ? { ok: true, text: 'Saved.' } : { ok: false, text: r.message });
    if (r.ok) { setPhotos([]); setNotes(''); router.refresh(); }
  });
  return (
    <details data-testid={addTo ? 'owner-handoff-add' : 'owner-handoff-new'}>
      <summary className={addTo ? 'small link' : 'btn btn--ghost btn--sm'}>{addTo ? 'Add photos' : 'Record a pickup from or return to the owner'}</summary>
      <div className="stack">
        {!addTo && <div className="field-row">
          <div className="field"><label className="label" htmlFor={`ohf-kind-${vehicleId}`}>What</label>
            <select className="input" id={`ohf-kind-${vehicleId}`} value={kind} onChange={(e) => setKind(e.target.value as typeof kind)}>
              <option value="pickup_from_owner">Pickup from owner</option><option value="return_to_owner">Return to owner</option></select></div>
          <div className="field"><label className="label" htmlFor={`ohf-at-${vehicleId}`}>When</label>
            <DateInput className="input" id={`ohf-at-${vehicleId}`} type="datetime-local" value={at} max={localNow()} onChange={(e) => setAt(e.target.value)} /></div>
          <div className="field"><label className="label" htmlFor={`ohf-km-${vehicleId}`}>Odometer (km)</label>
            <input className="input" id={`ohf-km-${vehicleId}`} inputMode="numeric" value={km} onChange={(e) => setKm(e.target.value)} /></div>
          <div className="field"><label className="label" htmlFor={`ohf-fuel-${vehicleId}`}>Fuel</label>
            <select className="input" id={`ohf-fuel-${vehicleId}`} value={fuel} onChange={(e) => setFuel(e.target.value)}>
              <option value="">Not given</option>{FUEL_LEVELS.map(([l, p]) => <option key={l} value={String(p)}>{l}</option>)}</select></div>
        </div>}
        <PhotoPicker scope="owner-handoff" id={vehicleId} photos={photos} onChange={setPhotos} max={60} testId={addTo ? `ohf-photos-${addTo}` : `ohf-photos-${vehicleId}`} />
        <div className="field"><label className="label" htmlFor={`ohf-notes-${addTo ?? vehicleId}`}>Notes</label>
          <textarea className="textarea" id={`ohf-notes-${addTo ?? vehicleId}`} maxLength={2000} value={notes} onChange={(e) => setNotes(e.target.value)} /></div>
        {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
        <button className="btn btn--primary btn--sm" type="button" disabled={pending || (!!addTo && !photos.length)} onClick={save}>{pending ? 'Saving' : 'Save'}</button>
      </div>
    </details>
  );
}
