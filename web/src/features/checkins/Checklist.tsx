'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toStandardImage } from '@/features/uploads/standard-image';
import { opsAct } from '@/server/actions/ops';
import { CHECKIN_ANGLES, issuesOf, missingAngles, serviceWords, type NextService, type Photo } from './model';
import './checkins.css';

// The check-in visit checklist (release 50, migration 4000): short and guided, on a phone at the car. Five photos (the four
// sides and the odometer), the odometer reading, any new damage, the tire tread, fluids and warning lights, notes. The
// database writes the reading and the tread into the maintenance tracker, raises a Fleet To do when something needs
// looking after, and logs a damage intake for the Admins when damage is found.
export function CheckinChecklist({ visitId, bookingId, currentKm, next, refresh }: { visitId: string; bookingId: string; currentKm: number | null; next: NextService | null; refresh: string[] }) {
  const router = useRouter();
  const [photos, setPhotos] = useState<Photo[]>([]);
  const [uploading, setUploading] = useState<string | null>(null);
  const [km, setKm] = useState('');
  const [damage, setDamage] = useState<boolean | null>(null);
  const [damageNote, setDamageNote] = useState('');
  const [tread, setTread] = useState('');
  const [fluids, setFluids] = useState<boolean | null>(null);
  const [lights, setLights] = useState('');
  const [notes, setNotes] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const missing = missingAngles(photos);
  const treadN = tread.trim() === '' ? null : Number(tread);
  const found = issuesOf({ tread_mm: treadN, fluids_ok: fluids, warning_lights: lights, next });

  async function upload(angle: string, file: File | undefined) {
    if (!file) return;
    setUploading(angle); setMsg(null);
    try {
      const fd = new FormData();
      fd.append('file', await toStandardImage(file), 'photo.jpg'); fd.append('scope', 'checkin'); fd.append('id', bookingId);
      const r = await fetch('/api/handover-photo', { method: 'POST', body: fd });
      const j = (await r.json().catch(() => ({}))) as { ok?: boolean; bucket?: string; path?: string; message?: string };
      if (!j.ok || !j.path) throw new Error(j.message ?? 'The photo could not be uploaded.');
      setPhotos((p) => [...p.filter((x) => x.angle !== angle), { angle, bucket: j.bucket ?? 'condition-photos', path: j.path! }]);
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : 'The photo could not be uploaded.' }); }
    finally { setUploading(null); }
  }

  function submit(e: React.FormEvent) {
    e.preventDefault();
    if (pending) return;
    start(async () => {
      const r = await opsAct<{ issues: string[] }>('checkin_do', {
        op: 'complete', id: visitId, photos, odometer_km: km.trim() === '' ? null : Number(km), damage_found: damage, damage_note: damageNote,
        tread_mm: treadN, fluids_ok: fluids, warning_lights: lights, notes
      }, refresh);
      if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
      const n = r.data.issues?.length ?? 0;
      setMsg({ ok: true, text: `Visit saved.${n ? ` A To do is raised for: ${r.data.issues.join('; ')}.` : ' Nothing to look after.'}${damage ? ' The damage is logged for the Admins.' : ''}` });
      router.refresh();
    });
  }

  const yesNo = (name: string, v: boolean | null, set: (b: boolean) => void, yes: string, no: string) => (
    <div className="row ci-modes" role="radiogroup">
      <label className="check"><input type="radio" name={name} checked={v === true} onChange={() => set(true)} data-testid={`${name}-yes`} /> <span>{yes}</span></label>
      <label className="check"><input type="radio" name={name} checked={v === false} onChange={() => set(false)} data-testid={`${name}-no`} /> <span>{no}</span></label>
    </div>);

  return (
    <form className="ci-check" onSubmit={submit} data-testid="checkin-checklist" data-guide="checkin-checklist" data-sent={msg?.ok ? 'yes' : 'no'}>
      <fieldset className="field" style={{ border: 0, padding: 0, margin: 0 }} data-guide="checkin-photos">
        <legend className="label">1. Photos: the four sides and the odometer ({CHECKIN_ANGLES.length - missing.length} of {CHECKIN_ANGLES.length})</legend>
        <div className="ci-photos">{CHECKIN_ANGLES.map(([k, l]) => {
          const have = photos.some((p) => p.angle === k);
          return (
            <label key={k} className="ci-photo pt-card" htmlFor={`ci-ph-${k}`}>
              <b className="small">{l}</b>
              <input id={`ci-ph-${k}`} type="file" accept="image/*" capture="environment" onChange={(e) => { void upload(k, e.target.files?.[0]); e.target.value = ''; }} data-testid={`checkin-photo-${k}`} />
              <span className={`small ci-photo__state ${have ? '' : 'muted'}`} data-testid={`checkin-photo-${k}-state`}>{uploading === k ? 'Uploading' : have ? 'Added' : 'Not yet'}</span>
            </label>);
        })}</div>
      </fieldset>
      <div className="field" data-guide="checkin-odometer">
        <label className="label" htmlFor="ci-km">2. Odometer (km)</label>
        <input className="input" id="ci-km" inputMode="numeric" pattern="[0-9]*" value={km} onChange={(e) => setKm(e.target.value.replace(/[^0-9]/g, ''))} data-testid="checkin-km" data-guide="checkin-km" />
        <p className="small muted">{currentKm ? `Last reading ${currentKm.toLocaleString('en-CA')} km. ` : ''}Next service: {serviceWords(next)}.</p>
      </div>
      <div className="field" data-guide="checkin-damage">
        <span className="label">3. Any new damage?</span>
        {yesNo('checkin-damage', damage, setDamage, 'Yes', 'No new damage')}
        {damage && <textarea className="input" rows={2} maxLength={1000} value={damageNote} onChange={(e) => setDamageNote(e.target.value)} placeholder="Where and what, for example: scratch on the rear bumper, left side" aria-label="The damage" data-testid="checkin-damage-note" />}
      </div>
      <div className="field" data-guide="checkin-tread">
        <label className="label" htmlFor="ci-tread">4. Tire tread (mm, the lowest)</label>
        <input className="input" id="ci-tread" inputMode="decimal" value={tread} onChange={(e) => setTread(e.target.value.replace(/[^0-9.]/g, ''))} placeholder="For example 6" data-testid="checkin-tread" />
      </div>
      <div className="field" data-guide="checkin-fluids">
        <span className="label">5. Fluids look right (oil, coolant, washer)?</span>
        {yesNo('checkin-fluids', fluids, setFluids, 'Yes', 'No, to check')}
        <label className="label" htmlFor="ci-lights">Warning lights on the dashboard</label>
        <input className="input" id="ci-lights" maxLength={300} value={lights} onChange={(e) => setLights(e.target.value)} placeholder="None" data-testid="checkin-lights" />
      </div>
      <div className="field">
        <label className="label" htmlFor="ci-notes">6. Notes (optional)</label>
        <textarea className="input" id="ci-notes" rows={3} maxLength={2000} value={notes} onChange={(e) => setNotes(e.target.value)} data-testid="checkin-notes" />
      </div>
      {found.length > 0 && <p className="alert alert--warn" role="status" data-testid="checkin-issues"><span>Saving raises a Fleet To do for: {found.join('; ')}.</span></p>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--warn'}`} role={msg.ok ? 'status' : 'alert'} data-testid="checkin-msg"><span>{msg.text}</span></p>}
      <p><button type="submit" className="btn btn--primary" disabled={pending || !!uploading || missing.length > 0 || !km || damage === null || fluids === null} title={missing.length ? 'Add the missing photos first' : !km ? 'Enter the odometer first' : damage === null || fluids === null ? 'Answer the damage and warning-light questions first' : undefined} data-testid="checkin-save" data-guide="checkin-save">
        {pending ? 'Saving' : missing.length ? `Add ${missing.length} more photo${missing.length > 1 ? 's' : ''}` : 'Save the visit'}</button></p>
    </form>
  );
}
