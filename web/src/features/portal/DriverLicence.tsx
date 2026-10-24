'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { driverLicenceSave, driverLicenceUpload } from '@/server/actions/driver-licence';
import { reencode } from './UploadCard';
import type { LicenceStatus } from '@/features/handover/types';

// The additional driver's licence on their signing link (migration 0130): the details, then the front, the back and a
// selfie holding it, each taken with the phone's camera and re-encoded in the browser (no location data kept).
const KINDS: Array<[string, string, string]> = [['licence_front', 'Licence, front', 'environment'], ['licence_back', 'Licence, back', 'environment'], ['selfie', 'Selfie with your licence', 'user']];
const STATE: Record<string, string> = { submitted: 'In review', approved: 'Verified', rejected: 'Needs a new photo' };

export function DriverLicence({ token, l, selfie }: { token: string; l: LicenceStatus; selfie: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [d, setD] = useState({ licence_number: '', licence_issuer: 'ON', licence_expiry: l.expiry ?? '' });
  const up = (kind: string, f: File | undefined) => {
    if (!f) return;
    start(async () => {
      setErr(null);
      let body: Blob = f;
      try { body = await reencode(f); } catch { /* keep the original */ }
      const fd = new FormData(); fd.set('kind', kind); fd.set('file', body, `${kind}.jpg`);
      const r = await driverLicenceUpload(token, fd);
      if (!r.ok) setErr(r.message); else router.refresh();
    });
  };
  return (
    <section className="pt-card stack" aria-labelledby="dl-t" data-testid="driver-licence">
      <h2 className="d4" id="dl-t">Your driver&apos;s licence</h2>
      <p className="small">{l.complete ? 'Received. Our team checks it before pickup.' : `Still needed: ${l.missing.join(', ')}.`}</p>
      {!l.expiry_ok && (
        <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); start(async () => { const r = await driverLicenceSave(token, d); if (!r.ok) setErr(r.message); else router.refresh(); }); }}>
          <div className="field-row">
            <div className="field"><label className="label" htmlFor="dl-num">Licence number</label><input className="input" id="dl-num" value={d.licence_number} onChange={(e) => setD({ ...d, licence_number: e.target.value })} data-testid="dl-number" /></div>
            <div className="field"><label className="label" htmlFor="dl-exp">Expiry date</label><input className="input" id="dl-exp" type="date" value={d.licence_expiry} onChange={(e) => setD({ ...d, licence_expiry: e.target.value })} data-testid="dl-expiry" /></div>
          </div>
          <div className="field"><label className="label" htmlFor="dl-iss">Issued by</label>
            <select className="select" id="dl-iss" value={d.licence_issuer} onChange={(e) => setD({ ...d, licence_issuer: e.target.value })}>{[['ON', 'Ontario'], ['QC', 'Quebec'], ['BC', 'British Columbia'], ['AB', 'Alberta'], ['US', 'United States'], ['OTHER', 'Another province or country']].map(([c, t]) => <option key={c} value={c}>{t}</option>)}</select></div>
          <button className="btn btn--ghost" type="submit" disabled={pending} data-testid="dl-save">Save the licence details</button>
        </form>
      )}
      <div className="pt-uploads">
        {KINDS.filter(([k]) => k !== 'selfie' || selfie).map(([k, t, cam]) => {
          const st = (l as unknown as Record<string, string | null>)[k];
          return (
            <div key={k} className="pt-up" data-testid={`dl-${k}`}>
              <div className="pt-card__head"><h3 className="d4">{t}</h3>{st && <span className={`badge ${st === 'approved' ? '' : st === 'rejected' ? 'badge--red' : 'badge--outline'}`}>{STATE[st] ?? st}</span>}</div>
              <label className="btn btn--ghost btn--sm">{pending ? 'Uploading' : st && st !== 'rejected' ? 'Replace' : 'Take or choose a photo'}
                <input className="vh" type="file" accept="image/*" capture={cam as 'user' | 'environment'} onChange={(e) => { up(k, e.target.files?.[0]); e.target.value = ''; }} data-testid={`dl-file-${k}`} /></label>
            </div>
          );
        })}
      </div>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </section>
  );
}
