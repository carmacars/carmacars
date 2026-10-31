'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { saveRegistration, uploadVehicleDocument } from '@/server/actions/vehicle-registration';

// A car's registration (migration 0237): the VIN (checked and decoded again), the year, the body style, the Ontario permit
// number and the plate sticker expiry (a fleet task 30 and 7 days before it); and the car's documents, the ownership permit
// first (it clears "Ownership permit" on the owner's checklist), and the Safety Standards Certificate with its number and dates
// (a fleet task 30 and 7 days before it expires).
export type RegistrationData = { vehicle_id: string; vin: string | null; year: number | null; body_type: string | null; trim: string | null;
  permit_number: string | null; sticker_expires_on: string | null;
  ssc?: { number: string | null; issued_on: string | null; expires_on: string | null }; documents: Array<{ id: string; kind: string; title: string; created_at: string; by: string | null }> };
const KINDS: Array<[string, string]> = [['ownership_permit', 'Ownership permit'], ['safety_certificate', 'Safety Standards Certificate'], ['owner_insurance_proof', 'Owner’s insurance'], ['other', 'Other document']];

export function Registration({ d }: { d: RegistrationData }) {
  const router = useRouter();
  const [f, setF] = useState({ vin: d.vin ?? '', year: d.year ? String(d.year) : '', body_type: d.body_type ?? '', permit_number: d.permit_number ?? '', sticker_expires_on: d.sticker_expires_on ?? '' });
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [kind, setKind] = useState('ownership_permit');
  const [file, setFile] = useState<File | null>(null);
  const [ssc, setSsc] = useState({ number: '', issued_on: '', expires_on: '' });
  const [up, setUp] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const field = (k: keyof typeof f, label: string, type = 'text', hint?: string) => (
    <div className="field ad-field"><label className="label" htmlFor={`reg-${k}`}>{label}</label>
      <input className="input" id={`reg-${k}`} type={type} value={f[k]} onChange={set(k)} data-testid={`reg-${k}`} />{hint && <p className="hint">{hint}</p>}</div>);
  return (
    <section className="pt-card ad-card stack" aria-labelledby="reg-h" data-testid="vehicle-registration">
      <div className="pt-card__head"><h2 className="d4" id="reg-h">Registration</h2></div>
      <div className="ad-fields">
        {field('vin', 'VIN', 'text', 'Checked (17 characters, the check digit, not on another car) and decoded again for the body style and trim.')}
        {field('year', 'Year', 'number')}
        {field('body_type', 'Body style', 'text', d.trim ? `Trim: ${d.trim}` : undefined)}
        {field('permit_number', 'Ontario permit number')}
        {field('sticker_expires_on', 'Plate sticker expires', 'date', 'Fleet gets a task 30 and 7 days before.')}
      </div>
      <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="reg-save" onClick={() => run(async () => {
        setMsg(null);
        const r = await saveRegistration({ vehicle_id: d.vehicle_id, ...f });
        setMsg(r.ok ? { ok: true, text: r.data.vin_changed ? `Saved. The VIN changed${r.data.decoded ? ' and was decoded again' : ''}.` : 'Saved.' } : { ok: false, text: r.message });
        if (r.ok) router.refresh();
      })}>{pending ? 'Saving' : 'Save the registration'}</button></div>
      {msg && <p className={`small${msg.ok ? '' : ' form-error'}`} role="status" data-testid="reg-msg">{msg.text}</p>}

      <h3 className="d4">Documents</h3>
      {d.documents.length ? <ul className="small" data-testid="reg-docs">{d.documents.map((x) => <li key={x.id}><a className="link" href={`/admin/documents/${x.id}`}>{x.title}</a> ({new Date(x.created_at).toLocaleDateString('en-CA')}{x.by ? `, ${x.by}` : ''})</li>)}</ul>
        : <p className="small muted">No document on the car yet.</p>}
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="reg-doc-kind">Document</label>
          <select className="input" id="reg-doc-kind" value={kind} onChange={(e) => setKind(e.target.value)} data-testid="reg-doc-kind">{KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
        <div className="field ad-field"><label className="label" htmlFor="reg-doc-file">Photo or PDF</label>
          <input className="input" id="reg-doc-file" type="file" accept="image/jpeg,image/png,application/pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} data-testid="reg-doc-file" /></div>
        {kind === 'safety_certificate' && <>
          <div className="field ad-field"><label className="label" htmlFor="reg-ssc-number">Certificate number</label>
            <input className="input" id="reg-ssc-number" value={ssc.number} onChange={(e) => setSsc((x) => ({ ...x, number: e.target.value }))} data-testid="reg-ssc-number" /></div>
          <div className="field ad-field"><label className="label" htmlFor="reg-ssc-issued">Issued on</label>
            <input className="input" id="reg-ssc-issued" type="date" value={ssc.issued_on} onChange={(e) => setSsc((x) => ({ ...x, issued_on: e.target.value }))} data-testid="reg-ssc-issued" /></div>
          <div className="field ad-field"><label className="label" htmlFor="reg-ssc-expires">Expires on</label>
            <input className="input" id="reg-ssc-expires" type="date" value={ssc.expires_on} onChange={(e) => setSsc((x) => ({ ...x, expires_on: e.target.value }))} data-testid="reg-ssc-expires" />
            <p className="hint">Fleet gets a task 30 and 7 days before.</p></div>
        </>}
      </div>
      {d.ssc?.expires_on && <p className="small" data-testid="reg-ssc">Safety Standards Certificate{d.ssc.number ? ` ${d.ssc.number}` : ''}: issued {d.ssc.issued_on ?? 'date not recorded'}, expires {d.ssc.expires_on}.</p>}
      <div className="row"><button className="btn btn--sm" type="button" disabled={pending} data-testid="reg-doc-upload" onClick={() => run(async () => {
        setUp(null);
        if (!file) { setUp({ ok: false, text: 'Choose the file first.' }); return; }
        const form = new FormData(); form.set('vehicle', d.vehicle_id); form.set('kind', kind); form.set('file', file);
        if (kind === 'safety_certificate') { form.set('number', ssc.number); form.set('issued_on', ssc.issued_on); form.set('expires_on', ssc.expires_on); }
        const r = await uploadVehicleDocument(form);
        setUp(r.ok ? { ok: true, text: 'Uploaded.' } : { ok: false, text: r.message });
        if (r.ok) { setFile(null); router.refresh(); }
      })}>Upload</button></div>
      {up && <p className={`small${up.ok ? '' : ' form-error'}`} role="status" data-testid="reg-doc-msg">{up.text}</p>}
    </section>
  );
}
